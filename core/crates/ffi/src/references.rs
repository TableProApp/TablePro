use std::sync::Arc;

use tablepro_core::Value;
use tablepro_core::browse::{ReferenceError, RowReference};
use tablepro_core::column::ResultColumn;
use tablepro_core::ddl::{InboundForeignKey, OutboundForeignKey};
use tablepro_core::meta::TableRef;
use tablepro_session::OperationKind;

use crate::cancel_token::{CancelToken, token};
use crate::catalog::TableName;
use crate::error::CoreError;
use crate::filter::TableFilterArg;
use crate::results::ResultSet;
use crate::runtime::on_runtime;
use crate::session::DatabaseSession;

// A menu lists no more than this each way; a table can declare thousands of keys over one column.
const MAX_CHOICES: usize = 64;

// A table's foreign keys both ways, read once; what a row leads to is worked out from them without the server.
#[derive(Debug, uniffi::Object)]
pub struct TableKeys {
    table: TableRef,
    outbound: Vec<OutboundForeignKey>,
    inbound: Vec<InboundForeignKey>,
}

// Why a key a row holds cannot be followed with a filter; the app words it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ReferenceRefusal {
    UnevenKey { key: String },
    UnknownSchema { table: String },
    NoFilterText { column: String },
    ComparedOtherwise { table: String },
}

// A key a row leads somewhere by, named for a menu. `key` and `referencing` are what `follow_reference` takes back;
// `columns` are the key's columns in the table that holds it, which tell two keys into one table apart.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RowReferenceChoice {
    pub key: u32,
    pub referencing: bool,
    pub key_name: String,
    pub table: TableName,
    pub columns: Vec<String>,
}

// A key with a NULL in the row, or one the rows do not hold every column of, leads nowhere and is left out.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RowReferences {
    pub referenced: Vec<RowReferenceChoice>,
    pub referencing: Vec<RowReferenceChoice>,
}

// The rows a chosen key leads to, or why a filter cannot reach them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FollowedReference {
    Rows { table: TableName, filter: TableFilterArg },
    Refused { refusal: ReferenceRefusal },
}

#[uniffi::export]
impl DatabaseSession {
    // Both ways in one operation, so a reconnect between the reads cannot pair keys of two connections.
    pub async fn table_keys(
        &self,
        table: TableName,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Arc<TableKeys>, CoreError> {
        let session = self.session().clone();
        let cancel = token(cancel);
        on_runtime(self.tasks(), async move {
            let table: TableRef = table.into();
            let (outbound, inbound) = session
                .run_cancellable(OperationKind::Metadata, &cancel, |lease, options| {
                    let table = table.clone();
                    async move {
                        let outbound = lease.fetch_outbound_foreign_keys(&table, options.clone()).await?;
                        let inbound = lease.fetch_inbound_foreign_keys(&table, options).await?;
                        Ok((outbound, inbound))
                    }
                })
                .await?;
            Ok(Arc::new(TableKeys {
                table,
                outbound,
                inbound,
            }))
        })
        .await
    }
}

#[uniffi::export]
impl TableKeys {
    // The table's keys that hold `column` (any column when None) and the other tables' keys, from `row` of `rows`.
    // Only whether each key's cells hold a value is read, so a menu copies no value; `follow_reference` builds the
    // filter of the one chosen.
    pub fn row_references(
        &self,
        rows: Arc<ResultSet>,
        row: u64,
        column: Option<String>,
    ) -> Result<RowReferences, CoreError> {
        in_range(&rows, row)?;
        let read = rows.result_columns();
        let referenced = self
            .outbound
            .iter()
            .enumerate()
            .filter(|(_, key)| column.as_ref().is_none_or(|column| key.key.columns.contains(column)))
            .filter(|(_, key)| holds_values(&rows, row, &read, &key.key.columns))
            .take(MAX_CHOICES)
            .map(|(index, key)| RowReferenceChoice {
                key: u32::try_from(index).unwrap_or(u32::MAX),
                referencing: false,
                key_name: key.key.name.clone(),
                table: TableName {
                    schema: key.key.ref_schema.clone(),
                    name: key.key.ref_table.clone(),
                },
                columns: key.key.columns.clone(),
            })
            .collect();
        let referencing = self
            .inbound
            .iter()
            .enumerate()
            .filter(|(_, key)| holds_values(&rows, row, &read, &key.referenced_columns))
            .take(MAX_CHOICES)
            .map(|(index, key)| RowReferenceChoice {
                key: u32::try_from(index).unwrap_or(u32::MAX),
                referencing: true,
                key_name: key.name.clone(),
                table: TableName {
                    schema: key.table.schema.clone(),
                    name: key.table.name.clone(),
                },
                columns: key.columns.clone(),
            })
            .collect();
        Ok(RowReferences {
            referenced,
            referencing,
        })
    }

