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
}
