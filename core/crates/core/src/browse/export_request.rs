use crate::column::ColumnInfo;
use crate::filter::FilterSet;
use crate::meta::{RowIdentity, TableRef};

use super::SortKey;

/// The rows an export reads: the table as the grid filters and sorts
/// it, every page at once.
#[derive(Debug, Clone, Copy)]
pub struct ExportRequest<'a> {
    pub table: &'a TableRef,
    pub columns: &'a [ColumnInfo],
    pub filter: &'a FilterSet,
    pub sort: &'a [SortKey],
    pub identity: &'a RowIdentity,
    pub fields: ExportFields,
}

/// Which fields an export reads. A table's rows hold its columns either
/// way; a collection's columns come from a census of its first documents,
/// so a later document can hold a field they do not list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportFields {
    /// The columns `columns` lists, in its order.
    Listed,
    /// Every field the rows hold, as the driver finds them while it reads.
    Every,
}
