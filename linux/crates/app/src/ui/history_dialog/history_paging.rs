use tablepro_storage::query_history::HistoryCursor;

/// Which page reads the dialog is waiting on. A refresh starts a new
/// generation, so a page that was still on its way for the old search
/// is dropped when it lands, and only one next-page read runs at once.
#[derive(Debug, Default)]
pub(super) struct HistoryPaging {
    generation: u64,
    next: Option<HistoryCursor>,
    loading_more: bool,
    loaded: bool,
}

impl HistoryPaging {
    pub(super) fn start_refresh(&mut self) -> u64 {
        self.generation += 1;
        self.loading_more = false;
        self.generation
    }

    /// Whether the first page belongs to the latest refresh.
    pub(super) fn first_page_arrived(&mut self, generation: u64, next: Option<HistoryCursor>) -> bool {
        if generation != self.generation {
            return false;
        }
        self.next = next;
        self.loaded = true;
        true
    }

    /// Whether a first page ever arrived, so a failed refresh knows if
    /// there are rows to keep.
    pub(super) fn has_loaded(&self) -> bool {
        self.loaded
    }

    pub(super) fn is_current(&self, generation: u64) -> bool {
        generation == self.generation
    }

    /// The generation and cursor for the next page, unless one is on its
    /// way or the last page is in.
    pub(super) fn start_more(&mut self) -> Option<(u64, HistoryCursor)> {
        if self.loading_more {
            return None;
        }
        let next = self.next?;
        self.loading_more = true;
        Some((self.generation, next))
    }

    pub(super) fn more_arrived(&mut self, generation: u64, next: Option<HistoryCursor>) -> bool {
        if generation != self.generation {
            return false;
        }
        self.loading_more = false;
        self.next = next;
        true
    }

    /// The read failed; the next edge reached tries it again.
    pub(super) fn more_failed(&mut self, generation: u64) {
        if generation == self.generation {
            self.loading_more = false;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::SystemTime;

    use tablepro_storage::query_history::Entry;
    use uuid::Uuid;

    use super::*;

    fn cursor(id: i64) -> HistoryCursor {
        HistoryCursor::after(&Entry {
            id,
            query: String::new(),
            driver_id: String::new(),
            connection_id: Uuid::nil(),
            connection_name: String::new(),
            executed_at: SystemTime::UNIX_EPOCH,
            duration_ms: None,
            rows_affected: None,
            success: true,
            cancelled: false,
            pinned: false,
            error: None,
        })
    }

    #[test]
    fn one_next_page_read_at_a_time() {
        let mut paging = HistoryPaging::default();
        let generation = paging.start_refresh();
        assert!(paging.first_page_arrived(generation, Some(cursor(10))));

        assert_eq!(paging.start_more(), Some((generation, cursor(10))));
        assert_eq!(
            paging.start_more(),
            None,
            "a second read started while one was on its way"
        );

        assert!(paging.more_arrived(generation, None));
        assert_eq!(paging.start_more(), None, "a read started past the last page");
    }

    #[test]
    fn a_page_for_an_older_search_is_dropped() {
        let mut paging = HistoryPaging::default();
        let old = paging.start_refresh();
        assert!(paging.first_page_arrived(old, Some(cursor(10))));
        let (more_for, _) = paging.start_more().expect("a next page");

        let new = paging.start_refresh();

        assert!(!paging.more_arrived(more_for, None));
        assert!(!paging.first_page_arrived(old, None));
        assert!(paging.first_page_arrived(new, Some(cursor(5))));
        assert_eq!(
            paging.start_more(),
            Some((new, cursor(5))),
            "the old read kept the slot"
        );
    }

    #[test]
    fn a_failed_next_page_can_be_tried_again() {
        let mut paging = HistoryPaging::default();
        let generation = paging.start_refresh();
        assert!(paging.first_page_arrived(generation, Some(cursor(10))));
        let _ = paging.start_more();

        paging.more_failed(generation);

        assert_eq!(paging.start_more(), Some((generation, cursor(10))));
    }
}
