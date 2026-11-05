mod imp;
mod saved_query_listing;
mod saved_query_object;
mod saved_query_object_imp;
mod saved_query_row;
#[cfg(test)]
mod tests;

use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_session::runtime::{TaskFailure, Tasks};
use tablepro_storage::{SavedQueries, StorageError};
use uuid::Uuid;

use crate::i18n::{gettext, gettext_f};
use crate::runtime::spawn_and_deliver;
use crate::ui::history_dialog::QueryDestination;
use saved_query_listing::{Listing, matches};
use saved_query_object::SavedQueryObject;
use saved_query_row::SavedQueryRow;

glib::wrapper! {
    pub struct SavedQueriesDialog(ObjectSubclass<imp::SavedQueriesDialog>)
        @extends adw::Dialog, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

pub(crate) struct SavedQueriesDialogInit {
    pub store: Option<SavedQueries>,
    // Its connection's queries are listed first.
    pub active_connection: Option<Uuid>,
    pub tasks: Tasks,
}

// What the last search matched. None shows every query.
type Matched = Rc<RefCell<Option<HashSet<i64>>>>;

struct DialogParts {
    store: Option<SavedQueries>,
    active_connection: Option<Uuid>,
    tasks: Tasks,
    items: gio::ListStore,
    matched: Matched,
    filter: gtk::CustomFilter,
    sorted: gtk::SortListModel,
}

#[derive(Debug, Clone, Copy)]
enum StoreChange {
    Rename,
    Delete,
}

impl StoreChange {
    fn failure_text(self, error: Option<&StorageError>) -> String {
        match (self, error) {
            (Self::Rename, Some(error)) => rename_failure_text(error),
            (Self::Rename, None) => gettext("The saved query could not be renamed."),
            (Self::Delete, _) => gettext("Could not delete that saved query."),
        }
    }
}

impl SavedQueriesDialog {
    pub(crate) fn new(init: SavedQueriesDialogInit) -> Self {
        let dialog: Self = glib::Object::new();
        let items = gio::ListStore::new::<SavedQueryObject>();
        let matched = Matched::default();
        let filter = matching_filter(matched.clone());
        let filtered = gtk::FilterListModel::new(Some(items.clone()), Some(filter.clone()));
        let sorted = gtk::SortListModel::new(Some(filtered), None::<gtk::Sorter>);
        sorted.set_section_sorter(Some(&by_group()));
        let _ = dialog.imp().parts.set(DialogParts {
            store: init.store,
            active_connection: init.active_connection,
            tasks: init.tasks,
            items,
            matched,
            filter,
            sorted,
        });
        dialog.setup_list();
        dialog.connect_controls();
        dialog.show_results();
        dialog.load();
        dialog
    }

    pub(crate) fn connect_query_chosen<F: Fn(&Self, QueryDestination, String) + 'static>(&self, f: F) {
        let f = Rc::new(f);
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
        list_view.set_model(Some(&gtk::NoSelection::new(Some(parts.sorted.clone()))));
        list_view.set_factory(Some(&self.row_factory()));
        list_view.set_header_factory(Some(&connection_header_factory()));
        let dialog = self.downgrade();
        list_view.connect_activate(move |list_view, position| {
            let id = list_view
                .model()
                .and_then(|model| model.item(position))
                .and_downcast::<SavedQueryObject>()
                .and_then(|object| object.id());
            if let (Some(dialog), Some(id)) = (dialog.upgrade(), id) {
                dialog.send_query(id, QueryDestination::NewTab);
            }
        });
    }

    fn connect_controls(&self) {
        let imp = self.imp();
        let dialog = self.downgrade();
        imp.search_entry.connect_search_changed(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.search();
            }
        });
        let dialog = self.downgrade();
        imp.retry_button.connect_clicked(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.load();
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
            let row = SavedQueryRow::default();
            row.insert_action_group("saved", Some(&dialog.row_actions(&row)));
            item.set_child(Some(&row));
        });
        factory.connect_bind(|_, object| {
            let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            if let (Some(row), Some(saved)) = (
                item.child().and_downcast::<SavedQueryRow>(),
                item.item().and_downcast::<SavedQueryObject>(),
            ) {
                row.bind(&saved);
            }
        });
        factory.connect_unbind(|_, object| {
            if let Some(row) = object
                .downcast_ref::<gtk::ListItem>()
                .and_then(|item| item.child().and_downcast::<SavedQueryRow>())
            {
                row.unbind();
            }
        });
        factory
    }

    fn row_actions(&self, row: &SavedQueryRow) -> gio::SimpleActionGroup {
        let actions = gio::SimpleActionGroup::new();
        actions.add_action_entries([
            self.row_action(row, "open", |dialog, id| {
                dialog.send_query(id, QueryDestination::NewTab)
            }),
            self.row_action(row, "replace", |dialog, id| {
                dialog.send_query(id, QueryDestination::CurrentTab)
            }),
            self.row_action(row, "copy", Self::copy_query),
            self.row_action(row, "rename", Self::prompt_rename),
            self.row_action(row, "delete", Self::confirm_delete),
        ]);
        actions
    }

    // Acts on whichever query the row shows when it is picked, since the
    // list view binds its rows again as it scrolls.
    fn row_action(
        &self,
        row: &SavedQueryRow,
        name: &str,
        act: fn(&Self, i64),
    ) -> gio::ActionEntry<gio::SimpleActionGroup> {
        let (dialog, row) = (self.downgrade(), row.downgrade());
        gio::ActionEntry::<gio::SimpleActionGroup>::builder(name)
            .activate(move |_, _, _| {
                if let (Some(dialog), Some(id)) = (dialog.upgrade(), row.upgrade().and_then(|row| row.id())) {
                    act(&dialog, id);
                }
            })
            .build()
    }

    fn object_by_id(&self, id: i64) -> Option<SavedQueryObject> {
        let parts = self.imp().parts.get()?;
        parts
            .items
            .iter::<SavedQueryObject>()
            .filter_map(Result::ok)
            .find(|object| object.id() == Some(id))
    }

    fn send_query(&self, id: i64, destination: QueryDestination) {
        let Some(query) = self
            .object_by_id(id)
            .and_then(|object| object.query().map(str::to_owned))
        else {
            return;
        };
        self.emit_by_name::<()>(destination.signal(), &[&query]);
        self.close();
    }

    fn copy_query(&self, id: i64) {
        if let Some(query) = self
            .object_by_id(id)
            .and_then(|object| object.query().map(str::to_owned))
        {
            crate::ui::clipboard::copy_text(self, query, |message| self.add_toast(message));
        }
    }

    fn prompt_rename(&self, id: i64) {
        let Some(current) = self
            .object_by_id(id)
            .and_then(|object| object.name().map(str::to_owned))
        else {
            return;
        };
        let alert = adw::AlertDialog::new(Some(&gettext("Rename Saved Query")), None);
        let entry = adw::EntryRow::builder()
            .title(gettext("Name"))
            .activates_default(true)
            .build();
        entry.set_text(&current);
        let group = adw::PreferencesGroup::new();
        group.add(&entry);
        alert.set_extra_child(Some(&group));
        alert.add_response("cancel", &gettext("Cancel"));
        alert.add_response("rename", &gettext("Rename"));
        alert.set_response_appearance("rename", adw::ResponseAppearance::Suggested);
        alert.set_default_response(Some("rename"));
        alert.set_close_response("cancel");
        crate::ui::name_entry::require_name(&alert, "rename", &entry);

        let dialog = self.downgrade();
        alert.connect_response(None, move |_, response| {
            if response != "rename" {
                return;
            }
            let name = entry.text().to_string();
            if name.trim().is_empty() {
                return;
            }
            if let Some(dialog) = dialog.upgrade() {
                dialog.rename(id, name);
            }
        });
        alert.present(Some(self));
    }

    fn confirm_delete(&self, id: i64) {
        let Some(name) = self
            .object_by_id(id)
            .and_then(|object| object.name().map(str::to_owned))
        else {
            return;
        };
        let alert = adw::AlertDialog::new(
            Some(&gettext_f("Delete “{name}”?", &[("name", &name)])),
            Some(&gettext(
                "The saved query is removed. The SQL itself is not run or changed.",
            )),
        );
        alert.add_response("cancel", &gettext("Cancel"));
        alert.add_response("delete", &gettext("Delete"));
        alert.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
        alert.set_default_response(Some("cancel"));
        alert.set_close_response("cancel");

        let dialog = self.downgrade();
        alert.connect_response(None, move |_, response| {
            if response == "delete"
                && let Some(dialog) = dialog.upgrade()
            {
                dialog.delete(id);
            }
        });
        alert.present(Some(self));
    }

    fn rename(&self, id: i64, name: String) {
        self.change(StoreChange::Rename, move |store| async move {
            store.rename(id, &name).await
        });
    }

    fn delete(&self, id: i64) {
        self.change(StoreChange::Delete, move |store| async move { store.delete(id).await });
    }

    // The list is read again whether the change landed or not, so it
    // shows what the store holds now.
    fn change<W>(&self, change: StoreChange, work: impl FnOnce(SavedQueries) -> W + Send + 'static)
    where
        W: Future<Output = Result<(), StorageError>> + Send + 'static,
    {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let Some(store) = parts.store.clone() else {
            return;
        };
        let dialog = self.downgrade();
        drop(spawn_and_deliver(
            &parts.tasks,
            async move { work(store).await },
            move |done| {
                let Some(dialog) = dialog.upgrade() else {
                    return;
                };
                let failure = match done {
                    Ok(Ok(())) => None,
                    Ok(Err(error)) => {
                        tracing::warn!(%error, ?change, "a saved query change failed");
                        Some(change.failure_text(Some(&error)))
                    }
                    Err(failure) => {
                        tracing::warn!(%failure, ?change, "a saved query change did not finish");
                        Some(change.failure_text(None))
                    }
                };
                if let Some(message) = failure {
                    dialog.add_toast(&message);
                }
                dialog.load();
            },
        ));
    }

    fn load(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let Some(store) = parts.store.clone() else {
            return;
        };
        let generation = imp.load_generation.get().wrapping_add(1);
        imp.load_generation.set(generation);
        let active = parts.active_connection;
        let dialog = self.downgrade();
        drop(spawn_and_deliver(
            &parts.tasks,
            async move { store.list(None).await.map(|queries| Listing::new(queries, active)) },
            move |listed| {
                if let Some(dialog) = dialog.upgrade() {
                    dialog.list_arrived(generation, listed);
                }
            },
        ));
    }

    fn list_arrived(&self, generation: u64, listed: Result<Result<Listing, StorageError>, TaskFailure>) {
        let imp = self.imp();
        if imp.load_generation.get() != generation {
            return;
        }
        let listing = match listed {
            Ok(Ok(listing)) => listing,
            Ok(Err(error)) => {
                tracing::warn!(%error, "could not read the saved queries");
                self.load_failed();
                return;
            }
            Err(failure) => {
                tracing::warn!(%failure, "the saved queries read did not finish");
                self.load_failed();
                return;
            }
        };
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let objects: Vec<SavedQueryObject> = listing
            .queries
            .into_iter()
            .map(|(group, saved)| SavedQueryObject::new(saved, group))
            .collect();
        parts.items.splice(0, parts.items.n_items(), &objects);
        imp.snapshot.replace(listing.snapshot);
        imp.listed.set(true);
        // The ids the search matched may have changed with the list.
        self.search();
        self.show_results();
    }

    fn load_failed(&self) {
        let imp = self.imp();
        let reason = gettext("The query history file could not be read. It may be damaged.");
        if imp.listed.get() {
            self.add_toast(&reason);
            return;
        }
        imp.error_page.set_description(Some(&reason));
        imp.stack.set_visible_child_name("error");
    }

    // Matching runs on the blocking pool over the snapshot the last read
    // built, and only the newest search's answer is applied.
    fn search(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let generation = imp.search_generation.get().wrapping_add(1);
        imp.search_generation.set(generation);
        let needle = imp.search_entry.text().to_string();
        if needle.trim().is_empty() {
            self.apply_matches(None);
            return;
        }
        let snapshot = imp.snapshot.borrow().clone();
        let matching = parts.tasks.spawn_blocking_task(move || matches(&snapshot, &needle));
        let dialog = self.downgrade();
        glib::spawn_future_local(async move {
            let found = matching.await;
            if let Some(dialog) = dialog.upgrade() {
                dialog.search_finished(generation, found);
            }
        });
    }

    fn search_finished(&self, generation: u64, found: Result<HashSet<i64>, TaskFailure>) {
        if self.imp().search_generation.get() != generation {
            return;
        }
        match found {
            Ok(found) => self.apply_matches(Some(found)),
            Err(failure) => tracing::warn!(%failure, "the saved queries search did not finish"),
        }
    }

    fn apply_matches(&self, found: Option<HashSet<i64>>) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        parts.matched.replace(found);
        parts.filter.changed(gtk::FilterChange::Different);
        self.show_results();
    }

    fn show_results(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        // Only a read that lands takes the list off the error page.
        if !imp.listed.get() && imp.stack.visible_child_name().as_deref() == Some("error") {
            return;
        }
        if parts.sorted.n_items() > 0 {
            imp.stack.set_visible_child_name("list");
            return;
        }
        let page = &imp.status_page;
        if imp.search_entry.text().trim().is_empty() {
            page.set_icon_name(Some(crate::ui::icons::DOCUMENT_OPEN_RECENT));
            page.set_title(&gettext("No Saved Queries"));
            page.set_description(Some(&gettext(
                "Save a query from the editor and it will be listed here.",
            )));
        } else {
            page.set_icon_name(Some(crate::ui::icons::SYSTEM_SEARCH));
            page.set_title(&gettext("No Matches"));
            page.set_description(Some(&gettext("Try a different search term.")));
        }
        imp.stack.set_visible_child_name("empty");
    }

    fn add_toast(&self, message: &str) {
        self.imp().toast_overlay.add_toast(crate::ui::plain_toast(message));
    }
}

