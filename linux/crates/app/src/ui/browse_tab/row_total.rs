use crate::ui::format::format_thousands;

/// What the tab knows of how many rows the table has under its filter.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) enum RowTotal {
    #[default]
    Unknown,
    /// The server's estimate, which the label says is about that many.
    Estimated(u64),
    /// A count is running. `estimate` shows meanwhile.
    Counting {
        estimate: Option<u64>,
    },
    Exact(u64),
    /// The count failed, and `reason` says why.
    Unavailable {
        estimate: Option<u64>,
        reason: String,
    },
}

impl RowTotal {
    /// "Rows 1 – 1,000 of 5,000", "of about 5,000,000", or no total.
    pub(crate) fn paginator_label(&self, start: u64, end: u64) -> String {
        self.label_with(start, end, format_thousands)
    }

    fn label_with(&self, start: u64, end: u64, format: impl Fn(u64) -> String) -> String {
        let (start, end) = (format(start), format(end));
        match self {
            Self::Exact(total) => crate::i18n::gettext_f(
                "Rows {start} – {end} of {total}",
                &[("start", &start), ("end", &end), ("total", &format(*total))],
            ),
            Self::Estimated(estimate)
            | Self::Counting {
                estimate: Some(estimate),
            }
            | Self::Unavailable {
                estimate: Some(estimate),
                ..
            } => crate::i18n::gettext_f(
                "Rows {start} – {end} of about {total}",
                &[("start", &start), ("end", &end), ("total", &format(*estimate))],
            ),
            Self::Unknown | Self::Counting { estimate: None } | Self::Unavailable { estimate: None, .. } => {
                crate::i18n::gettext_f("Rows {start} – {end}", &[("start", &start), ("end", &end)])
            }
        }
    }

    pub(crate) fn exact(&self) -> Option<u64> {
        match self {
            Self::Exact(total) => Some(*total),
            _ => None,
        }
    }

    /// The estimate a count started from, or the total it replaces.
    pub(crate) fn estimate(&self) -> Option<u64> {
        match self {
            Self::Exact(total) | Self::Estimated(total) => Some(*total),
            Self::Counting { estimate } | Self::Unavailable { estimate, .. } => *estimate,
            Self::Unknown => None,
        }
    }

    /// A committed save moved the total by what it inserted and deleted.
    /// Under a filter, an inserted or updated row may not match it, so
    /// an exact total becomes an estimate there.
    pub(crate) fn adjust_after_save(&mut self, inserted: u64, deleted: u64, filtered: bool) {
        let moved = |total: u64| total.saturating_add(inserted).saturating_sub(deleted);
        *self = match std::mem::take(self) {
            Self::Exact(total) if !filtered => Self::Exact(moved(total)),
            Self::Exact(total) | Self::Estimated(total) => Self::Estimated(moved(total)),
            Self::Counting { estimate } => Self::Counting {
                estimate: estimate.map(moved),
            },
            Self::Unavailable { estimate, reason } => Self::Unavailable {
                estimate: estimate.map(moved),
                reason,
            },
            Self::Unknown => Self::Unknown,
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::format::Thousands;

    fn label(total: &RowTotal, start: u64, end: u64) -> String {
        let english = Thousands::for_posix_locale("en_US.UTF-8");
        total.label_with(start, end, |n| english.format(n))
    }

    #[test]
    fn row_total_labels_use_thousands_and_about() {
        assert_eq!(label(&RowTotal::Exact(5_000), 1, 1_000), "Rows 1 – 1,000 of 5,000");
        assert_eq!(
            label(&RowTotal::Estimated(5_000_000), 1, 1_000),
            "Rows 1 – 1,000 of about 5,000,000"
        );
        assert_eq!(label(&RowTotal::Unknown, 1, 1_000), "Rows 1 – 1,000");
        assert_eq!(
            label(&RowTotal::Counting { estimate: Some(40) }, 1, 40),
            "Rows 1 – 40 of about 40"
        );
        assert_eq!(label(&RowTotal::Counting { estimate: None }, 1, 40), "Rows 1 – 40");
        assert_eq!(
            label(
                &RowTotal::Unavailable {
                    estimate: None,
                    reason: "Stopped.".to_owned()
                },
                1_001,
                2_000
            ),
            "Rows 1,001 – 2,000"
        );
    }

    #[test]
    fn adjust_after_save_keeps_exact_only_when_unfiltered() {
        let mut unfiltered = RowTotal::Exact(100);
        unfiltered.adjust_after_save(3, 1, false);
        assert_eq!(unfiltered, RowTotal::Exact(102));

        let mut filtered = RowTotal::Exact(100);
        filtered.adjust_after_save(3, 1, true);
        assert_eq!(filtered, RowTotal::Estimated(102));

        let mut estimated = RowTotal::Estimated(100);
        estimated.adjust_after_save(0, 10, false);
        assert_eq!(estimated, RowTotal::Estimated(90));

        let mut unknown = RowTotal::Unknown;
        unknown.adjust_after_save(5, 0, false);
        assert_eq!(unknown, RowTotal::Unknown);
    }

    #[test]
    fn row_total_adjust_is_saturating() {
        let mut total = RowTotal::Exact(2);
        total.adjust_after_save(0, 5, false);
        assert_eq!(total, RowTotal::Exact(0));

        let mut total = RowTotal::Exact(u64::MAX);
        total.adjust_after_save(1, 0, false);
        assert_eq!(total, RowTotal::Exact(u64::MAX));
    }
}
