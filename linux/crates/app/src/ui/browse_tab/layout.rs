use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use tablepro_core::FilterSet;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_session::Session;
use tablepro_session::runtime::Tasks;
use tablepro_storage::AppSettings;

use super::browse_tab_widgets::BrowseTabWidgets;
use super::pager_bar::PagerRequest;
use super::pending_changes_bar::PendingChangesRequest;
use super::{BrowseTab, BrowseTabInput, GridInput, PAGE_SIZE_OPTIONS, PagingInput, SaveInput, loading_description};
use crate::i18n::gettext;
use crate::persistence::ColumnLayoutStore;
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::ui::data_grid::{DataGrid, DialectSource, GridConfig, GridSorting, KeysHandle, LayoutBinding};
use crate::ui::filter_strip::FilterStrip;
use crate::ui::format::format_thousands;
use crate::ui::tab_load::StaleBanner;

pub(super) struct LayoutInit<'a> {
    pub(super) table_label: &'a str,
    pub(super) read_only: bool,
    pub(super) page_size: u64,
}

/// The tab as it opens, on the loading page, with each control sending
/// its input. Gives back the widgets the handlers drive.
pub(super) fn build(tab: &BrowseTab, init: &LayoutInit<'_>) -> BrowseTabWidgets {
    let imp = tab.imp();
    imp.loading_page
        .set_description(Some(&loading_description(init.table_label)));
    imp.inner_stack.set_visible_child_name("loading");
    imp.read_only_banner.set_revealed(init.read_only);
    let page_sizes = page_size_choices(&imp.page_size_dropdown, init.page_size);
    imp.more_button.set_menu_model(Some(&more_menu(&page_sizes)));
    connect_controls(tab, page_sizes.clone());
    BrowseTabWidgets {
        inner_stack: imp.inner_stack.get(),
        loading_page: imp.loading_page.get(),
        error_page: imp.error_page.get(),
        stale_banner: StaleBanner::new(imp.stale_banner.get(), sender(tab, || PagingInput::Refresh)),
        read_only_banner: imp.read_only_banner.get(),
        no_pk_banner: imp.no_pk_banner.get(),
        selection_label: imp.selection_label.get(),
        filter_button: imp.filter_button.get(),
        filter_badge: imp.filter_badge.get(),
        insert_button: imp.insert_button.get(),
        delete_button: imp.delete_button.get(),
        pager_bar: imp.pager_bar.get(),
        pending_bar: imp.pending_bar.get(),
        page_size_dropdown: imp.page_size_dropdown.get(),
        page_sizes,
    }
}

/// What the bottom bar holds past the tab's breakpoint, where it has no
/// room for it.
fn more_menu(page_sizes: &[u64]) -> gio::Menu {
    let actions = gio::Menu::new();
    actions.append(Some(&gettext("Filter Rows")), Some("browse.filter"));
    actions.append(Some(&gettext("Export Rows…")), Some("browse.export"));
    actions.append(Some(&gettext("Count Rows")), Some("browse.count-rows"));
    let sizes = gio::Menu::new();
    for size in page_sizes {
        let item = gio::MenuItem::new(Some(&format_thousands(*size)), None);
        item.set_action_and_target_value(Some("browse.page-size"), Some(&size.to_variant()));
        sizes.append_item(&item);
    }
    let menu = gio::Menu::new();
    menu.append_section(None, &actions);
    menu.append_section(Some(&gettext("Rows per Page")), &sizes);
    menu
}

/// An inline editor that slides down above the grid. It lives in the
/// tab so the user's in-progress rules survive a click into a cell or
/// the SQL editor. It offers what the connection's engine evaluates, and
/// its typed filter is a query document on an engine of documents and a
/// WHERE clause on the rest.
pub(super) fn filter_strip(tab: &BrowseTab, initial: &FilterSet, dialect: Option<Arc<dyn SqlDialect>>) -> FilterStrip {
    let strip = FilterStrip::new(Vec::new(), initial);
    if dialect.as_ref().map(|dialect| dialect.grammar()) == Some(SqlGrammar::Mongo) {
        strip.take_documents();
    }
    strip.set_dialect(dialect);
    strip.connect_applied({
        let tab = tab.downgrade();
        move |_, set| {
            if let Some(tab) = tab.upgrade() {
                tab.send(PagingInput::FilterApplied(set));
            }
        }
    });
    tab.imp().toolbar.add_top_bar(&strip);
    collapse_top_bars_with(tab, &strip);
    strip
}

