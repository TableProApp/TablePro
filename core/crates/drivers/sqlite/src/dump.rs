//! A SQLite file as a SQL dump in the order `sqlite3 .dump` writes it:
//! the stored CREATE text of `main`, its AUTOINCREMENT counters, and the
//! rows in between. Virtual tables and their shadow tables are left out:
//! their rows belong to a module the loading side may not have.

use sqlx::Row;
use sqlx::sqlite::{SqliteConnection as SqlxConnection, SqliteRow};
use tablepro_core::dump::{
    DumpCatalog, DumpDialect, DumpObject, DumpObjectKind, DumpScope, DumpSection, DumpStatement, DumpTable,
};
use tablepro_core::meta::TableRef;
use tablepro_core::{DriverError, UnsupportedFeature};

use crate::catalog::{self, MAIN_SCHEMA};
use crate::dialect::SqliteDialect;
use crate::errors::map_error;

impl DumpDialect for SqliteDialect {
    /// Foreign keys go off before the transaction, the only place the
    /// pragma takes effect, so the file loads in any table order.
    fn header(&self) -> String {
        "PRAGMA foreign_keys=OFF;\nBEGIN TRANSACTION;\n".to_owned()
    }

    fn footer(&self) -> String {
        "\nCOMMIT;\n".to_owned()
    }

    fn transactional_ddl(&self) -> bool {
        true
    }

    /// Inside an import's own transaction the file's `foreign_keys=OFF`
    /// does nothing, so the checks wait for the COMMIT instead.
    fn after_begin(&self) -> &'static [&'static str] {
        &["PRAGMA defer_foreign_keys = ON"]
    }
}

/// `sqlite_schema` in the order the objects were made, each table with
/// what `table_list` calls it, so a virtual table and its shadow tables
/// can be told from the rest. An automatic index has no text.
const OBJECTS_SQL: &str = "SELECT m.type AS type, m.name AS name, m.sql AS sql, coalesce(l.type, '') AS kind \
     FROM \"main\".sqlite_schema AS m \
     LEFT JOIN pragma_table_list AS l ON m.type = 'table' AND l.schema = ?1 AND l.name = m.name \
     WHERE m.sql IS NOT NULL AND m.name NOT LIKE 'sqlite!_%' ESCAPE '!' \
     ORDER BY m.rowid";

const SEQUENCE_SQL: &str =
    "SELECT name, CAST(seq AS INTEGER) AS seq FROM \"main\".sqlite_sequence WHERE name IS NOT NULL ORDER BY rowid";

struct SchemaEntry {
    kind: String,
    name: String,
    sql: String,
    table_kind: String,
}

/// The objects of `main`. An attached database's names would follow it
/// into the file, so only `main` is dumped.
pub(crate) async fn read_dump_catalog(
    connection: &mut SqlxConnection,
    scope: &DumpScope,
) -> Result<DumpCatalog, DriverError> {
    if let DumpScope::Schema(schema) = scope
        && schema != MAIN_SCHEMA
    {
        return Err(DriverError::Unsupported {
            feature: UnsupportedFeature::SqlDump,
        });
    }
    let entries = sqlx::query(OBJECTS_SQL)
        .bind(MAIN_SCHEMA)
        .fetch_all(&mut *connection)
        .await
        .map_err(map_error)?
        .iter()
        .map(schema_entry)
        .collect::<Result<Vec<_>, _>>()?;
    let counters = match has_sequence_table(connection).await? {
        true => sqlx::query(SEQUENCE_SQL)
            .fetch_all(&mut *connection)
            .await
            .map_err(map_error)?
            .iter()
            .map(|row| Ok((text(row, "name")?, row.try_get::<i64, _>("seq").map_err(map_error)?)))
            .collect::<Result<Vec<_>, DriverError>>()?,
        false => Vec::new(),
    };
    Ok(dump_catalog(entries, &counters))
}

async fn has_sequence_table(connection: &mut SqlxConnection) -> Result<bool, DriverError> {
    let found: i64 = sqlx::query_scalar(sqlx::AssertSqlSafe(catalog::has_table_sql("\"main\"")))
        .bind("sqlite_sequence")
        .fetch_one(&mut *connection)
        .await
        .map_err(map_error)?;
    Ok(found > 0)
}

fn schema_entry(row: &SqliteRow) -> Result<SchemaEntry, DriverError> {
    Ok(SchemaEntry {
        kind: text(row, "type")?,
        name: text(row, "name")?,
        sql: text(row, "sql")?,
        table_kind: text(row, "kind")?,
    })
}

fn text(row: &SqliteRow, column: &str) -> Result<String, DriverError> {
    row.try_get(column).map_err(map_error)
}

