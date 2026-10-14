use std::sync::Arc;

use tablepro_session::Session;

use super::{ExpectedRows, ExportQuery, ExportSource};
use crate::i18n::{gettext, ngettext_f, pgettext};
use crate::ui::browse_tab::RowTotal;
use crate::ui::export_dialog::SqlTarget;
use crate::ui::format::{format_thousands, plural_count};

/// What a tab asks the window to export.
#[derive(Debug, Clone)]
pub(crate) struct ExportOffer {
    pub origin: ExportOrigin,
    /// The session the tab reads through, which a read of every row
    /// goes through too.
    pub session: Option<Arc<Session>>,
    pub name: String,
    pub target: Option<SqlTarget>,
}

/// What the user was looking at when they asked to export, and what
/// else they could export from there.
#[derive(Debug, Clone)]
pub(crate) enum ExportOrigin {
    Browse {
        /// The page on screen, pending edits included.
        page: ExportSource,
        query: ExportQuery,
        total: RowTotal,
        has_unsaved_changes: bool,
    },
    Editor {
        /// The rows the result holds, which the run's row limit may
        /// have cut short.
        shown: ExportSource,
        query: ExportQuery,
        shown_rows: u64,
        truncated: bool,
    },
}

/// Which rows a scope exports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ScopeSource {
    /// The rows the grid holds.
    Shown,
    /// Every row, read again from the server.
    Query,
}

/// One entry of the dialog's Rows list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ScopeChoice {
    pub title: String,
    pub subtitle: String,
    pub source: ScopeSource,
    pub expected: Option<ExpectedRows>,
}

pub(crate) fn scope_choices(origin: &ExportOrigin) -> Vec<ScopeChoice> {
    scope_choices_with(origin, format_thousands)
}

fn scope_choices_with(origin: &ExportOrigin, format: impl Fn(u64) -> String) -> Vec<ScopeChoice> {
    match origin {
        ExportOrigin::Browse {
            page,
            query,
            total,
            has_unsaved_changes,
        } => {
            let shown = page.row_count().unwrap_or_default() as u64;
            let filtered = matches!(query, ExportQuery::Table(export) if !export.filter.is_empty());
            let mut table = vec![table_total(total, &format)];
            if filtered {
                table.push(gettext("filters apply"));
            }
            if *has_unsaved_changes {
                table.push(gettext("unsaved changes aren't included"));
            }
            vec![
                ScopeChoice {
                    title: gettext("Current Page"),
                    subtitle: rows_text(shown, &format),
                    source: ScopeSource::Shown,
                    expected: Some(ExpectedRows::Exact(shown)),
                },
                ScopeChoice {
                    title: gettext("Entire Table"),
                    subtitle: table.join(&pgettext("list separator", ", ")),
                    source: ScopeSource::Query,
                    expected: expected_total(total),
                },
            ]
        }
        ExportOrigin::Editor { shown_rows, .. } => vec![
            ScopeChoice {
                title: gettext("Shown Rows"),
                subtitle: rows_text(*shown_rows, &format),
                source: ScopeSource::Shown,
                expected: Some(ExpectedRows::Exact(*shown_rows)),
            },
            ScopeChoice {
                title: gettext("All Rows"),
                subtitle: gettext("Runs the statement again on a separate read-only connection"),
                source: ScopeSource::Query,
                expected: None,
            },
        ],
    }
}

impl ExportOrigin {
    /// The choice the dialog opens on: every row when the editor's
    /// result was cut short, since that is why the user is here.
    pub(crate) fn preselected(&self) -> ScopeSource {
        match self {
            Self::Editor { truncated: true, .. } => ScopeSource::Query,
            Self::Browse { .. } | Self::Editor { .. } => ScopeSource::Shown,
        }
    }

    /// The rows the grid held.
    #[cfg(test)]
    pub(crate) fn shown(&self) -> &ExportSource {
        match self {
            Self::Browse { page, .. } => page,
            Self::Editor { shown, .. } => shown,
        }
    }

    /// The rows `source` stands for. A read needs `session`, and there
    /// is none once the window has disconnected.
    pub(crate) fn into_source(self, source: ScopeSource, session: Option<Arc<Session>>) -> Option<ExportSource> {
        let (shown, query) = match self {
            Self::Browse { page, query, .. } => (page, query),
            Self::Editor { shown, query, .. } => (shown, query),
        };
        match source {
            ScopeSource::Shown => Some(shown),
            ScopeSource::Query => session.map(|session| ExportSource::Query { session, query }),
        }
    }
}

fn rows_text(rows: u64, format: &impl Fn(u64) -> String) -> String {
    ngettext_f("{n} row", "{n} rows", plural_count(rows), &[("n", &format(rows))])
}

fn table_total(total: &RowTotal, format: &impl Fn(u64) -> String) -> String {
    match (total.exact(), total.estimate()) {
        (Some(exact), _) => rows_text(exact, format),
        (None, Some(estimate)) => ngettext_f(
            "About {n} row",
            "About {n} rows",
            plural_count(estimate),
            &[("n", &format(estimate))],
        ),
        (None, None) => gettext("Every row"),
    }
}