/// What the tab's grid is built from.
pub(super) struct GridInit {
    pub(super) table: TableRef,
    pub(super) label: String,
    pub(super) connection_id: Option<uuid::Uuid>,
    pub(super) sorting: GridSorting,
    pub(super) tracker: TabTrackerHandle,
    pub(super) settings: Rc<AppSettings>,
    pub(super) layouts: ColumnLayoutStore,
    pub(super) keys: KeysHandle,
    /// Held weakly: the session outlives its tabs, and a grid must not
    /// keep a closed one.
    pub(super) session: std::sync::Weak<Session>,
    pub(super) tasks: Tasks,
}

/// The grid the tab shows its rows in for its whole life. It starts with
/// no columns; each read of another column set gives it new ones. Its
/// `grid` actions reach the tab's buttons through the tab.
pub(super) fn grid(tab: &BrowseTab, init: GridInit) -> DataGrid {
    let session = init.session;
    let dialect: DialectSource = Rc::new(move || session.upgrade()?.current_dialect());
    let layout = init.connection_id.map(|connection_id| LayoutBinding {
        store: init.layouts,
        connection_id,
        schema: init.table.schema.clone(),
        table: init.table.name.clone(),
    });
    let grid = DataGrid::new(GridConfig {
        columns: Arc::from([]),
        sorting: init.sorting,
        rules: None,
        tracker: Some(init.tracker),
        settings: init.settings,
        layout,
        references: Some(init.keys),
        dialect: Some(dialect),
        table: Some(init.table),
        // Ctrl+F is the filter strip's in a table tab.
        find: false,
        filter_by_value: true,
        tasks: init.tasks,
        label: init.label,
    });
    grid.set_vexpand(true);
    grid.set_hexpand(true);
    let imp = tab.imp();
    imp.grid_holder.append(&grid);
    let _ = imp.grid.set(grid.clone());
    connect_grid(tab, &grid);
    grid
}

/// Only queued: the grid emits these while it writes its rows, and the
/// tab may be handling an input that set it off.
fn connect_grid(tab: &BrowseTab, grid: &DataGrid) {
    let weak = tab.downgrade();
    grid.connect_request(move |_, request| {
        if let Some(tab) = weak.upgrade() {
            tab.send(GridInput::Request(request));
        }
    });
    let weak = tab.downgrade();
    grid.connect_selection_changed(move |_| {
        if let Some(tab) = weak.upgrade() {
            tab.send(GridInput::SelectionChanged);
        }
    });
    let weak = tab.downgrade();
    grid.connect_editing_changed(move |_| {
        if let Some(tab) = weak.upgrade() {
            tab.send(GridInput::EditingChanged);
        }
    });
}

/// The usual sizes, and the tab's own when Preferences or a saved tab
/// set another, so the dropdown always shows the size the tab reads.
/// Gives back the size at each position.
fn page_size_choices(dropdown: &gtk::DropDown, page_size: u64) -> Vec<u64> {
    let sizes = page_sizes_with(page_size);
    let labels: Vec<String> = sizes.iter().map(|n| format_thousands(*n)).collect();
    let strs: Vec<&str> = labels.iter().map(String::as_str).collect();
    dropdown.set_model(Some(&gtk::StringList::new(&strs)));
    let selected = sizes.iter().position(|n| *n == page_size).unwrap_or_default();
    dropdown.set_selected(u32::try_from(selected).unwrap_or_default());
    sizes
}

fn page_sizes_with(page_size: u64) -> Vec<u64> {
    let mut sizes = PAGE_SIZE_OPTIONS.to_vec();
    if !sizes.contains(&page_size) {
        sizes.push(page_size);
        sizes.sort_unstable();
    }
    sizes
}

