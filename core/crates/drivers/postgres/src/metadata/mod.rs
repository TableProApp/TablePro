//! The catalogue reads behind the sidebar, the grid and the structure
//! tab. Every statement projects built-in types only, so none of them
//! makes tokio-postgres look a type up with a named statement.

mod database_choices;
mod definitions;
mod estimate;
mod foreign_keys;
mod identity;
mod indexes;
mod objects;
mod table_info;

pub(crate) use database_choices::database_choices;
pub(crate) use definitions::fetch_object_definition;
pub(crate) use estimate::table_estimate;
pub(crate) use foreign_keys::{fetch_foreign_keys, fetch_outbound_foreign_keys};
pub(crate) use identity::row_identity;
pub(crate) use indexes::{fetch_indexes, in_tablespace, without_only};
pub(crate) use objects::{list_databases, list_objects, list_schemas};
pub(crate) use table_info::table_info;

use futures_util::TryStreamExt;
use postgres_types::{ToSql, Type};
use tablepro_core::DriverError;
use tablepro_core::column::ColumnInfo;
use tablepro_core::ddl::{InboundForeignKey, PrimaryKeyConstraint, TableDefinition};
use tablepro_core::meta::TableRef;
use tokio_postgres::{Client, Row};

use crate::catalog::{
    COLUMNS_SQL, PRIMARY_KEY_NAME_SQL, PgColumnRow, column_definition, column_info, inbound_foreign_key,
    inbound_foreign_keys_sql,
};
use crate::catalog_release::CatalogRelease;
use crate::codec::TextArray;
use crate::errors::map_error;

/// Rows of a catalogue query whose parameters are all text.
pub(crate) async fn text_rows(client: &Client, sql: &str, params: &[&str]) -> Result<Vec<Row>, DriverError> {
    let typed: Vec<(&(dyn ToSql + Sync), Type)> = params
        .iter()
        .map(|param| (param as &(dyn ToSql + Sync), Type::TEXT))
        .collect();
    let stream = client
        .query_typed_raw(sql, typed)
        .await
        .map_err(|error| map_error(&error))?;
    stream.try_collect().await.map_err(|error| map_error(&error))
}

pub(crate) fn decode_error(table: &'static str) -> impl Fn(tokio_postgres::Error) -> DriverError {
    move |error| DriverError::Decode {
        column: table.to_owned(),
        detail: error.to_string(),
    }
}

/// `relation` is the table's quoted, qualified name, which `::regclass`
/// resolves the same way the server resolves it in a query.
pub(crate) async fn fetch_columns(
    client: &Client,
    release: CatalogRelease,
    relation: &str,
) -> Result<Vec<ColumnInfo>, DriverError> {
    column_rows(client, release, relation)
        .await
        .map(|rows| rows.iter().map(column_info).collect())
}

async fn column_rows(
    client: &Client,
    release: CatalogRelease,
    relation: &str,
) -> Result<Vec<PgColumnRow>, DriverError> {
    text_rows(client, &release.render(COLUMNS_SQL), &[relation])
        .await?
        .iter()
        .map(PgColumnRow::from_row)
        .collect()
}

pub(crate) async fn fetch_inbound_foreign_keys(
    client: &Client,
    release: CatalogRelease,
    relation: &str,
) -> Result<Vec<InboundForeignKey>, DriverError> {
    text_rows(client, &inbound_foreign_keys_sql(release), &[relation])
        .await?
        .iter()
        .map(inbound_foreign_key)
        .collect()
}

