//! A database as one SQL file, read the way mysqldump reads it: each
//! object's own `SHOW CREATE` text, on a login of its own that prints it
//! under an empty `sql_mode`.

mod create_text;
mod dump_dialect;
mod program_settings;

use std::collections::HashSet;

use sqlx::mysql::{MySqlConnection, MySqlDatabaseError, MySqlRow};
use sqlx::{AssertSqlSafe, Executor as _, Row as _};
use tablepro_core::DriverError;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::dump::{
    DumpCatalog, DumpObject, DumpObjectKind, DumpScope, DumpSection, DumpSkip, DumpSkipReason, DumpStatement, DumpTable,
};
use tablepro_core::meta::TableRef;

use crate::dialect::MySqlDialect;
use crate::errors::map_error;
use crate::metadata::{catalog_rows, not_there, text_column};

use create_text::{ModeReading, remote_table, without_database, without_definer};
use program_settings::ProgramSettings;

/// SHOW CREATE prints by the session's mode: `ANSI_QUOTES` quotes names
/// in `"`, and MariaDB's `NO_TABLE_OPTIONS` drops ENGINE and the counter.
/// mysqldump prints under an empty mode too.
const PRINT_SETTINGS_STATEMENT: &str = "SET SESSION sql_mode = '', SESSION sql_quote_show_create = 1";

/// MariaDB's Oracle-mode packages are left out.
const ROUTINES_SQL: &str = "\
SELECT CONVERT(ROUTINE_NAME USING utf8mb4) COLLATE utf8mb4_bin, ROUTINE_TYPE
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = ? AND ROUTINE_TYPE IN ('FUNCTION', 'PROCEDURE')
ORDER BY 2, 1";

/// In firing order within each table: a trigger made after another for
/// the same event fires after it again.
const TRIGGERS_SQL: &str = "\
SELECT CONVERT(TRIGGER_NAME USING utf8mb4) COLLATE utf8mb4_bin
FROM information_schema.TRIGGERS
WHERE EVENT_OBJECT_SCHEMA = ?
ORDER BY CONVERT(EVENT_OBJECT_TABLE USING utf8mb4) COLLATE utf8mb4_bin, ACTION_ORDER, 1";

/// ER_TABLEACCESS_DENIED_ERROR, what SHOW CREATE answers for an object
/// the login may list but not read.
const DENIED: u16 = 1142;

