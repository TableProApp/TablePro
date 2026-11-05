//! A ClickHouse database as a SQL dump: each table, view and dictionary
//! as `SHOW CREATE TABLE` gives it, with the database's name taken out.
//! User-defined functions belong to the server, not to a database, so a
//! database's dump leaves them out.

mod create_text;

use tablepro_core::DriverError;
use tablepro_core::dump::{
    DumpCatalog, DumpDialect, DumpObject, DumpObjectKind, DumpSection, DumpSkip, DumpSkipReason, DumpStatement,
    DumpTable,
};
use tablepro_core::meta::TableRef;

use crate::call_client::CallClient;
use clickhouse::sql::Identifier;

use crate::catalog::CatalogTable;
use crate::dialect::ClickHouseDialect;
use crate::result_reader::{CatalogRow, read_table};

/// Statements end in `;`, and a CREATE does not roll back: ClickHouse
/// has no transaction a file could run in.
impl DumpDialect for ClickHouseDialect {}

/// What the server shows in place of a password or a key.

/// The objects of `database`, by name. `qualified` names the tables with
/// the database for reading their rows, where it is not the connection's.
pub(crate) async fn read_dump_catalog(
    calls: &CallClient,
    database: &str,
    qualified: bool,
) -> Result<DumpCatalog, DriverError> {
    // A materialized view's inner table is made again by its CREATE.
    let sql = "SELECT name, engine FROM system.tables \
               WHERE database = {db:String} AND is_temporary = 0 AND NOT startsWith(name, '.inner') \
               ORDER BY name";
    let listed = read_table(calls.raw(sql)?.param("db", database), None).await?;
    let mut catalog = DumpCatalog::default();
    for row in &listed.rows {
        let row = CatalogRow(row);
        let (name, engine) = (row.text(0)?, row.text(1)?);
        let source = CatalogTable {
            database: database.to_owned(),
            name: name.clone(),
        };
        let create = hidden_secrets_create(calls, &source).await?;
        let table = match qualified {
            true => TableRef::new(Some(database.to_owned()), name.clone()),
            false => TableRef::unqualified(name.clone()),
        };
        add_object(&mut catalog, table, &engine, create, database);
    }
    Ok(catalog)
}

/// SHOW CREATE TABLE with any password or key the text names shown as
/// `[HIDDEN]`, which the dump then leaves out, even for a login allowed
/// to see secrets.
async fn hidden_secrets_create(calls: &CallClient, table: &CatalogTable) -> Result<Option<String>, DriverError> {
    let query = calls
        .template("SHOW CREATE TABLE ?.?")?
        .bind(Identifier(&table.database))
        .bind(Identifier(&table.name))
        .with_setting("format_display_secrets_in_show_and_select", "0");
    let result = read_table(query, None).await?;
    result.rows.first().map(|row| CatalogRow(row).text(0)).transpose()
}

fn add_object(catalog: &mut DumpCatalog, table: TableRef, engine: &str, create: Option<String>, database: &str) {
    let placement = Placement::of(engine, create.as_deref().unwrap_or_default());
    let skip = |reason| DumpSkip {
        kind: placement.kind(),
        schema: None,
        name: table.name.clone(),
        reason,
    };
    let Some(create) = create.filter(|create| !create.trim().is_empty()) else {
        catalog.skipped.push(skip(DumpSkipReason::NoDefinition));
        return;
    };
    if create_text::hides_secret(&create) {
        catalog.skipped.push(skip(DumpSkipReason::HiddenSecret));
        return;
    }
    let create = create_text::without_database(&create, database);
    match placement {
        Placement::Table { rows } => {
            let mut dumped = DumpTable::new(table.clone());
            dumped.rows = rows;
            catalog
                .objects
                .push(DumpObject::table(table, vec![DumpStatement::new(create)]));
            catalog.tables.push(dumped);
        }
        Placement::Program(kind) => {
            let create = match kind {
                DumpObjectKind::View | DumpObjectKind::MaterializedView => create_text::without_definer(&create),
                _ => create,
            };
            if kind == DumpObjectKind::MaterializedView && create_text::keeps_own_rows(&create) {
                catalog.skipped.push(DumpSkip {
                    kind,
                    schema: None,
                    name: table.name.clone(),
                    reason: DumpSkipReason::RowsNotCarried,
                });
            }
            catalog.objects.push(DumpObject::new(
                kind,
                DumpSection::Programs,
                None,
                table.name,
                vec![DumpStatement::new(create)],
            ));
        }
    }
}

/// Where an object of `system.tables` goes in the file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Placement {
    /// Its CREATE goes before the rows. Only an engine that keeps rows
    /// of its own has them read: reading a Kafka table takes its
    /// messages, and a Distributed or Merge table reads other tables.
    Table { rows: bool },
    /// After the rows, so a materialized view does not see them load
    /// and write them into its target a second time.
    Program(DumpObjectKind),
}

impl Placement {
    fn of(engine: &str, create: &str) -> Self {
        match engine {
            "View" | "LiveView" | "WindowView" => Self::Program(DumpObjectKind::View),
            "MaterializedView" => Self::Program(DumpObjectKind::MaterializedView),
            "Dictionary" if create_text::is_dictionary(create) => Self::Program(DumpObjectKind::Dictionary),
            _ => Self::Table {
                rows: holds_rows(engine),
            },
        }
    }

