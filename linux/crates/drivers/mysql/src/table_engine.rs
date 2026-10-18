use sqlx::mysql::MySqlConnection;
use tablepro_core::meta::TableRef;
use tablepro_core::{DriverError, WriteAtomicity};

use crate::flavour::MySqlFlavour;
use crate::metadata::catalog_rows;

/// The storage engine of a table, and whether that engine can roll back.
pub(crate) const TABLE_ENGINE_SQL: &str = "\
SELECT t.ENGINE, e.TRANSACTIONS
FROM information_schema.TABLES t
LEFT JOIN information_schema.ENGINES e ON e.ENGINE = t.ENGINE
WHERE t.TABLE_SCHEMA = COALESCE(?, DATABASE()) AND t.TABLE_NAME = ?";

/// What a table's engine can promise a write.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct TableEngine {
    /// `None` for a view, or a table that is not there.
    pub engine: Option<String>,
    pub transactions: Option<String>,
}

impl TableEngine {
    /// Only an engine that says YES rolls back. MyISAM, MEMORY, ARCHIVE,
    /// CSV, MariaDB's Aria, and a view (no engine at all) write each
    /// statement as it runs.
    pub(crate) fn atomicity(&self) -> WriteAtomicity {
        match self.transactions.as_deref() {
            Some(answer) if answer.eq_ignore_ascii_case("YES") => WriteAtomicity::Transactional,
            _ => WriteAtomicity::StatementByStatement,
        }
    }

    pub(crate) fn is_ndb(&self) -> bool {
        self.engine
            .as_deref()
            .is_some_and(|engine| engine.eq_ignore_ascii_case("ndbcluster"))
    }
}

pub(crate) async fn lookup(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    table: &TableRef,
) -> Result<TableEngine, DriverError> {
    let rows = catalog_rows(
        connection,
        flavour,
        TABLE_ENGINE_SQL,
        "TABLES",
        &[table.schema.as_deref(), Some(table.name.as_str())],
    )
    .await?;
    let Some(row) = rows.first() else {
        return Ok(TableEngine::default());
    };
    Ok(TableEngine {
        engine: row.text(0)?,
        transactions: row.text(1)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine(transactions: Option<&str>) -> TableEngine {
        TableEngine {
            engine: Some("Engine".to_owned()),
            transactions: transactions.map(str::to_owned),
        }
    }

    #[test]
    fn transactions_column_mapping() {
        assert_eq!(engine(Some("YES")).atomicity(), WriteAtomicity::Transactional);
        assert_eq!(engine(Some("NO")).atomicity(), WriteAtomicity::StatementByStatement);
        assert_eq!(engine(None).atomicity(), WriteAtomicity::StatementByStatement);
        assert_eq!(
            TableEngine::default().atomicity(),
            WriteAtomicity::StatementByStatement,
            "a view has no engine of its own"
        );
        assert!(
            TableEngine {
                engine: Some("ndbcluster".to_owned()),
                transactions: Some("YES".to_owned())
            }
            .is_ndb()
        );
    }
}
