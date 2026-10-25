use super::cursor_page;

#[test]
fn streamed_progress_pluralizes_rows_and_pages_independently() {
    for (rows, pages, expected) in [
        (0usize, 0u64, "Received 0 rows · 0 pages"),
        (1, 1, "Received 1 row · 1 page"),
        (1, 2, "Received 1 row · 2 pages"),
        (2, 1, "Received 2 rows · 1 page"),
        (2, 2, "Received 2 rows · 2 pages"),
    ] {
        let result = super::super::super::StreamedResult {
            pages: vec![std::sync::Arc::new(cursor_page(&vec![1; rows], false).result)],
            page_indices: vec![pages.saturating_sub(1)],
            page_row_counts: vec![rows / pages.max(1) as usize; pages as usize],
            columns: Vec::new(),
            total_pages: pages,
            total_rows: rows,
            terminal: super::super::super::StreamTerminal::Complete,
            export: None,
            generation: 0,
            spool: None,
        };
        let text = super::super::stream_result_view::stream_progress_text(&result);
        assert_eq!(text, expected);
    }
}
