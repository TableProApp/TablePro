use std::collections::BTreeMap;

use tablepro_core::meta::PagePosition;

use super::row_total::RowTotal;

/// Where the tab's page starts, and how many rows a page holds. Each
/// move gives the position to read and the row the page then starts at.
///
/// A table that pages by key or heap address is read past the edge
/// row of the page on screen, so a page far into it costs what the
/// first one does. Only a page with no such edge, or a sort of the
/// user's, is read by offset.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct BrowsePager {
    page_size: u64,
    start_ordinal: u64,
    /// What a read of the page the pager is on asks for.
    position: PagePosition,
    /// How many rows that read asks for: a page, or for the last page
    /// read from the end, what is left of the table.
    limit: u64,
    /// The way from the page on screen to the pages either side of it,
    /// gone once the pager moves off that page.
    edges: PageEdges,
    /// The last page can be read backward from the table's end, which
    /// the last page read said.
    seeks: bool,
    /// Where each page of a table the server pages was read from, by its
    /// first row. A paging state only goes forward, so going back reads
    /// a page from the state it was read from before, rather than every
    /// row up to it.
    resumes: BTreeMap<u64, PagePosition>,
}

/// How to reach the pages either side of a page by its edge rows.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct PageEdges {
    pub(crate) previous: Option<PagePosition>,
    pub(crate) next: Option<PagePosition>,
    /// The server that pages the table said no row follows, whatever
    /// the page's size. Only an offset read past every row would say so
    /// otherwise.
    pub(crate) last: bool,
}

/// A page the pager can move to.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct PageTarget {
    pub(crate) position: PagePosition,
    /// How many rows of the table come before the page.
    pub(crate) start: u64,
    pub(crate) limit: u64,
}