/// The scope's tables with their rows, sequences, routines, views and
/// triggers. Events are left out.
pub(crate) async fn read_catalog(
    connection: &mut MySqlConnection,
    dialect: &MySqlDialect,
    scope: &DumpScope,
) -> Result<DumpCatalog, DriverError> {
    let flavour = dialect.flavour();
    connection
        .execute(PRINT_SETTINGS_STATEMENT)
        .await
        .map_err(|error| map_error(&error, flavour))?;
    let qualifier = match scope {
        DumpScope::Database => None,
        DumpScope::Schema(name) => Some(name.clone()),
    };
    let listed = list_tables(connection, dialect, qualifier.as_deref()).await?;
    let database = match &qualifier {
        Some(name) => name.clone(),
        None => current_database(connection, dialect).await?,
    };
    let binds = [Some(database.as_str())];
    let mut routines = Vec::new();
    for row in catalog_rows(connection, flavour, ROUTINES_SQL, "ROUTINES", &binds).await? {
        let kind = match row.required_text(1)?.as_str() {
            "FUNCTION" => DumpObjectKind::Function,
            _ => DumpObjectKind::Procedure,
        };
        routines.push((row.required_text(0)?, kind));
    }
    let mut triggers = Vec::new();
    for row in catalog_rows(connection, flavour, TRIGGERS_SQL, "TRIGGERS", &binds).await? {
        triggers.push(row.required_text(0)?);
    }
    let names = listed
        .iter()
        .map(|(name, _)| name)
        .chain(routines.iter().map(|(name, _)| name))
        .map(|name| name.to_lowercase())
        .collect();
    let mut reader = Reader {
        connection,
        dialect,
        qualifier,
        database,
        names,
        catalog: DumpCatalog::default(),
    };
    let mut views = Vec::new();
    for (name, kind) in listed {
        match kind {
            ListedKind::Table => reader.table(&name).await?,
            ListedKind::Sequence => reader.sequence(&name).await?,
            ListedKind::View => views.push(name),
        }
    }
    for (name, kind) in routines {
        reader.routine(&name, kind).await?;
    }
    for name in views {
        reader.view(&name).await?;
    }
    for name in triggers {
        reader.trigger(&name).await?;
    }
    Ok(reader.catalog)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ListedKind {
    Table,
    View,
    Sequence,
}

/// The scope's tables, views and sequences, by name. On a session with
/// no database the server's own error says so.
async fn list_tables(
    connection: &mut MySqlConnection,
    dialect: &MySqlDialect,
    qualifier: Option<&str>,
) -> Result<Vec<(String, ListedKind)>, DriverError> {
    let sql = match qualifier {
        Some(database) => format!("SHOW FULL TABLES FROM {}", dialect.quote_identifier(database)),
        None => "SHOW FULL TABLES".to_owned(),
    };
    let rows = sqlx::raw_sql(AssertSqlSafe(sql))
        .fetch_all(&mut *connection)
        .await
        .map_err(|error| map_error(&error, dialect.flavour()))?;
    let mut listed = Vec::with_capacity(rows.len());
    for row in &rows {
        let kind = match text_at(row, 1, "Table_type")?.as_deref() {
            Some("BASE TABLE" | "SYSTEM VERSIONED") => ListedKind::Table,
            Some("VIEW") => ListedKind::View,
            Some("SEQUENCE") => ListedKind::Sequence,
            _ => continue,
        };
        if let Some(name) = text_at(row, 0, "Tables_in")? {
            listed.push((name, kind));
        }
    }
    listed.sort_by(|left, right| left.0.cmp(&right.0));
    Ok(listed)
}

async fn current_database(connection: &mut MySqlConnection, dialect: &MySqlDialect) -> Result<String, DriverError> {
    let rows = catalog_rows(connection, dialect.flavour(), "SELECT DATABASE()", "DATABASE", &[]).await?;
    rows.first()
        .map(|row| row.required_text(0))
        .transpose()?
        .ok_or_else(|| DriverError::Protocol("SELECT DATABASE() returned no row".to_owned()))
}

fn text_at(row: &MySqlRow, index: usize, column: &str) -> Result<Option<String>, DriverError> {
    let decode = |detail: String| DriverError::Decode {
        column: column.to_owned(),
        detail,
    };
    let bytes: Option<&[u8]> = row
        .try_get_unchecked(index)
        .map_err(|error| decode(error.to_string()))?;
    bytes
        .map(|bytes| String::from_utf8(bytes.to_vec()).map_err(|error| decode(error.to_string())))
        .transpose()
}

/// What a SHOW CREATE found.
enum Shown {
    Row(MySqlRow),
    /// Dropped since the list was read.
    Gone,
    /// The login may list it but not read its text.
    Hidden,
}

struct Reader<'a> {
    connection: &'a mut MySqlConnection,
    dialect: &'a MySqlDialect,
    /// The database a schema scope names, which each read qualifies its
    /// names with. The file itself never names it.
    qualifier: Option<String>,
    database: String,
    /// The scope's tables, views, sequences and routines, in lower case.
    names: HashSet<String>,
    catalog: DumpCatalog,
}

