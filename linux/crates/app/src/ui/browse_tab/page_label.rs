use super::page_state::PageState;
use super::row_total::RowTotal;
use crate::ui::format::format_thousands;

/// The paginator's text for the page on screen.
pub(super) fn page_range_label(page: &PageState, total: &RowTotal) -> String {
    label_with(page, total, format_thousands)
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
        };
        label_with(&page, total, |n| english.format(n))
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
