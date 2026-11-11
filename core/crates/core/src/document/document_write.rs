use crate::column::ColumnInfo;
use crate::dml::BuildSqlError;
use crate::edit::CellInput;
use crate::meta::{RowIdentity, TableRef};
use crate::sql_syntax::mongo::{ShellMethod, ShellValue, is_addressable_field};
use crate::statement::Statement;
use crate::value::Value;

use super::document_filter::field;
use super::document_read::collection;
use super::shell_params::ShellParams;

/// A new document of the cells set. A cell left to the server is left
/// out, which for `_id` lets the server make one. A NULL cell is left out
/// too: a page reads a missing field as NULL, and an explicit `null` is a
/// field that a sparse or partial index counts.
pub(crate) fn insert(
    table: &TableRef,
    columns: &[ColumnInfo],
    cells: &[CellInput],
) -> Result<Statement, BuildSqlError> {
    if cells.len() != columns.len() {
        return Err(BuildSqlError::LengthMismatch {
            expected: columns.len(),
            found: cells.len(),
        });
    }
    let mut params = ShellParams::new();
    let mut fields = Vec::new();
    for (column, cell) in columns.iter().zip(cells) {
        if let Some(value) = cell.value().filter(|value| !value.is_null()) {
            fields.push((column.name.clone(), params.bind(value.clone(), Some(column))?));
        }
    }
    let mut call = collection(table);
    call.methods
        .push(ShellMethod::new("insertOne", vec![ShellValue::Object(fields)]));
    Ok(params.statement(&call))
}

/// Several new documents, all of the same columns, each leaving out its
/// NULL cells as `insert` does.
pub(crate) fn insert_many(
    table: &TableRef,
    columns: &[&ColumnInfo],
    rows: Vec<Vec<Value>>,
) -> Result<Statement, BuildSqlError> {
    if columns.is_empty() || rows.is_empty() {
        return Err(BuildSqlError::NoInsertValues);
    }
    let mut params = ShellParams::new();
    let mut documents = Vec::with_capacity(rows.len());
    for row in rows {
        if row.len() != columns.len() {
            return Err(BuildSqlError::LengthMismatch {
                expected: columns.len(),
                found: row.len(),
            });
        }
        let mut fields = Vec::with_capacity(columns.len());
        for (&column, value) in columns.iter().zip(row) {
            if !value.is_null() {
                fields.push((column.name.clone(), params.bind(value, Some(column))?));
            }
        }
        documents.push(ShellValue::Object(fields));
    }
    let mut call = collection(table);
    call.methods
        .push(ShellMethod::new("insertMany", vec![ShellValue::Array(documents)]));
    Ok(params.statement(&call))
}

/// The fields changed on one document, with `$set`. Only the fields named
/// change; one the document lacked is added. A field set to NULL is
/// removed with `$unset`, as a new document leaves it out, so a sparse or
/// partial index stops counting it. A key keeps `$set`.
pub(crate) fn update(
    table: &TableRef,
    columns: &[ColumnInfo],
    identity: &RowIdentity,
    key: &[Value],
    assignments: &[(usize, CellInput)],
    read: &[(usize, Value)],
) -> Result<Statement, BuildSqlError> {
    if assignments.is_empty() {
        return Err(BuildSqlError::NothingToUpdate);
    }
    let names = key_names(identity)?;
    let mut params = ShellParams::new();
    let mut set = Vec::with_capacity(assignments.len());
    let mut unset = Vec::new();
    for (index, input) in assignments {
        let column = columns.get(*index).ok_or(BuildSqlError::UnknownKeyColumn {
            name: index.to_string(),
        })?;
        if !is_addressable_field(&column.name) {
            return Err(BuildSqlError::UnaddressableField {
                name: column.name.clone(),
            });
        }
        let Some(value) = input.value() else {
            return Err(BuildSqlError::ServerComputedValue {
                name: column.name.clone(),
            });
        };
        match value {
            Value::Null if !names.contains(&column.name) => {
                unset.push((column.name.clone(), ShellValue::string("")));
            }
            _ => {
                let read = read.iter().find(|(at, _)| at == index).map(|(_, value)| value);
                set.push((column.name.clone(), params.bind_edit(value.clone(), column, read)?));
            }
        }
    }
    let filter = key_filter(columns, identity, key, &mut params)?;
    let operators = [("$set", set), ("$unset", unset)]
        .into_iter()
        .filter(|(_, fields)| !fields.is_empty())
        .map(|(name, fields)| (name.to_owned(), ShellValue::Object(fields)))
        .collect();
    let mut call = collection(table);
    call.methods.push(ShellMethod::new(
        "updateOne",
        vec![filter, ShellValue::Object(operators)],
    ));
    Ok(params.statement(&call))
}

pub(crate) fn delete(
    table: &TableRef,
    columns: &[ColumnInfo],
    identity: &RowIdentity,
    key: &[Value],
) -> Result<Statement, BuildSqlError> {
    let mut params = ShellParams::new();
    let filter = key_filter(columns, identity, key, &mut params)?;
    let mut call = collection(table);
    call.methods.push(ShellMethod::new("deleteOne", vec![filter]));
    Ok(params.statement(&call))
}

/// How many documents a key names, counting no further than two.
pub(crate) fn key_probe(
    table: &TableRef,
    columns: &[ColumnInfo],
    identity: &RowIdentity,
    key: &[Value],
) -> Result<Statement, BuildSqlError> {
    let mut params = ShellParams::new();
    let filter = key_filter(columns, identity, key, &mut params)?;
    let mut call = collection(table);
    call.methods.push(ShellMethod::new(
        "countDocuments",
        vec![filter, field("limit", ShellValue::integer(2))],
    ));
    Ok(params.statement(&call))
}

/// The document a key names, `{_id: $n}`.
fn key_filter(
    columns: &[ColumnInfo],
    identity: &RowIdentity,
    key: &[Value],
    params: &mut ShellParams,
) -> Result<ShellValue, BuildSqlError> {
    let names = key_names(identity)?;
    if names.len() != key.len() {
        return Err(BuildSqlError::LengthMismatch {
            expected: names.len(),
            found: key.len(),
        });
    }
    let mut fields = Vec::with_capacity(names.len());
    for (name, value) in names.iter().zip(key) {
        if matches!(value, Value::Undecodable(_)) {
            return Err(BuildSqlError::UndecodableKey);
        }
        let column = columns
            .iter()
            .find(|column| &column.name == name)
            .ok_or_else(|| BuildSqlError::UnknownKeyColumn { name: name.clone() })?;
        fields.push((name.clone(), params.bind(value.clone(), Some(column))?));
    }
    Ok(ShellValue::Object(fields))
}

fn key_names(identity: &RowIdentity) -> Result<&[String], BuildSqlError> {
    match identity {
        RowIdentity::UniqueKey { columns } => Ok(columns),
        RowIdentity::SortingKey { expressions } => Ok(expressions),
        RowIdentity::EngineRowId(_) => Err(BuildSqlError::NoRowIdentity),
        RowIdentity::Unordered => Err(BuildSqlError::ReadOnlyRows),
    }
}