    fn kind(self) -> DumpObjectKind {
        match self {
            Self::Table { .. } => DumpObjectKind::Table,
            Self::Program(kind) => kind,
        }
    }
}

fn holds_rows(engine: &str) -> bool {
    engine.ends_with("MergeTree")
        || matches!(
            engine,
            "Log" | "TinyLog" | "StripeLog" | "Memory" | "EmbeddedRocksDB" | "KeeperMap" | "Join"
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalog_of(objects: &[(&str, &str, Option<&str>)]) -> DumpCatalog {
        let mut catalog = DumpCatalog::default();
        for (name, engine, create) in objects {
            add_object(
                &mut catalog,
                TableRef::unqualified(*name),
                engine,
                create.map(str::to_owned),
                "app",
            );
        }
        catalog
    }

    #[test]
    fn tables_come_before_the_rows_and_views_after() {
        let catalog = catalog_of(&[
            (
                "counts",
                "MergeTree",
                Some("CREATE TABLE app.counts (`k` UInt64) ENGINE = MergeTree ORDER BY k"),
            ),
            (
                "mv",
                "MaterializedView",
                Some(
                    "CREATE MATERIALIZED VIEW app.mv TO app.counts (`k` UInt64) DEFINER = me SQL SECURITY DEFINER AS SELECT k FROM app.src",
                ),
            ),
            (
                "v",
                "View",
                Some("CREATE VIEW app.v (`k` UInt64) AS SELECT k FROM app.counts"),
            ),
        ]);

        let statements: Vec<(DumpSection, &str)> = catalog
            .objects
            .iter()
            .map(|object| (object.section, object.statements[0].sql.as_str()))
            .collect();
        assert_eq!(
            statements,
            [
                (
                    DumpSection::BeforeData,
                    "CREATE TABLE counts (`k` UInt64) ENGINE = MergeTree ORDER BY k"
                ),
                (
                    DumpSection::Programs,
                    "CREATE MATERIALIZED VIEW mv TO counts (`k` UInt64) SQL SECURITY DEFINER AS SELECT k FROM src"
                ),
                (
                    DumpSection::Programs,
                    "CREATE VIEW v (`k` UInt64) AS SELECT k FROM counts"
                ),
            ]
        );
        assert_eq!(catalog.objects[0].table, Some(TableRef::unqualified("counts")));
        assert_eq!(catalog.tables.len(), 1);
        assert!(catalog.tables[0].rows);
        assert!(catalog.objects.iter().all(|object| object.schema.is_none()));
    }

    #[test]
    fn only_an_engine_that_keeps_rows_has_them_read() {
        let catalog = catalog_of(&[
            (
                "events",
                "Kafka",
                Some("CREATE TABLE app.events (`m` String) ENGINE = Kafka"),
            ),
            (
                "log",
                "ReplicatedReplacingMergeTree",
                Some("CREATE TABLE app.log (`m` String) ENGINE = ReplicatedReplacingMergeTree ORDER BY m"),
            ),
            (
                "over",
                "Dictionary",
                Some("CREATE TABLE app.over (`id` UInt64) ENGINE = Dictionary(d)"),
            ),
        ]);

        let rows: Vec<(&str, bool)> = catalog
            .tables
            .iter()
            .map(|table| (table.table.name.as_str(), table.rows))
            .collect();
        assert_eq!(rows, [("events", false), ("log", true), ("over", false)]);
    }

    #[test]
    fn a_dictionary_is_a_program_unless_it_hides_a_secret() {
        let catalog = catalog_of(&[
            (
                "d",
                "Dictionary",
                Some(
                    "CREATE DICTIONARY app.d (`id` UInt64) PRIMARY KEY id SOURCE(CLICKHOUSE(TABLE 'src')) LIFETIME(0) LAYOUT(FLAT())",
                ),
            ),
            (
                "remote",
                "Dictionary",
                Some(
                    "CREATE DICTIONARY app.remote (`id` UInt64) PRIMARY KEY id SOURCE(CLICKHOUSE(HOST 'h' PASSWORD '[HIDDEN]' TABLE 'src')) LIFETIME(0) LAYOUT(FLAT())",
                ),
            ),
            ("gone", "MergeTree", None),
        ]);

        assert_eq!(catalog.objects.len(), 1);
        assert_eq!(catalog.objects[0].kind, DumpObjectKind::Dictionary);
        assert_eq!(catalog.objects[0].section, DumpSection::Programs);
        assert_eq!(
            catalog.skipped,
            [
                DumpSkip {
                    kind: DumpObjectKind::Dictionary,
                    schema: None,
                    name: "remote".to_owned(),
                    reason: DumpSkipReason::HiddenSecret,
                },
                DumpSkip {
                    kind: DumpObjectKind::Table,
                    schema: None,
                    name: "gone".to_owned(),
                    reason: DumpSkipReason::NoDefinition,
                },
            ]
        );
        assert!(catalog.tables.is_empty());
    }
}
