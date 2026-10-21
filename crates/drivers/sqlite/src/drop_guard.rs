use sqlparser::ast::{ObjectType, Statement};
use sqlparser::dialect::SQLiteDialect;
use sqlparser::parser::Parser;
use sqlx::SqliteConnection;
use tablepro_core::DriverError;

use crate::map_sqlx_error;

const REFERENCING_TABLES: &str = "SELECT m.name FROM sqlite_master m, pragma_foreign_key_list(m.name) f \
     WHERE m.type = 'table' AND f.\"table\" = ?1 COLLATE NOCASE AND m.name <> ?1 COLLATE NOCASE \
     GROUP BY m.name ORDER BY m.name";

fn dropped_tables(sql: &str) -> Vec<String> {
    let Ok(statements) = Parser::parse_sql(&SQLiteDialect {}, sql) else {
        return Vec::new();
    };
    statements
        .into_iter()
        .filter_map(|statement| match statement {
            Statement::Drop {
                object_type: ObjectType::Table,
                names,
                ..
            } => Some(names),
            _ => None,
        })
        .flatten()
        .filter_map(|name| {
            name.0
                .last()
                .and_then(|part| part.as_ident())
                .map(|ident| ident.value.clone())
        })
        .collect()
}

pub(super) async fn refuse_referenced_drop(connection: &mut SqliteConnection, sql: &str) -> Result<(), DriverError> {
    for table in dropped_tables(sql) {
        let referencing: Vec<String> = sqlx::query_scalar(REFERENCING_TABLES)
            .bind(&table)
            .fetch_all(&mut *connection)
            .await
            .map_err(map_sqlx_error)?;
        if !referencing.is_empty() {
            return Err(DriverError::Unsupported(format!(
                "cannot drop {table}: referenced by {}. Drop or change those tables first, otherwise SQLite would run their ON DELETE actions on the data",
                referencing.join(", ")
            )));
        }
    }
    Ok(())
}
