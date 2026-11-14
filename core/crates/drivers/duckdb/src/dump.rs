//! A DuckDB file as one SQL dump, in the order EXPORT DATABASE writes
//! its schema.sql: schemas, sequences, enum types, tables with their
//! foreign keys inline, the rows, indexes, macros, views, and the
//! triggers EXPORT leaves out. Names carry their schema and never the
//! catalog, which is the file's own name.

use std::collections::HashMap;

use duckdb::types::Value as DuckValue;
use tablepro_core::DriverError;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::dump::{
    DumpCatalog, DumpDialect, DumpObject, DumpObjectKind, DumpScope, DumpSection, DumpSkip, DumpSkipReason,
    DumpStatement, DumpTable,
};
use tablepro_core::meta::TableRef;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptToken, ScriptTokenKind};

use crate::catalog::DEFAULT_SCHEMA;
use crate::dialect::DuckDbDialect;
use crate::errors::map_error;
use crate::instance::Link;

impl DumpDialect for DuckDbDialect {
    fn header(&self) -> String {
        "BEGIN TRANSACTION;\n".to_owned()
    }

    fn footer(&self) -> String {
        "\nCOMMIT;\n".to_owned()
    }

    fn transactional_ddl(&self) -> bool {
        true
    }

    fn begin(&self) -> &'static str {
        "BEGIN TRANSACTION"
    }
}

// Each query takes the catalog, then the schema twice, which is NULL for
// the whole database.
const SCHEMAS_SQL: &str = "SELECT schema_name FROM duckdb_schemas() \
     WHERE database_name = ? AND (? IS NULL OR schema_name = ?) AND NOT internal \
     ORDER BY schema_name";

const SEQUENCES_SQL: &str = "SELECT schema_name, sequence_name, increment_by, min_value, max_value, cycle, sql \
     FROM duckdb_sequences() \
     WHERE database_name = ? AND (? IS NULL OR schema_name = ?) AND NOT temporary \
     ORDER BY schema_name, sequence_name";

/// A type is listed once per constructor, and only its first row has
/// the oid.
const ENUMS_SQL: &str = "SELECT schema_name, type_name, labels FROM duckdb_types() \
     WHERE database_name = ? AND (? IS NULL OR schema_name = ?) AND NOT internal \
       AND logical_type = 'ENUM' AND type_oid IS NOT NULL \
     ORDER BY schema_name, type_name";

const TABLES_SQL: &str = "SELECT schema_name, table_name, sql FROM duckdb_tables() \
     WHERE database_name = ? AND (? IS NULL OR schema_name = ?) AND NOT internal AND NOT temporary \
     ORDER BY schema_name, table_name";

/// DuckDB keeps a foreign key's parent in the child's schema. One row
/// per child, not per key, which would repeat the child's name.
const FOREIGN_KEYS_SQL: &str = "SELECT schema_name, table_name, \
            list(referenced_table ORDER BY constraint_index) \
     FROM duckdb_constraints() \
     WHERE database_name = ? AND (? IS NULL OR schema_name = ?) AND constraint_type = 'FOREIGN KEY' \
     GROUP BY schema_name, table_name ORDER BY schema_name, table_name";

/// The index behind a PRIMARY KEY or UNIQUE has no text: its table's
/// CREATE makes it.
const INDEXES_SQL: &str = "SELECT schema_name, index_name, sql FROM duckdb_indexes() \
     WHERE database_name = ? AND (? IS NULL OR schema_name = ?) AND sql IS NOT NULL \
     ORDER BY schema_name, index_name";

/// A macro's overloads come one row each, in the order they were
/// declared, which an ORDER BY would not keep.
const MACROS_SQL: &str = "SELECT schema_name, function_name, function_type, parameters, parameter_types, \
            macro_definition \
     FROM duckdb_functions() \
     WHERE database_name = ? AND (? IS NULL OR schema_name = ?) AND NOT internal \
       AND function_type IN ('macro', 'table_macro')";

const VIEWS_SQL: &str = "SELECT schema_name, view_name, sql FROM duckdb_views() \
     WHERE database_name = ? AND (? IS NULL OR schema_name = ?) AND NOT internal AND NOT temporary \
     ORDER BY schema_name, view_name";