pub(crate) async fn fetch_table_definition(
    client: &Client,
    release: CatalogRelease,
    table: &TableRef,
    relation: &str,
) -> Result<TableDefinition, DriverError> {
    // Every query is sent before the first answer is awaited, so all of
    // them run inside the flight's transaction, ahead of its COMMIT.
    let params = [relation];
    let (columns, primary_key, mut indexes, mut statements, foreign_keys, inbound_foreign_keys) = futures_util::try_join!(
        column_rows(client, release, relation),
        text_rows(client, PRIMARY_KEY_NAME_SQL, &params),
        fetch_indexes(client, release, relation),
        indexes::fetch_index_statements(client, relation),
        fetch_foreign_keys(client, release, relation),
        fetch_inbound_foreign_keys(client, release, relation),
    )?;
    for index in &mut indexes {
        index.definition = statements.remove(&index.name);
    }
    let primary_key = primary_key
        .first()
        .map(|row| -> Result<PrimaryKeyConstraint, DriverError> {
            let field = decode_error("pg_constraint");
            Ok(PrimaryKeyConstraint {
                name: Some(row.try_get(0).map_err(&field)?),
                columns: row.try_get::<_, TextArray>(1).map_err(&field)?.0,
            })
        })
        .transpose()?;
    Ok(TableDefinition {
        table: table.clone(),
        columns: columns.iter().map(column_definition).collect(),
        primary_key,
        indexes,
        foreign_keys,
        inbound_foreign_keys,
        // PostgreSQL has no statement that prints a table's own DDL.
        source: None,
        options: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog_release::SUPPORTED;
    use crate::dump::catalog_sql as dump;

    /// Words that take a parenthesis without calling a function by name.
    const SYNTAX: [&str; 16] = [
        "AS", "ARRAY", "COALESCE", "EXISTS", "FROM", "IN", "ANY", "NULLIF", "GREATEST", "ON", "AND", "OR", "NOT",
        "OPERATOR", "LATERAL", "SELECT",
    ];

    /// Names called without `pg_catalog.` in front, which the session's
    /// search_path would resolve. An alias's column list after AS is no
    /// call, and neither is text in a string.
    fn bare_calls(sql: &str) -> Vec<String> {
        let mut code = String::with_capacity(sql.len());
        let mut quoted = false;
        for c in sql.chars() {
            if c == '\'' {
                quoted = !quoted;
            }
            code.push(if quoted { ' ' } else { c });
        }
        let mut words: Vec<(usize, usize)> = Vec::new();
        let mut start = None;
        for (index, c) in code.char_indices().chain([(code.len(), ' ')]) {
            match (start, c.is_ascii_alphanumeric() || c == '_') {
                (None, true) => start = Some(index),
                (Some(from), false) => {
                    words.push((from, index));
                    start = None;
                }
                _ => {}
            }
        }
        let mut calls = Vec::new();
        for (nth, &(from, to)) in words.iter().enumerate() {
            let word = &code[from..to];
            let calls_it = code[to..].trim_start().starts_with('(');
            let qualified = code[..from].ends_with('.');
            let after_as = nth > 0 && code[words[nth - 1].0..words[nth - 1].1].eq_ignore_ascii_case("AS");
            let syntax = SYNTAX.iter().any(|keyword| keyword.eq_ignore_ascii_case(word));
            if calls_it && !qualified && !after_as && !syntax {
                calls.push(word.to_owned());
            }
        }
        calls
    }

    /// Every catalog statement the driver sends, rendered for `release`.
    fn catalog_statements(release: CatalogRelease) -> Vec<(&'static str, String)> {
        let rendered = [
            ("schemas", objects::SCHEMAS_SQL),
            ("objects", objects::OBJECTS_SQL),
            ("databases", objects::DATABASES_SQL),
            ("owners", database_choices::OWNERS_SQL),
            ("templates", database_choices::TEMPLATES_SQL),
            ("locales", database_choices::LOCALES_SQL),
            ("database defaults", database_choices::DEFAULTS_SQL),
            ("function definitions", definitions::FUNCTIONS_SQL),
            ("sequence definition", definitions::SEQUENCE_SQL),
            ("trigger definition", definitions::TRIGGER_SQL),
            ("identity", identity::IDENTITY_SQL),
            ("indexes", indexes::INDEXES_SQL),
            ("index statements", indexes::INDEX_STATEMENTS_SQL),
            ("estimate", estimate::ESTIMATE_SQL),
            ("table info", table_info::TABLE_INFO_SQL),
            ("primary key", PRIMARY_KEY_NAME_SQL),
            ("columns", COLUMNS_SQL),
            ("result origin", crate::editor::ORIGIN_SQL),
            ("dump schemas", dump::SCHEMAS_SQL),
            ("dump extensions", dump::EXTENSIONS_SQL),
            ("dump collations", dump::COLLATIONS_SQL),
            ("dump types", dump::TYPES_SQL),
            ("dump domain checks", dump::DOMAIN_CHECKS_SQL),
            ("dump functions", dump::FUNCTIONS_SQL),
            ("dump sequences", dump::SEQUENCES_SQL),
            ("dump tables", dump::TABLES_SQL),
            ("dump columns", dump::COLUMNS_SQL),
            ("dump constraints", dump::CONSTRAINTS_SQL),
            ("dump indexes", dump::INDEXES_SQL),
            ("dump views", dump::VIEWS_SQL),
            ("dump triggers", dump::TRIGGERS_SQL),
        ]
        .map(|(name, sql)| (name, release.render(sql)));
        rendered
            .into_iter()
            .chain([
                ("foreign keys", foreign_keys::foreign_keys_sql(release)),
                ("inbound foreign keys", inbound_foreign_keys_sql(release)),
            ])
            .collect()
    }

    #[test]
    fn every_catalog_read_names_its_functions_in_pg_catalog() {
        for release in SUPPORTED {
            for (name, sql) in catalog_statements(release) {
                assert_eq!(bare_calls(&sql), Vec::<String>::new(), "{name} on {release:?}");
            }
        }
    }

    #[test]
    fn every_placeholder_is_rendered_for_every_release() {
        for release in SUPPORTED {
            for (name, sql) in catalog_statements(release) {
                assert!(!sql.contains('{') && !sql.contains('}'), "{name} on {release:?}: {sql}");
            }
        }
    }

    #[test]
    fn a_release_reads_no_column_it_does_not_have() {
        let added = [
            (
                11,
                ["p.prokind", "i.indnkeyatts", "c.conparentid", "k.conparentid"].as_slice(),
            ),
            (12, ["a.attgenerated"].as_slice()),
            (13, ["t.tgparentid"].as_slice()),
            (14, ["a.attcompression", "p.prosqlbody"].as_slice()),
        ];
        for release in SUPPORTED {
            for (name, sql) in catalog_statements(release) {
                for (since, columns) in added {
                    for column in columns {
                        let reads = sql.contains(column);
                        assert!(
                            release >= CatalogRelease::new(since) || !reads,
                            "{name} on {release:?} reads {column}"
                        );
                    }
                }
                assert!(!sql.contains("starts_with"), "{name}");
                assert!(!sql.contains(".collisdeterministic"), "{name}");
            }
        }
    }

    #[test]
    fn a_bare_call_is_found_and_a_qualified_one_or_an_alias_is_not() {
        assert_eq!(
            bare_calls("SELECT unnest(a), pg_catalog.unnest(b), COALESCE(x, 'f(y)') FROM t AS k(a, b)"),
            ["unnest"]
        );
    }
}
