use tablepro_core::meta::PagePosition;

use super::row_total::RowTotal;

/// Where the tab's page starts, and how many rows a page holds. Each
/// move gives the position to read and the row the page then starts at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct BrowsePager {
    page_size: u64,
    start_ordinal: u64,
}

impl BrowsePager {
    pub(crate) fn new(page_size: u64, start_ordinal: u64) -> Self {
        Self {
            page_size: page_size.max(1),
            start_ordinal,
        }
    }

    pub(crate) fn page_size(&self) -> u64 {
        self.page_size
    }

    pub(crate) fn start_ordinal(&self) -> u64 {
        self.start_ordinal
    }

    /// The position a read of the page the pager is on asks for.
    pub(crate) fn position(&self) -> PagePosition {
        position_at(self.start_ordinal)
    }

    pub(crate) fn go_to(&mut self, start_ordinal: u64) {
        self.start_ordinal = start_ordinal;
    }

    /// A new page size starts again from the first row.
    pub(crate) fn resize(&mut self, page_size: u64) {
        self.page_size = page_size.max(1);
        self.start_ordinal = 0;
    }

    pub(crate) fn first(&self) -> Option<(PagePosition, u64)> {
        (self.start_ordinal > 0).then_some((PagePosition::First, 0))
    }

    pub(crate) fn prev(&self) -> Option<(PagePosition, u64)> {
        (self.start_ordinal > 0).then(|| {
            let start = self.start_ordinal.saturating_sub(self.page_size);
            (position_at(start), start)
        })
    }

    /// A page with fewer rows than a page holds was the last one.
    pub(crate) fn next(&self, rows_on_page: u64) -> Option<(PagePosition, u64)> {
        (rows_on_page >= self.page_size).then(|| {
            let start = self.start_ordinal.saturating_add(self.page_size);
            (position_at(start), start)
        })
    }

    /// Only an exact total says where the last page starts.
    pub(crate) fn last(&self, total: &RowTotal) -> Option<(PagePosition, u64)> {
        let start = self.last_start(total.exact()?)?;
        (start != self.start_ordinal).then(|| (position_at(start), start))
    }

    /// The last page, for a pager left past the end of a table that
    /// shrank since.
    pub(crate) fn clamp(&self, total: u64) -> Option<(PagePosition, u64)> {
        let start = self.last_start(total)?;
        (self.start_ordinal >= total).then(|| (position_at(start), start))
    }

    fn last_start(&self, total: u64) -> Option<u64> {
        let last_row = total.checked_sub(1)?;
        Some(last_row / self.page_size * self.page_size)
    }
}

fn position_at(start: u64) -> PagePosition {
    match start {
        0 => PagePosition::First,
        start => PagePosition::Offset(start),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn browse_pager_last_requires_exact_total() {
        let pager = BrowsePager::new(100, 0);

        assert_eq!(pager.last(&RowTotal::Unknown), None);
        assert_eq!(pager.last(&RowTotal::Estimated(1_000)), None);
        assert_eq!(pager.last(&RowTotal::Counting { estimate: Some(1_000) }), None);
        assert_eq!(
            pager.last(&RowTotal::Exact(1_000)),
            Some((PagePosition::Offset(900), 900))
        );
        assert_eq!(
            pager.last(&RowTotal::Exact(1_001)),
            Some((PagePosition::Offset(1_000), 1_000))
        );
        assert_eq!(pager.last(&RowTotal::Exact(0)), None);
        assert_eq!(BrowsePager::new(100, 900).last(&RowTotal::Exact(1_000)), None);
    }

    #[test]
    fn the_pager_moves_by_offset_and_stops_at_the_ends() {
        let pager = BrowsePager::new(100, 200);

        assert_eq!(pager.position(), PagePosition::Offset(200));
        assert_eq!(pager.first(), Some((PagePosition::First, 0)));
        assert_eq!(pager.prev(), Some((PagePosition::Offset(100), 100)));
        assert_eq!(pager.next(100), Some((PagePosition::Offset(300), 300)));
        assert_eq!(pager.next(40), None, "a short page went on");
        assert_eq!(BrowsePager::new(100, 0).first(), None);
        assert_eq!(BrowsePager::new(100, 0).prev(), None);
        assert_eq!(BrowsePager::new(100, 50).prev(), Some((PagePosition::First, 0)));
    }

    #[test]
    fn a_pager_past_the_end_clamps_to_the_last_page() {
        assert_eq!(
            BrowsePager::new(100, 500).clamp(250),
            Some((PagePosition::Offset(200), 200))
        );
        assert_eq!(BrowsePager::new(100, 200).clamp(250), None);
        assert_eq!(
            BrowsePager::new(100, 250).clamp(260),
            None,
            "a page with rows on it moved"
        );
        assert_eq!(BrowsePager::new(100, 200).clamp(0), None);
    }

    #[test]
    fn a_new_page_size_starts_from_the_first_row() {
        let mut pager = BrowsePager::new(100, 300);

        pager.resize(500);

        assert_eq!((pager.page_size(), pager.start_ordinal()), (500, 0));
        assert_eq!(BrowsePager::new(0, 0).page_size(), 1);
    }
}
