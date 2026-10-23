use std::sync::Arc;

use tablepro_core::ColumnInfo;
use tablepro_core::meta::{RowIdentity, TableEstimate};
use tablepro_session::OperationError;

use super::page_reply::PageReply;
use crate::runtime::Stamped;
use crate::ui::grid::TableKeys;
use crate::ui::tab_load::LoadFailure;

/// The table's columns from the session's catalog, and how its rows are
/// told apart, read together because a page needs both.
#[derive(Debug, Clone)]
pub(crate) struct ColumnsReply {
    pub columns: Arc<[ColumnInfo]>,
    pub identity: RowIdentity,
}

/// A reply to one of the tab's reads, stamped with the request it
/// answers so a reply to a replaced request is dropped.
#[derive(Debug)]
pub(crate) enum BrowseCommand {
    Columns(Stamped<Result<ColumnsReply, LoadFailure>>),
    Page(Stamped<Result<PageReply, OperationError>>),
    Estimate(Stamped<Result<TableEstimate, OperationError>>),
    Count(Stamped<Result<u64, OperationError>>),
    Keys(Stamped<Result<TableKeys, OperationError>>),
}
