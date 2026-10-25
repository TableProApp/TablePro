//! One result set of an editor run as the results list shows it: a
//! banner when the run's row limit cut it short, its grid, and how
//! many rows it holds.

mod result_limit_banner;
mod result_set_view;
mod result_summary;

use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use tablepro_session::runtime::Tasks;
use tablepro_storage::AppSettings;

pub(crate) use self::result_limit_banner::ResultLimitBanner;
pub(crate) use self::result_set_view::ResultSetView;
pub(crate) use self::result_summary::ResultSummary;
use crate::i18n::ngettext_f;
use crate::services::grid::grid_columns;
use crate::ui::data_grid::{DataGrid, DialectSource, GridConfig, GridSorting, RowData};
use crate::ui::export::ExportSource;
use crate::ui::format::{format_thousands, plural_count};

/// What a result grid reads from the tab that shows it.
#[derive(Clone)]
pub(crate) struct ResultGridDeps {
    pub settings: Rc<AppSettings>,
    pub tasks: Tasks,
    /// `None` where the rows have no SQL spelling: no IN list to copy.
    pub dialect: Option<DialectSource>,
}

/// The page for `view` and the grid on it, named `name` as the results
/// list names it. Export All on its banner hands `export_all` the rows
/// the grid shows, in the order it shows them, for the dialog's Shown
/// Rows.
pub(crate) fn result_set_page(
    view: &ResultSetView,
    name: &str,
    deps: &ResultGridDeps,
    export_all: impl Fn(ExportSource) + 'static,
) -> (gtk::Widget, DataGrid) {
    let grid = DataGrid::new(GridConfig {
        columns: grid_columns(&view.columns, &[], |_| true),
        sorting: GridSorting::Client,
        rules: None,
        tracker: None,
        settings: deps.settings.clone(),
        layout: None,
        references: None,
        dialect: deps.dialect.clone(),
        table: None,
        find: true,
        filter_by_value: false,
        tasks: deps.tasks.clone(),
        label: name.to_owned(),
    });
    grid.set_hexpand(true);
    grid.set_vexpand(true);
    grid.replace_rows(view.rows.iter().cloned().map(RowData::result).collect(), 0);
    let banner = ResultLimitBanner::new(&view.summary);
    let shown = grid.downgrade();
    banner.connect_export_all(move || {
        if let Some(grid) = shown.upgrade() {
            export_all(grid.export_source());
        }
    });
    let page = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
    page.append(banner.widget());
    page.append(&grid);
    page.append(&row_count_footer(view.row_count() as u64));
    (page.upcast(), grid)
}

fn row_count_footer(shown: u64) -> gtk::Label {
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
    footer
}