/// The counters go back after the rows, which move them, and before the
/// indexes, as `.dump` has them.
fn dump_catalog(entries: Vec<SchemaEntry>, counters: &[(String, i64)]) -> DumpCatalog {
    let mut catalog = DumpCatalog::default();
    let mut indexes = Vec::new();
    for entry in entries {
        let object =
            |kind, section, statement| DumpObject::new(kind, section, None, entry.name.clone(), vec![statement]);
        match (entry.kind.as_str(), entry.table_kind.as_str()) {
            ("table", "virtual" | "shadow") => {}
            ("table", _) => {
                let table = TableRef::unqualified(entry.name.clone());
                catalog
                    .objects
                    .push(DumpObject::table(table.clone(), vec![DumpStatement::new(entry.sql)]));
                catalog.tables.push(DumpTable::new(table));
            }
            ("index", _) => indexes.push(object(
                DumpObjectKind::Index,
                DumpSection::AfterData,
                DumpStatement::new(entry.sql),
            )),
            ("view", _) => catalog.objects.push(object(
                DumpObjectKind::View,
                DumpSection::Programs,
                DumpStatement::new(entry.sql),
            )),
            ("trigger", _) => catalog.objects.push(object(
                DumpObjectKind::Trigger,
                DumpSection::Triggers,
                DumpStatement::body(entry.sql),
            )),
            _ => {}
        }
    }
    if !counters.is_empty() {
        catalog.objects.push(counters_object(counters));
    }
    catalog.objects.extend(indexes);
    catalog
}

/// Loading the rows puts a counter at each table's highest key, which a
/// deleted last row had passed.
fn counters_object(counters: &[(String, i64)]) -> DumpObject {
    let mut statements = vec![DumpStatement::new("DELETE FROM sqlite_sequence")];
    statements.extend(counters.iter().map(|(name, seq)| {
        DumpStatement::new(format!(
            "INSERT INTO sqlite_sequence VALUES('{}',{seq})",
            name.replace('\'', "''")
        ))
    }));
    DumpObject::new(
        DumpObjectKind::SequenceValue,
        DumpSection::AfterData,
        None,
        "sqlite_sequence",
        statements,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(kind: &str, name: &str, sql: &str, table_kind: &str) -> SchemaEntry {
        SchemaEntry {
            kind: kind.to_owned(),
            name: name.to_owned(),
            sql: sql.to_owned(),
            table_kind: table_kind.to_owned(),
        }
    }

    fn placed(catalog: &DumpCatalog) -> Vec<(DumpSection, &str)> {
        catalog
            .objects
            .iter()
            .map(|object| (object.section, object.name.as_str()))
            .collect()
    }

    #[test]
    fn objects_keep_their_order_and_counters_come_before_the_indexes() {
        let catalog = dump_catalog(
            vec![
                entry(
                    "table",
                    "parent",
                    "CREATE TABLE parent (id INTEGER PRIMARY KEY AUTOINCREMENT)",
                    "table",
                ),
                entry("index", "parent_idx", "CREATE INDEX parent_idx ON parent (id)", ""),
                entry("view", "v", "CREATE VIEW v AS SELECT 1", ""),
                entry("table", "child", "CREATE TABLE child (id)", "table"),
                entry(
                    "trigger",
                    "t",
                    "CREATE TRIGGER t AFTER INSERT ON child BEGIN SELECT 1; END",
                    "",
                ),
            ],
            &[("parent".to_owned(), 7)],
        );

        assert_eq!(
            placed(&catalog),
            [
                (DumpSection::BeforeData, "parent"),
                (DumpSection::Programs, "v"),
                (DumpSection::BeforeData, "child"),
                (DumpSection::Triggers, "t"),
                (DumpSection::AfterData, "sqlite_sequence"),
                (DumpSection::AfterData, "parent_idx"),
            ]
        );
        let tables: Vec<&str> = catalog.tables.iter().map(|table| table.table.name.as_str()).collect();
        assert_eq!(tables, ["parent", "child"]);
        assert!(catalog.objects[3].statements[0].body);
    }

    #[test]
    fn a_virtual_table_and_its_shadow_tables_are_left_out() {
        let catalog = dump_catalog(
            vec![
                entry("table", "docs", "CREATE VIRTUAL TABLE docs USING fts5(body)", "virtual"),
                entry(
                    "table",
                    "docs_data",
                    "CREATE TABLE 'docs_data'(id INTEGER PRIMARY KEY, block BLOB)",
                    "shadow",
                ),
                entry("table", "kept", "CREATE TABLE kept (a)", "table"),
            ],
            &[],
        );

        assert_eq!(placed(&catalog), [(DumpSection::BeforeData, "kept")]);
        assert_eq!(catalog.tables.len(), 1);
    }

    #[test]
    fn counters_are_cleared_then_written_back() {
        let object = counters_object(&[("it's".to_owned(), 5), ("child".to_owned(), 12)]);

        let sql: Vec<&str> = object
            .statements
            .iter()
            .map(|statement| statement.sql.as_str())
            .collect();
        assert_eq!(
            sql,
            [
                "DELETE FROM sqlite_sequence",
                "INSERT INTO sqlite_sequence VALUES('it''s',5)",
                "INSERT INTO sqlite_sequence VALUES('child',12)",
            ]
        );
    }

    #[test]
    fn the_file_turns_foreign_keys_off_outside_its_transaction() {
        let dialect = SqliteDialect::new(crate::catalog::SqliteVersion::new(3, 46, 1));

        assert_eq!(dialect.header(), "PRAGMA foreign_keys=OFF;\nBEGIN TRANSACTION;\n");
        assert!(dialect.transactional_ddl());
        assert_eq!(dialect.after_begin(), ["PRAGMA defer_foreign_keys = ON"]);
    }
}
