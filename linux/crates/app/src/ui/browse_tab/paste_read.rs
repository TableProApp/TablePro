use tablepro_core::ColumnInfo;
use tablepro_core::import::{CsvRowError, ImportError, PastedRows, PastedTable};

use super::paste_at::PasteAt;

#[derive(Debug)]
pub(crate) struct PasteRequest {
    /// Only the latest paste lands: the clipboard of another program can
    /// take any time to answer, or never.
    pub(crate) ticket: u64,
    pub(crate) at: Option<PasteAt>,
    pub(crate) columns: Vec<ColumnInfo>,
    /// The columns values fill one after another, by their place in a
    /// row: as the grid shows them, from the one the paste starts at.
    pub(crate) in_order: Vec<usize>,
}

#[derive(Debug)]
pub(crate) enum PasteOutcome {
    /// No text, or text with no rows in it.
    Nothing,
    /// One value alone, for the cell the paste started at. `None` is a
    /// NULL.
    Value(Option<String>),
    Rows(PastedRows),
    Unreadable(ImportError),
    Refused(CsvRowError),
    /// Reading the text failed in a way the user can only retry.
    Failed,
    /// More than a paste reads at once.
    TooLarge,
}

/// What the clipboard held: the cells a grid copy offers beside its
/// text, or text alone.
#[derive(Debug)]
pub(crate) enum PasteSource {
    Cells(Vec<u8>),
    Text(String),
}

#[derive(Debug)]
pub(crate) struct PasteRead {
    pub(crate) request: PasteRequest,
    pub(crate) outcome: PasteOutcome,
}

/// Read what the clipboard held against `columns`. With a cell to start
/// at, one value alone is that cell's.
pub(super) fn read_pasted(
    source: &PasteSource,
    columns: &[ColumnInfo],
    in_order: &[usize],
    at_cell: bool,
) -> PasteOutcome {
    let read = match source {
        PasteSource::Cells(json) => PastedTable::from_cells(json),
        PasteSource::Text(text) => PastedTable::read(text),
    };
    let table = match read {
        Ok(table) => table,
        Err(error) => return PasteOutcome::Unreadable(error),
    };
    if table.is_empty() {
        return PasteOutcome::Nothing;
    }
    if table.truncated() {
        return PasteOutcome::TooLarge;
    }
    if at_cell && let Some(value) = table.single_value() {
        return PasteOutcome::Value(value.map(str::to_owned));
    }
    match table.rows(columns, in_order) {
        Ok(rows) => PasteOutcome::Rows(rows),
        Err(error) => PasteOutcome::Refused(error),
    }
}
