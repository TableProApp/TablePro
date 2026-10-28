use std::sync::Arc;

use tablepro_core::column::{ColumnInfo, ColumnType, ResultColumn};
use tablepro_core::dialect::{LiteralError, SqlDialect};
use tablepro_core::edit::CellInput;
use tablepro_core::export::{
    self, CellsEncoder, CsvEncoder, CsvOptions, EncodeError, JsonArrayEncoder, JsonLinesEncoder, MarkdownEncoder,
    OneRowEncoder, PrettyTableEncoder, RenderInsertError, RowEncoder, TsvEncoder,
};
use tablepro_core::meta::TableRef;
use tablepro_core::value::Value;
use tablepro_session::runtime::{TaskResult, Tasks};
use thiserror::Error;

use super::clipboard_writer::holds_nul;
use super::{ClipboardFormat, ClipboardPayload};
use crate::services::grid::RowSnapshot;

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
    /// One column's values as an IN list, in the spelling of the engine
    /// the rows came from.
    InClause {
        dialect: Arc<dyn SqlDialect>,
        values: InClauseRows,
    },
}

/// One column of the rows a user picked, for an IN list.
#[derive(Debug)]
pub struct InClauseRows {
    pub columns: Arc<[ResultColumn]>,
    pub rows: Vec<RowSnapshot>,
    pub column: usize,
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
    JsonLines,
    Markdown,
    PrettyTable,
    OneRow,
}

/// Rows as INSERT statements for the server the tab reads.
#[derive(Debug)]
pub struct InsertCopy {
    pub dialect: Arc<dyn SqlDialect>,
    pub table: TableRef,
    pub columns: Arc<[ColumnInfo]>,
    pub rows: Vec<InsertRow>,
}

#[derive(Debug)]
pub enum InsertRow {
    /// A row the table holds, with its pending edits.
    Saved(RowSnapshot),
    /// A draft's cells as its save would write them, so the columns the
    /// server fills stay out of its statement.
    Draft(Vec<CellInput>),
}

