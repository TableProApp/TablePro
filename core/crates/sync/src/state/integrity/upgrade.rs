// A file an older schema wrote (0054, The sync digest: each row's columns in the order the file's schema version
// defines). Its rows take this schema's encoding in the open's transaction, and the open's commit seals them, so no
// commit leaves the file under one schema's digest with the other's rows.

use sqlx::{AssertSqlSafe, Sqlite, Transaction};

use super::super::codec;
use super::super::file::{SCHEMA_VERSION, read, sql, write};
use super::digest;
use crate::api::error::StateError;
use crate::api::state::{Row, RowKey, Table};

// Whether the file was in schema 1 and now holds this schema's rows. Each call after the first finds nothing to do.
pub(super) async fn rows(tx: &mut Transaction<'static, Sqlite>) -> Result<bool, StateError> {
    let Some(Row::Binding(mut binding)) = read(tx, &RowKey::Binding).await? else {
        return Err(StateError::Integrity);
    };
    match binding.schema_version {
        SCHEMA_VERSION => return Ok(false),
        1 => {}
        _ => return Err(StateError::Integrity),
    }
    // Schema 1 had none of these tables, so no commit wrote what they hold.
    for table in [Table::StoresKinds, Table::Refused, Table::Moves] {
        let statement = format!("DELETE FROM {}", table.name());
        sqlx::query(AssertSqlSafe(statement))
            .execute(&mut **tx)
            .await
            .map_err(sql)?;
    }
    for table in [Table::Scopes, Table::KeyObjects, Table::KeyPins] {
        let statement = format!("UPDATE {} SET columns = ? WHERE key = ?", table.name());
        for (key, columns) in digest::read_table(tx, table).await? {
            sqlx::query(AssertSqlSafe(statement.clone()))
                .bind(codec::schema_1_columns(table, &columns).map_err(|_| StateError::Integrity)?)
                .bind(key)
                .execute(&mut **tx)
                .await
                .map_err(sql)?;
        }
    }
    binding.schema_version = SCHEMA_VERSION;
    write(tx, &Row::Binding(binding)).await?;
    Ok(true)
}
