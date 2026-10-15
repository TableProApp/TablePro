use super::row_total::RowTotal;
use crate::ui::format::format_thousands;

/// The paginator's text for a page of `rows` rows that starts after
/// `start` rows of the table.
pub(super) fn page_range_label(start: u64, rows: usize, total: &RowTotal) -> String {
    label_with(start, rows, total, format_thousands)
}

fn label_with(start: u64, rows: usize, total: &RowTotal, format: impl Fn(u64) -> String) -> String {
    if rows == 0 {
        // Reachable when the user navigated past the end of a table that
        // shrank in another session, before the count clamps the offset
        // back.
        return crate::i18n::gettext("No rows on this page");
    }
    total.label_with(start + 1, start + rows as u64, format)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::format::Thousands;

    fn label(start: u64, rows: usize, total: &RowTotal) -> String {
        let english = Thousands::for_posix_locale("en_US.UTF-8");
        label_with(start, rows, total, |n| english.format(n))
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
}
