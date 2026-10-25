use std::collections::VecDeque;
use std::sync::Arc;

use tablepro_app_services::stream_result_spool::StreamResultSpool;
use tablepro_core::{ColumnInfo, MAX_QUERY_RESULT_BYTES, QueryResult};

#[derive(Debug, PartialEq, Eq)]
pub(super) enum PageAppendError {
    OutOfOrder,
    SchemaChanged,
    InvalidRowWidth,
}

#[derive(Debug, Clone)]
pub enum StreamTerminal {
    Loading,
    Complete,
    Cancelled,
    TimedOut,
    Failed(super::StatementFailure),
}

#[derive(Debug, Clone)]
pub struct StreamedResult {
    pub(super) pages: Vec<Arc<QueryResult>>,
    pub(super) page_indices: Vec<u64>,
    pub(super) page_row_counts: Vec<usize>,
    pub(super) columns: Vec<ColumnInfo>,
    pub(super) total_pages: u64,
    pub(super) total_rows: usize,
    pub(super) terminal: StreamTerminal,
    pub(super) export: Option<crate::ui::export_dialog::StreamExportRequest>,
    pub(super) generation: u64,
    pub(super) spool: Option<StreamResultSpool>,
}

#[derive(Default)]
pub(super) struct StreamPageCache {
    pages: VecDeque<(u64, Arc<QueryResult>, usize)>,
    retained_bytes: usize,
    columns: Option<Vec<ColumnInfo>>,
    next_page: u64,
    empty_pages: u64,
    page_row_counts: Vec<usize>,
    total_rows: usize,
}

impl StreamPageCache {
    pub(super) fn append(&mut self, index: u64, result: Arc<QueryResult>) -> Result<(), PageAppendError> {
        if index != self.next_page {
            return Err(PageAppendError::OutOfOrder);
        }
        if result.rows.iter().any(|row| row.len() != result.columns.len()) {
            return Err(PageAppendError::InvalidRowWidth);
        }
        if self.columns.as_ref().is_some_and(|columns| *columns != result.columns) {
            return Err(PageAppendError::SchemaChanged);
        }
        if self.columns.is_none() {
            self.columns = Some(result.columns.clone());
        }
        self.page_row_counts.push(result.rows.len());
        if index > 0 && result.rows.is_empty() {
            self.next_page = self.next_page.saturating_add(1);
            self.empty_pages = self.empty_pages.saturating_add(1);
            return Ok(());
        }
        self.total_rows = self.total_rows.saturating_add(result.rows.len());
        let bytes = result.estimated_row_bytes();
        self.retained_bytes = self.retained_bytes.saturating_add(bytes);
        self.pages.push_back((index, result, bytes));
        self.next_page = self.next_page.saturating_add(1);
        while self.pages.len() > 1 && self.retained_bytes > MAX_QUERY_RESULT_BYTES {
            if let Some((_, _, bytes)) = self.pages.pop_front() {
                self.retained_bytes = self.retained_bytes.saturating_sub(bytes);
            }
        }
        Ok(())
    }

    #[cfg(test)]
    pub(super) fn pages(&self) -> &VecDeque<(u64, Arc<QueryResult>, usize)> {
        &self.pages
    }

    #[cfg(test)]
    pub(super) fn first_page(&self) -> u64 {
        self.pages.front().map_or(self.next_page, |(index, _, _)| *index)
    }

    pub(super) fn total_rows(&self) -> usize {
        self.total_rows
    }

    #[cfg(test)]
    pub(super) fn columns(&self) -> Option<&[ColumnInfo]> {
        self.columns.as_deref()
    }

    #[cfg(test)]
    pub(super) fn snapshot(
        &self,
        terminal: StreamTerminal,
        query: Option<crate::ui::export_dialog::StreamExportQuery>,
    ) -> StreamedResult {
        self.snapshot_with_spool(terminal, query, 0, None)
    }

