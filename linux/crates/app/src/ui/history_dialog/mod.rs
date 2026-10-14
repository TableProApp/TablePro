//! The query history: a searchable list of what ran, read a page at a
//! time off the GTK thread.

mod connection_filter;
mod history_actions;
mod history_entry_object;
mod history_entry_object_imp;
mod history_export;
mod history_formatting;
mod history_paging;
mod history_row;
mod imp;
#[cfg(test)]
mod tests;

use std::collections::HashSet;
use std::time::{Duration, SystemTime};

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, gio, glib, graphene};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_session::runtime::{TaskFailure, Tasks};
use tablepro_storage::query_history::{
    Entry, HistoryConnection, HistoryPage, HistoryPageRequest, HistoryQuery, StatusFilter,
};
use tablepro_storage::{ConnectionStore, QueryHistory, SavedConnection, StorageError};
use uuid::Uuid;

use crate::application::{ShortcutOwner, local_shortcut_controller};
use crate::i18n::{gettext, ngettext_f};
use crate::runtime::spawn_and_deliver;
use crate::services::history_service::HistoryService;
use crate::ui::format::plural_count;
use history_export::{ExportKind, history_export_failure_text, save_export, show_export_failure};

use connection_filter::ConnectionFilterModel;
pub(crate) use history_entry_object::HistoryEntryObject;
use history_row::HistoryRow;

/// Several screens of rows, so the edge is reached rarely, and few
/// enough that the first page is quick on a large history.
const PAGE_SIZE: usize = 100;

glib::wrapper! {
    pub struct HistoryDialog(ObjectSubclass<imp::HistoryDialog>)
        @extends adw::Dialog, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

pub(crate) struct HistoryDialogInit {
    pub history: HistoryService,
    /// Where the filter reads the connections' current names.
    pub connections: ConnectionStore,
    /// The presenting window's connection, which the filter starts on.
    pub preferred_connection: Option<Uuid>,
    pub tasks: Tasks,
}

/// Where a query the user picked goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum QueryDestination {
    NewTab,
    CurrentTab,
}

impl QueryDestination {
    fn signal(self) -> &'static str {
        match self {
            Self::NewTab => "open-in-new-tab",
            Self::CurrentTab => "replace-current-tab",
        }
    }
}

/// What the dialog is built with and keeps for its life.
pub(super) struct DialogParts {
    history: Option<QueryHistory>,
    connections: ConnectionStore,
    preferred_connection: Option<Uuid>,
    connection_filter: ConnectionFilterModel,
    tasks: Tasks,
    entries: gio::ListStore,
    plain: gtk::NoSelection,
    multiple: gtk::MultiSelection,
    menu: gtk::PopoverMenu,
}

impl HistoryDialog {
    pub(crate) fn new(init: HistoryDialogInit) -> Self {
        let dialog: Self = glib::Object::new();
        let imp = dialog.imp();
        let entries = gio::ListStore::new::<HistoryEntryObject>();
        let sorted = gtk::SortListModel::new(Some(entries.clone()), None::<gtk::Sorter>);
        sorted.set_section_sorter(Some(&pinned_first()));
        let menu = gtk::PopoverMenu::from_model(None::<&gio::MenuModel>);
        menu.set_has_arrow(true);
        // Parented now: a popover menu finds its actions through the
        // parent it had when it was set up.
        menu.set_parent(&imp.list_view.get());
        let connection_filter = ConnectionFilterModel::new();
        imp.connection_row.set_model(Some(connection_filter.labels()));
        let _ = imp.parts.set(DialogParts {
            history: init.history.store(),
            connections: init.connections,
            preferred_connection: init.preferred_connection,
            connection_filter,
            tasks: init.tasks,
            entries,
            plain: gtk::NoSelection::new(Some(sorted.clone())),
            multiple: gtk::MultiSelection::new(Some(sorted)),
            menu,
        });
        dialog.setup_list();
        dialog.load_connections();
        dialog
    }

