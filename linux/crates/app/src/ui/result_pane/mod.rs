//! One result set of an editor run as the results list shows it: a
//! banner when the run's row limit cut it short, its grid, and how
//! many rows it holds.

mod result_limit_banner;
mod result_set_view;
mod result_summary;

use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use tablepro_core::meta::TableRef;
use tablepro_linux_platform::AppSettings;
use tablepro_session::runtime::Tasks;

pub(crate) use self::result_limit_banner::ResultLimitBanner;
pub(crate) use self::result_set_view::ResultSetView;
pub(crate) use self::result_summary::ResultSummary;
use crate::i18n::ngettext_f;
use crate::services::grid::{GridColumn, GridMasks, ResultRefusal, grid_columns};
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::ui::data_grid::{DataGrid, DialectSource, EditRules, GridConfig, GridSorting, RowData};
use crate::ui::export::ExportSource;
use crate::ui::format::format_thousands;

/// What a result grid reads from the tab that shows it.
#[derive(Clone)]
pub(crate) struct ResultGridDeps {
    pub settings: Rc<AppSettings>,
    pub tasks: Tasks,
    /// `None` where the rows have no SQL spelling: no IN list to copy.
    pub dialect: Option<DialectSource>,
}

pub(crate) struct ResultGrid {
    pub columns: Arc<[GridColumn]>,
    pub masks: GridMasks,
    pub rows: Vec<RowData>,
    pub rules: Option<EditRules>,
    pub tracker: Option<TabTrackerHandle>,
    pub table: Option<TableRef>,
    pub result_lock: Option<ResultRefusal>,
}

impl ResultGrid {
    pub(crate) fn read_only(view: &ResultSetView, result_lock: Option<ResultRefusal>) -> Self {
        Self {
            columns: grid_columns(&view.columns, &[], |_| true),
            masks: view.masks.clone(),
            rows: view.rows.iter().cloned().map(RowData::result).collect(),
            rules: None,
            tracker: None,
            table: None,
            result_lock,
        }
    }
}

/// The page for `view` and the grid on it, named `name` as the results
/// list names it. Export All on its banner hands `export_all` the rows
/// the grid shows, in the order it shows them, for the dialog's Shown
/// Rows.
pub(crate) fn result_set_page(
    view: &ResultSetView,
    shown: ResultGrid,
    name: &str,
    deps: &ResultGridDeps,
    export_all: impl Fn(ExportSource) + 'static,
) -> (gtk::Widget, DataGrid) {
    let ResultGrid {
        columns,
        masks,
        rows,
        rules,
        tracker,
        table,
        result_lock,
    } = shown;
    let grid = DataGrid::new(GridConfig {
        columns,
        sorting: GridSorting::Client,
        rules,
        tracker,
        result_lock,
        settings: deps.settings.clone(),
        layout: None,
        references: None,
        dialect: deps.dialect.clone(),
        table,
        find: true,
        filter_by_value: false,
        share: true,
        reveal: true,
        tasks: deps.tasks.clone(),
        label: name.to_owned(),
    });
    grid.set_hexpand(true);
    grid.set_vexpand(true);
    grid.set_masks(masks);
    grid.replace_rows(rows, 0);
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
    let footer = gtk::Box::builder().spacing(6).build();
    footer.append(&row_count_footer(view.row_count() as u64));
    footer.append(&grid.selection_summary());
    page.append(&footer);
    (page.upcast(), grid)
}

fn row_count_footer(shown: u64) -> gtk::Label {
    let footer = gtk::Label::builder()
        .label(ngettext_f(
            "{n} row",
            "{n} rows",
            shown,
            &[("n", &format_thousands(shown))],
        ))
        .xalign(0.0)
        .margin_start(12)
        .margin_end(12)
        .margin_top(4)
        .margin_bottom(4)
        .build();
    footer.add_css_class("dimmed");
    footer.add_css_class("caption");
    footer
}
