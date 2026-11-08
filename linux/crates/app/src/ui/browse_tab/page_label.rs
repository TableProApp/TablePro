use super::page_state::PageState;
use super::row_total::RowTotal;
use crate::ui::format::format_thousands;

/// The paginator's text for the page on screen.
pub(super) fn page_range_label(page: &PageState, total: &RowTotal) -> String {
    let range = label_with(page, total, format_thousands);
    match page.elapsed {
        Some(elapsed) if page.row_count > 0 => crate::i18n::gettext_f(
            // Translators: the rows on screen, then how long the server took to give them.
            "{range} · {time}",
            &[("range", &range), ("time", &elapsed_text(elapsed))],
        ),
        _ => range,
    }
}

/// A read's time as the macOS bar words it: milliseconds, then seconds
/// from a second on, the shortest read still a millisecond.
fn elapsed_text(elapsed: std::time::Duration) -> String {
    let millis = elapsed.as_millis().max(1);
    if millis < 1000 {
        crate::i18n::gettext_f("{n} ms", &[("n", &millis.to_string())])
    } else {
        crate::i18n::gettext_f("{n} s", &[("n", &format!("{:.1}", elapsed.as_secs_f64()))])
    }
}

fn label_with(page: &PageState, total: &RowTotal, format: impl Fn(u64) -> String) -> String {
    let (start, rows) = (page.start_ordinal, page.row_count);
    match (rows, start, page.filtered) {
        (0, 0, false) => crate::i18n::gettext("No rows"),
        (0, 0, true) => crate::i18n::gettext("No rows match the filter"),
        // Past the end of a table that shrank in another session, until
        // the count moves the pager back.
        (0, _, _) => crate::i18n::gettext("No rows on this page"),
        _ => total.label_with(start + 1, start + rows as u64, format),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::format::Thousands;

    fn label(start: u64, rows: usize, total: &RowTotal) -> String {
        labelled(start, rows, false, total)
    }

    fn labelled(start: u64, rows: usize, filtered: bool, total: &RowTotal) -> String {
        let english = Thousands::for_posix_locale("en_US.UTF-8");
        let page = PageState {
            row_count: rows,
            start_ordinal: start,
            filtered,
            elapsed: None,
        };
        label_with(&page, total, |n| english.format(n))
    }

    #[test]
    fn a_read_is_timed_after_the_rows_in_milliseconds_then_seconds() {
        use std::time::Duration;

        assert_eq!(elapsed_text(Duration::from_micros(200)), "1 ms");
        assert_eq!(elapsed_text(Duration::from_millis(5)), "5 ms");
        assert_eq!(elapsed_text(Duration::from_millis(999)), "999 ms");
        assert_eq!(elapsed_text(Duration::from_millis(1_234)), "1.2 s");
        let page = PageState {
            row_count: 2,
            start_ordinal: 0,
            filtered: false,
            elapsed: Some(Duration::from_millis(5)),
        };
        assert_eq!(page_range_label(&page, &RowTotal::Exact(2)), "Rows 1 – 2 of 2 · 5 ms");
    }

    #[test]
    fn first_page_label() {
        assert_eq!(label(0, 100, &RowTotal::Unknown), "Rows 1 – 100");
    }

    #[test]
    fn last_partial_page_label() {
        assert_eq!(label(900, 42, &RowTotal::Exact(942)), "Rows 901 – 942 of 942");
    }

    #[test]
    fn estimated_total_label() {
        assert_eq!(
            label(0, 100, &RowTotal::Estimated(5_000)),
            "Rows 1 – 100 of about 5,000"
        );
    }

    #[test]
    fn exact_total_uses_thousands_separators() {
        assert_eq!(
            label(1_000, 1_000, &RowTotal::Exact(1_234_567)),
            "Rows 1,001 – 2,000 of 1,234,567"
        );
    }

    #[test]
    fn an_empty_page_says_so() {
        assert_eq!(label(2_000, 0, &RowTotal::Exact(1_500)), "No rows on this page");
    }

    #[test]
    fn an_empty_table_or_filter_says_which() {
        assert_eq!(label(0, 0, &RowTotal::Exact(0)), "No rows");
        assert_eq!(labelled(0, 0, true, &RowTotal::Unknown), "No rows match the filter");
    }
}
