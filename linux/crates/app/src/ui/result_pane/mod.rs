//! One result set of an editor run as the results list shows it: a
//! banner when the run's row limit cut it short, its grid, and how
//! many rows it holds.

mod result_limit_banner;
mod result_set_view;
mod result_summary;

use gtk4 as gtk;
use gtk4::prelude::*;

pub(crate) use self::result_limit_banner::ResultLimitBanner;
pub(crate) use self::result_set_view::ResultSetView;
pub(crate) use self::result_summary::ResultSummary;
use crate::i18n::ngettext_f;
use crate::ui::export::ExportSource;
use crate::ui::format::{format_thousands, plural_count};
use crate::ui::grid::{GridContent, GridSink, RowObject, TabGridContext, build_column_view, export_snapshot};

/// The page for `view`. Export All on its banner hands `export_all` the
/// rows the grid shows, in the order it shows them, for the dialog's
/// Shown Rows.
pub(crate) fn result_set_page(
    view: &ResultSetView,
    sink: GridSink,
    export_all: impl Fn(ExportSource) + 'static,
) -> gtk::Widget {
    let content = GridContent {
        columns: view.columns.clone(),
        rows: view.rows.iter().cloned().map(RowObject::result).collect(),
    };
    let (column_view, _selection) = build_column_view(content, &[], sink, None, false, TabGridContext::default());
    let banner = ResultLimitBanner::new(&view.summary);
    let columns = view.columns.clone();
    let grid = column_view.downgrade();
    banner.connect_export_all(move || {
        let Some(column_view) = grid.upgrade() else {
            return;
        };
        export_all(ExportSource::Rows {
            columns: columns.clone(),
            rows: export_snapshot(&column_view, &TabGridContext::default()),
        });
    });
    let scrolled = gtk::ScrolledWindow::builder()
        .child(&column_view)
        .hexpand(true)
        .vexpand(true)
        .build();
    let shown = view.row_count() as u64;
    let footer = gtk::Label::builder()
        .label(ngettext_f(
            "{n} row",
            "{n} rows",
            plural_count(shown),
            &[("n", &format_thousands(shown))],
        ))
        .xalign(0.0)
        .margin_start(12)
        .margin_end(12)
        .margin_top(4)
        .margin_bottom(4)
        .build();
    footer.add_css_class("dim-label");
    footer.add_css_class("caption");
    let page = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
    page.append(banner.widget());
    page.append(&scrolled);
    page.append(&footer);
    page.upcast()
}