fn expected_total(total: &RowTotal) -> Option<ExpectedRows> {
    match (total.exact(), total.estimate()) {
        (Some(exact), _) => Some(ExpectedRows::Exact(exact)),
        (None, Some(estimate)) => Some(ExpectedRows::About(estimate)),
        (None, None) => None,
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::{RowIdentity, TableRef};
    use tablepro_core::{FilterOp, FilterRule, FilterSet, UserSql};

    use super::*;
    use crate::ui::export::TableExport;
    use crate::ui::format::Thousands;

    fn english(origin: &ExportOrigin) -> Vec<ScopeChoice> {
        let english = Thousands::for_posix_locale("en_US.UTF-8");
        scope_choices_with(origin, |n| english.format(n))
    }

    fn page(rows: usize) -> ExportSource {
        ExportSource::Rows {
            columns: Vec::new().into(),
            rows: (0..rows)
                .map(|_| crate::ui::grid::RowSnapshot::new(Vec::new().into(), Vec::new()))
                .collect(),
        }
    }

    fn table(filter: FilterSet) -> ExportQuery {
        ExportQuery::Table(TableExport {
            table: TableRef::new(None, "users".to_owned()),
            columns: Vec::new().into(),
            filter,
            sort: Vec::new(),
            identity: RowIdentity::Unordered,
        })
    }

    fn browse(total: RowTotal, filter: FilterSet, has_unsaved_changes: bool) -> ExportOrigin {
        ExportOrigin::Browse {
            page: page(3),
            query: table(filter),
            total,
            has_unsaved_changes,
        }
    }

    fn editor(shown_rows: u64, truncated: bool) -> ExportOrigin {
        ExportOrigin::Editor {
            shown: page(0),
            query: ExportQuery::Editor {
                sql: UserSql::new("SELECT 1"),
            },
            shown_rows,
            truncated,
        }
    }

    fn filtered() -> FilterSet {
        FilterSet {
            rules: vec![FilterRule {
                column: "name".to_owned(),
                op: FilterOp::IsNull,
                value: None,
            }],
            ..FilterSet::default()
        }
    }

    #[test]
    fn scope_choices_browse_entire_table_uses_about_for_estimates() {
        let estimated = english(&browse(RowTotal::Estimated(5_000_000), FilterSet::default(), false));
        let exact = english(&browse(RowTotal::Exact(1), FilterSet::default(), false));
        let unknown = english(&browse(RowTotal::Unknown, FilterSet::default(), false));
        let counting = english(&browse(
            RowTotal::Counting { estimate: Some(40) },
            FilterSet::default(),
            false,
        ));

        assert_eq!(estimated[0].title, "Current Page");
        assert_eq!(estimated[0].subtitle, "3 rows");
        assert_eq!(estimated[0].expected, Some(ExpectedRows::Exact(3)));
        assert_eq!(estimated[1].title, "Entire Table");
        assert_eq!(estimated[1].subtitle, "About 5,000,000 rows");
        assert_eq!(estimated[1].source, ScopeSource::Query);
        assert_eq!(estimated[1].expected, Some(ExpectedRows::About(5_000_000)));
        assert_eq!(exact[1].subtitle, "1 row");
        assert_eq!(exact[1].expected, Some(ExpectedRows::Exact(1)));
        assert_eq!(counting[1].subtitle, "About 40 rows");
        assert_eq!(unknown[1].subtitle, "Every row");
        assert_eq!(unknown[1].expected, None, "an unknown total has nothing to fill a bar");
    }

    #[test]
    fn scope_choices_browse_notes_unsaved_changes() {
        let clean = english(&browse(RowTotal::Exact(10), FilterSet::default(), false));
        let dirty = english(&browse(RowTotal::Exact(10), filtered(), true));

        assert_eq!(clean[1].subtitle, "10 rows");
        assert_eq!(
            dirty[1].subtitle,
            "10 rows, filters apply, unsaved changes aren't included"
        );
        assert_eq!(dirty[0].subtitle, "3 rows", "the page holds the pending edits");
    }

    #[test]
    fn scope_choices_editor_preselects_all_rows_when_truncated() {
        let truncated = editor(1_000, true);
        let complete = editor(10, false);
        let choices = english(&truncated);

        assert_eq!(
            choices.iter().map(|choice| choice.title.as_str()).collect::<Vec<_>>(),
            ["Shown Rows", "All Rows"]
        );
        assert_eq!(choices[0].subtitle, "1,000 rows");
        assert_eq!(choices[1].expected, None);
        assert_eq!(truncated.preselected(), ScopeSource::Query);
        assert_eq!(complete.preselected(), ScopeSource::Shown);
        assert_eq!(
            browse(RowTotal::Unknown, FilterSet::default(), false).preselected(),
            ScopeSource::Shown
        );
    }

    #[test]
    fn scope_subtitles_use_thousands_separators() {
        let browse = english(&browse(RowTotal::Exact(1_234_567), FilterSet::default(), false));
        let editor = english(&editor(12_345, true));

        assert_eq!(browse[1].subtitle, "1,234,567 rows");
        assert_eq!(editor[0].subtitle, "12,345 rows");
    }

    #[test]
    fn a_read_needs_a_session() {
        let shown = editor(1, true).into_source(ScopeSource::Shown, None);
        let read = editor(1, true).into_source(ScopeSource::Query, None);

        assert!(matches!(shown, Some(ExportSource::Rows { .. })));
        assert!(read.is_none());
    }
}
