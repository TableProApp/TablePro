use crate::browse::{
    BrowseSqlError, ExportRequest, PageLayout, PageRequest, PageSpec, PagingMode, RowKeyLayout, SortKey,
};
use crate::column::ColumnInfo;
use crate::dialect::TablePaging;
use crate::dml::BuildSqlError;
use crate::filter::FilterSet;
use crate::meta::{PageCost, PagePosition, PageStability, RowIdentity, TableRef};
use crate::sql_syntax::mongo::{CallRoot, ShellCall, ShellMethod, ShellValue, is_addressable_field};
use crate::statement::Statement;
use crate::value::Value;

use super::document_filter::{field, filter_document};
use super::shell_params::ShellParams;
use super::value_order::aliases_beyond;

/// One page of a collection: an aggregate that filters, orders on the
/// sort and then `_id`, and projects the columns in order.
///
/// With no sort the page seeks on `_id`: past the edge key within its
/// type, and on into the types MongoDB sorts after it, so a collection
/// whose ids differ in type still pages through every document. A view
/// has no key, so its pages are counted off in the order it gives, and
/// its rows take no edits.
pub(crate) fn page(request: &PageRequest<'_>) -> Result<PageSpec, BrowseSqlError> {
    let key = key_column(request.identity, request.columns)?;
    let mut params = ShellParams::new();
    let mut conditions: Vec<ShellValue> = filter_document(request.columns, request.filter, &mut params)?
        .into_iter()
        .collect();
    let mode = crate::browse::paging_mode(TablePaging::InStatement, request.identity, request.sort);
    let user = user_sort(request.columns, request.sort)?;
    let seek = match mode {
        PagingMode::Keyset => PageCost::KeySeek,
        PagingMode::CtidWindow | PagingMode::Offset | PagingMode::ServerPaging => PageCost::SortPerPage,
    };
    let (backward, skip, stability, cost) = match (mode, request.position) {
        (_, PagePosition::First) => (false, 0, PageStability::Stable, seek),
        (PagingMode::Keyset, PagePosition::Last) => (true, 0, PageStability::Stable, PageCost::KeySeek),
        (_, PagePosition::Offset(offset)) => (false, *offset, PageStability::Stable, PageCost::SortPerPage),
        (PagingMode::Keyset, PagePosition::AfterKey(anchor) | PagePosition::BeforeKey(anchor)) => {
            let Some((column, _)) = key else {
                return Err(BrowseSqlError::UnsupportedPosition { mode });
            };
            let after = matches!(request.position, PagePosition::AfterKey(_));
            conditions.push(past_key(&column.name, anchor, after, &mut params)?);
            (!after, 0, PageStability::Stable, PageCost::KeySeek)
        }
        _ => return Err(BrowseSqlError::UnsupportedPosition { mode }),
    };
    let mut sort = user;
    let stability = match key {
        Some((column, _)) => {
            sort.push((column.name.clone(), if backward { -1 } else { 1 }));
            stability
        }
        None if sort.is_empty() => PageStability::Unordered,
        None => PageStability::NonUniqueOrder,
    };
    let mut stages = Vec::new();
    if let Some(filter) = joined(conditions) {
        stages.push(field("$match", filter));
    }
    // A `$sort` with no field is refused, and a view with no sort keeps
    // the order its pipeline gives.
    if !sort.is_empty() {
        stages.push(field("$sort", sort_document(sort)));
    }
    if skip > 0 {
        stages.push(field("$skip", ShellValue::integer(saturating_i64(skip))));
    }
    stages.push(field(
        "$limit",
        ShellValue::integer(saturating_i64(request.limit.max(1))),
    ));
    stages.push(field("$project", projection(request.columns)));
    let statement = params.statement(&aggregate(request.table, stages));
    Ok(PageSpec {
        statement,
        layout: PageLayout {
            visible: 0..request.columns.len(),
            identity: request.columns.len()..request.columns.len(),
        },
        row_key: match key {
            Some((_, index)) => RowKeyLayout::Columns(vec![index]),
            None => RowKeyLayout::ReadOnly,
        },
        stability,
        cost,
    })
}

/// How many documents the filter matches.
pub(crate) fn count(table: &TableRef, columns: &[ColumnInfo], filter: &FilterSet) -> Result<Statement, BrowseSqlError> {
    let mut params = ShellParams::new();
    let filter = filter_document(columns, filter, &mut params)?.unwrap_or(ShellValue::Object(Vec::new()));
    let mut call = collection(table);
    call.methods.push(ShellMethod::new("countDocuments", vec![filter]));
    Ok(params.statement(&call))
}

/// Every document the filter matches, in the page's order, for an export.
pub(crate) fn export(request: &ExportRequest<'_>) -> Result<Statement, BrowseSqlError> {
    let key = key_column(request.identity, request.columns)?;
    let mut params = ShellParams::new();
    let mut stages = Vec::new();
    if let Some(filter) = filter_document(request.columns, request.filter, &mut params)? {
        stages.push(field("$match", filter));
    }
    let mut sort = user_sort(request.columns, request.sort)?;
    if let Some((column, _)) = key {
        sort.push((column.name.clone(), 1));
    }
    if !sort.is_empty() {
        stages.push(field("$sort", sort_document(sort)));
    }
    stages.push(field("$project", projection(request.columns)));
    Ok(params.statement(&aggregate(request.table, stages)))
}