    pub(crate) fn connect_query_chosen<F: Fn(&Self, QueryDestination, String) + 'static>(&self, f: F) {
        let f = std::rc::Rc::new(f);
        for destination in [QueryDestination::NewTab, QueryDestination::CurrentTab] {
            let f = f.clone();
            self.connect_closure(
                destination.signal(),
                false,
                glib::closure_local!(move |dialog: &Self, query: String| f(dialog, destination, query)),
            );
        }
    }

    fn setup_list(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let list_view = imp.list_view.get();
        list_view.set_model(Some(&parts.plain));
        list_view.set_factory(Some(&self.row_factory()));
        list_view.set_header_factory(Some(&section_header_factory()));
        // The Menu key reaches the list view, which has the focused row.
        list_view.add_controller(local_shortcut_controller(ShortcutOwner::HistoryRow));
        let dialog = self.downgrade();
        list_view.connect_activate(move |_, position| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.open_at(position);
            }
        });
        let dialog = self.downgrade();
        parts.multiple.connect_selection_changed(move |_, _, _| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.selection_changed();
            }
        });
        let dialog = self.downgrade();
        imp.scroll.connect_edge_reached(move |_, edge| {
            if edge == gtk::PositionType::Bottom
                && let Some(dialog) = dialog.upgrade()
            {
                dialog.load_more();
            }
        });
        imp.search_bar.set_key_capture_widget(Some(&imp.stack.get()));
    }

    fn connect_filters(&self) {
        let imp = self.imp();
        let dialog = self.downgrade();
        imp.search_entry.connect_search_changed(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.refresh();
            }
        });
        for row in [&imp.connection_row, &imp.status_row, &imp.window_row] {
            let dialog = self.downgrade();
            row.connect_selected_notify(move |_| {
                if let Some(dialog) = dialog.upgrade() {
                    dialog.refresh();
                }
            });
        }
        let dialog = self.downgrade();
        imp.reset_filters_button.connect_clicked(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                let imp = dialog.imp();
                for row in [&imp.connection_row, &imp.status_row, &imp.window_row] {
                    row.set_selected(0);
                }
            }
        });
    }

    fn row_factory(&self) -> gtk::SignalListItemFactory {
        let factory = gtk::SignalListItemFactory::new();
        let dialog = self.downgrade();
        factory.connect_setup(move |_, object| {
            let (Some(item), Some(dialog)) = (object.downcast_ref::<gtk::ListItem>(), dialog.upgrade()) else {
                return;
            };
            let row = HistoryRow::default();
            dialog
                .bind_property("selecting", &row.check(), "visible")
                .sync_create()
                .build();
            dialog.follow_selection(item, &row);
            dialog.attach_row_menu(&row);
            item.set_child(Some(&row));
        });
        factory.connect_bind(|_, object| {
            let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let (Some(row), Some(entry)) = (
                item.child().and_downcast::<HistoryRow>(),
                item.item().and_downcast::<HistoryEntryObject>(),
            ) else {
                return;
            };
            row.bind(&entry, SystemTime::now());
            row.check().set_active(item.is_selected());
        });
        factory.connect_unbind(|_, object| {
            if let Some(row) = object
                .downcast_ref::<gtk::ListItem>()
                .and_then(|item| item.child().and_downcast::<HistoryRow>())
            {
                row.unbind();
            }
        });
        factory
    }

    /// The row's check and the list's selection say the same thing,
    /// whichever of them the user changes.
    fn follow_selection(&self, item: &gtk::ListItem, row: &HistoryRow) {
        let check = row.check();
        let shown = check.downgrade();
        item.connect_selected_notify(move |item| {
            if let Some(check) = shown.upgrade() {
                check.set_active(item.is_selected());
            }
        });
        let (dialog, item) = (self.downgrade(), item.downgrade());
        check.connect_toggled(move |check| {
            let (Some(dialog), Some(item)) = (dialog.upgrade(), item.upgrade()) else {
                return;
            };
            if item.is_selected() == check.is_active() {
                return;
            }
            let Some(parts) = dialog.imp().parts.get() else {
                return;
            };
            let position = item.position();
            if check.is_active() {
                parts.multiple.select_item(position, false);
            } else {
                parts.multiple.unselect_item(position);
            }
        });
    }

    fn attach_row_menu(&self, row: &HistoryRow) {
        let gesture = gtk::GestureClick::new();
        gesture.set_button(gdk::BUTTON_SECONDARY);
        let dialog = self.downgrade();
        gesture.connect_pressed(move |gesture, _, x, y| {
            let (Some(dialog), Some(row)) = (dialog.upgrade(), gesture.widget().and_downcast::<HistoryRow>()) else {
                return;
            };
            gesture.set_state(gtk::EventSequenceState::Claimed);
            dialog.popup_row_menu(&row, Some(graphene::Point::new(x as f32, y as f32)));
        });
        row.add_controller(gesture);
    }

    /// Open the menu for `row`'s entry, at `at` in the row, or over the
    /// whole row for the Menu key.
    fn popup_row_menu(&self, row: &HistoryRow, at: Option<graphene::Point>) {
        let imp = self.imp();
        let (Some(parts), Some(entry)) = (imp.parts.get(), row.entry()) else {
            return;
        };
        let list_view = imp.list_view.get();
        // The menu is parented to the list view, so it points in the
        // view's coordinates, not the row's.
        let pointing = match at {
            Some(point) => row
                .compute_point(&list_view, &point)
                .map(|point| gdk::Rectangle::new(point.x() as i32, point.y() as i32, 1, 1)),
            None => row.compute_bounds(&list_view).map(|bounds| {
                gdk::Rectangle::new(
                    bounds.x() as i32,
                    bounds.y() as i32,
                    bounds.width() as i32,
                    bounds.height() as i32,
                )
            }),
        };
        parts.menu.set_menu_model(Some(&row_menu(&entry)));
        parts.menu.set_pointing_to(pointing.as_ref());
        parts.menu.popup();
    }

    fn popup_focused_row_menu(&self) {
        let Some(item) = self.imp().list_view.focus_child() else {
            return;
        };
        let mut child = item.first_child();
        while let Some(widget) = child {
            if let Some(row) = widget.downcast_ref::<HistoryRow>() {
                self.popup_row_menu(row, None);
                return;
            }
            child = widget.next_sibling();
        }
    }

    fn selection_mode_changed(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let selecting = self.selecting();
        if selecting {
            imp.list_view.set_model(Some(&parts.multiple));
        } else {
            parts.multiple.unselect_all();
            imp.list_view.set_model(Some(&parts.plain));
        }
        // A click picks a row in select mode rather than opening it.
        imp.list_view.set_single_click_activate(!selecting);
        self.selection_changed();
    }

    fn selection_changed(&self) {
        let imp = self.imp();
        let count = if self.selecting() { self.selected_ids().len() } else { 0 };
        if count == 0 {
            imp.selection_bar.set_reveal_child(false);
            return;
        }
        let n = count as u64;
        imp.selection_label.set_label(&ngettext_f(
            "{n} selected",
            "{n} selected",
            plural_count(n),
            &[("n", &n.to_string())],
        ));
        imp.selection_bar.set_reveal_child(true);
    }

    fn selected_ids(&self) -> Vec<i64> {
        let Some(parts) = self.imp().parts.get() else {
            return Vec::new();
        };
        let selection = &parts.multiple;
        (0..selection.n_items())
            .filter(|position| selection.is_selected(*position))
            .filter_map(|position| selection.item(position).and_downcast::<HistoryEntryObject>())
            .filter_map(|entry| entry.id())
            .collect()
    }

    fn reselect(&self, ids: &HashSet<i64>) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        if ids.is_empty() {
            return;
        }
        let selection = &parts.multiple;
        for position in 0..selection.n_items() {
            let keep = selection
                .item(position)
                .and_downcast::<HistoryEntryObject>()
                .and_then(|entry| entry.id())
                .is_some_and(|id| ids.contains(&id));
            if keep {
                selection.select_item(position, false);
            }
        }
    }

    fn entry_by_id(&self, id: i64) -> Option<HistoryEntryObject> {
        let parts = self.imp().parts.get()?;
        parts
            .entries
            .iter::<HistoryEntryObject>()
            .filter_map(Result::ok)
            .find(|entry| entry.id() == Some(id))
    }

    fn open_at(&self, position: u32) {
        if self.selecting() {
            return;
        }
        let entry = self
            .imp()
            .list_view
            .model()
            .and_then(|model| model.item(position))
            .and_downcast::<HistoryEntryObject>();
        if let Some(id) = entry.and_then(|entry| entry.id()) {
            self.send_query(id, QueryDestination::NewTab);
        }
    }

    fn send_query(&self, id: i64, destination: QueryDestination) {
        let Some(query) = self.entry_by_id(id).and_then(|entry| entry.query()) else {
            return;
        };
        self.emit_by_name::<()>(destination.signal(), &[&query]);
        self.close();
    }

    fn copy_query(&self, id: i64) {
        if let Some(query) = self.entry_by_id(id).and_then(|entry| entry.query()) {
            self.clipboard().set_text(&query);
        }
    }

    fn storage(&self) -> Option<(QueryHistory, Tasks)> {
        let parts = self.imp().parts.get()?;
        Some((parts.history.clone()?, parts.tasks.clone()))
    }

    /// Run `work` against the history off the GTK thread, then refresh
    /// the list once it has landed.
    fn change_then_refresh<W>(&self, what: &'static str, work: impl FnOnce(QueryHistory) -> W + Send + 'static)
    where
        W: Future<Output = Result<(), StorageError>> + Send + 'static,
    {
        let Some((history, tasks)) = self.storage() else {
            return;
        };
        let dialog = self.downgrade();
        drop(spawn_and_deliver(
            &tasks,
            async move { work(history).await },
            move |done| {
                match done {
                    Ok(Ok(())) => {}
                    Ok(Err(error)) => tracing::warn!(%error, what, "a query history change failed"),
                    Err(failure) => tracing::warn!(%failure, what, "a query history task failed"),
                }
                if let Some(dialog) = dialog.upgrade() {
                    dialog.refresh();
                }
            },
        ));
    }

    fn toggle_pin(&self, id: i64) {
        let Some(entry) = self.entry_by_id(id) else {
            return;
        };
        let pinned = !entry.is_pinned();
        self.change_then_refresh(
            "pin",
            move |history| async move { history.set_pinned(id, pinned).await },
        );
    }

    /// Delete at once and offer Undo, rather than ask first: the entries
    /// come back as they were.
    fn delete_entries(&self, ids: Vec<i64>) {
        if ids.is_empty() {
            return;
        }
        let Some((history, tasks)) = self.storage() else {
            return;
        };
        let dialog = self.downgrade();
        drop(spawn_and_deliver(
            &tasks,
            async move { history.delete_returning(&ids).await },
            move |deleted| {
                let Some(dialog) = dialog.upgrade() else {
                    return;
                };
                match deleted {
                    Ok(Ok(entries)) => dialog.entries_deleted(entries),
                    Ok(Err(error)) => {
                        tracing::warn!(%error, "could not delete from the query history");
                        dialog.add_toast(&gettext("The queries could not be deleted."));
                    }
                    Err(failure) => tracing::warn!(%failure, "the query history delete failed"),
                }
            },
        ));
    }

    fn entries_deleted(&self, entries: Vec<Entry>) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        if entries.is_empty() {
            return;
        }
        let gone: HashSet<i64> = entries.iter().map(|entry| entry.id).collect();
        parts.entries.retain(|object| {
            object
                .downcast_ref::<HistoryEntryObject>()
                .and_then(HistoryEntryObject::id)
                .is_none_or(|id| !gone.contains(&id))
        });
        self.selection_changed();
        self.show_results();

        let count = entries.len() as u64;
        let toast = adw::Toast::new(&ngettext_f(
            "{count} query deleted",
            "{count} queries deleted",
            plural_count(count),
            &[("count", &count.to_string())],
        ));
        toast.set_use_markup(false);
        toast.set_button_label(Some(&gettext("_Undo")));
        let dialog = self.downgrade();
        toast.connect_button_clicked(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                let entries = entries.clone();
                dialog.change_then_refresh("restore", move |history| async move { history.restore(&entries).await });
            }
        });
        imp.toast_overlay.add_toast(toast);
    }

    fn delete_selected(&self) {
        self.delete_entries(self.selected_ids());
    }

    fn confirm_clear_all(&self) {
        let alert = adw::AlertDialog::new(
            Some(&gettext("Clear All Query History?")),
            Some(&gettext(
                "This permanently deletes every saved query, including pinned ones.",
            )),
        );
        alert.add_response("cancel", &gettext("Cancel"));
        alert.add_response("clear", &gettext("Clear"));
        alert.set_response_appearance("clear", adw::ResponseAppearance::Destructive);
        alert.set_default_response(Some("cancel"));
        alert.set_close_response("cancel");
        let dialog = self.downgrade();
        alert.connect_response(None, move |_, response| {
            if response == "clear"
                && let Some(dialog) = dialog.upgrade()
            {
                dialog.change_then_refresh("clear", |history| async move { history.clear_all().await.map(drop) });
            }
        });
        alert.present(Some(self));
    }

    fn show_storage(&self) {
        let Some((history, _)) = self.storage() else {
            return;
        };
        let path = history.path();
        let folder = path.parent().unwrap_or(path);
        let launcher = gtk::FileLauncher::new(Some(&gio::File::for_path(folder)));
        launcher.launch(
            self.root().and_downcast::<gtk::Window>().as_ref(),
            gio::Cancellable::NONE,
            |_| {},
        );
    }

    fn export_selected(&self, kind: ExportKind) {
        let ids = self.selected_ids();
        if ids.is_empty() {
            return;
        }
        let Some((history, tasks)) = self.storage() else {
            return;
        };
        let dialog = self.downgrade();
        drop(spawn_and_deliver(&tasks, kind.render(history, ids), move |rendered| {
            let Some(dialog) = dialog.upgrade() else {
                return;
            };
            match rendered {
                Ok(Ok(content)) => save_export(dialog.upcast_ref(), kind, content),
                Ok(Err(error)) => {
                    tracing::warn!(%error, "history export failed");
                    show_export_failure(dialog.upcast_ref(), &history_export_failure_text(&error));
                }
                Err(failure) => tracing::warn!(%failure, "the history export task failed"),
            }
        }));
    }

    /// List every connection the history holds entries for, so one that
    /// is not open can still be picked, then read the first page with
    /// the filter on the presenting window's connection.
    fn load_connections(&self) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let Some(history) = parts.history.clone() else {
            self.connect_filters();
            self.show_unavailable();
            return;
        };
        let (store, tasks) = (parts.connections.clone(), parts.tasks.clone());
        let blocking = tasks.clone();
        let dialog = self.downgrade();
        drop(spawn_and_deliver(
            &tasks,
            async move {
                let listed = history.connections_with_history().await;
                let saved = blocking.spawn_blocking_task(move || store.load_blocking()).await;
                (listed, saved)
            },
            move |loaded| {
                let Some(dialog) = dialog.upgrade() else {
                    return;
                };
                match loaded {
                    Ok((listed, saved)) => dialog.connections_loaded(listed, saved),
                    Err(failure) => tracing::warn!(%failure, "the history connections task failed"),
                }
                dialog.connect_filters();
                dialog.refresh();
            },
        ));
    }

    fn connections_loaded(
        &self,
        listed: Result<Vec<HistoryConnection>, StorageError>,
        saved: Result<Result<std::sync::Arc<[SavedConnection]>, StorageError>, TaskFailure>,
    ) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let listed = match listed {
            Ok(listed) => listed,
            Err(error) => {
                tracing::warn!(%error, "could not list the connections in the history");
                return;
            }
        };
        // Without the saved list the history's own names still serve.
        let saved = match saved {
            Ok(Ok(saved)) => saved,
            Ok(Err(error)) => {
                tracing::warn!(%error, "could not read the saved connections for the history filter");
                std::sync::Arc::from([])
            }
            Err(failure) => {
                tracing::warn!(%failure, "the saved connections read failed");
                std::sync::Arc::from([])
            }
        };
        parts.connection_filter.fill(&listed, &saved);
        let preferred = parts
            .preferred_connection
            .and_then(|id| parts.connection_filter.position_of(id));
        if let Some(position) = preferred {
            imp.connection_row.set_selected(position);
        }
    }

    fn query_from_filters(&self) -> HistoryQuery {
        let imp = self.imp();
        let mut query = HistoryQuery::from_input(&imp.search_entry.text());
        query.connection = imp
            .parts
            .get()
            .and_then(|parts| parts.connection_filter.id_at(imp.connection_row.selected()));
        query.status = match imp.status_row.selected() {
            1 => StatusFilter::Succeeded,
            2 => StatusFilter::Failed,
            3 => StatusFilter::Cancelled,
            _ => StatusFilter::Any,
        };
        let window = match imp.window_row.selected() {
            1 => Some(Duration::from_secs(86_400)),
            2 => Some(Duration::from_secs(7 * 86_400)),
            3 => Some(Duration::from_secs(30 * 86_400)),
            _ => None,
        };
        query.executed_after = window.and_then(|window| SystemTime::now().checked_sub(window));
        query
    }

    /// Read the first page for the current search. The rows on screen
    /// stay until it arrives, so typing never blanks the list.
    fn refresh(&self) {
        let imp = self.imp();
        let query = self.query_from_filters();
        imp.query.replace(query.clone());
        let generation = imp.paging.borrow_mut().start_refresh();
        let Some((history, tasks)) = self.storage() else {
            self.show_unavailable();
            return;
        };
        let dialog = self.downgrade();
        drop(spawn_and_deliver(
            &tasks,
            async move { history.search_page(&query, HistoryPageRequest::first(PAGE_SIZE)).await },
            move |page| {
                if let Some(dialog) = dialog.upgrade() {
                    dialog.first_page_arrived(generation, page);
                }
            },
        ));
    }

    fn first_page_arrived(&self, generation: u64, page: Result<Result<HistoryPage, StorageError>, TaskFailure>) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let page = match page {
            Ok(Ok(page)) => page,
            Ok(Err(error)) => {
                tracing::warn!(%error, "could not read the query history");
                self.first_page_failed(generation);
                return;
            }
            Err(failure) => {
                tracing::warn!(%failure, "the query history read failed");
                self.first_page_failed(generation);
                return;
            }
        };
        if !imp.paging.borrow_mut().first_page_arrived(generation, page.next) {
            return;
        }
        let selected: HashSet<i64> = self.selected_ids().into_iter().collect();
        let objects: Vec<HistoryEntryObject> = page.entries.into_iter().map(HistoryEntryObject::new).collect();
        parts.entries.splice(0, parts.entries.n_items(), &objects);
        self.reselect(&selected);
        // Rows that went with the splice leave the selection without a
        // selection-changed, so the count is read again here.
        self.selection_changed();
        self.show_results();
    }

    /// A refresh that fails keeps the rows the last one showed.
    fn first_page_failed(&self, generation: u64) {
        let imp = self.imp();
        let paging = imp.paging.borrow();
        if !paging.is_current(generation) {
            return;
        }
        if paging.has_loaded() {
            drop(paging);
            self.add_toast(&gettext("The query history could not be read."));
        } else {
            drop(paging);
            self.show_unavailable();
        }
    }

    fn load_more(&self) {
        let imp = self.imp();
        let Some((generation, after)) = imp.paging.borrow_mut().start_more() else {
            return;
        };
        let Some((history, tasks)) = self.storage() else {
            return;
        };
        let query = imp.query.borrow().clone();
        let dialog = self.downgrade();
        let request = HistoryPageRequest {
            after: Some(after),
            limit: PAGE_SIZE,
        };
        drop(spawn_and_deliver(
            &tasks,
            async move { history.search_page(&query, request).await },
            move |page| {
                if let Some(dialog) = dialog.upgrade() {
                    dialog.more_arrived(generation, page);
                }
            },
        ));
    }

    fn more_arrived(&self, generation: u64, page: Result<Result<HistoryPage, StorageError>, TaskFailure>) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let page = match page {
            Ok(Ok(page)) => page,
            Ok(Err(error)) => {
                tracing::warn!(%error, "could not read the next page of the query history");
                imp.paging.borrow_mut().more_failed(generation);
                return;
            }
            Err(failure) => {
                tracing::warn!(%failure, "the next query history page failed");
                imp.paging.borrow_mut().more_failed(generation);
                return;
            }
        };
        if !imp.paging.borrow_mut().more_arrived(generation, page.next) {
            return;
        }
        let objects: Vec<HistoryEntryObject> = page.entries.into_iter().map(HistoryEntryObject::new).collect();
        parts.entries.splice(parts.entries.n_items(), 0, &objects);
    }

    fn show_results(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        if parts.entries.n_items() > 0 {
            imp.stack.set_visible_child_name("list");
            return;
        }
        let query = imp.query.borrow();
        let narrowed = !query.terms().is_empty()
            || query.connection.is_some()
            || query.status != StatusFilter::Any
            || query.executed_after.is_some();
        let page = &imp.status_page;
        if narrowed {
            page.set_icon_name(Some(crate::ui::icons::SYSTEM_SEARCH));
            page.set_title(&gettext("No Matches"));
            page.set_description(Some(&gettext("Try a different search term or change the filters.")));
        } else {
            page.set_icon_name(Some(crate::ui::icons::DOCUMENT_OPEN_RECENT));
            page.set_title(&gettext("No Queries Yet"));
            page.set_description(Some(&gettext("Run a query in the SQL editor and it will appear here.")));
        }
        imp.stack.set_visible_child_name("empty");
    }

    fn show_unavailable(&self) {
        let imp = self.imp();
        imp.status_page.set_icon_name(Some(crate::ui::icons::DIALOG_ERROR));
        imp.status_page.set_title(&gettext("History Unavailable"));
        imp.status_page
            .set_description(Some(&gettext("The query history could not be read.")));
        imp.stack.set_visible_child_name("empty");
    }

    fn add_toast(&self, message: &str) {
        let toast = adw::Toast::new(message);
        toast.set_use_markup(false);
        self.imp().toast_overlay.add_toast(toast);
    }
}