impl Reader<'_> {
    fn reference(&self, name: &str) -> TableRef {
        TableRef::new(self.qualifier.clone(), name)
    }

    async fn show(&mut self, what: &str, name: &str) -> Result<Shown, DriverError> {
        let sql = format!("SHOW CREATE {what} {}", self.dialect.qualify(&self.reference(name)));
        match sqlx::raw_sql(AssertSqlSafe(sql)).fetch_one(&mut *self.connection).await {
            Ok(row) => Ok(Shown::Row(row)),
            Err(error) if not_there(&error) => Ok(Shown::Gone),
            Err(error) if number(&error) == Some(DENIED) => Ok(Shown::Hidden),
            Err(error) => Err(map_error(&error, self.dialect.flavour())),
        }
    }

    /// The object's text from `column`, or `None` with the object listed
    /// as skipped where the login may not read it.
    async fn create_text(
        &mut self,
        kind: DumpObjectKind,
        name: &str,
        column: &str,
    ) -> Result<Option<(String, MySqlRow)>, DriverError> {
        let what = match kind {
            DumpObjectKind::Function => "FUNCTION",
            DumpObjectKind::Procedure => "PROCEDURE",
            DumpObjectKind::Sequence => "SEQUENCE",
            DumpObjectKind::View => "VIEW",
            DumpObjectKind::Trigger => "TRIGGER",
            _ => "TABLE",
        };
        let row = match self.show(what, name).await? {
            Shown::Row(row) => row,
            Shown::Gone => return Ok(None),
            Shown::Hidden => {
                self.skip(kind, name);
                return Ok(None);
            }
        };
        // NULL where the login may not read a routine's body.
        match text_column(&row, column)? {
            Some(text) => Ok(Some((text, row))),
            None => {
                self.skip(kind, name);
                Ok(None)
            }
        }
    }

    fn skip(&mut self, kind: DumpObjectKind, name: &str) {
        self.catalog.skipped.push(DumpSkip {
            kind,
            schema: self.qualifier.clone(),
            name: name.to_owned(),
            reason: DumpSkipReason::NoDefinition,
        });
    }

    fn push(&mut self, kind: DumpObjectKind, section: DumpSection, name: &str, statements: Vec<DumpStatement>) {
        self.catalog
            .objects
            .push(DumpObject::new(kind, section, self.qualifier.clone(), name, statements));
    }

    /// SHOW CREATE TABLE keeps the foreign keys inline, which the
    /// header's `FOREIGN_KEY_CHECKS=0` lets load in any order, and
    /// `AUTO_INCREMENT=` with the counter past the highest key.
    async fn table(&mut self, name: &str) -> Result<(), DriverError> {
        let Some((create, _)) = self.create_text(DumpObjectKind::Table, name, "Create Table").await? else {
            return Ok(());
        };
        if remote_table(&create) {
            self.catalog.skipped.push(DumpSkip {
                kind: DumpObjectKind::Table,
                schema: self.qualifier.clone(),
                name: name.to_owned(),
                reason: DumpSkipReason::RemoteRows,
            });
            return Ok(());
        }
        let create = without_database(&create, &self.database, &self.names, ModeReading::of(None));
        let table = self.reference(name);
        self.catalog
            .objects
            .push(DumpObject::table(table.clone(), vec![DumpStatement::new(create)]));
        self.catalog.tables.push(DumpTable::new(table));
        Ok(())
    }

    /// The sequence as made, and after the rows the value it hands out
    /// next, as mariadb-dump writes it.
    async fn sequence(&mut self, name: &str) -> Result<(), DriverError> {
        let Some((create, _)) = self.create_text(DumpObjectKind::Sequence, name, "Create Table").await? else {
            return Ok(());
        };
        let next = self.next_value(name).await?;
        self.push(
            DumpObjectKind::Sequence,
            DumpSection::BeforeData,
            name,
            vec![DumpStatement::new(create)],
        );
        if let Some(next) = next {
            let statement = set_value(&self.dialect.quote_identifier(name), &next)?;
            self.push(
                DumpObjectKind::SequenceValue,
                DumpSection::AfterData,
                name,
                vec![statement],
            );
        }
        Ok(())
    }

    async fn next_value(&mut self, name: &str) -> Result<Option<String>, DriverError> {
        let sql = format!(
            "SELECT CAST(next_not_cached_value AS CHAR) AS next_value FROM {}",
            self.dialect.qualify(&self.reference(name))
        );
        match sqlx::raw_sql(AssertSqlSafe(sql))
            .fetch_optional(&mut *self.connection)
            .await
        {
            Ok(Some(row)) => text_column(&row, "next_value"),
            Ok(None) => Ok(None),
            Err(error) if not_there(&error) => Ok(None),
            Err(error) => Err(map_error(&error, self.dialect.flavour())),
        }
    }

    async fn routine(&mut self, name: &str, kind: DumpObjectKind) -> Result<(), DriverError> {
        let column = match kind {
            DumpObjectKind::Function => "Create Function",
            _ => "Create Procedure",
        };
        let Some((create, row)) = self.create_text(kind, name, column).await? else {
            return Ok(());
        };
        let settings = ProgramSettings {
            sql_mode: text_column(&row, "sql_mode")?,
            collation_connection: text_column(&row, "collation_connection")?,
        };
        let reading = ModeReading::of(settings.sql_mode.as_deref());
        let create = without_database(&without_definer(&create), &self.database, &self.names, reading);
        let statements = settings.around(DumpStatement::body(create));
        self.push(kind, DumpSection::Programs, name, statements);
        Ok(())
    }

    async fn view(&mut self, name: &str) -> Result<(), DriverError> {
        let Some((create, row)) = self.create_text(DumpObjectKind::View, name, "Create View").await? else {
            return Ok(());
        };
        let settings = ProgramSettings {
            sql_mode: None,
            collation_connection: text_column(&row, "collation_connection")?,
        };
        let create = without_database(
            &without_definer(&create),
            &self.database,
            &self.names,
            ModeReading::of(None),
        );
        let statements = settings.around(DumpStatement::new(create));
        self.push(DumpObjectKind::View, DumpSection::Programs, name, statements);
        Ok(())
    }

    async fn trigger(&mut self, name: &str) -> Result<(), DriverError> {
        let Some((create, row)) = self
            .create_text(DumpObjectKind::Trigger, name, "SQL Original Statement")
            .await?
        else {
            return Ok(());
        };
        let settings = ProgramSettings {
            sql_mode: text_column(&row, "sql_mode")?,
            collation_connection: text_column(&row, "collation_connection")?,
        };
        let reading = ModeReading::of(settings.sql_mode.as_deref());
        let create = without_database(&without_definer(&create), &self.database, &self.names, reading);
        let statements = settings.around(DumpStatement::body(create));
        self.push(DumpObjectKind::Trigger, DumpSection::Triggers, name, statements);
        Ok(())
    }
}