    // The filter of one key `row_references` offered, built from the row's stored values.
    pub fn follow_reference(
        &self,
        rows: Arc<ResultSet>,
        row: u64,
        referencing: bool,
        key: u32,
    ) -> Result<FollowedReference, CoreError> {
        in_range(&rows, row)?;
        let read = rows.result_columns();
        let index = usize::try_from(key).unwrap_or(usize::MAX);
        let reference = match referencing {
            false => {
                let key = self.outbound.get(index).ok_or_else(no_key)?;
                key_cells(&rows, row, &read, &key.key.columns, &key.key.ref_columns, &key.key.name)
                    .and_then(|(columns, values)| RowReference::referenced(&self.table, key, &columns, &values))
            }
            true => {
                let key = self.inbound.get(index).ok_or_else(no_key)?;
                key_cells(&rows, row, &read, &key.referenced_columns, &key.columns, &key.name)
                    .and_then(|(columns, values)| RowReference::referencing(&self.table, key, &columns, &values))
            }
        };
        let refusal = match reference {
            Ok(reference) => {
                return Ok(FollowedReference::Rows {
                    table: TableName {
                        schema: reference.table.schema,
                        name: reference.table.name,
                    },
                    filter: reference.filter.into(),
                });
            }
            Err(ReferenceError::NullKey | ReferenceError::MissingColumn { .. }) => {
                return Err(CoreError::failed("ffi.out_of_range", "the row no longer holds the key"));
            }
            Err(ReferenceError::UnevenKey { key }) => ReferenceRefusal::UnevenKey { key },
            Err(ReferenceError::UnknownSchema { table }) => ReferenceRefusal::UnknownSchema { table },
            Err(ReferenceError::NoFilterText { column }) => ReferenceRefusal::NoFilterText { column },
            Err(ReferenceError::ComparedOtherwise { table }) => ReferenceRefusal::ComparedOtherwise { table },
        };
        Ok(FollowedReference::Refused { refusal })
    }
}

fn in_range(rows: &ResultSet, row: u64) -> Result<(), CoreError> {
    match row < rows.row_count() {
        true => Ok(()),
        false => Err(CoreError::failed(
            "ffi.out_of_range",
            format!("no row {row} in the result"),
        )),
    }
}

fn no_key() -> CoreError {
    CoreError::failed("ffi.out_of_range", "no such key")
}

// Every column of the key is in the rows and holds a value in the row, read from the cells' kinds alone.
fn holds_values(rows: &ResultSet, row: u64, read: &[ResultColumn], names: &[String]) -> bool {
    names.iter().all(|name| {
        read.iter()
            .position(|column| column.name == *name)
            .is_some_and(|index| matches!(rows.cell_kind(row, index), Some(Some(_))))
    })
}

// A key value past this has no filter: the filter would carry it, twice its size as hex for a binary key.
const MAX_KEY_BYTES: usize = 8 * 1024;

// Only the key's cells are copied, so a row of large values stays in the store. A value the store cannot name
// exactly, such as a float, has no text a filter would match.
fn key_cells(
    rows: &ResultSet,
    row: u64,
    read: &[ResultColumn],
    names: &[String],
    targets: &[String],
    key: &str,
) -> Result<(Vec<ResultColumn>, Vec<Value>), ReferenceError> {
    let mut columns = Vec::with_capacity(names.len());
    let mut values = Vec::with_capacity(names.len());
    let mut unnamed = None;
    for (position, name) in names.iter().enumerate() {
        let Some(index) = read.iter().position(|column| column.name == *name) else {
            return Err(ReferenceError::MissingColumn { column: name.clone() });
        };
        if rows.cell_len(row, index).is_some_and(|length| length > MAX_KEY_BYTES) {
            unnamed.get_or_insert(position);
            continue;
        }
        match rows.stored_value(row, index) {
            Some(Value::Null) => return Err(ReferenceError::NullKey),
            Some(value) => {
                columns.push(read[index].clone());
                values.push(value);
            }
            None => {
                unnamed.get_or_insert(position);
            }
        }
    }
    match unnamed {
        None => Ok((columns, values)),
        Some(position) => Err(match targets.get(position) {
            Some(column) => ReferenceError::NoFilterText { column: column.clone() },
            None => ReferenceError::UnevenKey { key: key.to_owned() },
        }),
    }
}