/// Pinned entries form the first section. Every entry within a section
/// compares equal, so the order the history returned holds inside it.
fn pinned_first() -> gtk::CustomSorter {
    gtk::CustomSorter::new(|a, b| {
        let pinned = |object: &glib::Object| {
            object
                .downcast_ref::<HistoryEntryObject>()
                .is_some_and(HistoryEntryObject::is_pinned)
        };
        pinned(b).cmp(&pinned(a)).into()
    })
}

fn section_header_factory() -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, object| {
        let Some(header) = object.downcast_ref::<gtk::ListHeader>() else {
            return;
        };
        let label = gtk::Label::builder()
            .xalign(0.0)
            .margin_top(12)
            .margin_bottom(6)
            .margin_start(6)
            .build();
        label.add_css_class("heading");
        header.set_child(Some(&label));
    });
    factory.connect_bind(|_, object| {
        let Some(header) = object.downcast_ref::<gtk::ListHeader>() else {
            return;
        };
        let Some(label) = header.child().and_downcast::<gtk::Label>() else {
            return;
        };
        let pinned = header
            .item()
            .and_downcast::<HistoryEntryObject>()
            .is_some_and(|entry| entry.is_pinned());
        label.set_label(&if pinned {
            gettext("Pinned")
        } else {
            gettext("All Queries")
        });
    });
    factory
}

/// The row menu for one entry. Each item carries the entry's id, so the
/// one popover serves every row.
fn row_menu(entry: &HistoryEntryObject) -> gio::Menu {
    let Some(id) = entry.id() else {
        return gio::Menu::new();
    };
    let target = id.to_variant();
    let item = |label: String, action: &str| {
        let item = gio::MenuItem::new(Some(&label), None);
        item.set_action_and_target_value(Some(action), Some(&target));
        item
    };
    let open = gio::Menu::new();
    open.append_item(&item(gettext("Open in New Tab"), "history.open"));
    open.append_item(&item(gettext("Replace Current Tab"), "history.replace"));
    let keep = gio::Menu::new();
    let pin = if entry.is_pinned() {
        gettext("Unpin")
    } else {
        gettext("Pin")
    };
    keep.append_item(&item(pin, "history.pin"));
    keep.append_item(&item(gettext("Copy SQL"), "history.copy"));
    let remove = gio::Menu::new();
    remove.append_item(&item(gettext("Delete"), "history.delete"));
    let menu = gio::Menu::new();
    menu.append_section(None, &open);
    menu.append_section(None, &keep);
    menu.append_section(None, &remove);
    menu
}
