//! What a prompt says about the connection, read from the session's
//! catalog: never a row.

use std::sync::Arc;

use tablepro_ai::{ColumnShape, MAX_DESCRIBED_TABLES, QueryLanguage, SchemaContext, TableShape};
use tablepro_core::meta::{ObjectInfo, ObjectScope};
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::LexicalSettings;
use tablepro_core::{ColumnInfo, TableRef};
use tablepro_session::Session;

use crate::ui::editor::{CompletionScope, read_catalog, tables_named};

/// The schema the user is in, its tables, and the structure of the
/// tables `text` names. Shares the catalog's reads with the sidebar and
/// completion, so it rarely reaches the server.
pub(crate) async fn read(session: Arc<Session>, engine: String, text: String) -> SchemaContext {
    let grammar = session
        .current_dialect()
        .map_or(SqlGrammar::PostgreSql, |dialect| dialect.grammar());
    let language = if grammar.is_sql() {
        QueryLanguage::Sql
    } else {
        QueryLanguage::Commands
    };
    let mut named = tables_named(&text, grammar, LexicalSettings::default_for(grammar));
    // A question in words names tables as words, which no SQL parse sees.
    if let Ok(objects) = session.objects(ObjectScope::DefaultSchema).await {
        for table in named_in_words(&text, &objects) {
            if !named.contains(&table) {
                named.push(table);
            }
        }
    }
    named.truncate(MAX_DESCRIBED_TABLES);
    let answer = read_catalog(
        session.clone(),
        CompletionScope::General {
            tables_in_statement: named,
        },
    )
    .await;
    let schema = session.schemas().await.ok().and_then(|schemas| {
        schemas
            .iter()
            .find(|schema| schema.is_default)
            .map(|schema| schema.name.clone())
    });
    let tables = answer
        .objects
        .map(|objects| {
            objects
                .iter()
                .filter(|object| object.kind.is_browsable())
                .map(|object| object.name.clone())
                .collect()
        })
        .unwrap_or_default();
    let described = answer
        .columns
        .into_iter()
        .filter(|(_, columns)| !columns.is_empty())
        .map(|(table, columns)| shape(&table, schema.as_deref(), &columns))
        .collect();
    SchemaContext {
        engine,
        language,
        database: session.database().map(str::to_owned),
        schema,
        tables,
        described,
    }
}

/// The tables and views of `objects` whose names stand in `text` as
/// words, ignoring case, in the order the catalog lists them.
fn named_in_words(text: &str, objects: &[ObjectInfo]) -> Vec<TableRef> {
    let words: std::collections::HashSet<String> = text
        .split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .filter(|word| !word.is_empty())
        .map(str::to_lowercase)
        .collect();
    objects
        .iter()
        .filter(|object| object.kind.is_browsable() && words.contains(&object.name.to_lowercase()))
        .map(|object| TableRef::new(object.schema.clone(), object.name.clone()))
        .collect()
}

/// A table in the schema the user is in goes by its name alone, as the
/// statement names it.
fn shape(table: &TableRef, default_schema: Option<&str>, columns: &[ColumnInfo]) -> TableShape {
    let name = match table.schema.as_deref() {
        Some(schema) if Some(schema) != default_schema => format!("{schema}.{}", table.name),
        _ => table.name.clone(),
    };
    TableShape {
        name,
        columns: columns
            .iter()
            .map(|column| ColumnShape {
                name: column.name.clone(),
                type_name: column.column_type.name.clone(),
                nullable: column.nullable,
                primary_key: column.primary_key,
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnDefault, ColumnType};

    use super::*;

    fn column(name: &str, primary_key: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::untyped_text("integer"),
            nullable: !primary_key,
            primary_key,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    #[test]
    fn a_question_in_words_names_the_tables_it_mentions() {
        let object = |name: &str, kind| ObjectInfo {
            schema: Some("public".to_owned()),
            name: name.to_owned(),
            kind,
        };
        let objects = [
            object("orders", tablepro_core::meta::ObjectKind::Table),
            object("Customers", tablepro_core::meta::ObjectKind::View),
            object("order_total", tablepro_core::meta::ObjectKind::Function),
            object("items", tablepro_core::meta::ObjectKind::Table),
        ];

        let named = named_in_words("Which customers have open orders? order_total too.", &objects);

        assert_eq!(
            named,
            [
                TableRef::new(Some("public".to_owned()), "orders"),
                TableRef::new(Some("public".to_owned()), "Customers"),
            ]
        );
    }

    #[test]
    fn a_table_outside_the_default_schema_keeps_its_schema() {
        let columns = [column("id", true), column("total", false)];

        let here = shape(
            &TableRef::new(Some("public".to_owned()), "orders"),
            Some("public"),
            &columns,
        );
        let there = shape(
            &TableRef::new(Some("audit".to_owned()), "log"),
            Some("public"),
            &columns,
        );

        assert_eq!(here.name, "orders");
        assert_eq!(there.name, "audit.log");
        assert_eq!(here.columns[0].type_name, "integer");
        assert!(here.columns[0].primary_key);
        assert!(here.columns[1].nullable);
    }
}
