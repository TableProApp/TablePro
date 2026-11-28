use std::sync::Arc;

use tablepro_core::column::{ColumnDefault, ColumnInfo, ResultColumn};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::grid::clipboard::ClipboardPayload;
use tablepro_core::grid::copy::{self, CopyError, CopyKind, CopyRequest, InClauseRows, InsertCopy, InsertRow};
use tablepro_core::meta::TableRef;
use tablepro_core::value::Value;

use super::ResultSet;
use crate::error::CoreError;

/// A grid copy format that needs no SQL dialect: the engine-independent
/// spreadsheet and text shapes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum GridCopyFormat {
    Tsv,
    TsvWithHeaders,
    Csv,
    CsvWithHeaders,
    Json,
    JsonLines,
    Markdown,
    TextTable,
}

/// A rendered copy for the clipboard: the text, the cells a paste reads back,
/// the type to offer beside plain text, and the row and skip counts.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GridCopy {
    pub text: String,
    pub cells: Option<String>,
    pub mime_type: Option<String>,
    pub rows: u64,
    pub skipped: u64,
}

impl From<ClipboardPayload> for GridCopy {
    fn from(payload: ClipboardPayload) -> Self {
        Self {
            mime_type: payload.format.mime_type().map(str::to_owned),
            text: payload.text,
            cells: payload.cells,
            rows: payload.rows as u64,
            skipped: payload.skipped as u64,
        }
    }
}

#[uniffi::export]
impl ResultSet {
    /// Copy `rows` under `columns` (result-column indices, in the order the
    /// grid shows them) in a dialect-free format.
    pub fn copy(&self, rows: Vec<u64>, columns: Vec<u32>, format: GridCopyFormat) -> Result<GridCopy, CoreError> {
        let (picked, data) = selection(self, &rows, &columns)?;
        let kind = match format {
            GridCopyFormat::Tsv => CopyKind::Rows,
            GridCopyFormat::TsvWithHeaders => CopyKind::RowsWithHeaders,
            GridCopyFormat::Csv => CopyKind::Csv,
            GridCopyFormat::CsvWithHeaders => CopyKind::CsvWithHeaders,
            GridCopyFormat::Json => CopyKind::Json,
            GridCopyFormat::JsonLines => CopyKind::JsonLines,
            GridCopyFormat::Markdown => CopyKind::Markdown,
            GridCopyFormat::TextTable => CopyKind::TextTable,
        };
        render(CopyRequest::Rows {
            columns: picked,
            rows: data,
            kind,
        })
    }
}

/// `rows` of this result as INSERT statements into `schema`.`table`, under
/// the visible `columns`.
pub(crate) fn copy_as_insert(
    result: &ResultSet,
    rows: &[u64],
    columns: &[u32],
    dialect: Arc<dyn SqlDialect>,
    schema: Option<String>,
    table: &str,
) -> Result<GridCopy, CoreError> {
    let (picked, data) = selection(result, rows, columns)?;
    let infos: Arc<[ColumnInfo]> = picked.iter().map(plain_column).collect();
    let insert_rows = data.into_iter().map(InsertRow::Saved).collect();
    render(CopyRequest::Insert(InsertCopy {
        dialect,
        table: TableRef::new(schema, table),
        columns: infos,
        rows: insert_rows,
    }))
}

/// One column's values of `rows` as an IN list in the engine's spelling.
pub(crate) fn copy_in_clause(
    result: &ResultSet,
    rows: &[u64],
    column: u32,
    dialect: Arc<dyn SqlDialect>,
) -> Result<GridCopy, CoreError> {
    let (picked, data) = selection(result, rows, &[column])?;
    render(CopyRequest::InClause {
        dialect,
        values: InClauseRows {
            columns: picked,
            rows: data,
            column: 0,
        },
    })
}

/// Every value of `rows` under `columns` as one list of the engine's literals.
pub(crate) fn copy_as_values(
    result: &ResultSet,
    rows: &[u64],
    columns: &[u32],
    dialect: Arc<dyn SqlDialect>,
) -> Result<GridCopy, CoreError> {
    let (picked, data) = selection(result, rows, columns)?;
    render(CopyRequest::Values {
        dialect,
        columns: picked,
        rows: data,
    })
}

fn render(request: CopyRequest<Vec<Value>>) -> Result<GridCopy, CoreError> {
    copy::render(request).map(GridCopy::from).map_err(copy_error)
}

/// The picked columns in display order and each row's cells under them.
type Selection = (Arc<[ResultColumn]>, Vec<Vec<Value>>);

fn selection(result: &ResultSet, rows: &[u64], columns: &[u32]) -> Result<Selection, CoreError> {
    let all = result.result_columns();
    let indices: Vec<usize> = columns
        .iter()
        .map(|column| {
            usize::try_from(*column)
                .ok()
                .filter(|index| *index < all.len())
                .ok_or_else(|| CoreError::failed("ffi.out_of_range", format!("no column {column}")))
        })
        .collect::<Result<_, _>>()?;
    let picked: Arc<[ResultColumn]> = indices.iter().map(|&index| all[index].clone()).collect();
    let data = rows
        .iter()
        .map(|&row| indices.iter().map(|&column| result.copy_value(row, column)).collect())
        .collect();
    Ok((picked, data))
}

fn plain_column(column: &ResultColumn) -> ColumnInfo {
    ColumnInfo {
        name: column.name.clone(),
        column_type: column.column_type.clone(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        is_generated: false,
        partition_scoped: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

fn copy_error(error: CopyError) -> CoreError {
    match error {
        CopyError::Encode(_) => CoreError::failed("grid.copy.unreadable_value", error.to_string()),
        CopyError::Insert(_) | CopyError::Literal(_) => CoreError::failed("grid.copy.not_sql", error.to_string()),
        CopyError::EmptyInClause => CoreError::failed("grid.copy.empty_in_clause", error.to_string()),
        CopyError::TextTableTooLarge => CoreError::failed("grid.copy.text_table_too_large", error.to_string()),
        CopyError::ContainsNul => CoreError::failed("grid.copy.contains_nul", error.to_string()),
    }
}