#[derive(Debug, Error)]
pub(crate) enum CopyError {
    #[error(transparent)]
    Encode(#[from] EncodeError),
    #[error(transparent)]
    Insert(#[from] RenderInsertError),
    #[error(transparent)]
    Literal(#[from] LiteralError),
    /// Every value was NULL or binary, and `()` is not SQL anywhere.
    #[error("no value can go in an IN list")]
    EmptyInClause,
    #[error("the text holds a NUL character")]
    ContainsNul,
}

/// Render `request` on the blocking pool: a copy of every row can take
/// long enough to stall the window.
pub(crate) fn render_copy(tasks: &Tasks, request: CopyRequest) -> TaskResult<Result<ClipboardPayload, CopyError>> {
    tasks.spawn_blocking_task(move || render(request))
}

pub(crate) fn render(request: CopyRequest) -> Result<ClipboardPayload, CopyError> {
    let payload = match request {
        CopyRequest::Rows { columns, rows, kind } => render_rows(columns, &rows, kind),
        CopyRequest::Insert(insert) => render_insert(insert),
        CopyRequest::InClause { dialect, values } => render_in_clause(&*dialect, &values),
    }?;
    if holds_nul(&payload.text) {
        return Err(CopyError::ContainsNul);
    }
    Ok(payload)
}

fn render_rows(
    columns: Arc<[ResultColumn]>,
    rows: &[RowSnapshot],
    kind: CopyKind,
) -> Result<ClipboardPayload, CopyError> {
    let cells = copied_cells(&columns, rows, kind)?;
    let payload = match kind {
        CopyKind::Value(column) => value_text(&columns, rows, column).map(ClipboardPayload::plain),
        CopyKind::Rows => encode(TsvEncoder::new(columns, false), rows, ClipboardFormat::Tsv),
        CopyKind::RowsWithHeaders => encode(TsvEncoder::new(columns, true), rows, ClipboardFormat::Tsv),
        CopyKind::Csv => encode(
            CsvEncoder::new(columns, clipboard_csv(false)),
            rows,
            ClipboardFormat::Csv,
        ),
        CopyKind::CsvWithHeaders => encode(
            CsvEncoder::new(columns, clipboard_csv(true)),
            rows,
            ClipboardFormat::Csv,
        ),
        CopyKind::Json => encode(JsonArrayEncoder::new(columns), rows, ClipboardFormat::Json),
        CopyKind::JsonLines => encode(JsonLinesEncoder::new(columns), rows, ClipboardFormat::PlainText),
        CopyKind::Markdown => encode(MarkdownEncoder::new(columns), rows, ClipboardFormat::Markdown),
        CopyKind::PrettyTable => encode(PrettyTableEncoder::new(columns), rows, ClipboardFormat::PlainText),
        CopyKind::OneRow => encode(OneRowEncoder::new(columns), rows, ClipboardFormat::PlainText),
    }?;
    Ok(ClipboardPayload {
        cells: Some(cells),
        ..payload
    })
}

/// The cells beside the text, which a paste reads back as they were.
/// A copy that names its columns lets the paste place values by name.
fn copied_cells(columns: &Arc<[ResultColumn]>, rows: &[RowSnapshot], kind: CopyKind) -> Result<String, CopyError> {
    let with_headers = match kind {
        CopyKind::Value(_) | CopyKind::Rows | CopyKind::Csv | CopyKind::OneRow => false,
        CopyKind::RowsWithHeaders
        | CopyKind::CsvWithHeaders
        | CopyKind::Json
        | CopyKind::JsonLines
        | CopyKind::Markdown
        | CopyKind::PrettyTable => true,
    };
    let CopyKind::Value(column) = kind else {
        return encoded(CellsEncoder::new(columns.clone(), with_headers), rows);
    };
    let mut encoder = CellsEncoder::new(columns.get(column).cloned().into_iter().collect(), with_headers);
    let mut out = Vec::new();
    encoder.begin(&mut out);
    if let Some(row) = rows.first() {
        encoder.row(&mut out, &mut std::iter::once(row.value(column)))?;
    }
    encoder.finish(&mut out);
    Ok(utf8(out))
}

/// CSV as the clipboard carries it. Copied text goes as the user sees
/// it: the apostrophe an export puts before `-` or `@alice` would be
/// pasted into every other place the text goes too.
fn clipboard_csv(header_row: bool) -> CsvOptions {
    CsvOptions {
        header_row,
        sanitize_formulas: false,
        ..CsvOptions::default()
    }
}

fn render_in_clause(dialect: &dyn SqlDialect, values: &InClauseRows) -> Result<ClipboardPayload, CopyError> {
    let InClauseRows { columns, rows, column } = values;
    let column_type = columns
        .get(*column)
        .map_or_else(|| ColumnType::untyped_text("text"), |column| column.column_type.clone());
    let clause = export::render_in_clause(dialect, &column_type, rows.iter().map(|row| row.value(*column)))?;
    if clause.sql.is_empty() {
        return Err(CopyError::EmptyInClause);
    }
    Ok(ClipboardPayload {
        text: clause.sql,
        format: ClipboardFormat::Sql,
        rows: rows.len() - clause.skipped,
        skipped: clause.skipped,
        cells: None,
    })
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
    encoder: impl RowEncoder,
    rows: &[RowSnapshot],
    format: ClipboardFormat,
) -> Result<ClipboardPayload, CopyError> {
    Ok(ClipboardPayload {
        text: encoded(encoder, rows)?,
        format,
        rows: rows.len(),
        skipped: 0,
        cells: None,
    })
}

fn encoded(mut encoder: impl RowEncoder, rows: &[RowSnapshot]) -> Result<String, CopyError> {
    let mut out = Vec::new();
    encoder.begin(&mut out);
    for row in rows {
        encoder.row(&mut out, &mut row.values())?;
    }
    encoder.finish(&mut out);
    Ok(utf8(out))
}

/// Every encoder writes UTF-8, so the lossy branch is never taken.
fn utf8(out: Vec<u8>) -> String {
    String::from_utf8(out).unwrap_or_else(|error| String::from_utf8_lossy(error.as_bytes()).into_owned())
}

fn render_insert(insert: InsertCopy) -> Result<ClipboardPayload, CopyError> {
    let InsertCopy {
        dialect,
        table,
        columns,
        rows,
    } = insert;
    let statements = rows
        .iter()
        .map(|row| match row {
            InsertRow::Saved(snapshot) => {
                // A row id read after the columns has no place in the
                // statement, so it is not copied.
                let cells: Vec<CellInput> = snapshot
                    .values()
                    .take(columns.len())
                    .cloned()
                    .map(CellInput::Value)
                    .collect();
                export::render_insert(&*dialect, &table, &columns, &cells)
            }
            InsertRow::Draft(cells) => export::render_insert(&*dialect, &table, &columns, cells),
        })
        .collect::<Result<Vec<String>, _>>()?;
    Ok(ClipboardPayload {
        text: statements.join("\n"),
        format: ClipboardFormat::Sql,
        rows: rows.len(),
        skipped: 0,
        cells: None,
    })
}