/// The call chain that names a collection, in its own database where
/// the table names one.
pub(crate) fn collection(table: &TableRef) -> ShellCall {
    ShellCall {
        root: CallRoot::Db,
        database: table.schema.clone(),
        collection: Some(table.name.clone()),
        methods: Vec::new(),
    }
}

fn aggregate(table: &TableRef, stages: Vec<ShellValue>) -> ShellCall {
    let mut call = collection(table);
    call.methods.push(ShellMethod::new(
        "aggregate",
        vec![ShellValue::Array(stages), field("allowDiskUse", ShellValue::Bool(true))],
    ));
    call
}

/// The one column a document is named by, and where it sits: none for
/// a view, whose documents nothing names.
fn key_column<'a>(
    identity: &RowIdentity,
    columns: &'a [ColumnInfo],
) -> Result<Option<(&'a ColumnInfo, usize)>, BrowseSqlError> {
    let names = match identity {
        RowIdentity::UniqueKey { columns: names } => names,
        RowIdentity::Unordered => return Ok(None),
        RowIdentity::SortingKey { .. } | RowIdentity::EngineRowId(_) => {
            return Err(BuildSqlError::NoRowIdentity.into());
        }
    };
    let [name] = names.as_slice() else {
        return Err(BuildSqlError::NoRowIdentity.into());
    };
    columns
        .iter()
        .enumerate()
        .find(|(_, column)| &column.name == name)
        .map(|(index, column)| Some((column, index)))
        .ok_or_else(|| BuildSqlError::UnknownKeyColumn { name: name.clone() }.into())
}

fn user_sort(columns: &[ColumnInfo], sort: &[SortKey]) -> Result<Vec<(String, i64)>, BrowseSqlError> {
    sort.iter()
        .map(|key| {
            let column = columns
                .get(key.column)
                .ok_or(BrowseSqlError::UnknownSortColumn(key.column))?;
            if !is_addressable_field(&column.name) {
                return Err(BuildSqlError::UnaddressableField {
                    name: column.name.clone(),
                }
                .into());
            }
            Ok((column.name.clone(), if key.ascending { 1 } else { -1 }))
        })
        .collect()
}

fn sort_document(sort: Vec<(String, i64)>) -> ShellValue {
    let mut fields: Vec<(String, ShellValue)> = Vec::with_capacity(sort.len());
    for (name, direction) in sort {
        // The key closes the order, and a user sort on it already did.
        if !fields.iter().any(|(existing, _)| *existing == name) {
            fields.push((name, ShellValue::integer(direction)));
        }
    }
    ShellValue::Object(fields)
}

/// The columns in order. A field whose name has a dot or starts with `$`
/// is read with `$getField` under a name of its own, since a projection
/// key would read it as a path. The name is one no column has.
fn projection(columns: &[ColumnInfo]) -> ShellValue {
    let mut prefix = String::from("__field_");
    while columns.iter().any(|column| column.name.starts_with(&prefix)) {
        prefix.insert(0, '_');
    }
    ShellValue::Object(
        columns
            .iter()
            .enumerate()
            .map(|(index, column)| match is_addressable_field(&column.name) {
                true => (column.name.clone(), ShellValue::integer(1)),
                false => (
                    format!("{prefix}{index}"),
                    field(
                        "$getField",
                        ShellValue::Object(vec![
                            ("field".to_owned(), field("$literal", ShellValue::string(&column.name))),
                            ("input".to_owned(), ShellValue::string("$$ROOT")),
                        ]),
                    ),
                ),
            })
            .collect(),
    )
}

/// The documents past `anchor`: a greater key of the same type, or any
/// key of a type MongoDB sorts later. A key of a type with no known place
/// is compared with `$expr`, which orders across types.
fn past_key(key: &str, anchor: &[Value], after: bool, params: &mut ShellParams) -> Result<ShellValue, BrowseSqlError> {
    let [value] = anchor else {
        return Err(BuildSqlError::LengthMismatch {
            expected: 1,
            found: anchor.len(),
        }
        .into());
    };
    match value {
        Value::Null => return Err(BrowseSqlError::NullAnchor),
        Value::Undecodable(_) => return Err(BuildSqlError::UndecodableKey.into()),
        _ => {}
    }
    let comparison = if after { "$gt" } else { "$lt" };
    let marker = params.bind(value.clone(), None)?;
    let Some(beyond) = aliases_beyond(value, after) else {
        return Ok(field(
            "$expr",
            field(
                comparison,
                ShellValue::Array(vec![ShellValue::string(format!("${key}")), marker]),
            ),
        ));
    };
    let within = field(key, field(comparison, marker));
    if beyond.is_empty() {
        return Ok(within);
    }
    let types = ShellValue::Array(beyond.into_iter().map(ShellValue::string).collect());
    Ok(field(
        "$or",
        ShellValue::Array(vec![within, field(key, field("$type", types))]),
    ))
}

fn joined(mut conditions: Vec<ShellValue>) -> Option<ShellValue> {
    match conditions.len() {
        0 => None,
        1 => conditions.pop(),
        _ => Some(field("$and", ShellValue::Array(conditions))),
    }
}

fn saturating_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}
