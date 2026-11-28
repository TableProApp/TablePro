use std::sync::Arc;

use thiserror::Error;

use crate::column::{ColumnInfo, ColumnType, ResultColumn};
use crate::dialect::{LiteralError, SqlDialect};
use crate::edit::CellInput;
use crate::export::{
    self, CellsEncoder, CsvEncoder, CsvOptions, EncodeError, JsonArrayEncoder, JsonLinesEncoder, MarkdownEncoder,
    RenderInsertError, RowEncoder, TextTableError, TsvEncoder,
};
use crate::grid::clipboard::{ClipboardFormat, ClipboardPayload, holds_nul};
use crate::meta::TableRef;
use crate::value::Value;

static NULL: Value = Value::Null;

/// A row a copy reads, pending edits included. The grid holds its rows its
/// own way; a copy reaches their cells through this.
pub trait CopyRow {
    /// How many cells the row has.
    fn width(&self) -> usize;

    /// The cell at `column`, NULL for one past the row's end.
    fn value(&self, column: usize) -> &Value;

    /// The row's cells in order.
    fn values(&self) -> RowValues<'_, Self> {
        RowValues { row: self, column: 0 }
    }
}

/// An iterator over a row's cells, kept concrete so the encoders take it as
/// one `dyn Iterator`.
pub struct RowValues<'a, R: ?Sized> {
    row: &'a R,
    column: usize,
}

impl<'a, R: CopyRow + ?Sized> Iterator for RowValues<'a, R> {
    type Item = &'a Value;

    fn next(&mut self) -> Option<&'a Value> {
        if self.column >= self.row.width() {
            return None;
        }
        let value = self.row.value(self.column);
        self.column += 1;
        Some(value)
    }
}

impl CopyRow for Vec<Value> {
    fn width(&self) -> usize {
        self.len()
    }

    fn value(&self, column: usize) -> &Value {
        self.get(column).unwrap_or(&NULL)
    }
}

/// What a copy holds, taken on the grid's thread and rendered off it.
#[derive(Debug)]
pub enum CopyRequest<R> {
    /// Rows as the grid shows them, under its visible columns.
    Rows {
        columns: Arc<[ResultColumn]>,
        rows: Vec<R>,
        kind: CopyKind,
    },
    Insert(InsertCopy<R>),
    /// One column's values as an IN list, in the spelling of the engine the
    /// rows came from.
    InClause {
        dialect: Arc<dyn SqlDialect>,
        values: InClauseRows<R>,
    },
    /// Every value of the rows as one list of the engine's literals.
    Values {
        dialect: Arc<dyn SqlDialect>,
        columns: Arc<[ResultColumn]>,
        rows: Vec<R>,
    },
}

/// One column of the rows a user picked, for an IN list.
#[derive(Debug)]
pub struct InClauseRows<R> {
    pub columns: Arc<[ResultColumn]>,
    pub rows: Vec<R>,
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
    TextTable,
}

/// Rows as INSERT statements for the server the tab reads.
#[derive(Debug)]
pub struct InsertCopy<R> {
    pub dialect: Arc<dyn SqlDialect>,
    pub table: TableRef,
    pub columns: Arc<[ColumnInfo]>,
    pub rows: Vec<InsertRow<R>>,
}

#[derive(Debug)]
pub enum InsertRow<R> {
    /// A row the table holds, with its pending edits.
    Saved(R),
    /// A draft's cells as its save would write them, so the columns the
    /// server fills stay out of its statement.
    Draft(Vec<CellInput>),
}

