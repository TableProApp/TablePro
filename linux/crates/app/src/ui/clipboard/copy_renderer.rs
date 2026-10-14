use std::sync::Arc;

use tablepro_core::column::{ColumnInfo, ResultColumn};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::CellInput;
use tablepro_core::export::{
    self, CsvEncoder, CsvOptions, EncodeError, JsonArrayEncoder, MarkdownEncoder, RenderInsertError, RowEncoder,
    TsvEncoder,
};
use tablepro_core::meta::TableRef;
use tablepro_core::value::Value;
use tablepro_session::runtime::{TaskResult, Tasks};
use thiserror::Error;

use super::{ClipboardFormat, ClipboardPayload};
use crate::ui::grid::RowSnapshot;

/// What a copy holds, taken on the GTK thread and rendered off it.
#[derive(Debug)]
pub enum CopyRequest {
    /// Rows as the grid shows them, under its visible columns.
    Rows {
        columns: Arc<[ResultColumn]>,
        rows: Vec<RowSnapshot>,
        kind: CopyKind,
    },
    Insert(InsertCopy),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CopyKind {
    /// One cell of the first row.
    Value(usize),
    Rows,
    RowsWithHeaders,
    Csv,
    CsvWithHeaders,
    Json,
    Markdown,
    /// One column's values as an IN list.
    InClause(usize),
}

/// Rows as INSERT statements for the server the tab reads. A draft's
/// cells come as its save would write them, so the columns the server
/// fills stay out of its statement.
#[derive(Debug)]
pub struct InsertCopy {
    pub dialect: Arc<dyn SqlDialect>,
    pub table: TableRef,
    pub columns: Arc<[ColumnInfo]>,
    pub rows: Vec<Vec<CellInput>>,
}

#[derive(Debug, Error)]
pub(crate) enum CopyError {
    #[error(transparent)]
    Encode(#[from] EncodeError),
    #[error(transparent)]
    Insert(#[from] RenderInsertError),
    /// Every value was NULL or binary, and `()` is not SQL anywhere.
    #[error("no value can go in an IN list")]
    EmptyInClause,
}

/// Render `request` on the blocking pool: a copy of every row can take
/// long enough to stall the window.
pub(crate) fn render_copy(tasks: &Tasks, request: CopyRequest) -> TaskResult<Result<ClipboardPayload, CopyError>> {
    tasks.spawn_blocking_task(move || render(request))
}

pub(crate) fn render(request: CopyRequest) -> Result<ClipboardPayload, CopyError> {
    match request {
        CopyRequest::Rows { columns, rows, kind } => render_rows(columns, &rows, kind),
        CopyRequest::Insert(insert) => render_insert(insert),
    }
}

fn render_rows(
    columns: Arc<[ResultColumn]>,
    rows: &[RowSnapshot],
    kind: CopyKind,
) -> Result<ClipboardPayload, CopyError> {
    match kind {
        CopyKind::Value(column) => value_text(&columns, rows, column).map(ClipboardPayload::plain),
        CopyKind::Rows => encode(TsvEncoder::new(columns, false), rows, ClipboardFormat::Tsv),
        CopyKind::RowsWithHeaders => encode(TsvEncoder::new(columns, true), rows, ClipboardFormat::Tsv),
        CopyKind::Csv => encode(
            CsvEncoder::new(
                columns,
                CsvOptions {
                    header_row: false,
                    ..CsvOptions::default()
                },
            ),
            rows,
            ClipboardFormat::Csv,
        ),
        CopyKind::CsvWithHeaders => encode(
            CsvEncoder::new(columns, CsvOptions::default()),
            rows,
            ClipboardFormat::Csv,
        ),
        CopyKind::Json => encode(JsonArrayEncoder::new(columns), rows, ClipboardFormat::Json),
        CopyKind::Markdown => encode(MarkdownEncoder::new(columns), rows, ClipboardFormat::Markdown),
        CopyKind::InClause(column) => {
            let clause = export::render_in_clause(rows.iter().map(|row| row.value(column)));
            if clause.sql.is_empty() {
                return Err(CopyError::EmptyInClause);
            }
            Ok(ClipboardPayload {
                text: clause.sql,
                format: ClipboardFormat::Sql,
                rows: rows.len() - clause.skipped,
                skipped: clause.skipped,
            })
        }
    }
}

/// The cell's full text, never the grid's display form, which stands in
/// `<NULL>` for a NULL and cuts long values.
fn value_text(columns: &[ResultColumn], rows: &[RowSnapshot], column: usize) -> Result<String, CopyError> {
    let Some(value) = rows.first().map(|row| row.value(column)) else {
        return Ok(String::new());
    };
    if let Value::Undecodable(_) = value {
        return Err(EncodeError::Undecodable {
            column: columns
                .get(column)
                .map_or_else(|| (column + 1).to_string(), |column| column.name.clone()),
        }
        .into());
    }
    Ok(export::cell_text(columns, column, value).unwrap_or_default())
}

fn encode(
    mut encoder: impl RowEncoder,
    rows: &[RowSnapshot],
    format: ClipboardFormat,
) -> Result<ClipboardPayload, CopyError> {
    let mut out = Vec::new();
    encoder.begin(&mut out);
    for row in rows {
        encoder.row(&mut out, &mut row.values())?;
    }
    encoder.finish(&mut out);
    Ok(ClipboardPayload {
        // Every encoder writes UTF-8, so the lossy branch is never taken.
        text: String::from_utf8(out).unwrap_or_else(|error| String::from_utf8_lossy(error.as_bytes()).into_owned()),
        format,
        rows: rows.len(),
        skipped: 0,
    })
}

fn render_insert(insert: InsertCopy) -> Result<ClipboardPayload, CopyError> {
    let statements = insert
        .rows
        .iter()
        .map(|cells| export::render_insert(&*insert.dialect, &insert.table, &insert.columns, cells))
        .collect::<Result<Vec<String>, _>>()?;
    Ok(ClipboardPayload {
        text: statements.join("\n"),
        format: ClipboardFormat::Sql,
        rows: insert.rows.len(),
        skipped: 0,
    })
}