/// Holds the tab weakly, since the tab owns the control that holds this.
fn sender<I: Into<BrowseTabInput> + 'static>(tab: &BrowseTab, msg: fn() -> I) -> impl Fn() + 'static {
    let tab = tab.downgrade();
    move || {
        if let Some(tab) = tab.upgrade() {
            tab.send(msg());
        }
    }
}

fn connect_controls(tab: &BrowseTab, page_sizes: Vec<u64>) {
    let imp = tab.imp();
    for (request, send) in [
        (PagerRequest::First, sender(tab, || PagingInput::FirstPage)),
        (PagerRequest::Previous, sender(tab, || PagingInput::PrevPage)),
        (PagerRequest::Next, sender(tab, || PagingInput::NextPage)),
        (PagerRequest::Last, sender(tab, || PagingInput::LastPage)),
        (PagerRequest::CountRows, sender(tab, || PagingInput::CountRows)),
    ] {
        imp.pager_bar.connect_request(request, move |_| send());
    }
    for (request, send) in [
        (PendingChangesRequest::Save, sender(tab, || SaveInput::CommitSave)),
        (
            PendingChangesRequest::Discard,
            sender(tab, || SaveInput::ConfirmDiscard),
        ),
        (PendingChangesRequest::StopSaving, sender(tab, || SaveInput::StopSaving)),
    ] {
        imp.pending_bar.connect_request(request, move |_| send());
    }
    let export = sender(tab, || GridInput::Export);
    imp.export_button.connect_clicked(move |_| export());
    let retry = sender(tab, || PagingInput::Refresh);
    imp.retry_button.connect_clicked(move |_| retry());
    let tab = tab.downgrade();
    imp.page_size_dropdown.connect_selected_notify(move |dropdown| {
        let index = usize::try_from(dropdown.selected()).unwrap_or(usize::MAX);
        if let (Some(tab), Some(&size)) = (tab.upgrade(), page_sizes.get(index)) {
            tab.send(PagingInput::PageSizeChanged(size));
        }
    });
}

/// The top-bar slot draws a thin strip even when every banner in it is
/// collapsed, so the slot itself is hidden unless one shows.
fn collapse_top_bars_with(tab: &BrowseTab, filter: &FilterStrip) {
    let imp = tab.imp();
    // The banners and the strip hold this through their notify handlers,
    // and the tab holds them, so it holds them all weakly.
    let sync: Rc<dyn Fn()> = {
        let toolbar = imp.toolbar.downgrade();
        let banners = [
            imp.stale_banner.downgrade(),
            imp.read_only_banner.downgrade(),
            imp.no_pk_banner.downgrade(),
        ];
        let filter = filter.downgrade();
        Rc::new(move || {
            let (Some(toolbar), Some(filter)) = (toolbar.upgrade(), filter.upgrade()) else {
                return;
            };
            let banner_shown = banners
                .iter()
                .filter_map(glib::WeakRef::upgrade)
                .any(|banner| banner.is_revealed());
            toolbar.set_reveal_top_bars(banner_shown || filter.revealed());
        })
    };
    sync();
    for banner in [&imp.stale_banner, &imp.read_only_banner, &imp.no_pk_banner] {
        let sync = sync.clone();
        banner.connect_revealed_notify(move |_| sync());
    }
    filter.connect_revealed_notify(move |_| sync());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn the_dropdown_shows_a_page_size_set_in_preferences() {
        let dropdown = gtk::DropDown::default();

        let sizes = page_size_choices(&dropdown, 2_500);

        assert_eq!(sizes, [100, 500, 1_000, 2_500, 5_000, 10_000]);
        assert_eq!(sizes.get(dropdown.selected() as usize), Some(&2_500));
        assert_eq!(page_size_choices(&dropdown, 1_000), PAGE_SIZE_OPTIONS);
        assert_eq!(sizes.len(), PAGE_SIZE_OPTIONS.len() + 1);
    }
}
