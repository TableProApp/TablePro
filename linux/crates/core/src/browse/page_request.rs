use crate::column::ColumnInfo;
use crate::filter::FilterSet;
use crate::meta::{PagePosition, RowIdentity, TableRef};

use super::SortKey;

/// Everything a page query depends on.
#[derive(Debug, Clone, Copy)]
pub struct PageRequest<'a> {
    pub table: &'a TableRef,
    /// The table's columns from the catalogue, in the order the grid
    /// shows them.
    pub columns: &'a [ColumnInfo],
    pub filter: &'a FilterSet,
    pub sort: &'a [SortKey],
    pub identity: &'a RowIdentity,
    pub position: &'a PagePosition,
    pub limit: u64,
}
