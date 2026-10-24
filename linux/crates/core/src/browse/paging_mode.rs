use crate::dialect::TablePaging;
use crate::meta::{EngineRowId, RowIdentity};

use super::SortKey;

/// How the next page is found.
///
/// One rule for the page builder and the pager, so the SQL and the
/// position the pager asks for cannot disagree.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PagingMode {
    /// Seek past the edge row's key. Constant cost whatever the page.
    Keyset,
    /// A range of PostgreSQL heap blocks, for a table with no key.
    CtidWindow,
    /// Skip rows. Any order the user asks for, at a cost that grows
    /// with the offset.
    Offset,
    /// Resume from the paging state the server handed back with the
    /// page before, in the engine's own order.
    ServerPaging,
}

/// The paging mode for a table and the sort the user chose.
///
/// An engine that pages on the server pages every table that way. A
/// user sort orders by columns that are not unique, which a seek cannot
/// resume from, so it always pages by offset. A partitioned table's
/// ctid is unique only within one partition, so it has no block window
/// to walk.
pub fn paging_mode(paging: TablePaging, identity: &RowIdentity, sort: &[SortKey]) -> PagingMode {
    if paging == TablePaging::ServerState {
        return PagingMode::ServerPaging;
    }
    if !sort.is_empty() {
        return PagingMode::Offset;
    }
    match identity {
        RowIdentity::UniqueKey { .. } | RowIdentity::EngineRowId(EngineRowId::SqliteRowid) => PagingMode::Keyset,
        RowIdentity::EngineRowId(EngineRowId::PostgresCtid) => PagingMode::CtidWindow,
        RowIdentity::EngineRowId(EngineRowId::PostgresTableoidCtid)
        | RowIdentity::SortingKey { .. }
        | RowIdentity::Unordered => PagingMode::Offset,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn by_id() -> RowIdentity {
        RowIdentity::UniqueKey {
            columns: vec!["id".to_owned()],
        }
    }

    #[test]
    fn a_key_with_no_user_sort_seeks() {
        assert_eq!(paging_mode(TablePaging::InStatement, &by_id(), &[]), PagingMode::Keyset);
        assert_eq!(
            paging_mode(
                TablePaging::InStatement,
                &RowIdentity::EngineRowId(EngineRowId::SqliteRowid),
                &[]
            ),
            PagingMode::Keyset
        );
    }

    #[test]
    fn a_heap_with_no_key_walks_block_windows() {
        assert_eq!(
            paging_mode(
                TablePaging::InStatement,
                &RowIdentity::EngineRowId(EngineRowId::PostgresCtid),
                &[]
            ),
            PagingMode::CtidWindow
        );
        assert_eq!(
            paging_mode(
                TablePaging::InStatement,
                &RowIdentity::EngineRowId(EngineRowId::PostgresTableoidCtid),
                &[]
            ),
            PagingMode::Offset,
            "a ctid repeats across partitions"
        );
    }

    #[test]
    fn a_user_sort_always_pages_by_offset() {
        let sort = [SortKey {
            column: 0,
            ascending: false,
        }];

        assert_eq!(
            paging_mode(TablePaging::InStatement, &by_id(), &sort),
            PagingMode::Offset
        );
        assert_eq!(
            paging_mode(
                TablePaging::InStatement,
                &RowIdentity::EngineRowId(EngineRowId::PostgresCtid),
                &sort
            ),
            PagingMode::Offset
        );
        assert_eq!(
            paging_mode(TablePaging::InStatement, &RowIdentity::Unordered, &[]),
            PagingMode::Offset
        );
    }

    #[test]
    fn a_server_that_pages_pages_every_table() {
        for identity in [by_id(), RowIdentity::Unordered] {
            assert_eq!(
                paging_mode(TablePaging::ServerState, &identity, &[]),
                PagingMode::ServerPaging
            );
        }
    }
}
