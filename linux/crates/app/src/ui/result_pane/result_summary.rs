use tablepro_core::Truncation;

use crate::i18n::{gettext_f, ngettext_f};
use crate::ui::format::format_thousands;

/// How much of a result set an editor run kept, as the driver reported
/// it when the set ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResultSummary {
    /// The rows the result holds.
    pub retained: u64,
    /// What the server says the whole set held, when it says.
    pub total_rows: Option<u64>,
    pub truncation: Truncation,
    /// The run's limit on the rows of all its results, when that limit
    /// cut this one short.
    pub run_limit: Option<u64>,
    // The run's limit on the bytes of all its results, when that limit cut this one short.
    pub size_limit: Option<u64>,
}

impl ResultSummary {
    /// A set that has not ended, or ended with every row it held.
    pub(crate) fn complete(retained: u64) -> Self {
        Self {
            retained,
            total_rows: None,
            truncation: Truncation::Complete,
            run_limit: None,
            size_limit: None,
        }
    }

    pub(crate) fn is_truncated(&self) -> bool {
        self.truncation != Truncation::Complete || self.run_limit.is_some() || self.size_limit.is_some()
    }

    /// What the banner over a cut-short result says. `None` for a
    /// complete one, which shows no banner.
    pub(crate) fn limit_title(&self) -> Option<String> {
        self.limit_title_with(format_thousands, |bytes| gtk4::glib::format_size(bytes).to_string())
    }

    fn limit_title_with(&self, format: impl Fn(u64) -> String, format_size: impl Fn(u64) -> String) -> Option<String> {
        let shown = format(self.retained);
        if let Some(limit) = self.run_limit {
            let limit = format(limit);
            return Some(match self.retained {
                0 => gettext_f(
                    "No rows kept; a run keeps at most {limit} rows across its results",
                    &[("limit", &limit)],
                ),
                retained => ngettext_f(
                    "Showing the first {shown} row; a run keeps at most {limit} rows across its results",
                    "Showing the first {shown} rows; a run keeps at most {limit} rows across its results",
                    retained,
                    &[("shown", &shown), ("limit", &limit)],
                ),
            });
        }
        if let Some(bytes) = self.size_limit {
            return Some(self.size_title(&shown, &format_size(bytes), format));
        }
        match (self.truncation, self.total_rows) {
            (Truncation::Complete, _) => None,
            (Truncation::ReadPastLimit | Truncation::ByteLimit, Some(total)) => Some(ngettext_f(
                "Showing {shown} of {total} row",
                "Showing {shown} of {total} rows",
                total,
                &[("shown", &shown), ("total", &format(total))],
            )),
            (Truncation::ReadPastLimit | Truncation::ByteLimit, None) => Some(ngettext_f(
                "Showing the first {shown} row",
                "Showing the first {shown} rows",
                self.retained,
                &[("shown", &shown)],
            )),
            // A SELECT that calls a function per row may have done that for
            // only part of the rows, which "showing" alone would hide.
            (Truncation::ServerStopped, _) => Some(ngettext_f(
                "Showing the first {shown} row: the server stopped the statement at the row limit, before its end",
                "Showing the first {shown} rows: the server stopped the statement at the row limit, before its end",
                self.retained,
                &[("shown", &shown)],
            )),
        }
    }

