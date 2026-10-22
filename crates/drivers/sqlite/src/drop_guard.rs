use sqlparser::ast::{ObjectType, Statement};
use sqlparser::dialect::SQLiteDialect;
use sqlparser::parser::Parser;
use sqlx::SqliteConnection;
use tablepro_core::DriverError;

use crate::{map_sqlx_error, quote_ident};

const SCHEMA_SEARCH_ORDER: &str = "SELECT name FROM pragma_database_list \
     ORDER BY CASE name WHEN 'temp' THEN 0 WHEN 'main' THEN 1 ELSE 2 END, seq";

fn dropped_tables(sql: &str) -> Vec<(Option<String>, String)> {
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
            let parts: Vec<String> = name
                .0
                .iter()
                .filter_map(|part| part.as_ident())
                .map(|ident| ident.value.clone())
                .collect();
            let (table, schema) = parts.split_last()?;
            Some((schema.last().cloned(), table.clone()))
        })
        .collect()
}

async fn has_table(connection: &mut SqliteConnection, schema: &str, table: &str) -> Result<bool, DriverError> {
    let sql = format!(
        "SELECT 1 FROM {}.sqlite_master WHERE type = 'table' AND name = ?1 COLLATE NOCASE",
        quote_ident(schema)
    );
    let found: Option<i64> = sqlx::query_scalar(sqlx::AssertSqlSafe(sql))
        .bind(table)
        .fetch_optional(&mut *connection)
        .await
        .map_err(map_sqlx_error)?;
    Ok(found.is_some())
}

async fn owning_schema(
    connection: &mut SqliteConnection,
    schema: Option<&str>,
    table: &str,
) -> Result<Option<String>, DriverError> {
    let schemas: Vec<String> = sqlx::query_scalar(SCHEMA_SEARCH_ORDER)
        .fetch_all(&mut *connection)
        .await
        .map_err(map_sqlx_error)?;
    if let Some(schema) = schema {
        return Ok(schemas.into_iter().find(|known| known.eq_ignore_ascii_case(schema)));
    }
    for known in schemas {
        if has_table(connection, &known, table).await? {
            return Ok(Some(known));
        }
    }
    Ok(None)
}

async fn referencing_tables(
    connection: &mut SqliteConnection,
    schema: &str,
    table: &str,
) -> Result<Vec<String>, DriverError> {
    let sql = format!(
        "SELECT m.name FROM {}.sqlite_master m, pragma_foreign_key_list(m.name, ?2) f \
         WHERE m.type = 'table' AND f.\"table\" = ?1 COLLATE NOCASE AND m.name <> ?1 COLLATE NOCASE \
         GROUP BY m.name ORDER BY m.name",
        quote_ident(schema)
    );
    sqlx::query_scalar(sqlx::AssertSqlSafe(sql))
        .bind(table)
        .bind(schema)
        .fetch_all(&mut *connection)
        .await
        .map_err(map_sqlx_error)
}

pub(super) async fn refuse_referenced_drop(connection: &mut SqliteConnection, sql: &str) -> Result<(), DriverError> {
    for (schema, table) in dropped_tables(sql) {
        let Some(schema) = owning_schema(connection, schema.as_deref(), &table).await? else {
            continue;
        };
        let referencing = referencing_tables(connection, &schema, &table).await?;
        if !referencing.is_empty() {
            return Err(DriverError::Unsupported(format!(
                "cannot drop {table}: referenced by {}. Drop or change those tables first, otherwise SQLite would run their ON DELETE actions on the data",
                referencing.join(", ")
            )));
        }
    }
    Ok(())
}