const TRIGGERS_SQL: &str = "SELECT schema_name, trigger_name, sql FROM duckdb_triggers() \
     WHERE database_name = ? AND (? IS NULL OR schema_name = ?) AND NOT temporary \
     ORDER BY schema_name, trigger_name";

struct Reader<'a> {
    link: &'a Link,
    catalog: &'a str,
    schema: Option<&'a str>,
}

impl Reader<'_> {
    fn rows<T>(
        &self,
        sql: &str,
        read: impl FnMut(&duckdb::Row<'_>) -> duckdb::Result<T>,
    ) -> Result<Vec<T>, DriverError> {
        let mut statement = self.link.connection.prepare(sql).map_err(map_error)?;
        let rows = statement
            .query_map(duckdb::params![self.catalog, self.schema, self.schema], read)
            .map_err(map_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_error)
    }

    fn named(&self, sql: &str) -> Result<Vec<Named>, DriverError> {
        self.rows(sql, |row| {
            Ok(Named {
                schema: row.get(0)?,
                name: row.get(1)?,
                sql: row
                    .get::<_, Option<String>>(2)?
                    .map(|sql| without_catalog(&sql, self.catalog)),
            })
        })
    }
}

struct Named {
    schema: String,
    name: String,
    sql: Option<String>,
}

impl Named {
    fn text(&self) -> Option<&str> {
        self.sql.as_deref().filter(|sql| !sql.trim().is_empty())
    }

    fn skip(&self, kind: DumpObjectKind) -> DumpSkip {
        DumpSkip {
            kind,
            schema: Some(self.schema.clone()),
            name: self.name.clone(),
            reason: DumpSkipReason::NoDefinition,
        }
    }
}

struct Sequence {
    schema: String,
    name: String,
    increment: i64,
    min: i64,
    max: i64,
    cycle: bool,
    sql: String,
}

struct MacroOverload {
    schema: String,
    name: String,
    table: bool,
    parameters: Vec<(String, Option<String>)>,
    definition: Option<String>,
}

pub(crate) fn read_dump_catalog(link: &Link, catalog: &str, scope: &DumpScope) -> Result<DumpCatalog, DriverError> {
    let reader = Reader {
        link,
        catalog,
        schema: match scope {
            DumpScope::Database => None,
            DumpScope::Schema(schema) => Some(schema.as_str()),
        },
    };
    let dialect = DuckDbDialect::new();
    let mut dump = DumpCatalog::default();
    for schema in reader.rows(SCHEMAS_SQL, |row| row.get::<_, String>(0))? {
        if schema != DEFAULT_SCHEMA {
            let create = format!("CREATE SCHEMA IF NOT EXISTS {}", dialect.quote_identifier(&schema));
            dump.objects.push(DumpObject::new(
                DumpObjectKind::Schema,
                DumpSection::BeforeData,
                None,
                schema,
                vec![DumpStatement::new(create)],
            ));
        }
    }
    for sequence in reader.rows(SEQUENCES_SQL, read_sequence)? {
        dump.objects.push(sequence_object(&dialect, &sequence)?);
    }
    add_enums(&reader, &dialect, &mut dump)?;
    add_tables(&reader, &mut dump)?;
    place(
        &mut dump,
        reader.named(INDEXES_SQL)?,
        DumpObjectKind::Index,
        DumpSection::AfterData,
    );
    add_macros(&reader, &dialect, &mut dump)?;
    place(
        &mut dump,
        reader.named(VIEWS_SQL)?,
        DumpObjectKind::View,
        DumpSection::Programs,
    );
    place(
        &mut dump,
        reader.named(TRIGGERS_SQL)?,
        DumpObjectKind::Trigger,
        DumpSection::Triggers,
    );
    Ok(dump)
}

/// DuckDB's text ends with a `;`, which the writer takes off.
fn place(dump: &mut DumpCatalog, objects: Vec<Named>, kind: DumpObjectKind, section: DumpSection) {
    for object in objects {
        match object.text() {
            Some(sql) => dump.objects.push(DumpObject::new(
                kind,
                section,
                Some(object.schema.clone()),
                object.name.clone(),
                vec![DumpStatement::new(sql)],
            )),
            None => dump.skipped.push(object.skip(kind)),
        }
    }
}