    pub(super) fn snapshot_with_spool(
        &self,
        terminal: StreamTerminal,
        query: Option<crate::ui::export_dialog::StreamExportQuery>,
        generation: u64,
        spool: Option<StreamResultSpool>,
    ) -> StreamedResult {
        let export = query
            .zip(self.columns.clone())
            .map(|(query, columns)| crate::ui::export_dialog::StreamExportRequest { query, columns });
        StreamedResult {
            pages: self.pages.iter().map(|(_, page, _)| page.clone()).collect(),
            page_indices: self.pages.iter().map(|(index, _, _)| *index).collect(),
            page_row_counts: self.page_row_counts.clone(),
            columns: self.columns.clone().unwrap_or_default(),
            total_pages: self.next_page.saturating_sub(self.empty_pages),
            total_rows: self.total_rows,
            terminal,
            export,
            generation,
            spool,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::Value;

    pub(super) fn page(columns: &[&str], values: &[i64]) -> Arc<QueryResult> {
        Arc::new(QueryResult {
            columns: columns
                .iter()
                .map(|name| ColumnInfo {
                    name: (*name).into(),
                    data_type: "BIGINT".into(),
                    nullable: false,
                    primary_key: false,
                    is_auto_increment: false,
                    default_value: None,
                    is_generated: false,
                    comment: None,
                    collation: None,
                    enum_type: None,
                    domain_type: None,
                })
                .collect(),
            rows: values.iter().map(|value| vec![Value::Int(*value)]).collect(),
            truncated: false,
        })
    }

    #[test]
    fn retains_all_small_pages_within_the_byte_budget_and_counts_all_delivered_rows() {
        let mut cache = StreamPageCache::default();
        for index in 0..20 {
            cache
                .append(index, page(&["id"], &[index as i64]))
                .expect("append page");
        }

        assert_eq!(cache.pages().len(), 20);
        assert_eq!(cache.first_page(), 0);
        assert_eq!(cache.total_rows(), 20);
        assert_eq!(
            cache.pages().iter().map(|(index, _, _)| *index).collect::<Vec<_>>(),
            (0..20).collect::<Vec<_>>()
        );
        let snapshot = cache.snapshot(StreamTerminal::Complete, None);
        assert_eq!(snapshot.total_pages, 20);
        assert_eq!(snapshot.page_indices, (0..20).collect::<Vec<_>>());
    }

    #[test]
    fn wide_pages_evict_by_bytes_before_the_page_count_limit() {
        let mut cache = StreamPageCache::default();
        let mut retired = None;
        for index in 0..3 {
            let mut result = page(&["payload"], &[]).as_ref().clone();
            result.rows = vec![vec![Value::Text("x".repeat(24 * 1024 * 1024))]];
            let result = Arc::new(result);
            if index == 0 {
                retired = Some(Arc::downgrade(&result));
            }
            cache.append(index, result).unwrap();
        }
        assert_eq!(cache.pages().len(), 2);
        assert!(retired.unwrap().upgrade().is_none());
        let snapshot = cache.snapshot(StreamTerminal::Complete, None);
        assert_eq!(snapshot.page_indices, vec![1, 2]);
        assert_eq!(snapshot.total_rows, 3);
        assert_eq!(snapshot.total_pages, 3);
        assert_eq!(snapshot.page_row_counts, vec![1, 1, 1]);
        assert_eq!(snapshot.pages[0].rows[0][0], Value::Text("x".repeat(24 * 1024 * 1024)));
    }

    #[test]
    fn the_newest_page_is_kept_even_when_it_alone_exceeds_the_byte_budget() {
        let mut cache = StreamPageCache::default();
        let mut result = page(&["payload"], &[]).as_ref().clone();
        result.rows = vec![vec![Value::Bytes(vec![7; 65 * 1024 * 1024])]];
        let result = Arc::new(result);
        let retired = Arc::downgrade(&result);
        cache.append(0, result).unwrap();
        assert_eq!(cache.pages().len(), 1);
        assert_eq!(cache.total_rows(), 1);
        cache.append(1, page(&["payload"], &[2])).unwrap();
        assert!(retired.upgrade().is_none());
        assert_eq!(cache.first_page(), 1);
        assert_eq!(cache.total_rows(), 2);
    }

    #[test]
    fn rejects_out_of_order_pages_without_advancing_the_cache() {
        let mut cache = StreamPageCache::default();
        cache.append(0, page(&["id"], &[1])).expect("first page");

        let error = cache.append(2, page(&["id"], &[3])).unwrap_err();

        assert_eq!(error, PageAppendError::OutOfOrder);
        assert_eq!(cache.total_rows(), 1);
        assert_eq!(cache.pages().len(), 1);
    }

    #[test]
    fn rejects_a_late_schema_change_and_keeps_decoded_rows_from_a_truncated_page() {
        let mut cache = StreamPageCache::default();
        cache.append(0, page(&["id"], &[1])).expect("first page");
        let error = cache.append(1, page(&["name"], &[2])).unwrap_err();
        assert_eq!(error, PageAppendError::SchemaChanged);

        let mut truncated = page(&["id"], &[2]).as_ref().clone();
        truncated.truncated = true;
        cache.append(1, Arc::new(truncated)).expect("partial page");
        let result = cache.snapshot(StreamTerminal::Failed("page budget exceeded".into()), None);
        assert_eq!(result.total_rows, 2);
        assert!(result.pages[1].truncated);
        assert!(matches!(result.terminal, StreamTerminal::Failed(_)));
    }

    #[test]
    fn an_empty_final_page_keeps_result_metadata() {
        let mut cache = StreamPageCache::default();
        let empty = Arc::new(QueryResult {
            columns: page(&["id"], &[]).columns.clone(),
            rows: Vec::new(),
            truncated: false,
        });
        cache.append(0, empty).expect("empty result page");

        assert_eq!(cache.total_rows(), 0);
        assert_eq!(cache.columns().map(|columns| columns[0].name.as_str()), Some("id"));
    }

    #[test]
    fn an_empty_page_after_the_first_ends_the_stream_without_evicting_rows() {
        let mut cache = StreamPageCache::default();
        for index in 0..20 {
            cache.append(index, page(&["id"], &[index as i64])).unwrap();
        }

        cache.append(20, page(&["id"], &[])).unwrap();

        assert_eq!(cache.pages().len(), 20);
        assert_eq!(cache.first_page(), 0);
        let snapshot = cache.snapshot(StreamTerminal::Complete, None);
        assert_eq!(snapshot.total_pages, 20);
        assert!(snapshot.pages.iter().all(|page| !page.rows.is_empty()));
    }

    #[test]
    fn an_empty_first_page_is_kept_for_its_columns() {
        let mut cache = StreamPageCache::default();
        cache.append(0, page(&["id"], &[])).unwrap();
        assert_eq!(cache.pages().len(), 1);
        assert_eq!(cache.snapshot(StreamTerminal::Complete, None).total_pages, 1);
    }

    #[test]
    fn a_page_after_a_skipped_empty_page_is_still_in_order() {
        let mut cache = StreamPageCache::default();
        cache.append(0, page(&["id"], &[1])).unwrap();
        cache.append(1, page(&["id"], &[])).unwrap();

        cache
            .append(2, page(&["id"], &[2]))
            .expect("the next page is not out of order");

        assert_eq!(cache.snapshot(StreamTerminal::Complete, None).total_pages, 2);
    }
}

#[cfg(test)]
#[path = "stream_pages/performance_tests.rs"]
mod performance_tests;
