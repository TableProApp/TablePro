use tablepro_core::FilterSet;

/// What moves the tab to other rows of the table: the page, its size,
/// the sort, the filter, a refresh and the row count.
#[derive(Debug)]
pub(crate) enum PagingInput {
    /// F5.
    Refresh,
    /// F5: the window asks first when the tab has unsaved changes.
    RequestRefresh,
    ToggleFilterStrip,
    /// The strip's rules, or an empty set for Clear All.
    FilterApplied(FilterSet),
    FirstPage,
    PrevPage,
    NextPage,
    LastPage,
    SortChanged {
        col_idx: usize,
        ascending: bool,
    },
    SortCleared,
    PageSizeChanged(u64),
    /// Count Rows, or Try Again after a count failed.
    CountRows,
}
