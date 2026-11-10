use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use tablepro_core::browse::{ExportRequest, build_export};
use tablepro_core::column::ResultColumn;
use tablepro_core::export::{CsvOptions, render_csv, render_json, render_sql_insert};
use tablepro_core::{ColumnInfo, ReadStatement, TableRef, Value};
use tablepro_session::Session;
use tokio_util::sync::CancellationToken;

use crate::browse_request::filter_set;
use crate::connection_tools::to_json;
use crate::query_tools::{DEFAULT_TIMEOUT_SECONDS, row_limit, stream, table_shape};
use crate::tool_args::{ExportArgs, ExportFormat};
use crate::tool_context::ToolContext;
use crate::tool_error::ToolError;

// The answer is inline, so the tables a call names bound its size along with max_rows.
pub const MAX_EXPORT_TABLES: usize = 20;

#[derive(Serialize)]
struct ExportDocument {
    format: ExportFormat,
    exports: Vec<TableExport>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    notes: Vec<&'static str>,
}

#[derive(Serialize)]
struct TableExport {
    table: String,
    row_count: usize,
    truncated: bool,
    data: String,
}

pub async fn export_data(
    context: &ToolContext,
    args: ExportArgs,
    cancel: CancellationToken,
) -> Result<String, ToolError> {
    let connection = context.connection(&args.connection_id)?;
    let limit = row_limit(args.max_rows, "max_rows")?;
    match args.tables.len() {
        0 => return Err(ToolError::InvalidArgument("tables names no table".to_owned())),
        count if count > MAX_EXPORT_TABLES => {
            return Err(ToolError::InvalidArgument(format!(
                "tables names {count} tables; one call exports {MAX_EXPORT_TABLES} at most"
            )));
        }
        _ => {}
    }
    if args.tables.iter().any(String::is_empty) {
        return Err(ToolError::InvalidArgument("tables holds an empty name".to_owned()));
    }
    let session = context
        .held_session(&connection, args.database.as_deref())
        .await?
        .session;
    let mut exports = Vec::with_capacity(args.tables.len());
    let mut undecodable = false;
    for name in args.tables {
        let table = TableRef::new(args.schema.clone(), name);
        let (export, lossy) = export_table(&session, table, args.format, limit, &cancel).await?;
        exports.push(export);
        undecodable |= lossy;
    }
    let notes = match undecodable {
        true => vec!["Some values could not be decoded by TablePro and are written as null."],
        false => Vec::new(),
    };
    to_json(&ExportDocument {
        format: args.format,
        exports,
        notes,
    })
}

// The flag says a value the driver could not decode went out as null.
async fn export_table(
    session: &Session,
    table: TableRef,
    format: ExportFormat,
    limit: usize,
    cancel: &CancellationToken,
) -> Result<(TableExport, bool), ToolError> {
    let (columns, identity) = table_shape(session, &table).await?;
    let catalog: Arc<[ColumnInfo]> = columns.into();
    let filter = filter_set(&[], None)?;
    let read_table = table.clone();
    let read_catalog = catalog.clone();
    let mut collected = stream(
        session,
        limit,
        Duration::from_secs(u64::from(DEFAULT_TIMEOUT_SECONDS)),
        cancel,
        Some(catalog.clone()),
        move |lease| {
            let request = ExportRequest {
                table: &read_table,
                columns: &read_catalog,
                filter: &filter,
                sort: &[],
                identity: &identity,
            };
            Ok(ReadStatement::Generated(build_export(&*lease.dialect(), &request)?))
        },
    )
    .await?;
    // An empty table can end the read before it names its columns.
    let (result_columns, rows, truncated) = match collected.sets.pop() {
        Some(set) => (set.columns, set.rows, set.truncated),
        None => (
            catalog.iter().map(ColumnInfo::result_column).collect(),
            Vec::new(),
            false,
        ),
    };
    let data = render(session, format, &table, &catalog, &result_columns, &rows)?;
    let export = TableExport {
        row_count: rows.len(),
        truncated,
        data,
        table: table.name,
    };
    Ok((export, collected.undecodable))
}

fn render(
    session: &Session,
    format: ExportFormat,
    table: &TableRef,
    catalog: &[ColumnInfo],
    columns: &[ResultColumn],
    rows: &[Vec<Value>],
) -> Result<String, ToolError> {
    let encoded = match format {
        ExportFormat::Csv => render_csv(columns, rows, &CsvOptions::default()),
        ExportFormat::Json => render_json(columns, rows),
        ExportFormat::Sql => {
            let dialect = session
                .current_dialect()
                .ok_or_else(|| ToolError::NotConnected("the connection was closed in TablePro".to_owned()))?;
            // The table export's own statements: a column the server computes is left out, and
            // one it numbers keeps its value so other rows still point at it.
            let generated = names(catalog, |column| column.is_generated);
            let numbered = names(catalog, |column| column.is_auto_increment);
            return Ok(render_sql_insert(
                &*dialect, table, columns, &generated, &numbered, rows,
            ));
        }
    };
    encoded.map_err(|error| ToolError::Internal(error.to_string()))
}

fn names(catalog: &[ColumnInfo], keep: impl Fn(&ColumnInfo) -> bool) -> Vec<String> {
    catalog
        .iter()
        .filter(|column| keep(column))
        .map(|column| column.name.clone())
        .collect()
}
