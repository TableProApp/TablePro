use std::sync::Arc;

use tablepro_core::browse::{ExportRequest, SortKey};
use tablepro_core::meta::{RowIdentity, TableRef};
use tablepro_core::{ColumnInfo, FilterSet, UserSql};

/// A read an export runs on the server rather than rows it already
/// holds.
#[derive(Debug, Clone)]
pub enum ExportQuery {
    /// Every row of a table under the grid's filter and sort.
    Table(TableExport),
    /// The statement behind an editor result, run again from the top.
    Editor { sql: UserSql },
}

/// A table as a browse tab filters and sorts it.
#[derive(Debug, Clone)]
pub struct TableExport {
    pub table: TableRef,
    pub columns: Arc<[ColumnInfo]>,
    pub filter: FilterSet,
    pub sort: Vec<SortKey>,
    pub identity: RowIdentity,
}

impl TableExport {
    pub fn request(&self) -> ExportRequest<'_> {
        ExportRequest {
            table: &self.table,
            columns: &self.columns,
            filter: &self.filter,
            sort: &self.sort,
            identity: &self.identity,
        }
    }
}