fn read_sequence(row: &duckdb::Row<'_>) -> duckdb::Result<Sequence> {
    Ok(Sequence {
        schema: row.get(0)?,
        name: row.get(1)?,
        increment: row.get(2)?,
        min: row.get(3)?,
        max: row.get(4)?,
        cycle: row.get(5)?,
        sql: row.get(6)?,
    })
}

/// The sequence made again at the value its next call would give, which
/// DuckDB's own text has as its START and lists nowhere else: a call to
/// `setval` moves it without a last value to count from.
fn sequence_object(dialect: &DuckDbDialect, sequence: &Sequence) -> Result<DumpObject, DriverError> {
    let next = next_value(&sequence.sql)
        .ok_or_else(|| DriverError::Protocol(format!("DuckDB gave sequence {} no START", sequence.name)))?;
    let name = dialect.portable_name(&TableRef::new(Some(sequence.schema.clone()), sequence.name.clone()));
    let cycle = match sequence.cycle {
        true => "CYCLE",
        false => "NO CYCLE",
    };
    let create = format!(
        "CREATE SEQUENCE {name} INCREMENT BY {} MINVALUE {} MAXVALUE {} START {next} {cycle}",
        sequence.increment, sequence.min, sequence.max
    );
    Ok(DumpObject::new(
        DumpObjectKind::Sequence,
        DumpSection::BeforeData,
        Some(sequence.schema.clone()),
        sequence.name.clone(),
        vec![DumpStatement::new(create)],
    ))
}

/// The number after the last ` START `, since the sequence's name comes
/// first and can hold anything.
fn next_value(sql: &str) -> Option<i64> {
    let (_, after) = sql.rsplit_once(" START ")?;
    after.split_whitespace().next()?.parse().ok()
}

/// A table names an enum by its labels, so a table loads without the
/// type, but a cast or a macro may name it.
fn add_enums(reader: &Reader<'_>, dialect: &DuckDbDialect, dump: &mut DumpCatalog) -> Result<(), DriverError> {
    let enums = reader.rows(ENUMS_SQL, |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, texts(row.get(2)?)))
    })?;
    for (schema, name, labels) in enums {
        let Some(labels) = labels.into_iter().collect::<Option<Vec<String>>>() else {
            dump.skipped.push(DumpSkip {
                kind: DumpObjectKind::Type,
                schema: Some(schema),
                name,
                reason: DumpSkipReason::NoDefinition,
            });
            continue;
        };
        let quoted: Vec<String> = labels.iter().map(|label| dialect.string_literal(label)).collect();
        let create = format!(
            "CREATE TYPE {} AS ENUM ({})",
            dialect.portable_name(&TableRef::new(Some(schema.clone()), name.clone())),
            quoted.join(", ")
        );
        dump.objects.push(DumpObject::new(
            DumpObjectKind::Type,
            DumpSection::BeforeData,
            Some(schema),
            name,
            vec![DumpStatement::new(create)],
        ));
    }
    Ok(())
}

/// The items of a list of text, `None` for a NULL item. A value that is
/// no list has one `None`, so it reads as incomplete.
fn texts(value: DuckValue) -> Vec<Option<String>> {
    match value {
        DuckValue::List(items) => items
            .into_iter()
            .map(|item| match item {
                DuckValue::Text(text) => Some(text),
                _ => None,
            })
            .collect(),
        _ => vec![None],
    }
}

fn add_tables(reader: &Reader<'_>, dump: &mut DumpCatalog) -> Result<(), DriverError> {
    let tables = reader.named(TABLES_SQL)?;
    let keys = reader.rows(FOREIGN_KEYS_SQL, |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            texts(row.get(2)?).into_iter().flatten().collect(),
        ))
    })?;
    let listed: Vec<&Named> = tables.iter().filter(|table| table.text().is_some()).collect();
    dump.tables.extend(dump_tables(&listed, &keys));
    for table in &tables {
        match table.text() {
            Some(sql) => dump.objects.push(DumpObject::table(
                TableRef::new(Some(table.schema.clone()), table.name.clone()),
                vec![DumpStatement::new(sql)],
            )),
            None => dump.skipped.push(table.skip(DumpObjectKind::Table)),
        }
    }
    Ok(())
}