    // The row that crosses the size is kept whole, so the size is where keeping stops, not a cap.
    fn size_title(&self, shown: &str, size: &str, format: impl Fn(u64) -> String) -> String {
        let stopped = self.truncation == Truncation::ServerStopped;
        match (self.retained, self.total_rows) {
            (0, _) if stopped => gettext_f(
                "No rows kept; a run stops keeping rows past {size}, and the server stopped the statement at the row limit, before its end",
                &[("size", size)],
            ),
            (0, _) => gettext_f("No rows kept; a run stops keeping rows past {size}", &[("size", size)]),
            (retained, _) if stopped => ngettext_f(
                "Showing the first {shown} row; a run stops keeping rows past {size}, and the server stopped the statement at the row limit, before its end",
                "Showing the first {shown} rows; a run stops keeping rows past {size}, and the server stopped the statement at the row limit, before its end",
                retained,
                &[("shown", shown), ("size", size)],
            ),
            (_, Some(total)) => ngettext_f(
                "Showing {shown} of {total} row; a run stops keeping rows past {size}",
                "Showing {shown} of {total} rows; a run stops keeping rows past {size}",
                total,
                &[("shown", shown), ("total", &format(total)), ("size", size)],
            ),
            (retained, None) => ngettext_f(
                "Showing the first {shown} row; a run stops keeping rows past {size}",
                "Showing the first {shown} rows; a run stops keeping rows past {size}",
                retained,
                &[("shown", shown), ("size", size)],
            ),
        }
    }

    /// The result's line in the results list: its place in the run and
    /// how many rows it has, with a `+` when there were more than it
    /// kept and nobody counted them.
    pub(crate) fn tab_label(&self, index: usize) -> String {
        self.tab_label_with(index, format_thousands)
    }

    fn tab_label_with(&self, index: usize, format: impl Fn(u64) -> String) -> String {
        let rows = match (self.is_truncated(), self.total_rows) {
            (false, _) => format(self.retained),
            (true, Some(total)) => format(total),
            (true, None) => gettext_f("{rows}+", &[("rows", &format(self.retained))]),
        };
        gettext_f(
            "Result {n} ({rows})",
            &[("n", &(index + 1).to_string()), ("rows", &rows)],
        )
    }