fn matching_filter(matched: Matched) -> gtk::CustomFilter {
    gtk::CustomFilter::new(move |object| {
        let matched = matched.borrow();
        let Some(found) = matched.as_ref() else {
            return true;
        };
        object
            .downcast_ref::<SavedQueryObject>()
            .and_then(SavedQueryObject::id)
            .is_some_and(|id| found.contains(&id))
    })
}

// Each connection is a section. Every query within one compares equal,
// so the store's order holds inside it.
fn by_group() -> gtk::CustomSorter {
    gtk::CustomSorter::new(|a, b| {
        let group = |object: &glib::Object| object.downcast_ref::<SavedQueryObject>().map(SavedQueryObject::group);
        group(a).cmp(&group(b)).into()
    })
}

fn connection_header_factory() -> gtk::SignalListItemFactory {
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
        let saved = header.item().and_downcast::<SavedQueryObject>();
        label.set_label(
            saved
                .as_ref()
                .and_then(SavedQueryObject::connection_name)
                .unwrap_or_default(),
        );
    });
    factory
}

// What a failed rename tells the user. A taken name is the one the user
// can fix from the dialog.
fn rename_failure_text(error: &StorageError) -> String {
    match error {
        StorageError::NameTaken => gettext("That name is already used by another saved query."),
        StorageError::TooLarge { .. } => gettext("That name is too long."),
        StorageError::NotFound => gettext("That saved query was deleted elsewhere."),
        _ => gettext("The saved query could not be renamed."),
    }
}

fn row_menu() -> gio::Menu {
    let menu = gio::Menu::new();
    let open_section = gio::Menu::new();
    open_section.append(Some(&gettext("_Open in New Tab")), Some("saved.open"));
    open_section.append(Some(&gettext("_Replace Current Tab")), Some("saved.replace"));
    open_section.append(Some(&gettext("_Copy SQL")), Some("saved.copy"));
    menu.append_section(None, &open_section);
    let edit_section = gio::Menu::new();
    edit_section.append(Some(&gettext("Re_name…")), Some("saved.rename"));
    menu.append_section(None, &edit_section);
    let danger_section = gio::Menu::new();
    danger_section.append(Some(&gettext("_Delete")), Some("saved.delete"));
    menu.append_section(None, &danger_section);
    menu
}