/// DuckDB checks a foreign key as each statement ends, and has no way
/// to add one after the rows, so a table's rows follow its parents', and
/// a table whose key points at itself takes a row per statement.
fn dump_tables(tables: &[&Named], keys: &[(String, String, Vec<String>)]) -> Vec<DumpTable> {
    let parents_of: HashMap<(&str, &str), &[String]> = keys
        .iter()
        .map(|(schema, child, parents)| ((schema.as_str(), child.as_str()), parents.as_slice()))
        .collect();
    // A key keeps its parent as the CREATE spelled it, and DuckDB folds the case of names.
    let mut declared_names: HashMap<(&str, String), &str> = HashMap::new();
    for table in tables {
        declared_names
            .entry((table.schema.as_str(), table.name.to_ascii_lowercase()))
            .or_insert(table.name.as_str());
    }
    tables
        .iter()
        .map(|table| {
            let mut dumped = DumpTable::new(TableRef::new(Some(table.schema.clone()), table.name.clone()));
            let parents = parents_of
                .get(&(table.schema.as_str(), table.name.as_str()))
                .copied()
                .unwrap_or_default();
            for parent in parents {
                let declared = declared_names
                    .get(&(table.schema.as_str(), parent.to_ascii_lowercase()))
                    .copied()
                    .unwrap_or(parent.as_str());
                if declared == table.name {
                    dumped.one_row_per_insert = true;
                    continue;
                }
                let reference = TableRef::new(Some(table.schema.clone()), declared.to_owned());
                if !dumped.references.contains(&reference) {
                    dumped.references.push(reference);
                }
            }
            dumped
        })
        .collect()
}

fn add_macros(reader: &Reader<'_>, dialect: &DuckDbDialect, dump: &mut DumpCatalog) -> Result<(), DriverError> {
    let mut overloads = reader.rows(MACROS_SQL, |row| {
        let names = texts(row.get(3)?);
        let types = texts(row.get(4)?);
        Ok(MacroOverload {
            schema: row.get(0)?,
            name: row.get(1)?,
            table: row.get::<_, String>(2)? == "table_macro",
            parameters: names
                .into_iter()
                .enumerate()
                .filter_map(|(position, name)| Some((name?, types.get(position).cloned().flatten())))
                .collect(),
            definition: row
                .get::<_, Option<String>>(5)?
                .map(|body| without_catalog(&body, reader.catalog)),
        })
    })?;
    // Stable, so each macro's overloads keep their order.
    overloads.sort_by(|left, right| (&left.schema, &left.name).cmp(&(&right.schema, &right.name)));
    for group in overloads.chunk_by(|left, right| left.schema == right.schema && left.name == right.name) {
        let Some(first) = group.first() else {
            continue;
        };
        let name = dialect.portable_name(&TableRef::new(Some(first.schema.clone()), first.name.clone()));
        // A generated column or a default can call a scalar macro, and
        // DuckDB keeps the call in the table's text; a table macro reads
        // tables, which have to exist first.
        let section = match first.table {
            true => DumpSection::Programs,
            false => DumpSection::BeforeData,
        };
        match macro_sql(dialect, &name, group) {
            Some(create) => dump.objects.push(DumpObject::new(
                DumpObjectKind::Function,
                section,
                Some(first.schema.clone()),
                first.name.clone(),
                vec![DumpStatement::new(create)],
            )),
            None => dump.skipped.push(DumpSkip {
                kind: DumpObjectKind::Function,
                schema: Some(first.schema.clone()),
                name: first.name.clone(),
                reason: DumpSkipReason::NoDefinition,
            }),
        }
    }
    Ok(())
}