    /// The rows the history line records for this result: every row it
    /// had, which is unknown for a result cut short with no total.
    pub(crate) fn history_row_count(&self) -> Option<i64> {
        let rows = match (self.is_truncated(), self.total_rows) {
            (false, _) => Some(self.retained),
            (true, total) => total,
        };
        rows.map(|rows| i64::try_from(rows).unwrap_or(i64::MAX))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::format::Thousands;

    fn english(n: u64) -> String {
        Thousands::for_posix_locale("en_US.UTF-8").format(n)
    }

    // A fixed spelling, since glib writes the decimal point of the test's locale.
    fn megabytes(bytes: u64) -> String {
        format!("{} MB", bytes / 1_000_000)
    }

    fn summary(retained: u64, total_rows: Option<u64>, truncation: Truncation) -> ResultSummary {
        ResultSummary {
            retained,
            total_rows,
            truncation,
            run_limit: None,
            size_limit: None,
        }
    }

    #[test]
    fn limit_title_for_server_stopped_without_total() {
        let stopped = summary(1_000, None, Truncation::ServerStopped);
        let read_past = summary(1_000, None, Truncation::ReadPastLimit);

        assert_eq!(
            stopped.limit_title_with(english, megabytes).as_deref(),
            Some("Showing the first 1,000 rows: the server stopped the statement at the row limit, before its end")
        );
        assert_eq!(
            read_past.limit_title_with(english, megabytes).as_deref(),
            Some("Showing the first 1,000 rows")
        );
    }

    #[test]
    fn limit_title_for_read_past_limit_with_total_uses_thousands() {
        let read_past = summary(10_000, Some(1_234_567), Truncation::ReadPastLimit);

        assert_eq!(
            read_past.limit_title_with(english, megabytes).as_deref(),
            Some("Showing 10,000 of 1,234,567 rows")
        );
    }

    #[test]
    fn limit_title_names_the_run_limit_when_it_cut_the_result() {
        let cut = |retained| ResultSummary {
            run_limit: Some(100_000),
            ..summary(retained, None, Truncation::Complete)
        };

        assert_eq!(
            cut(2_500).limit_title_with(english, megabytes).as_deref(),
            Some("Showing the first 2,500 rows; a run keeps at most 100,000 rows across its results")
        );
        assert_eq!(
            cut(0).limit_title_with(english, megabytes).as_deref(),
            Some("No rows kept; a run keeps at most 100,000 rows across its results")
        );
        assert_eq!(cut(0).tab_label_with(4, english), "Result 5 (0+)");
        assert_eq!(cut(0).history_row_count(), None);
    }

    #[test]
    fn limit_title_names_the_size_limit_when_it_cut_the_result() {
        let cut = |retained, total_rows| ResultSummary {
            size_limit: Some(256_000_000),
            ..summary(retained, total_rows, Truncation::ByteLimit)
        };

        assert_eq!(
            cut(128, None).limit_title_with(english, megabytes).as_deref(),
            Some("Showing the first 128 rows; a run stops keeping rows past 256 MB")
        );
        assert_eq!(
            cut(1_280, Some(10_000)).limit_title_with(english, megabytes).as_deref(),
            Some("Showing 1,280 of 10,000 rows; a run stops keeping rows past 256 MB")
        );
        assert_eq!(
            cut(0, Some(4)).limit_title_with(english, megabytes).as_deref(),
            Some("No rows kept; a run stops keeping rows past 256 MB")
        );
        let stopped = ResultSummary {
            truncation: Truncation::ServerStopped,
            ..cut(128, None)
        };
        assert_eq!(
            stopped.limit_title_with(english, megabytes).as_deref(),
            Some(
                "Showing the first 128 rows; a run stops keeping rows past 256 MB, and the server stopped the statement at the row limit, before its end"
            )
        );
        let stopped_empty = ResultSummary {
            truncation: Truncation::ServerStopped,
            ..cut(0, None)
        };
        assert_eq!(
            stopped_empty.limit_title_with(english, megabytes).as_deref(),
            Some(
                "No rows kept; a run stops keeping rows past 256 MB, and the server stopped the statement at the row limit, before its end"
            )
        );
        assert_eq!(cut(128, None).tab_label_with(0, english), "Result 1 (128+)");
        assert_eq!(cut(1_280, Some(10_000)).tab_label_with(1, english), "Result 2 (10,000)");
        assert_eq!(cut(0, Some(4)).tab_label_with(2, english), "Result 3 (4)");
        assert_eq!(cut(128, None).history_row_count(), None);
    }

    #[test]
    fn limit_title_none_when_complete() {
        assert_eq!(
            summary(5, Some(5), Truncation::Complete).limit_title_with(english, megabytes),
            None
        );
        assert_eq!(ResultSummary::complete(0).limit_title_with(english, megabytes), None);
    }

    #[test]
    fn tab_label_marks_truncated_count_with_plus() {
        assert_eq!(
            summary(10_000, None, Truncation::ServerStopped).tab_label_with(0, english),
            "Result 1 (10,000+)"
        );
        assert_eq!(
            summary(10_000, Some(25_000), Truncation::ReadPastLimit).tab_label_with(1, english),
            "Result 2 (25,000)"
        );
        assert_eq!(
            summary(3, Some(3), Truncation::Complete).tab_label_with(2, english),
            "Result 3 (3)"
        );
    }

    #[test]
    fn history_row_count_is_none_for_capped_result_without_total() {
        assert_eq!(
            summary(1_000, None, Truncation::ServerStopped).history_row_count(),
            None
        );
        assert_eq!(
            summary(1_000, None, Truncation::ReadPastLimit).history_row_count(),
            None
        );
    }

    #[test]
    fn history_row_count_is_total_for_read_past_limit() {
        assert_eq!(
            summary(1_000, Some(4_321), Truncation::ReadPastLimit).history_row_count(),
            Some(4_321)
        );
        assert_eq!(summary(7, Some(7), Truncation::Complete).history_row_count(), Some(7));
        assert_eq!(ResultSummary::complete(2).history_row_count(), Some(2));
    }
}