#[derive(Debug, Error)]
pub enum CopyError {
    #[error(transparent)]
    Encode(#[from] EncodeError),
    #[error(transparent)]
    Insert(#[from] RenderInsertError),
    #[error(transparent)]
    Literal(#[from] LiteralError),
    /// Every value was NULL or binary, and `()` is not SQL anywhere.
    #[error("no value can go in an IN list")]
    EmptyInClause,
    #[error("the text table would be too large")]
    TextTableTooLarge,
    #[error("the text holds a NUL character")]
    ContainsNul,
}

/// Render `request` into a payload for the clipboard. A copy of every row
/// can take long enough to stall a window, so the app runs this off its UI
/// thread.
pub fn render<R: CopyRow>(request: CopyRequest<R>) -> Result<ClipboardPayload, CopyError> {
    let payload = match request {
        CopyRequest::Rows { columns, rows, kind } => render_rows(columns, &rows, kind),
        CopyRequest::Insert(insert) => render_insert(insert),
        CopyRequest::InClause { dialect, values } => render_in_clause(&*dialect, &values),
        CopyRequest::Values { dialect, columns, rows } => render_values(&*dialect, &columns, &rows),
    }?;
    if holds_nul(&payload.text) {
        return Err(CopyError::ContainsNul);
    }
    Ok(payload)
}

fn render_rows<R: CopyRow>(
    columns: Arc<[ResultColumn]>,
    rows: &[R],
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
        // No desktop type names JSON Lines, and several values are not one
        // `application/json` document.
        CopyKind::JsonLines => encode(JsonLinesEncoder::new(columns), rows, ClipboardFormat::PlainText),
        CopyKind::Markdown => encode(MarkdownEncoder::new(columns), rows, ClipboardFormat::Markdown),
        CopyKind::TextTable => text_table(&columns, rows),
    }?;
    Ok(ClipboardPayload {
        cells: Some(cells),
        ..payload
    })
}

/// The cells beside the text, which a paste reads back as they were. A copy
/// that names its columns lets the paste place values by name.
fn copied_cells<R: CopyRow>(columns: &Arc<[ResultColumn]>, rows: &[R], kind: CopyKind) -> Result<String, CopyError> {
    let with_headers = match kind {
        CopyKind::Value(_) | CopyKind::Rows | CopyKind::Csv => false,
        CopyKind::RowsWithHeaders
        | CopyKind::CsvWithHeaders
        | CopyKind::Json
        | CopyKind::JsonLines
        | CopyKind::Markdown
        | CopyKind::TextTable => true,
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

/// CSV as the clipboard carries it. Copied text goes as the user sees it:
/// the apostrophe an export puts before `-` or `@alice` would be pasted into
/// every other place the text goes too.
fn clipboard_csv(header_row: bool) -> CsvOptions {
    CsvOptions {
        header_row,
        sanitize_formulas: false,
        ..CsvOptions::default()
    }
}

fn render_in_clause<R: CopyRow>(
    dialect: &dyn SqlDialect,
    values: &InClauseRows<R>,
) -> Result<ClipboardPayload, CopyError> {
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

fn render_values<R: CopyRow>(
    dialect: &dyn SqlDialect,
    columns: &[ResultColumn],
    rows: &[R],
) -> Result<ClipboardPayload, CopyError> {
    Ok(ClipboardPayload {
        text: export::render_value_list(dialect, columns, rows.iter().map(CopyRow::values))?,
        format: ClipboardFormat::Sql,
        rows: rows.len(),
        skipped: 0,
        cells: None,
    })
}

fn text_table<R: CopyRow>(columns: &[ResultColumn], rows: &[R]) -> Result<ClipboardPayload, CopyError> {
    let text = export::render_text_table(columns, rows.iter().map(CopyRow::values)).map_err(|error| match error {
        TextTableError::Encode(error) => CopyError::Encode(error),
        TextTableError::TooLarge => CopyError::TextTableTooLarge,
    })?;
    Ok(ClipboardPayload {
        text,
        format: ClipboardFormat::PlainText,
        rows: rows.len(),
        skipped: 0,
        cells: None,
    })
}

/// The cell's full text, never the grid's display form, which stands in
/// `<NULL>` for a NULL and cuts long values.
fn value_text<R: CopyRow>(columns: &[ResultColumn], rows: &[R], column: usize) -> Result<String, CopyError> {
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

fn encode<R: CopyRow>(
    encoder: impl RowEncoder,
    rows: &[R],
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

fn encoded<R: CopyRow>(mut encoder: impl RowEncoder, rows: &[R]) -> Result<String, CopyError> {
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

fn render_insert<R: CopyRow>(insert: InsertCopy<R>) -> Result<ClipboardPayload, CopyError> {
    let InsertCopy {
        dialect,
        table,
        columns,
        rows,
    } = insert;
    let count = rows.len();
    let cells: Vec<Vec<CellInput>> = rows
        .into_iter()
        .map(|row| match row {
            // A row id read after the columns has no place in the statement,
            // so it is not copied.
            InsertRow::Saved(row) => row
                .values()
                .take(columns.len())
                .cloned()
                .map(CellInput::Value)
                .collect(),
            InsertRow::Draft(cells) => cells,
        })
        .collect();
    Ok(ClipboardPayload {
        text: export::render_inserts(&*dialect, &table, &columns, &cells)?,
        format: ClipboardFormat::Sql,
        rows: count,
        skipped: 0,
        cells: None,
    })
}

#[cfg(test)]
mod tests {
    use crate::column::{ColumnDefault, ColumnInfo, ColumnType, ResultColumn};
    use crate::dialect::TestDialect;
    use crate::edit::CellInput;
    use crate::export::{CsvOptions, render_csv};
    use crate::meta::TableRef;
    use crate::value::Value;

    use super::*;

    fn columns(names: &[&str]) -> Arc<[ResultColumn]> {
        names
            .iter()
            .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
            .collect()
    }

    fn people() -> Vec<Vec<Value>> {
        vec![
            vec![Value::Int(-5), Value::Text("=cmd".into())],
            vec![Value::Int(7), Value::Text("Ada, \"the first\"".into())],
        ]
    }

    fn rows_request(rows: &[Vec<Value>], kind: CopyKind) -> CopyRequest<Vec<Value>> {
        CopyRequest::Rows {
            columns: columns(&["id", "name"]),
            rows: rows.to_vec(),
            kind,
        }
    }

    fn column_info(name: &str, primary_key: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::untyped_text("text"),
            nullable: !primary_key,
            primary_key,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    #[test]
    fn csv_copy_matches_render_csv() {
        let rows = people();
        let cases = [
            (
                CopyKind::Csv,
                CsvOptions {
                    header_row: false,
                    sanitize_formulas: false,
                    ..CsvOptions::default()
                },
            ),
            (
                CopyKind::CsvWithHeaders,
                CsvOptions {
                    sanitize_formulas: false,
                    ..CsvOptions::default()
                },
            ),
        ];
        for (kind, options) in cases {
            let payload = render(rows_request(&rows, kind)).expect("the copy");

            let expected = render_csv(&columns(&["id", "name"]), &rows, &options).expect("the csv");
            assert_eq!(payload.text, expected, "{kind:?}");
            assert_eq!(payload.format, ClipboardFormat::Csv);
            assert_eq!(payload.rows, 2);
            assert!(payload.cells.is_some());
        }
    }

    #[test]
    fn tsv_json_markdown_and_text_table_copies_carry_their_format() {
        let rows = people();
        let tsv = render(rows_request(&rows, CopyKind::Rows)).expect("tsv");
        assert_eq!(tsv.text, "-5\t=cmd\n7\t\"Ada, \"\"the first\"\"\"\n");
        assert_eq!(tsv.format, ClipboardFormat::Tsv);

        let json = render(rows_request(&rows, CopyKind::Json)).expect("json");
        assert_eq!(json.format, ClipboardFormat::Json);
        let parsed: serde_json::Value = serde_json::from_str(&json.text).expect("JSON");
        assert_eq!(parsed[1]["name"], serde_json::json!("Ada, \"the first\""));

        let lines = render(rows_request(&rows, CopyKind::JsonLines)).expect("json lines");
        assert_eq!(lines.format, ClipboardFormat::PlainText);
        assert_eq!(
            lines.text,
            "{\"id\":-5,\"name\":\"=cmd\"}\n{\"id\":7,\"name\":\"Ada, \\\"the first\\\"\"}\n"
        );

        let markdown = render(rows_request(&rows, CopyKind::Markdown)).expect("markdown");
        assert_eq!(markdown.format, ClipboardFormat::Markdown);

        let table = render(rows_request(&rows, CopyKind::TextTable)).expect("table");
        assert_eq!(
            table.text,
            "+----+------------------+\n\
             | id | name             |\n\
             +----+------------------+\n\
             | -5 | =cmd             |\n\
             |  7 | Ada, \"the first\" |\n\
             +----+------------------+"
        );
        assert_eq!(table.format, ClipboardFormat::PlainText);
    }

    #[test]
    fn a_copy_keeps_text_that_starts_like_a_formula_as_it_is() {
        let rows = vec![vec![Value::Text("-".into()), Value::Text("@alice".into())]];

        let tsv = render(rows_request(&rows, CopyKind::Rows)).expect("the copy");
        let csv = render(rows_request(&rows, CopyKind::Csv)).expect("the copy");

        assert_eq!(tsv.text, "-\t@alice\n");
        assert_eq!(csv.text, "-,@alice\n");
    }

    #[test]
    fn copy_as_one_cell_takes_the_full_value() {
        let payload = render(rows_request(&people(), CopyKind::Value(1))).expect("the copy");

        assert_eq!(payload.text, "=cmd");
        assert_eq!(payload.format, ClipboardFormat::PlainText);
    }

    #[test]
    fn copy_insert_uses_visible_columns_only() {
        let request = CopyRequest::Insert(InsertCopy {
            dialect: Arc::new(TestDialect::default()),
            table: TableRef::new(None, "users"),
            columns: vec![column_info("id", true), column_info("name", false)].into(),
            rows: vec![
                // A row read with its engine row id after the visible cells.
                InsertRow::Saved(vec![
                    Value::Int(1),
                    Value::Text("Ada".into()),
                    Value::Text("(0,1)".into()),
                ]),
                InsertRow::Draft(vec![CellInput::Default, CellInput::Value(Value::Text("Grace".into()))]),
            ],
        });

        let payload = render(request).expect("the copy");

        // The saved row drops its trailing row id; the draft leaves out the
        // column the server fills.
        let expected = export::render_inserts(
            &TestDialect::default(),
            &TableRef::new(None, "users"),
            &[column_info("id", true), column_info("name", false)],
            &[
                vec![
                    CellInput::Value(Value::Int(1)),
                    CellInput::Value(Value::Text("Ada".into())),
                ],
                vec![CellInput::Default, CellInput::Value(Value::Text("Grace".into()))],
            ],
        )
        .expect("the inserts");
        assert_eq!(payload.text, expected);
        assert_eq!(payload.format, ClipboardFormat::Sql);
        assert_eq!(payload.rows, 2);
    }

    #[test]
    fn copy_as_values_matches_render_value_list() {
        let rows = vec![
            vec![Value::Int(7), Value::Text("Ada".into())],
            vec![Value::Int(8), Value::Null],
        ];
        let payload = render(CopyRequest::Values {
            dialect: Arc::new(TestDialect::default()),
            columns: columns(&["id", "name"]),
            rows: rows.clone(),
        })
        .expect("the copy");

        let expected = export::render_value_list(
            &TestDialect::default(),
            &columns(&["id", "name"]),
            rows.iter().map(|row| row.iter()),
        )
        .expect("the list");
        assert_eq!(payload.text, expected);
        assert_eq!((payload.format, payload.rows), (ClipboardFormat::Sql, 2));
    }

    #[test]
    fn an_in_clause_skips_null_and_binary_and_counts_them() {
        let rows = vec![
            vec![Value::Int(1), Value::Text("a".into())],
            vec![Value::Int(2), Value::Null],
        ];
        let payload = render(CopyRequest::InClause {
            dialect: Arc::new(TestDialect::default()),
            values: InClauseRows {
                columns: columns(&["id", "name"]),
                rows: rows.clone(),
                column: 1,
            },
        })
        .expect("the copy");

        assert_eq!(
            (payload.format, payload.rows, payload.skipped),
            (ClipboardFormat::Sql, 1, 1)
        );
    }

    #[test]
    fn an_in_clause_of_only_null_is_refused() {
        let refused = render(CopyRequest::InClause {
            dialect: Arc::new(TestDialect::default()),
            values: InClauseRows {
                columns: columns(&["id"]),
                rows: vec![vec![Value::Null]],
                column: 0,
            },
        });

        assert!(matches!(refused, Err(CopyError::EmptyInClause)), "{refused:?}");
    }

    #[test]
    fn a_copy_holding_a_nul_is_refused() {
        let rows = vec![vec![Value::Int(1), Value::Text("a\0b".into())]];

        let refused = render(rows_request(&rows, CopyKind::Rows)).expect_err("a NUL");

        assert!(matches!(refused, CopyError::ContainsNul), "{refused:?}");
    }

    #[test]
    fn a_text_table_too_large_to_hold_is_refused() {
        let long = Value::Text("x".repeat(60_000));
        let rows: Vec<Vec<Value>> = std::iter::once(vec![long])
            .chain((0..1_200).map(|_| vec![Value::Null]))
            .collect();

        let refused = render(CopyRequest::Rows {
            columns: columns(&["note"]),
            rows,
            kind: CopyKind::TextTable,
        });

        assert!(matches!(refused, Err(CopyError::TextTableTooLarge)), "{refused:?}");
    }
}
