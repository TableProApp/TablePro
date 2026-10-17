use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::FilterSet;

use super::browse_tab_widgets::BrowseTabWidgets;
use super::pager_bar::PagerRequest;
use super::pending_changes_bar::PendingChangesRequest;
use super::{
    BrowseTab, BrowseTabInput, ClipboardInput, DEFAULT_PAGE_SIZE, PAGE_SIZE_OPTIONS, PagingInput, SaveInput,
    loading_description,
};
use crate::ui::filter_strip::FilterStrip;
use crate::ui::format::format_thousands;
use crate::ui::grid::GridSink;
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
    page_size_choices(&imp.page_size_dropdown, init.page_size);
    connect_controls(tab);
    BrowseTabWidgets {
        inner_stack: imp.inner_stack.get(),
        grid_holder: imp.grid_holder.get(),
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
    }
}

/// An inline editor that slides down above the grid. It lives in the
/// tab so the user's in-progress rules survive a click into a cell or
/// the SQL editor.
pub(super) fn filter_strip(tab: &BrowseTab, initial: &FilterSet) -> FilterStrip {
    let strip = FilterStrip::new(Vec::new(), initial);
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

/// Handled at once: a tracked change redraws the cells bound to its
/// row in place, so the cell that sent it is still there for the Tab
/// that ended the edit to move focus from.
pub(super) fn grid_sink(tab: &BrowseTab) -> GridSink {
    let tab = tab.downgrade();
    Rc::new(move |msg| {
        if let Some(tab) = tab.upgrade() {
            tab.send(BrowseTabInput::from(msg));
        }
    })
}

fn page_size_choices(dropdown: &gtk::DropDown, page_size: u64) {
    let labels: Vec<String> = PAGE_SIZE_OPTIONS.iter().map(|n| format_thousands(*n)).collect();
    let strs: Vec<&str> = labels.iter().map(String::as_str).collect();
    dropdown.set_model(Some(&gtk::StringList::new(&strs)));
    let initial_idx = PAGE_SIZE_OPTIONS
        .iter()
        .position(|n| *n == page_size)
        .unwrap_or_else(|| {
            PAGE_SIZE_OPTIONS
                .iter()
                .position(|n| *n == DEFAULT_PAGE_SIZE)
                .unwrap_or(2)
        });
    dropdown.set_selected(u32::try_from(initial_idx).unwrap_or_default());
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

fn connect_controls(tab: &BrowseTab) {
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
        (PendingChangesRequest::Discard, sender(tab, || SaveInput::ConfirmDiscard)),
        (PendingChangesRequest::StopSaving, sender(tab, || SaveInput::StopSaving)),
    ] {
        imp.pending_bar.connect_request(request, move |_| send());
    }
    let export = sender(tab, || ClipboardInput::Export(None));
    imp.export_button.connect_clicked(move |_| export());
    let retry = sender(tab, || PagingInput::Refresh);
    imp.retry_button.connect_clicked(move |_| retry());
    let tab = tab.downgrade();
    imp.page_size_dropdown.connect_selected_notify(move |dropdown| {
        let index = usize::try_from(dropdown.selected()).unwrap_or(usize::MAX);
        if let (Some(tab), Some(&size)) = (tab.upgrade(), PAGE_SIZE_OPTIONS.get(index)) {
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