impl BrowsePager {
    pub(crate) fn new(page_size: u64, start_ordinal: u64) -> Self {
        let page_size = page_size.max(1);
        Self {
            page_size,
            start_ordinal,
            position: position_at(start_ordinal),
            limit: page_size,
            edges: PageEdges::default(),
            seeks: false,
            resumes: BTreeMap::new(),
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
        self.position.clone()
    }

    pub(crate) fn limit(&self) -> u64 {
        self.limit
    }

    pub(crate) fn move_to(&mut self, target: PageTarget) {
        self.position = target.position;
        self.start_ordinal = target.start;
        self.limit = target.limit;
        self.edges = PageEdges::default();
    }

    /// Back to the first row, under a sort or filter that may page
    /// another way, which the next page read says.
    pub(crate) fn restart(&mut self) {
        self.move_to(self.target(PagePosition::First, 0));
        self.seeks = false;
        self.resumes.clear();
    }

    /// The table's columns changed, and with them the statement a page
    /// is read with, which a paging state the server handed back for the
    /// old one cannot resume. The page stays where it was, by its offset.
    pub(crate) fn forget_paging_states(&mut self) {
        self.resumes.clear();
        if matches!(self.position, PagePosition::Resume(_)) {
            self.move_to(self.target(position_at(self.start_ordinal), self.start_ordinal));
        }
        for edge in [&mut self.edges.previous, &mut self.edges.next] {
            if matches!(edge, Some(PagePosition::Resume(_))) {
                *edge = None;
            }
        }
    }

    /// The table's row identity changed, so a key the pager holds names
    /// rows by columns the table may no longer key on.
    pub(crate) fn rebase(&mut self) {
        self.move_to(self.target(position_at(self.start_ordinal), self.start_ordinal));
        self.seeks = false;
        self.resumes.clear();
    }

    /// A page landed: where it starts, what it was read as, and the way
    /// on from it.
    pub(crate) fn land(&mut self, start: u64, position: PagePosition, edges: PageEdges, seeks: bool) {
        if position == PagePosition::First {
            self.limit = self.page_size;
        }
        if matches!(position, PagePosition::Resume(_)) {
            self.resumes.insert(start, position.clone());
        }
        self.position = position;
        self.start_ordinal = start;
        self.edges = edges;
        self.seeks = seeks;
    }

    /// A new page size starts again from the first row.
    pub(crate) fn resize(&mut self, page_size: u64) {
        self.page_size = page_size.max(1);
        self.move_to(self.target(PagePosition::First, 0));
        self.resumes.clear();
    }

    pub(crate) fn first(&self) -> Option<PageTarget> {
        (self.start_ordinal > 0).then(|| self.target(PagePosition::First, 0))
    }

    pub(crate) fn prev(&self) -> Option<PageTarget> {
        (self.start_ordinal > 0).then(|| {
            let start = self.start_ordinal.saturating_sub(self.page_size);
            let position = match start {
                0 => PagePosition::First,
                start => self
                    .edges
                    .previous
                    .clone()
                    .or_else(|| self.resumes.get(&start).cloned())
                    .unwrap_or(PagePosition::Offset(start)),
            };
            self.target(position, start)
        })
    }

    /// A page with fewer rows than a page holds was the last one.
    pub(crate) fn next(&self, rows_on_page: u64) -> Option<PageTarget> {
        (rows_on_page >= self.page_size && !self.edges.last).then(|| {
            let start = self.start_ordinal.saturating_add(self.page_size);
            let position = self.edges.next.clone().unwrap_or(PagePosition::Offset(start));
            self.target(position, start)
        })
    }

    /// Only an exact total says where the last page starts.
    pub(crate) fn last(&self, total: &RowTotal) -> Option<PageTarget> {
        let total = total.exact()?;
        let start = self.last_start(total)?;
        (start != self.start_ordinal).then(|| self.last_page(start, total))
    }

    /// The last page, for a pager left past the end of a table that
    /// shrank since.
    pub(crate) fn clamp(&self, total: u64) -> Option<PageTarget> {
        let start = self.last_start(total)?;
        (self.start_ordinal >= total).then(|| self.last_page(start, total))
    }

    fn last_page(&self, start: u64, total: u64) -> PageTarget {
        match (start, self.seeks) {
            (0, _) => self.target(PagePosition::First, 0),
            (start, true) => PageTarget {
                position: PagePosition::Last,
                start,
                limit: total - start,
            },
            (start, false) => self.target(PagePosition::Offset(start), start),
        }
    }

    fn last_start(&self, total: u64) -> Option<u64> {
        let last_row = total.checked_sub(1)?;
        Some(last_row / self.page_size * self.page_size)
    }

    fn target(&self, position: PagePosition, start: u64) -> PageTarget {
        PageTarget {
            position,
            start,
            limit: self.page_size,
        }
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
    use tablepro_core::Value;

    use super::*;

    fn target(position: PagePosition, start: u64) -> Option<PageTarget> {
        Some(PageTarget {
            position,
            start,
            limit: 100,
        })
    }

    fn keyed_edges(first: i64, last: i64) -> PageEdges {
        PageEdges {
            previous: Some(PagePosition::BeforeKey(vec![Value::Int(first)])),
            next: Some(PagePosition::AfterKey(vec![Value::Int(last)])),
            last: false,
        }
    }

    fn resumed(byte: u8) -> PagePosition {
        let mut builder = tablepro_core::statement::StatementBuilder::new();
        builder.push_sql("SELECT \"id\" FROM \"t\"");
        PagePosition::Resume(tablepro_core::meta::PagingState::new(
            std::sync::Arc::from(vec![byte]),
            builder.finish(),
        ))
    }

    fn resuming(next: u8) -> PageEdges {
        PageEdges {
            previous: None,
            next: Some(resumed(next)),
            last: false,
        }
    }

    #[test]
    fn a_full_server_page_with_nothing_after_it_is_the_last() {
        let mut pager = BrowsePager::new(100, 0);
        pager.land(
            0,
            PagePosition::First,
            PageEdges {
                last: true,
                ..PageEdges::default()
            },
            false,
        );

        assert_eq!(pager.next(100), None);
    }

    #[test]
    fn new_columns_leave_a_server_paged_table_at_its_offset() {
        let mut pager = BrowsePager::new(100, 0);
        pager.land(0, PagePosition::First, resuming(1), false);
        pager.move_to(pager.next(100).expect("a next page"));
        pager.land(100, resumed(1), resuming(2), false);

        pager.forget_paging_states();

        assert_eq!(pager.position(), PagePosition::Offset(100));
        assert_eq!(pager.next(100), target(PagePosition::Offset(200), 200));
        assert_eq!(pager.prev(), target(PagePosition::First, 0));
    }

    #[test]
    fn a_server_paged_table_goes_back_by_the_state_its_page_was_read_from() {
        let mut pager = BrowsePager::new(100, 0);
        pager.land(0, PagePosition::First, resuming(1), false);
        for (start, byte) in [(100, 1), (200, 2)] {
            let next = pager.next(100).expect("a next page");
            assert_eq!(next, target(resumed(byte), start).expect("a target"));
            pager.move_to(next);
            pager.land(start, resumed(byte), resuming(byte + 1), false);
        }

        assert_eq!(pager.prev(), target(resumed(1), 100));
        pager.move_to(pager.prev().expect("a previous page"));
        assert_eq!(pager.prev(), target(PagePosition::First, 0));

        pager.restart();
        pager.move_to(target(PagePosition::Offset(200), 200).expect("a target"));
        assert_eq!(
            pager.prev(),
            target(PagePosition::Offset(100), 100),
            "a restarted browse kept a state from before"
        );
    }

    #[test]
    fn browse_pager_last_requires_exact_total() {
        let pager = BrowsePager::new(100, 0);

        assert_eq!(pager.last(&RowTotal::Unknown), None);
        assert_eq!(pager.last(&RowTotal::Estimated(1_000)), None);
        assert_eq!(pager.last(&RowTotal::Counting { estimate: Some(1_000) }), None);
        assert_eq!(
            pager.last(&RowTotal::Exact(1_000)),
            target(PagePosition::Offset(900), 900)
        );
        assert_eq!(
            pager.last(&RowTotal::Exact(1_001)),
            target(PagePosition::Offset(1_000), 1_000)
        );
        assert_eq!(pager.last(&RowTotal::Exact(0)), None);
        assert_eq!(BrowsePager::new(100, 900).last(&RowTotal::Exact(1_000)), None);
    }

    #[test]
    fn the_pager_moves_by_offset_and_stops_at_the_ends() {
        let pager = BrowsePager::new(100, 200);

        assert_eq!(pager.position(), PagePosition::Offset(200));
        assert_eq!(pager.first(), target(PagePosition::First, 0));
        assert_eq!(pager.prev(), target(PagePosition::Offset(100), 100));
        assert_eq!(pager.next(100), target(PagePosition::Offset(300), 300));
        assert_eq!(pager.next(40), None, "a short page went on");
        assert_eq!(BrowsePager::new(100, 0).first(), None);
        assert_eq!(BrowsePager::new(100, 0).prev(), None);
        assert_eq!(BrowsePager::new(100, 50).prev(), target(PagePosition::First, 0));
    }

    #[test]
    fn a_keyed_page_pages_past_its_edge_rows_and_keeps_the_row_numbers() {
        let mut pager = BrowsePager::new(100, 0);
        pager.land(200, PagePosition::Offset(200), keyed_edges(201, 300), true);

        assert_eq!(
            pager.next(100),
            target(PagePosition::AfterKey(vec![Value::Int(300)]), 300)
        );
        assert_eq!(
            pager.prev(),
            target(PagePosition::BeforeKey(vec![Value::Int(201)]), 100)
        );
        let mut near_start = BrowsePager::new(100, 0);
        near_start.land(100, PagePosition::Offset(100), keyed_edges(101, 200), true);
        assert_eq!(
            near_start.prev(),
            target(PagePosition::First, 0),
            "a page read backward from the second page would start mid-table"
        );
    }

    #[test]
    fn a_move_forgets_the_edges_of_the_page_it_left() {
        let mut pager = BrowsePager::new(100, 0);
        pager.land(0, PagePosition::First, keyed_edges(1, 100), true);
        let next = pager.next(100).expect("a next page");

        pager.move_to(next);

        assert_eq!(
            pager.next(100),
            target(PagePosition::Offset(200), 200),
            "a page not yet read has no edge to read past"
        );
    }

    #[test]
    fn the_last_page_of_a_seekable_table_reads_what_is_left_from_its_end() {
        let mut pager = BrowsePager::new(100, 0);
        pager.land(0, PagePosition::First, keyed_edges(1, 100), true);

        assert_eq!(
            pager.last(&RowTotal::Exact(1_042)),
            Some(PageTarget {
                position: PagePosition::Last,
                start: 1_000,
                limit: 42,
            })
        );
        let mut past_end = BrowsePager::new(100, 0);
        past_end.land(1_500, PagePosition::Offset(1_500), PageEdges::default(), true);
        assert_eq!(
            past_end.clamp(1_100),
            Some(PageTarget {
                position: PagePosition::Last,
                start: 1_000,
                limit: 100,
            })
        );
    }

    #[test]
    fn a_new_sort_pages_by_offset_until_its_first_page_lands() {
        let mut pager = BrowsePager::new(100, 0);
        pager.land(300, PagePosition::Offset(300), keyed_edges(301, 400), true);

        pager.restart();

        assert_eq!((pager.position(), pager.start_ordinal()), (PagePosition::First, 0));
        assert_eq!(
            pager.last(&RowTotal::Exact(1_042)),
            target(PagePosition::Offset(1_000), 1_000)
        );
    }

    #[test]
    fn a_pager_past_the_end_clamps_to_the_last_page() {
        assert_eq!(
            BrowsePager::new(100, 500).clamp(250),
            target(PagePosition::Offset(200), 200)
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
        assert_eq!((pager.position(), pager.limit()), (PagePosition::First, 500));
        assert_eq!(BrowsePager::new(0, 0).page_size(), 1);
    }
}