fn number(error: &sqlx::Error) -> Option<u16> {
    let sqlx::Error::Database(database) = error else {
        return None;
    };
    database
        .try_downcast_ref::<MySqlDatabaseError>()
        .map(MySqlDatabaseError::number)
}

/// `DO SETVAL(seq, next, 0)`: the next NEXTVAL hands out `next`. The
/// value is the server's own number, checked to be one before it
/// becomes SQL.
fn set_value(sequence_sql: &str, next: &str) -> Result<DumpStatement, DriverError> {
    let value: i64 = next.trim().parse().map_err(|_| DriverError::Decode {
        column: "next_not_cached_value".to_owned(),
        detail: format!("{next:?} is not a number"),
    })?;
    Ok(DumpStatement::new(format!("DO SETVAL({sequence_sql}, {value}, 0)")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sequence_restarts_at_the_value_it_hands_out_next() {
        assert_eq!(
            set_value("`invoice_no`", "2000")
                .map(|statement| statement.sql)
                .ok()
                .as_deref(),
            Some("DO SETVAL(`invoice_no`, 2000, 0)")
        );
        assert_eq!(
            set_value("`down`", "-5").map(|statement| statement.sql).ok().as_deref(),
            Some("DO SETVAL(`down`, -5, 0)")
        );
        assert!(set_value("`s`", "1; DROP TABLE t").is_err());
    }
}
