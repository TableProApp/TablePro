use std::sync::Arc;

use tablepro_core::ColumnInfo;
use tablepro_core::meta::TableRef;
use tablepro_session::Session;

use crate::ui::tab_load::LoadFailure;

/// Whether a read of the table's columns may take the catalog's copy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ColumnFreshness {
    Cached,
    /// Ask the server even when the catalog has them. A failure keeps
    /// the catalog's copy for the next read.
    Refetch,
}

/// The columns a page is built from. A table with none the account can
/// read is a failure too, since no page can be read from it.
pub(crate) async fn load_columns(
    session: Arc<Session>,
    table: TableRef,
    freshness: ColumnFreshness,
) -> Result<Arc<[ColumnInfo]>, LoadFailure> {
    let read = match freshness {
        ColumnFreshness::Cached => session.columns(table.clone()).await,
        ColumnFreshness::Refetch => session.refresh_columns(table.clone()).await,
    };
    let failure = match read {
        Ok(columns) if !columns.is_empty() => return Ok(columns),
        Ok(_) => LoadFailure::NoColumns,
        Err(error) => LoadFailure::Columns(error),
    };
    tracing::warn!(
        schema = ?table.schema,
        table = %table.name,
        category = ?failure.category(),
        "browse columns failed"
    );
    Err(failure)
}