/// One CREATE MACRO for all of a macro's overloads, written as DuckDB
/// writes one. The catalogue lists no parameter's default, so a
/// parameter declared with one comes back without it.
fn macro_sql(dialect: &DuckDbDialect, name: &str, overloads: &[MacroOverload]) -> Option<String> {
    let definitions = overloads
        .iter()
        .map(|overload| {
            let body = overload.definition.as_deref().filter(|body| !body.trim().is_empty())?;
            let parameters: Vec<String> = overload
                .parameters
                .iter()
                .map(|(parameter, type_name)| match type_name {
                    Some(type_name) => format!("{} {type_name}", dialect.quote_identifier(parameter)),
                    None => dialect.quote_identifier(parameter),
                })
                .collect();
            let parameters = parameters.join(", ");
            Some(match overload.table {
                true => format!("({parameters}) AS TABLE ({body})"),
                false => format!("({parameters}) AS ({body})"),
            })
        })
        .collect::<Option<Vec<String>>>()?;
    Some(format!("CREATE MACRO {name} {}", definitions.join(", ")))
}

/// `sql` without the catalog in front of `catalog.schema.name`: DuckDB
/// keeps a definition's names as they were written, and the catalog is
/// the source file's name, which the file the dump loads into does not
/// have. A text that names the catalog on its own, as an alias or a
/// table, can mean that by `name.schema.`, so it is kept.
fn without_catalog(sql: &str, catalog: &str) -> String {
    let plan = ScriptPlan::build(
        sql,
        SqlGrammar::DuckDb,
        LexicalSettings::default_for(SqlGrammar::DuckDb),
    );
    let tokens: Vec<ScriptToken> = plan
        .tokens(0..sql.len())
        .filter(|token| !token.kind.is_trivia())
        .collect();
    let text = |at: usize| tokens.get(at).and_then(|token| sql.get(token.range.clone()));
    let dot = |at: usize| text(at) == Some(".");
    let is_catalog = |at: usize| name_of(sql, &tokens[at]).is_some_and(|name| name.eq_ignore_ascii_case(catalog));
    if (0..tokens.len()).any(|at| is_catalog(at) && !dot(at + 1)) {
        return sql.to_owned();
    }
    let mut kept = String::with_capacity(sql.len());
    let mut from = 0;
    for at in 0..tokens.len() {
        let qualifies = is_catalog(at) && dot(at + 1) && dot(at + 3) && !at.checked_sub(1).is_some_and(dot);
        if qualifies {
            kept.push_str(&sql[from..tokens[at].range.start]);
            from = tokens[at + 1].range.end;
        }
    }
    kept.push_str(&sql[from..]);
    kept
}

