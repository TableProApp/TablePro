use std::collections::VecDeque;
use std::sync::Arc;

use tablepro_core::{ColumnInfo, QueryResult};

pub(super) const MAX_RETAINED_STREAM_PAGES: usize = 4;

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
    Failed(String),
}

#[derive(Debug, Clone)]
pub struct StreamedResult {
    pub(super) pages: Vec<Arc<QueryResult>>,
    pub(super) first_page: u64,
    pub(super) total_pages: u64,
    pub(super) total_rows: usize,
    pub(super) terminal: StreamTerminal,
    pub(super) export: Option<crate::ui::export_dialog::StreamExportRequest>,
}

#[derive(Default)]
pub(super) struct StreamPageCache {
    pages: VecDeque<(u64, Arc<QueryResult>)>,
    columns: Option<Vec<ColumnInfo>>,
    next_page: u64,
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
        self.total_rows = self.total_rows.saturating_add(result.rows.len());
        self.pages.push_back((index, result));
        self.next_page = self.next_page.saturating_add(1);
        if self.pages.len() > MAX_RETAINED_STREAM_PAGES {
            self.pages.pop_front();
        }
        Ok(())
    }

    #[cfg(test)]
    pub(super) fn pages(&self) -> &VecDeque<(u64, Arc<QueryResult>)> {
        &self.pages
    }

    pub(super) fn first_page(&self) -> u64 {
        self.pages.front().map_or(self.next_page, |(index, _)| *index)
    }

    pub(super) fn total_rows(&self) -> usize {
        self.total_rows
    }

    #[cfg(test)]
    pub(super) fn columns(&self) -> Option<&[ColumnInfo]> {
        self.columns.as_deref()
    }

    pub(super) fn snapshot(
        &self,
        terminal: StreamTerminal,
        query: Option<crate::ui::export_dialog::StreamExportQuery>,
    ) -> StreamedResult {
        let export = query
            .zip(self.columns.clone())
            .map(|(query, columns)| crate::ui::export_dialog::StreamExportRequest { query, columns });
        StreamedResult {
            pages: self.pages.iter().map(|(_, page)| page.clone()).collect(),
            first_page: self.first_page(),
            total_pages: self.next_page,
            total_rows: self.total_rows,
            terminal,
            export,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::Value;

    fn page(columns: &[&str], values: &[i64]) -> Arc<QueryResult> {
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
    fn retains_a_bounded_ordered_window_and_counts_all_delivered_rows() {
        let mut cache = StreamPageCache::default();
        for index in 0..(MAX_RETAINED_STREAM_PAGES as u64 + 1) {
            cache
                .append(index, page(&["id"], &[index as i64]))
                .expect("append page");
        }

        assert_eq!(cache.pages().len(), MAX_RETAINED_STREAM_PAGES);
        assert_eq!(cache.first_page(), 1);
        assert_eq!(cache.total_rows(), (MAX_RETAINED_STREAM_PAGES + 1));
        assert_eq!(
            cache.pages().iter().map(|(index, _)| *index).collect::<Vec<_>>(),
            (1..=MAX_RETAINED_STREAM_PAGES as u64).collect::<Vec<_>>()
        );
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
}
