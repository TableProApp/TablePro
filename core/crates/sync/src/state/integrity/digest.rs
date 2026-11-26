// The key digest and the sync digest (0054, Integrity): SHA-256 over tables in a fixed order, each framed as
// `LP(name) || u32(row count)` and then its rows in the byte order of their encoded primary keys. A row is its values
// in column order, the primary key first, which is how the file stores it: the encoded key, then the other columns.

use sha2::{Digest, Sha256};
use sqlx::{AssertSqlSafe, Sqlite, Transaction};

use super::super::codec;
use super::super::file::sql;
use crate::api::error::StateError;
use crate::api::state::{Provider, Row, Table};

// A table's rows as the file stores them: the encoded primary key and the other columns, in key order.
pub(crate) type Stored = Vec<(Vec<u8>, Vec<u8>)>;

// iCloud files have no key tables, so their key digest covers none.
pub(crate) const fn key_tables(provider: Provider) -> &'static [Table] {
    match provider {
        Provider::Service => &Table::KEY,
        Provider::ICloud => &[],
    }
}

fn frame(hasher: &mut Sha256, table: Table, rows: &Stored) {
    let name = table.name().as_bytes();
    hasher.update(u32::try_from(name.len()).unwrap_or(u32::MAX).to_be_bytes());
    hasher.update(name);
    hasher.update(u32::try_from(rows.len()).unwrap_or(u32::MAX).to_be_bytes());
    for (key, columns) in rows {
        hasher.update(key);
        hasher.update(columns);
    }
}

// The binding goes in without its state MAC, since that MAC is computed over this digest.
fn digest_columns(row: &Row) -> Vec<u8> {
    match row {
        Row::Binding(binding) => codec::binding_digest_columns(binding),
        row => codec::columns(row),
    }
}

fn of_rows(tables: &[Table], rows: &[Row]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    for table in tables {
        let mut stored: Stored = rows
            .iter()
            .filter(|row| row.key().table() == *table)
            .map(|row| (row.key().encoded(), digest_columns(row)))
            .collect();
        stored.sort();
        frame(&mut hasher, *table, &stored);
    }
    hasher.finalize().into()
}

// The key digest of a file holding `rows`; rows of other tables are left out.
pub fn key_digest(provider: Provider, rows: &[Row]) -> [u8; 32] {
    of_rows(key_tables(provider), rows)
}

// The sync digest of a file holding `rows`; rows of key tables are left out.
pub fn sync_digest(rows: &[Row]) -> [u8; 32] {
    of_rows(&Table::SYNC, rows)
}

pub(crate) async fn read_table(tx: &mut Transaction<'static, Sqlite>, table: Table) -> Result<Stored, StateError> {
    let statement = format!("SELECT key, columns FROM {} ORDER BY key", table.name());
    sqlx::query_as::<_, (Vec<u8>, Vec<u8>)>(AssertSqlSafe(statement))
        .fetch_all(&mut **tx)
        .await
        .map_err(sql)
}

pub(crate) async fn key_digest_in(
    tx: &mut Transaction<'static, Sqlite>,
    provider: Provider,
) -> Result<[u8; 32], StateError> {
    let mut hasher = Sha256::new();
    for table in key_tables(provider) {
        let rows = read_table(tx, *table).await?;
        frame(&mut hasher, *table, &rows);
    }
    Ok(hasher.finalize().into())
}

// The sync tables a schema's digest takes, in order. Schema 1 had no `stores_kinds` or `refused` (0066, The state
// file).
fn sync_tables(schema: u32) -> impl Iterator<Item = Table> {
    Table::SYNC
        .into_iter()
        .filter(move |table| schema > 1 || !matches!(table, Table::StoresKinds | Table::Refused))
}

pub(crate) async fn sync_digest_in(tx: &mut Transaction<'static, Sqlite>, schema: u32) -> Result<[u8; 32], StateError> {
    let mut hasher = Sha256::new();
    for table in sync_tables(schema) {
        let mut rows = read_table(tx, table).await?;
        if table == Table::Binding {
            for (key, columns) in &mut rows {
                let row = codec::decode(table, key, columns)?;
                *columns = digest_columns(&row);
            }
        }
        frame(&mut hasher, table, &rows);
    }
    Ok(hasher.finalize().into())
}
