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

// `columns` are the key's columns in the table that holds it, which tell two keys into one table apart.
// Exactly one of `filter` and `refusal` is set.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RowReferenceChoice {
    pub key_name: String,
    pub table: TableName,
    pub columns: Vec<String>,
    pub filter: Option<TableFilterArg>,
    pub refusal: Option<ReferenceRefusal>,
}

// A key with a NULL in the row, or one the rows do not hold every column of, leads nowhere and is left out.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RowReferences {
    pub referenced: Vec<RowReferenceChoice>,
    pub referencing: Vec<RowReferenceChoice>,
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
    // The table's keys that hold `column` (any column when None) and the other tables' keys, from `row` of `rows`
    // as the server holds it. `rows` is a page of this table, sorted or not.
    pub fn row_references(
        &self,
        rows: Arc<ResultSet>,
        row: u64,
        column: Option<String>,
    ) -> Result<RowReferences, CoreError> {
        if row >= rows.row_count() {
            return Err(CoreError::failed(
                "ffi.out_of_range",
                format!("no row {row} in the result"),
            ));
        }
        let read = rows.result_columns();
        let referenced = self
            .outbound
            .iter()
            .filter(|key| column.as_ref().is_none_or(|column| key.key.columns.contains(column)))
            .filter_map(|key| {
                let cells = key_cells(&rows, row, &read, &key.key.columns, &key.key.ref_columns, &key.key.name);
                choice(
                    &key.key.name,
                    TableRef::new(key.key.ref_schema.clone(), key.key.ref_table.clone()),
                    &key.key.columns,
                    cells.and_then(|(columns, values)| RowReference::referenced(&self.table, key, &columns, &values)),
                )
            })
            .collect();
        let referencing = self
            .inbound
            .iter()
            .filter_map(|key| {
                let cells = key_cells(&rows, row, &read, &key.referenced_columns, &key.columns, &key.name);
                choice(
                    &key.name,
                    key.table.clone(),
                    &key.columns,
                    cells.and_then(|(columns, values)| RowReference::referencing(&self.table, key, &columns, &values)),
                )
            })
            .collect();
        Ok(RowReferences {
            referenced,
            referencing,
        })
    }
}

// A key value past this has no filter: every key of a row is built as a menu opens, and a row could hold many
// keys of megabytes each.
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

fn choice(
    key_name: &str,
    table: TableRef,
    columns: &[String],
    reference: Result<RowReference, ReferenceError>,
) -> Option<RowReferenceChoice> {
    let (filter, refusal) = match reference {
        Ok(reference) => (Some(reference.filter.into()), None),
        Err(ReferenceError::NullKey | ReferenceError::MissingColumn { .. }) => return None,
        Err(ReferenceError::UnevenKey { key }) => (None, Some(ReferenceRefusal::UnevenKey { key })),
        Err(ReferenceError::UnknownSchema { table }) => (None, Some(ReferenceRefusal::UnknownSchema { table })),
        Err(ReferenceError::NoFilterText { column }) => (None, Some(ReferenceRefusal::NoFilterText { column })),
        Err(ReferenceError::ComparedOtherwise { table }) => (None, Some(ReferenceRefusal::ComparedOtherwise { table })),
    };
    Some(RowReferenceChoice {
        key_name: key_name.to_owned(),
        table: TableName {
            schema: table.schema,
            name: table.name,
        },
        columns: columns.to_vec(),
        filter,
        refusal,
    })
}