fn name_of(sql: &str, token: &ScriptToken) -> Option<String> {
    let text = sql.get(token.range.clone())?;
    match token.kind {
        ScriptTokenKind::Word => Some(text.to_owned()),
        ScriptTokenKind::QuotedIdentifier => Some(text.strip_prefix('"')?.strip_suffix('"')?.replace("\"\"", "\"")),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn named(schema: &str, name: &str) -> Named {
        Named {
            schema: schema.to_owned(),
            name: name.to_owned(),
            sql: Some(format!("CREATE TABLE {name}(id INTEGER);")),
        }
    }

    fn key(schema: &str, child: &str, parents: &[&str]) -> (String, String, Vec<String>) {
        (
            schema.to_owned(),
            child.to_owned(),
            parents.iter().map(|parent| (*parent).to_owned()).collect(),
        )
    }

    #[test]
    fn the_next_value_is_the_last_start_in_the_text() {
        assert_eq!(
            next_value("CREATE SEQUENCE s INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START 6 NO CYCLE;"),
            Some(6)
        );
        assert_eq!(
            next_value("CREATE SEQUENCE \"a START 9 b\" INCREMENT BY -2 MINVALUE -10 MAXVALUE 0 START -4 CYCLE;"),
            Some(-4)
        );
        assert_eq!(next_value("CREATE SEQUENCE s;"), None);
    }

    #[test]
    fn a_sequence_starts_where_it_stopped() {
        let sequence = Sequence {
            schema: "app".to_owned(),
            name: "ids".to_owned(),
            increment: 1,
            min: 1,
            max: 100,
            cycle: false,
            sql: "CREATE SEQUENCE ids INCREMENT BY 1 MINVALUE 1 MAXVALUE 100 START 5 NO CYCLE;".to_owned(),
        };

        let object = sequence_object(&DuckDbDialect::new(), &sequence).unwrap();

        assert_eq!(
            object.statements[0].sql,
            "CREATE SEQUENCE \"app\".\"ids\" INCREMENT BY 1 MINVALUE 1 MAXVALUE 100 START 5 NO CYCLE"
        );
    }

    #[test]
    fn a_table_follows_its_parents_and_a_self_reference_loads_a_row_at_a_time() {
        let (parent, child, other) = (named("app", "parent"), named("app", "child"), named("main", "parent"));
        let tables = [&child, &parent, &other];
        let keys = [key("app", "child", &["Parent", "parent", "child"])];

        let dumped = dump_tables(&tables, &keys);

        assert_eq!(
            dumped[0].references,
            [TableRef::new(Some("app".to_owned()), "parent".to_owned())]
        );
        assert!(dumped[0].one_row_per_insert);
        assert!(dumped[1].references.is_empty() && !dumped[1].one_row_per_insert);
    }

    #[test]
    fn a_macro_is_written_with_every_overload() {
        let overload = |parameters: &[(&str, Option<&str>)], body: &str, table: bool| MacroOverload {
            schema: "app".to_owned(),
            name: "m".to_owned(),
            table,
            parameters: parameters
                .iter()
                .map(|(name, type_name)| ((*name).to_owned(), type_name.map(str::to_owned)))
                .collect(),
            definition: Some(body.to_owned()),
        };
        let dialect = DuckDbDialect::new();

        assert_eq!(
            macro_sql(
                &dialect,
                "\"app\".\"m\"",
                &[
                    overload(&[("x", None)], "(x * 2)", false),
                    overload(&[("x", None), ("y", Some("INTEGER"))], "(x + y)", false)
                ]
            )
            .as_deref(),
            Some("CREATE MACRO \"app\".\"m\" (\"x\") AS ((x * 2)), (\"x\", \"y\" INTEGER) AS ((x + y))")
        );
        assert_eq!(
            macro_sql(&dialect, "\"app\".\"t\"", &[overload(&[], "SELECT 1", true)]).as_deref(),
            Some("CREATE MACRO \"app\".\"t\" () AS TABLE (SELECT 1)")
        );
        let mut missing = overload(&[], "", false);
        missing.definition = None;
        assert_eq!(macro_sql(&dialect, "\"app\".\"m\"", &[missing]), None);
    }

    #[test]
    fn the_source_catalog_comes_off_three_part_names() {
        assert_eq!(
            without_catalog(
                "CREATE VIEW v AS SELECT * FROM source.main.t JOIN \"Source\".app.u USING (id) JOIN other.main.t USING (id);",
                "source"
            ),
            "CREATE VIEW v AS SELECT * FROM main.t JOIN app.u USING (id) JOIN other.main.t USING (id);"
        );
        assert_eq!(
            without_catalog(
                "CREATE VIEW v AS SELECT 'source.main.t' AS s, x.source.main AS m FROM x;",
                "source"
            ),
            "CREATE VIEW v AS SELECT 'source.main.t' AS s, x.source.main AS m FROM x;"
        );
    }

    #[test]
    fn a_text_that_names_the_catalog_alone_keeps_it() {
        let view = "CREATE VIEW v AS SELECT source.payload.id FROM main.events AS source;";

        assert_eq!(without_catalog(view, "source"), view);
    }

    #[test]
    fn a_list_with_a_null_or_no_list_reads_as_incomplete() {
        assert_eq!(
            texts(DuckValue::List(vec![DuckValue::Text("a".to_owned()), DuckValue::Null])),
            [Some("a".to_owned()), None]
        );
        assert_eq!(texts(DuckValue::Null), [None]);
    }

    #[test]
    fn the_file_is_one_transaction() {
        let dialect = DuckDbDialect::new();

        assert_eq!(dialect.header(), "BEGIN TRANSACTION;\n");
        assert_eq!(dialect.footer(), "\nCOMMIT;\n");
        assert_eq!(dialect.begin(), "BEGIN TRANSACTION");
        assert!(dialect.transactional_ddl());
    }
}
