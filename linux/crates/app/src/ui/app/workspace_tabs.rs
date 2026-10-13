use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::Arc;

use relm4::adw::prelude::*;
use relm4::gtk::{gio, glib};
use relm4::{ComponentSender, adw, gtk};

use tablepro_session::SessionKey;
use tablepro_storage::{DraftId, DraftScope};
use uuid::Uuid;

use crate::services::from_session::FromSession;
use crate::ui::browse_tab::{BrowseTab, BrowseTabInit, BrowseTabInput, ExportRequest, SaveRequest};
use crate::ui::editor::{SqlEditor, SqlEditorInit, derive_tab_label};
use crate::ui::structure_tab::{StructureMode, StructureTab, StructureTabInit};
use crate::workspace::{
    RestoredDrafts, TabRecord, WorkspaceFileName, WorkspaceLoad, WorkspaceRecord, WorkspaceSaveError,
};

use super::workspace_persistence::reopen;
use super::{
    App, AppMsg, CLOSED_TABS_CAPACITY, ClosedTabDescriptor, EditorTabSlot, OpenMode, WorkspaceTab,
    read_workspace_tab_id, write_workspace_tab_id,
};

impl App {
    /// Builds the unified AdwTabOverview tree once per connection.
    /// Idempotent via `workspace_root_added`.
    pub(super) fn ensure_workspace_root(&mut self, sender: ComponentSender<Self>) {
        if self.workspace_root_added.get() {
            return;
        }
        if self.workspace_root.is_none() {
            self.build_workspace_root(sender);
        }
        if let Some(root) = self.workspace_root.as_ref()
            && self.workspace_outer_stack.child_by_name("tabs").is_none()
        {
            self.workspace_outer_stack.add_named(root, Some("tabs"));
        }
        self.workspace_root_added.set(true);
    }

    fn build_workspace_root(&mut self, sender: ComponentSender<Self>) {
        let settings = self.settings.clone();
        let history = self.history.store();
        let tasks = self.tasks.clone();
        let session = self.context.active.clone();
        let hold = self.context.hold.clone();
        let close_timeout = self.context.close_timeout();
        let editor_init = move || SqlEditorInit {
            initial_query: None,
            settings: settings.clone(),
            history: history.clone(),
            tasks: tasks.clone(),
            session: session.clone(),
            hold: hold.clone(),
            close_timeout,
        };
        let create_tab = overview_editor_tab(
            self.workspace_tabs.clone(),
            editor_init,
            sender.input_sender().clone(),
            self.toast_overlay.downgrade(),
        );
        let chrome = build_workspace_chrome(sender.input_sender(), create_tab);
        self.workspace_root = Some(chrome.overview);
        self.workspace_tab_view = Some(chrome.view);
    }

    /// Read the saved tabs of the session just adopted, and the editor
    /// text that goes with them, off the GTK thread.
    pub(super) fn restore_workspace_tabs(&mut self, key: SessionKey, sender: ComponentSender<Self>) {
        let Some(session) = self.context.active.get() else {
            return;
        };
        let origin = Arc::downgrade(&session);
        let loading = self.storage.workspaces().load(&key);
        let store = self.drafts.store().clone();
        let scope = WorkspaceFileName::for_key(&key).draft_scope();
        let tasks = self.tasks.clone();
        glib::spawn_future_local(async move {
            let load = loading.await;
            let referenced: Vec<DraftId> = match &load {
                WorkspaceLoad::Restored(record) => saved_drafts(record).collect(),
                WorkspaceLoad::Empty | WorkspaceLoad::Blocked(_) => Vec::new(),
            };
            let reading = tasks.spawn_blocking_task(move || RestoredDrafts::read_blocking(&store, &scope, referenced));
            let drafts = reading.await.unwrap_or_default();
            sender.input(AppMsg::WorkspaceLoaded(FromSession::new(
                origin,
                LoadedWorkspace { key, load, drafts },
            )));
        });
    }

    /// Rebuild the saved tabs, then start writing the tab list.
    ///
    /// Nothing is written for the session before this: a write would
    /// replace the saved tabs before they were read.
    pub(super) fn on_workspace_loaded(&mut self, loaded: LoadedWorkspace, sender: ComponentSender<Self>) {
        let LoadedWorkspace { key, load, drafts } = loaded;
        let RestoredDrafts { mut texts, unreadable } = drafts;
        match load {
            WorkspaceLoad::Restored(record) => {
                self.retain_drafts(&key, saved_drafts(&record));
                if let Some(view) = self.workspace_tab_view.clone() {
                    reopen(&view, record, |tab| self.reopen_tab(tab, &mut texts, sender.clone()));
                }
            }
            WorkspaceLoad::Empty => self.retain_drafts(&key, std::iter::empty()),
            // Which drafts the file names is unknown, so none is deleted.
            WorkspaceLoad::Blocked(_) => self.show_unreadable_workspace_toast(),
        }
        if unreadable > 0 {
            let count = u32::try_from(unreadable).unwrap_or(u32::MAX);
            self.show_toast(&crate::i18n::ngettext_f(
                "Saved text of {n} query tab could not be read. The file was kept.",
                "Saved text of {n} query tabs could not be read. The files were kept.",
                count,
                &[("n", &unreadable.to_string())],
            ));
        }
        if let Some(view) = self.workspace_tab_view.as_ref() {
            self.workspace.attach(key, view, self.workspace_tabs.clone());
            self.persist_workspace_state();
        }
    }

    /// Delete the session's drafts that neither the saved tabs nor an
    /// open tab name: those of tabs closed in a session that did not
    /// shut down cleanly.
    fn retain_drafts(&self, key: &SessionKey, saved: impl Iterator<Item = DraftId>) {
        // A copy that Reset moved aside may name drafts the saved tabs
        // do not, and it leads back to them only while they are kept.
        if self.storage.workspaces().has_moved_aside_copy(key) {
            return;
        }
        let scope = WorkspaceFileName::for_key(key).draft_scope();
        let mut keep: HashSet<DraftId> = saved.collect();
        keep.extend(self.workspace_tabs.borrow().values().filter_map(|tab| match tab {
            WorkspaceTab::Editor(slot) => Some(slot.draft),
            _ => None,
        }));
        self.drafts.retain(&scope, keep);
    }

    fn reopen_tab(
        &mut self,
        tab: TabRecord,
        drafts: &mut HashMap<DraftId, String>,
        sender: ComponentSender<Self>,
    ) -> Option<adw::TabPage> {
        match tab {
            TabRecord::Table {
                schema,
                table,
                offset,
                page_size,
                sort,
            } => self.append_table_tab(
                schema,
                table,
                offset,
                page_size,
                sort.map(|sort| (sort.column, sort.ascending)),
                sender,
            ),
            TabRecord::Structure { schema, table } => self.append_existing_structure_tab(schema, table, sender),
            // Its text is on disk already, or there is none to keep, so
            // nothing is written until the user types.
            TabRecord::Editor { draft } => self.append_editor_tab_with_draft(
                Some(drafts.remove(&draft).unwrap_or_default()),
                draft,
                DraftWrite::OnChange,
                sender,
            ),
        }
    }

    fn show_unreadable_workspace_toast(&self) {
        let toast = adw::Toast::builder()
            .title(crate::i18n::gettext("Saved tabs could not be read"))
            .button_label(crate::i18n::gettext("Reset"))
            .action_name("win.reset-workspace-layout")
            .build();
        self.toast_overlay.add_toast(toast);
    }

    /// Move the unreadable saved tabs aside, so the open ones can be
    /// saved in their place.
    pub(super) fn on_reset_workspace_layout(&self, sender: ComponentSender<Self>) {
        let (Some(key), Some(session)) = (self.session_key().cloned(), self.context.active.get()) else {
            return;
        };
        let origin = Arc::downgrade(&session);
        let resetting = self.storage.workspaces().reset(&key);
        glib::spawn_future_local(async move {
            let outcome = resetting.await;
            sender.input(AppMsg::WorkspaceLayoutReset(FromSession::new(origin, outcome)));
        });
    }

    pub(super) fn on_workspace_layout_reset(&self, outcome: Result<Option<std::path::PathBuf>, WorkspaceSaveError>) {
        match outcome {
            Ok(moved) => {
                if let Some(moved) = moved {
                    tracing::info!(moved = %moved.display(), "moved the unreadable saved tabs aside");
                }
                self.persist_workspace_state();
            }
            Err(error) => {
                tracing::warn!(%error, "could not move the saved tabs aside");
                self.show_toast(&crate::i18n::gettext("Saved tabs could not be reset"));
            }
        }
    }

    /// Public entry: append a Structure draft tab for the New-Table
    /// flow. Edit-mode is no longer reachable through this helper;
    /// use `append_table_tab` for the unified Browse + Structure
    /// view of an existing table.
    pub(super) fn append_new_structure_tab(&mut self, schema: Option<String>, sender: ComponentSender<Self>) {
        self.ensure_workspace_root(sender.clone());
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let tab_id = Uuid::new_v4();
        let Some(session) = self.context.active.get() else {
            return;
        };
        let structure = StructureTab::new(StructureTabInit {
            tracker: self.structure_trackers.register(tab_id),
            schema: schema.clone(),
            table: String::new(),
            mode: StructureMode::New,
            session,
            tasks: self.context.tasks.clone(),
        });
        connect_structure(&structure, tab_id, sender.input_sender());

        let page = tab_view.append(&structure);
        page.set_title(&crate::i18n::gettext("New Table"));
        write_workspace_tab_id(&page, tab_id);

        let slot = super::StructureTabSlot {
            id: tab_id,
            structure,
            page: page.clone(),
            schema,
            table: String::new(),
            mode: StructureMode::New,
        };
        self.workspace_tabs
            .borrow_mut()
            .insert(tab_id, WorkspaceTab::Structure(slot));
        tab_view.set_selected_page(&page);
        self.workspace_outer_stack.set_visible_child_name("tabs");
        self.refresh_window_title();
        self.persist_workspace_state();
    }

    /// Public entry: append a unified Table tab (Browse + Structure
    /// share one AdwTabPage with an `AdwViewSwitcher` toggle). Both
    /// sub-controllers initialise eagerly so switching modes is
    /// instant and per-side state (pagination, sort, search,
    /// pending edits) survives a round trip.
    /// Append a Browse (Data-view) tab for an existing
    /// `(schema, table)`. The DDL editor for the same table opens as
    /// a separate `WorkspaceTab::Structure` page via the sidebar
    /// right-click "Edit Structure" action (`append_existing_structure_tab`).
    pub(super) fn append_table_tab(
        &mut self,
        schema: Option<String>,
        table: String,
        offset: u64,
        page_size: u64,
        sort: Option<(usize, bool)>,
        sender: ComponentSender<Self>,
    ) -> Option<adw::TabPage> {
        self.ensure_workspace_root(sender.clone());
        let tab_view = self.workspace_tab_view.clone()?;
        let tab_id = Uuid::new_v4();
        let connection_id = self.context.active.metadata().map(|metadata| metadata.id);
        let read_only = self.read_only;
        let session = self.context.active.get()?;
        let browse = BrowseTab::new(BrowseTabInit {
            tracker: self.change_trackers.register(tab_id),
            schema: schema.clone(),
            table: table.clone(),
            connection_id,
            read_only,
            page_size,
            initial_offset: offset,
            initial_sort: sort,
            column_widths: self.storage.column_widths().clone(),
            filter_settings: self.storage.filter_settings().clone(),
            session,
            tasks: self.context.tasks.clone(),
        });
        connect_browse(&browse, tab_id, sender.input_sender());

        let page = tab_view.append(&browse);
        let label = qualified_browse_tab_label(self.sidebar_schemas_distinct(), schema.as_deref(), &table);
        page.set_title(&label);
        if let Some(tip) = browse_tab_tooltip(schema.as_deref(), &table, &label) {
            page.set_tooltip(&tip);
        }
        write_workspace_tab_id(&page, tab_id);

        let slot = super::TableTabSlot {
            id: tab_id,
            page: page.clone(),
            schema,
            table,
            browse,
        };
        self.workspace_tabs
            .borrow_mut()
            .insert(tab_id, WorkspaceTab::Table(slot));
        tab_view.set_selected_page(&page);
        self.workspace_outer_stack.set_visible_child_name("tabs");
        self.refresh_window_title();
        self.persist_workspace_state();
        Some(page)
    }

    /// Open a Structure (DDL editor) tab for an EXISTING
    /// `(schema, table)`. Mirrors `append_new_structure_tab` shape
    /// but uses `StructureMode::Edit` and fetches the table's columns
    /// / indexes / FKs immediately. Called from
    /// `on_edit_structure_tab` (sidebar right-click → Edit Structure).
    pub(super) fn append_existing_structure_tab(
        &mut self,
        schema: Option<String>,
        table: String,
        sender: ComponentSender<Self>,
    ) -> Option<adw::TabPage> {
        self.ensure_workspace_root(sender.clone());
        let tab_view = self.workspace_tab_view.clone()?;
        let tab_id = Uuid::new_v4();
        let session = self.context.active.get()?;
        let mode = StructureMode::Edit;
        let structure = StructureTab::new(StructureTabInit {
            tracker: self.structure_trackers.register(tab_id),
            schema: schema.clone(),
            table: table.clone(),
            mode,
            session,
            tasks: self.context.tasks.clone(),
        });
        connect_structure(&structure, tab_id, sender.input_sender());

        let page = tab_view.append(&structure);
        let title = qualified_browse_tab_label(self.sidebar_schemas_distinct(), schema.as_deref(), &table);
        // Told apart from the table's own tab, with the middle dot GNOME
        // apps use in compound titles.
        page.set_title(&format!("{title} · {}", crate::i18n::gettext("Structure")));
        write_workspace_tab_id(&page, tab_id);

        let slot = super::StructureTabSlot {
            id: tab_id,
            structure,
            page: page.clone(),
            schema,
            table,
            mode,
        };
        self.workspace_tabs
            .borrow_mut()
            .insert(tab_id, WorkspaceTab::Structure(slot));
        tab_view.set_selected_page(&page);
        self.workspace_outer_stack.set_visible_child_name("tabs");
        self.refresh_window_title();
        self.persist_workspace_state();
        Some(page)
    }

    /// Public entry: append an Editor tab with optional initial query.
    pub(super) fn append_editor_tab(&mut self, initial_query: Option<String>, sender: ComponentSender<Self>) {
        self.append_editor_tab_with_draft(initial_query, DraftId::new(), DraftWrite::Now, sender);
    }

    /// Append an Editor tab that writes to a given draft, so a restored
    /// tab keeps the file it was already using.
    fn append_editor_tab_with_draft(
        &mut self,
        initial_query: Option<String>,
        draft: DraftId,
        write: DraftWrite,
        sender: ComponentSender<Self>,
    ) -> Option<adw::TabPage> {
        self.ensure_workspace_root(sender.clone());
        let tab_view = self.workspace_tab_view.clone()?;
        let tab_id = Uuid::new_v4();
        // Such a tab shows the editor's sample query, which names nothing.
        let opened_empty = initial_query.is_none();
        let editor = SqlEditor::new(SqlEditorInit {
            initial_query,
            settings: self.settings.clone(),
            history: self.history.store(),
            tasks: self.tasks.clone(),
            session: self.context.active.clone(),
            hold: self.context.hold.clone(),
            close_timeout: self.context.close_timeout(),
        });
        connect_editor(&editor, tab_id, sender.input_sender(), &self.toast_overlay.downgrade());
        let page = tab_view.append(&editor);
        let preview = EditorPreview::read(&editor.buffer());
        let label = if opened_empty || preview.is_blank() {
            default_editor_tab_label(self.editor_tab_count() + 1)
        } else {
            derive_tab_label(&preview.text)
        };
        page.set_title(&label);
        if !opened_empty && let Some(tip) = editor_tab_tooltip(&preview, &label) {
            page.set_tooltip(&tip);
        }
        write_workspace_tab_id(&page, tab_id);

        if write == DraftWrite::Now {
            // Text a new tab opens with is written even if the user
            // never types in it.
            self.drafts.schedule(&self.draft_scope(), draft, &editor.buffer());
        }
        let slot = EditorTabSlot {
            editor,
            page: page.clone(),
            draft,
        };
        self.workspace_tabs
            .borrow_mut()
            .insert(tab_id, WorkspaceTab::Editor(slot));
        tab_view.set_selected_page(&page);
        self.workspace_outer_stack.set_visible_child_name("tabs");
        self.refresh_window_title();
        self.persist_workspace_state();
        Some(page)
    }

    /// The directory this session's editor drafts live in.
    fn draft_scope(&self) -> DraftScope {
        self.session_key()
            .map(|key| WorkspaceFileName::for_key(key).draft_scope())
            .unwrap_or_default()
    }

    pub(super) fn close_workspace_tab_by_id(&mut self, id: Uuid, sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };

        let pending = self.dirty_tabs().contains(&id);
        let open_transaction = matches!(
            self.workspace_tabs.borrow().get(&id),
            Some(WorkspaceTab::Editor(slot)) if slot.editor.has_open_transaction()
        );
        if open_transaction {
            self.confirm_close_with_open_transaction(id, &tab_view, sender);
            return;
        }
        if pending {
            let page = self.workspace_tabs.borrow().get(&id).map(|t| match t {
                WorkspaceTab::Editor(s) => s.page.clone(),
                WorkspaceTab::Structure(s) => s.page.clone(),
                WorkspaceTab::Table(s) => s.page.clone(),
            });
            let Some(page) = page else { return };
            let raw_title = page.title().to_string();
            let tab_label = raw_title.strip_prefix("• ").unwrap_or(&raw_title).to_string();
            // Cancel | Discard(destructive) | Save(suggested), Save is
            // default. Mirrors GNOME Text Editor's close-with-unsaved
            // template (libadwaita AdwAlertDialog reference). Naming
            // the tab in the heading + factual body copy follows the
            // GNOME HIG pattern for destructive-confirmation dialogs.
            let dialog = adw::AlertDialog::new(None, None);
            dialog.set_heading(Some(&crate::i18n::gettext_f(
                "Save changes to “{name}”?",
                &[("name", &tab_label)],
            )));
            dialog.set_body(&crate::i18n::gettext(
                "Unsaved changes will be permanently lost if you discard them.",
            ));
            dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
            dialog.add_response("discard", &crate::i18n::gettext("Discard"));
            dialog.add_response("save", &crate::i18n::gettext("Save"));
            dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
            dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
            dialog.set_default_response(Some("save"));
            dialog.set_close_response("cancel");
            let tab_view_for_resp = tab_view.clone();
            let page_for_resp = page.clone();
            let sender_for_resp = sender.clone();
            let close_after_save = self.close_after_save.clone();
            // Snapshot which trackers actually have pending changes
            // before the dialog opens. Drives the discard + save
            // branches so a Table tab whose only dirt is on the
            // Structure side doesn't try to save through the Browse
            // path (and vice versa).
            let data_tracker = self
                .change_trackers
                .get(id)
                .filter(|tracker| tracker.pending_count() > 0);
            let structure_tracker = self.structure_trackers.get(id).filter(|tracker| tracker.has_pending());
            let (data_dirty, struct_dirty) = (data_tracker.is_some(), structure_tracker.is_some());
            dialog.connect_response(None, move |dlg, response| {
                dlg.close();
                match response {
                    "discard" => {
                        // The tab closes next, so no grid is left to
                        // show the discarded rows.
                        if let Some(tracker) = &data_tracker {
                            let _ = tracker.discard();
                        }
                        if let Some(tracker) = &structure_tracker {
                            tracker.clear();
                        }
                        sender_for_resp.input(AppMsg::WorkspaceTabClosed(id));
                    }
                    "save" => {
                        // Mark the tab so SaveCompletedForTab will close
                        // it once the transaction commits. The counter
                        // increments once per dispatched save: a Table
                        // tab dirty on both sides bumps to 2, and the
                        // close fires only after BOTH saves drain it.
                        // SaveFailed removes the entry entirely and
                        // aborts the close.
                        let pending_saves: u32 = u32::from(data_dirty) + u32::from(struct_dirty);
                        if pending_saves > 0 {
                            *close_after_save.borrow_mut().entry(id).or_insert(0) += pending_saves;
                        }
                        // Revert AdwTabView's "closing" state for now
                        // (the user might still cancel via SaveFailed).
                        tab_view_for_resp.close_page_finish(&page_for_resp, false);
                        // Dispatch the right save path per dirty side.
                        if data_dirty {
                            sender_for_resp.input(AppMsg::SaveActiveBrowseTabById(id));
                        }
                        if struct_dirty {
                            sender_for_resp.input(AppMsg::SaveActiveStructureTabById(id));
                        }
                    }
                    _ => {
                        // Cancel: revert AdwTabView's "closing" state
                        // so the page stays open. Without this the X
                        // click would still dismiss the page.
                        tab_view_for_resp.close_page_finish(&page_for_resp, false);
                    }
                }
            });
            dialog.present(Some(&self.window));
            return;
        }

        self.finish_close_workspace_tab(id, &tab_view);
    }

    /// An editor tab's connection ends with the tab, and the server
    /// rolls back whatever transaction it held, so closing one with a
    /// transaction open asks first.
    fn confirm_close_with_open_transaction(&self, id: Uuid, tab_view: &adw::TabView, sender: ComponentSender<Self>) {
        let Some(page) = self.workspace_tabs.borrow().get(&id).map(|tab| match tab {
            WorkspaceTab::Editor(s) => s.page.clone(),
            WorkspaceTab::Structure(s) => s.page.clone(),
            WorkspaceTab::Table(s) => s.page.clone(),
        }) else {
            return;
        };
        let dialog = adw::AlertDialog::new(
            Some(&crate::i18n::gettext("Close Tab With an Open Transaction?")),
            Some(&crate::i18n::gettext(
                "Closing the tab ends its connection, and the server rolls back the changes the transaction has not committed.",
            )),
        );
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("close", &crate::i18n::gettext("Close Tab"));
        dialog.set_response_appearance("close", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let tab_view = tab_view.clone();
        dialog.connect_response(None, move |_, response| {
            if response == "close" {
                sender.input(AppMsg::WorkspaceTabClosed(id));
            } else {
                tab_view.close_page_finish(&page, false);
            }
        });
        dialog.present(Some(&self.window));
    }

    /// Tear down a tab without prompting. Internal helper called once
    /// the close-with-pending dialog (if any) has resolved.
    pub(super) fn finish_close_workspace_tab(&mut self, id: Uuid, tab_view: &adw::TabView) {
        let removed = self.workspace_tabs.borrow_mut().remove(&id);
        let Some(removed) = removed else {
            return;
        };
        // Before the teardown, while the tab still has its page, sort
        // and query.
        if let Some(descriptor) = describe_closed_tab(&removed) {
            push_closed_tab(&self.closed_tabs_stack, descriptor);
        }
        // Drop any close-after-save / window-close-after-save intent
        // pinned to this tab. `close_tabs_for_table` (Drop Table)
        // calls into here directly without going through the per-tab
        // close prompt, so a stale entry would otherwise live on
        // forever and cause a future unrelated SaveCompleted to
        // spuriously close the window.
        self.close_after_save.borrow_mut().remove(&id);
        match &removed {
            WorkspaceTab::Editor(slot) => {
                slot.editor.shutdown();
                // The record no longer names this draft, so the file has
                // nothing left pointing at it.
                self.drafts.discard(&self.draft_scope(), slot.draft);
            }
            WorkspaceTab::Structure(slot) => {
                slot.structure.shutdown();
                self.structure_trackers.unregister(slot.id);
                self.structure_saves_in_flight.borrow_mut().remove(&slot.id);
            }
            WorkspaceTab::Table(slot) => {
                slot.browse.shutdown();
                self.change_trackers.unregister(slot.id);
                self.structure_saves_in_flight.borrow_mut().remove(&slot.id);
            }
        }
        let page = match &removed {
            WorkspaceTab::Editor(s) => s.page.clone(),
            WorkspaceTab::Structure(s) => s.page.clone(),
            WorkspaceTab::Table(s) => s.page.clone(),
        };
        tab_view.close_page_finish(&page, true);
        drop(removed);
        self.persist_workspace_state();
        if self.workspace_tabs.borrow().is_empty() {
            self.workspace_outer_stack.set_visible_child_name("empty");
        }
        self.refresh_window_title();
    }

    pub(super) fn close_active_workspace_tab(&mut self, sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.as_ref() else {
            // No tabs at all (disconnected) → close window.
            self.window.close();
            return;
        };
        let Some(page) = tab_view.selected_page() else {
            self.window.close();
            return;
        };
        tab_view.close_page(&page);
        let _ = sender;
    }

    /// Close every workspace tab except `keep_id`. Each close goes
    /// through the per-tab close path so dirty browse tabs still
    /// trigger the unsaved-changes alert; the user can cancel the
    /// dialog and the tab stays open while the others continue
    /// closing in the background.
    pub(super) fn close_other_workspace_tabs(&mut self, keep_id: Uuid, _sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let pages = tab_view.pages();
        let mut targets: Vec<adw::TabPage> = Vec::with_capacity(pages.n_items() as usize);
        for i in 0..pages.n_items() {
            let Some(page) = pages.item(i).and_downcast::<adw::TabPage>() else {
                continue;
            };
            if read_workspace_tab_id(&page) == Some(keep_id) {
                continue;
            }
            targets.push(page);
        }
        for page in targets {
            tab_view.close_page(&page);
        }
    }

    /// Close every workspace tab whose display position is greater
    /// than the targeted one. Useful for rapidly trimming a long
    /// session of throwaway tabs the user accumulated.
    pub(super) fn close_workspace_tabs_to_right(&mut self, anchor_id: Uuid, _sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let pages = tab_view.pages();
        let mut anchor_idx: Option<u32> = None;
        for i in 0..pages.n_items() {
            let Some(page) = pages.item(i).and_downcast::<adw::TabPage>() else {
                continue;
            };
            if read_workspace_tab_id(&page) == Some(anchor_id) {
                anchor_idx = Some(i);
                break;
            }
        }
        let Some(anchor_idx) = anchor_idx else {
            return;
        };
        let mut targets: Vec<adw::TabPage> = Vec::new();
        for i in (anchor_idx + 1)..pages.n_items() {
            let Some(page) = pages.item(i).and_downcast::<adw::TabPage>() else {
                continue;
            };
            targets.push(page);
        }
        for page in targets {
            tab_view.close_page(&page);
        }
    }

    /// A sidebar click never replaces the active tab: AdwTabView's
    /// close animation overlapped the append and flashed both tabs.
    pub(super) fn dispatch_select_table(
        &mut self,
        schema: Option<String>,
        name: String,
        open_mode: OpenMode,
        sender: ComponentSender<Self>,
    ) {
        if matches!(open_mode, OpenMode::SwitchOrAppend) {
            // Multiple tabs may be open for the same (schema, table)
            // pair (Ctrl+click duplicates). Prefer the currently-
            // selected tab when it matches, then any other match.
            let existing = {
                let tabs = self.workspace_tabs.borrow();
                let selected_page = self.workspace_tab_view.as_ref().and_then(|tv| tv.selected_page());
                let matches_slot = |t: &WorkspaceTab| match t {
                    WorkspaceTab::Table(s) if s.schema.as_deref() == schema.as_deref() && s.table == name => {
                        Some(s.page.clone())
                    }
                    _ => None,
                };
                let selected_match = selected_page.and_then(|sp| {
                    let id = read_workspace_tab_id(&sp)?;
                    matches_slot(tabs.get(&id)?)
                });
                selected_match.or_else(|| tabs.values().find_map(matches_slot))
            };
            if let Some(page) = existing
                && let Some(tab_view) = self.workspace_tab_view.as_ref()
            {
                tab_view.set_selected_page(&page);
                return;
            }
        }
        // Default open path appends a Data-view Browse tab. Structure
        // for the same table opens as its own separate tab via the
        // sidebar right-click "Edit Structure" action.
        let page_size = u64::from(self.settings.default_page_size());
        self.append_table_tab(schema, name, 0, page_size, None, sender);
    }

    /// Ctrl+F / Filter button: toggle the inline filter strip on the
    /// active Browse tab.
    pub(super) fn on_show_filter_dialog(&self) {
        let Some(id) = self.selected_browse_tab_id() else {
            self.show_toast(&crate::i18n::gettext("Open a table to filter rows."));
            return;
        };
        self.dispatch_to_tab(id, BrowseTabInput::ToggleFilterStrip);
    }

    pub(super) fn on_refresh_active_tab(&self) {
        let Some(id) = self.selected_browse_tab_id() else {
            return;
        };
        let dirty = self
            .change_trackers
            .get(id)
            .is_some_and(|tracker| tracker.pending_count() > 0);
        if !dirty {
            self.dispatch_to_tab(id, BrowseTabInput::Refresh);
            return;
        }
        // A refetch replaces the rows and with them every pending edit,
        // so F5 mid-edit asks first, as closing a dirty tab does.
        let dialog = adw::AlertDialog::new(
            Some(&crate::i18n::gettext("Discard pending changes?")),
            Some(&crate::i18n::gettext(
                "Refreshing reloads the table from the database and drops every unsaved edit on this tab.",
            )),
        );
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("discard", &crate::i18n::gettext("Discard and refresh"));
        dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let workspace_tabs = self.workspace_tabs.clone();
        dialog.connect_response(None, move |dlg: &adw::AlertDialog, response: &str| {
            dlg.close();
            if response != "discard" {
                return;
            }
            let browse = workspace_tabs
                .borrow()
                .get(&id)
                .and_then(|tab| tab.browse_tab())
                .cloned();
            if let Some(browse) = browse {
                browse.send(BrowseTabInput::DiscardAndRefresh);
            }
        });
        dialog.present(Some(&self.window));
    }

    /// Write the tab list a moment after the last change.
    pub(super) fn persist_workspace_state(&self) {
        self.workspace.request();
    }
}

impl App {
    /// Single handler for `WorkspaceTabsChanged`. Persists tab state,
    /// refreshes the window title (so tab switches update the subtitle),
    /// and syncs the sidebar selection to the active Browse tab's table.
    pub(super) fn on_workspace_tabs_changed(&self) {
        self.persist_workspace_state();
        self.refresh_window_title();
        self.sync_sidebar_selection();
    }

    /// With no Table tab active, no row stays selected: one would say
    /// the editor shows that table.
    fn sync_sidebar_selection(&self) {
        let listbox = self.sidebar_factory.widget();
        let Some((schema, table)) = self.selected_browse_slot_table() else {
            listbox.unselect_all();
            return;
        };
        let schemas = self.sidebar_schemas.borrow();
        let mut idx = 0_i32;
        while let Some(row) = listbox.row_at_index(idx) {
            // The factory builds one row per TableInfo, in the same order
            // as `sidebar_schemas`, so we can pair each row with its
            // schema-Option by index. SidebarRow stashes its table name
            // in widget-name (no CSS conflict, no qdata machinery).
            let row_table = row.widget_name();
            let row_schema = schemas.get(idx as usize).cloned().unwrap_or(None);
            if row_table.as_str() == table && row_schema.as_deref() == schema.as_deref() {
                // select_row doesn't trigger row-activated (user-only
                // signal), so this won't recurse into SelectTable.
                listbox.select_row(Some(&row));
                return;
            }
            idx += 1;
        }
    }

    pub(super) fn selected_workspace_tab_id(&self) -> Option<Uuid> {
        let tab_view = self.workspace_tab_view.as_ref()?;
        let page = tab_view.selected_page()?;
        read_workspace_tab_id(&page)
    }

    pub(super) fn selected_browse_tab_id(&self) -> Option<Uuid> {
        let id = self.selected_workspace_tab_id()?;
        let tabs = self.workspace_tabs.borrow();
        let slot = tabs.get(&id)?;
        if slot.browse_tab().is_some() { Some(id) } else { None }
    }

    pub(super) fn selected_browse_slot_table(&self) -> Option<(Option<String>, String)> {
        let id = self.selected_browse_tab_id()?;
        let tabs = self.workspace_tabs.borrow();
        let (schema, table) = tabs.get(&id)?.schema_table()?;
        Some((schema.map(str::to_owned), table.to_string()))
    }

    pub(super) fn sidebar_schemas_distinct(&self) -> usize {
        let schemas = self.sidebar_schemas.borrow();
        let distinct: std::collections::BTreeSet<&str> = schemas.iter().filter_map(|s| s.as_deref()).collect();
        distinct.len()
    }

    /// The label is built again rather than stored, so the schema
    /// prefix follows the other tabs. Only a background tab asks for
    /// attention; the selected one has its "•" in view.
    pub(super) fn refresh_browse_tab_dirty(&self, tab_id: uuid::Uuid, dirty: bool) {
        let schemas_count = self.sidebar_schemas_distinct();
        let tabs = self.workspace_tabs.borrow();
        let Some(slot) = tabs.get(&tab_id) else {
            return;
        };
        // Combined dirty state: data-side OR structure-side. The
        // Structure-side input also calls this helper via the
        // dirty-changed bus, so the Boolean ORs naturally compose.
        let WorkspaceTab::Table(s) = slot else {
            return;
        };
        let (page, schema, table) = (&s.page, s.schema.as_deref(), s.table.as_str());
        let combined_dirty = dirty || self.dirty_tabs().contains(&s.id);
        let base = qualified_browse_tab_label(schemas_count, schema, table);
        let title = if combined_dirty { format!("• {base}") } else { base };
        page.set_title(&title);
        let is_selected = self
            .workspace_tab_view
            .as_ref()
            .and_then(|tv| tv.selected_page())
            .map(|p| &p == page)
            .unwrap_or(false);
        page.set_needs_attention(combined_dirty && !is_selected);
        self.refresh_window_title();
    }

    pub(super) fn teardown_workspace_tabs(&mut self) {
        self.flush_workspace_state();
        self.cancel_all_editor_runs();
        // The pending edits name rows of the connection going away, so
        // they cannot be saved after it.
        for tab in self.workspace_tabs.borrow().values() {
            match tab {
                WorkspaceTab::Structure(slot) => {
                    slot.structure.shutdown();
                    self.structure_trackers.unregister(slot.id);
                }
                WorkspaceTab::Table(slot) => {
                    slot.browse.shutdown();
                    self.change_trackers.unregister(slot.id);
                }
                WorkspaceTab::Editor(_) => {}
            }
        }
        if let Some(root) = self.workspace_root.take()
            && self.workspace_root_added.get()
        {
            if self.workspace_outer_stack.child_by_name("tabs").is_some() {
                self.workspace_outer_stack.remove(&root);
            }
            self.workspace_root_added.set(false);
        }
        self.workspace_outer_stack.set_visible_child_name("empty");
        self.workspace_tab_view = None;
        self.workspace_tabs.borrow_mut().clear();
    }

    /// Write the tabs and the editor text as they are now, before the
    /// teardown frees them. The process is held until the writes land,
    /// so quitting right after a disconnect does not lose them.
    fn flush_workspace_state(&self) {
        let tabs = self.workspace.detach();
        let drafts = self.drafts.flush_all();
        let writer = self.drafts.clone();
        let hold = self.context.hold.acquire();
        glib::spawn_future_local(async move {
            for failure in drafts.await {
                tracing::warn!(failure, "an editor draft was not saved");
            }
            writer.release_closed();
            if let Some(tabs) = tabs
                && let Err(error) = tabs.await
            {
                tracing::debug!(%error, "the open tabs were not saved");
            }
            drop(hold);
        });
    }

    /// Stop every editor run and close each editor tab's connection,
    /// for a disconnect that takes the tabs with it.
    pub(super) fn cancel_all_editor_runs(&self) {
        for tab in self.workspace_tabs.borrow().values() {
            if let WorkspaceTab::Editor(s) = tab {
                s.editor.shutdown();
            }
        }
    }

    /// Forward a per-tab Browse input to the right slot. Routes to the
    /// Browse-side controller in both legacy `Browse` slots and the
    /// unified `Table` slot.
    pub(super) fn dispatch_to_tab(&self, tab_id: Uuid, msg: BrowseTabInput) {
        let browse = self
            .workspace_tabs
            .borrow()
            .get(&tab_id)
            .and_then(|t| t.browse_tab())
            .cloned();
        if let Some(browse) = browse {
            browse.send(msg);
        }
    }

    /// Name the tab after the start of its script, and write the script
    /// a moment later. Only the first `PREVIEW_CHARS` are read here, so a
    /// long script costs nothing to type in.
    pub(super) fn on_editor_tab_content_changed(&self, id: Uuid) {
        let tabs = self.workspace_tabs.borrow();
        let Some(WorkspaceTab::Editor(slot)) = tabs.get(&id) else {
            return;
        };
        let buffer = slot.editor.buffer();
        let preview = EditorPreview::read(&buffer);
        let label = if preview.is_blank() {
            crate::i18n::gettext("Empty query")
        } else {
            derive_tab_label(&preview.text)
        };
        slot.page.set_title(&label);
        // libadwaita treats an empty tooltip as none, which clears the
        // last one.
        slot.page
            .set_tooltip(&editor_tab_tooltip(&preview, &label).unwrap_or_default());
        self.drafts.schedule(&self.draft_scope(), slot.draft, &buffer);
    }

    pub(super) fn on_editor_tab_run_state_changed(&self, id: Uuid, running: bool) {
        if let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow().get(&id) {
            slot.page.set_loading(running);
        }
    }

    pub(super) fn on_replace_active_tab_query(&mut self, text: String, sender: ComponentSender<Self>) {
        if let Some(id) = self.selected_workspace_tab_id()
            && let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow().get(&id)
        {
            slot.editor.replace_query(&text);
            return;
        }
        self.append_editor_tab(Some(text), sender);
    }

    /// The SQL in the editor tab the user is looking at, or `None`
    /// when the active tab is not an editor.
    pub(super) fn active_editor_query(&self) -> Option<String> {
        let id = self.selected_workspace_tab_id()?;
        match self.workspace_tabs.borrow().get(&id) {
            Some(WorkspaceTab::Editor(slot)) => Some(whole_text(&slot.editor.buffer())),
            _ => None,
        }
    }

    fn editor_tab_count(&self) -> usize {
        self.workspace_tabs
            .borrow()
            .values()
            .filter(|t| matches!(t, WorkspaceTab::Editor(_)))
            .count()
    }
}

/// What a connected window's tabs live in: the overview, and the view
/// inside it that holds the pages.
struct WorkspaceChrome {
    overview: adw::TabOverview,
    view: adw::TabView,
}

/// Build the tab bar, view and overview. `create_tab` makes the page the
/// overview's own new-tab button asks for, which it needs back at once.
fn build_workspace_chrome(
    input: &relm4::Sender<AppMsg>,
    create_tab: impl Fn(&adw::TabView) -> adw::TabPage + 'static,
) -> WorkspaceChrome {
    let tab_view = adw::TabView::new();
    let tab_bar = adw::TabBar::builder()
        .view(&tab_view)
        .autohide(false)
        .expand_tabs(true)
        .build();

    let overview_button = adw::TabButton::builder()
        .view(&tab_view)
        .action_name("overview.open")
        .tooltip_text(crate::i18n::gettext("View open tabs"))
        .valign(gtk::Align::Center)
        .build();
    // With one page the overview has nothing to choose between. A
    // binding, unlike a notify handler, holds the button weakly, and the
    // button holds the view.
    tab_view
        .bind_property("n-pages", &overview_button, "visible")
        .transform_to(|_, pages: i32| Some(pages > 1))
        .sync_create()
        .build();
    tab_bar.set_start_action_widget(Some(&overview_button));

    // Browse tabs need a table to show, so they open from the sidebar,
    // and this button only makes editor tabs.
    let new_query_button = gtk::Button::builder()
        .icon_name(crate::ui::icons::TAB_NEW)
        .tooltip_text(crate::i18n::gettext("New query (Ctrl+E)"))
        .valign(gtk::Align::Center)
        .build();
    new_query_button.add_css_class("flat");
    let new_tab_input = input.clone();
    new_query_button.connect_clicked(move |_| new_tab_input.emit(AppMsg::NewEditorTab));
    tab_bar.set_end_action_widget(Some(&new_query_button));

    // A tab with unsaved work asks first, so the App finishes the close.
    let close_input = input.clone();
    tab_view.connect_close_page(move |_view, page| {
        if let Some(id) = read_workspace_tab_id(page) {
            close_input.emit(AppMsg::WorkspaceTabClosed(id));
        }
        glib::Propagation::Stop
    });

    // The view names the right-clicked page only while its menu is
    // open, so the actions read it from here.
    let menu_target: Rc<RefCell<Option<adw::TabPage>>> = Rc::new(RefCell::new(None));
    let menu_target_setup = menu_target.clone();
    tab_view.connect_setup_menu(move |_view, page| {
        *menu_target_setup.borrow_mut() = page.cloned();
    });
    let action_group = gio::SimpleActionGroup::new();
    let close_others_action = gio::SimpleAction::new("close-others", None);
    let menu_target_others = menu_target.clone();
    let close_others_input = input.clone();
    close_others_action.connect_activate(move |_, _| {
        let target = menu_target_others.borrow().clone();
        if let Some(page) = target
            && let Some(id) = read_workspace_tab_id(&page)
        {
            close_others_input.emit(AppMsg::CloseOtherWorkspaceTabs(id));
        }
    });
    action_group.add_action(&close_others_action);
    let close_right_action = gio::SimpleAction::new("close-right", None);
    let menu_target_right = menu_target;
    let close_right_input = input.clone();
    close_right_action.connect_activate(move |_, _| {
        let target = menu_target_right.borrow().clone();
        if let Some(page) = target
            && let Some(id) = read_workspace_tab_id(&page)
        {
            close_right_input.emit(AppMsg::CloseWorkspaceTabsToRight(id));
        }
    });
    action_group.add_action(&close_right_action);
    tab_view.insert_action_group("tab", Some(&action_group));

    let bulk_menu = gio::Menu::new();
    bulk_menu.append(
        Some(&crate::i18n::gettext("Close Other Tabs")),
        Some("tab.close-others"),
    );
    bulk_menu.append(
        Some(&crate::i18n::gettext("Close Tabs to the Right")),
        Some("tab.close-right"),
    );
    tab_view.set_menu_model(Some(&bulk_menu));

    // A drag reorder changes only `pages`, and it has to persist too.
    let selected_input = input.clone();
    tab_view.connect_selected_page_notify(move |_| selected_input.emit(AppMsg::WorkspaceTabsChanged));
    let pages_input = input.clone();
    tab_view.connect_pages_notify(move |_| pages_input.emit(AppMsg::WorkspaceTabsChanged));

    let inner = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
    inner.append(&tab_bar);
    inner.append(&tab_view);

    let overview = adw::TabOverview::builder()
        .view(&tab_view)
        .enable_new_tab(true)
        .enable_search(true)
        .child(&inner)
        .build();
    // `create-tab` returns its page (transfer none): a generic closure adds a
    // reference that outlives the page's close. The overview holds the view
    // already, so this capture adds no cycle.
    let create_view = tab_view.clone();
    overview.connect_create_tab(move |_| create_tab(&create_view));

    WorkspaceChrome {
        overview,
        view: tab_view,
    }
}

// Numbered like the tabs `append_editor_tab` makes, so the two ways of
// opening one look the same.
fn overview_editor_tab(
    workspace_tabs: Rc<RefCell<HashMap<Uuid, WorkspaceTab>>>,
    editor_init: impl Fn() -> SqlEditorInit + 'static,
    input: relm4::Sender<AppMsg>,
    toasts: glib::WeakRef<adw::ToastOverlay>,
) -> impl Fn(&adw::TabView) -> adw::TabPage + 'static {
    move |tab_view| {
        let tab_id = Uuid::new_v4();
        let editor = SqlEditor::new(editor_init());
        connect_editor(&editor, tab_id, &input, &toasts);
        let page = tab_view.append(&editor);
        let editor_count = workspace_tabs
            .borrow()
            .values()
            .filter(|t| matches!(t, WorkspaceTab::Editor(_)))
            .count();
        page.set_title(&default_editor_tab_label(editor_count + 1));
        write_workspace_tab_id(&page, tab_id);
        let slot = EditorTabSlot {
            editor,
            page: page.clone(),
            draft: DraftId::new(),
        };
        workspace_tabs.borrow_mut().insert(tab_id, WorkspaceTab::Editor(slot));
        input.emit(AppMsg::WorkspaceTabsChanged);
        page
    }
}

pub(super) fn qualified_browse_tab_label(schemas_count: usize, schema: Option<&str>, table: &str) -> String {
    if schemas_count >= 2
        && let Some(s) = schema
    {
        format!("{s}.{table}")
    } else {
        table.to_string()
    }
}

fn default_editor_tab_label(n: usize) -> String {
    crate::i18n::gettext_f("Query {n}", &[("n", &n.to_string())])
}

/// Returns a tooltip for a Browse tab, but only when it would add info
/// beyond the visible label. When the label is already
/// `schema.table`, or there is no schema, the tooltip would just
/// duplicate the tab title and we skip it.
fn browse_tab_tooltip(schema: Option<&str>, table: &str, label: &str) -> Option<String> {
    let s = schema?;
    let qualified = format!("{s}.{table}");
    if qualified == label { None } else { Some(qualified) }
}

fn describe_closed_tab(slot: &WorkspaceTab) -> Option<ClosedTabDescriptor> {
    match slot {
        WorkspaceTab::Editor(s) => Some(ClosedTabDescriptor::Editor {
            query: whole_text(&s.editor.buffer()),
        }),
        WorkspaceTab::Table(s) => Some(ClosedTabDescriptor::Table {
            schema: s.schema.clone(),
            table: s.table.clone(),
            offset: s.browse.current_offset(),
            page_size: s.browse.page_size(),
            sort: s.browse.current_sort(),
        }),
        WorkspaceTab::Structure(s) => match s.mode {
            // A draft names no table to reopen.
            StructureMode::New => None,
            StructureMode::Edit => Some(ClosedTabDescriptor::Structure {
                schema: s.schema.clone(),
                table: s.table.clone(),
            }),
        },
    }
}

fn push_closed_tab(
    stack: &std::rc::Rc<std::cell::RefCell<std::collections::VecDeque<ClosedTabDescriptor>>>,
    descriptor: ClosedTabDescriptor,
) {
    let mut q = stack.borrow_mut();
    if q.len() == CLOSED_TABS_CAPACITY {
        q.pop_front();
    }
    q.push_back(descriptor);
}

impl App {
    pub(super) fn on_reopen_closed_tab(&mut self, sender: ComponentSender<Self>) {
        if !self.connected {
            return;
        }
        let descriptor = self.closed_tabs_stack.borrow_mut().pop_back();
        let Some(descriptor) = descriptor else {
            // Without a toast the shortcut would read as broken.
            self.show_toast(&crate::i18n::gettext("No recently closed tab"));
            return;
        };
        match descriptor {
            ClosedTabDescriptor::Editor { query } => {
                let initial = if query.is_empty() { None } else { Some(query) };
                self.append_editor_tab(initial, sender);
            }
            ClosedTabDescriptor::Table {
                schema,
                table,
                offset,
                page_size,
                sort,
            } => {
                self.append_table_tab(schema, table, offset, page_size, sort, sender);
            }
            ClosedTabDescriptor::Structure { schema, table } => {
                self.append_existing_structure_tab(schema, table, sender);
            }
        }
    }

    pub(super) fn clear_closed_tabs_stack(&self) {
        self.closed_tabs_stack.borrow_mut().clear();
    }
}

const PREVIEW_CHARS: i32 = 200;

/// The start of an editor's script, read without copying the rest.
struct EditorPreview {
    text: String,
    truncated: bool,
}

impl EditorPreview {
    fn read(buffer: &gtk::TextBuffer) -> Self {
        let end = buffer.iter_at_offset(PREVIEW_CHARS);
        Self {
            text: buffer.text(&buffer.start_iter(), &end, false).to_string(),
            truncated: !end.is_end(),
        }
    }

    fn is_blank(&self) -> bool {
        !self.truncated && self.text.trim().is_empty()
    }
}

/// The start of the script, and none when the label already shows it.
fn editor_tab_tooltip(preview: &EditorPreview, label: &str) -> Option<String> {
    let text = preview.text.trim();
    if text.is_empty() {
        return None;
    }
    let tooltip = match preview.truncated {
        true => format!("{}…", preview.text.trim_start()),
        false => text.to_owned(),
    };
    (tooltip != label).then_some(tooltip)
}

/// The whole script, for the few places that need all of it at once.
fn whole_text(buffer: &gtk::TextBuffer) -> String {
    buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string()
}

/// Whether a new editor tab's draft is written at once or only after
/// the user changes it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DraftWrite {
    Now,
    OnChange,
}

#[derive(Debug)]
pub(crate) struct LoadedWorkspace {
    key: SessionKey,
    load: WorkspaceLoad,
    drafts: RestoredDrafts,
}

fn saved_drafts(record: &WorkspaceRecord) -> impl Iterator<Item = DraftId> + '_ {
    record.tabs.iter().filter_map(|tab| match tab {
        TabRecord::Editor { draft } => Some(*draft),
        _ => None,
    })
}

/// The structure tab's signals, as this window's inputs for the tab.
fn connect_structure(structure: &StructureTab, tab_id: Uuid, input: &relm4::Sender<AppMsg>) {
    let dirty = input.clone();
    structure.connect_dirty_changed(move |_, is_dirty| dirty.emit(AppMsg::StructureTabDirtyChanged(tab_id, is_dirty)));
    let save = input.clone();
    structure.connect_save_requested(move |_| save.emit(AppMsg::SaveActiveStructureTabById(tab_id)));
    let drop_table = input.clone();
    structure.connect_drop_table_requested(move |_, schema, table| {
        drop_table.emit(AppMsg::DropTablePrompt { schema, table });
    });
    let toast = input.clone();
    structure.connect_toast(move |_, text| toast.emit(AppMsg::ShowToast(text)));
    let alert = input.clone();
    structure.connect_alert(move |_, title, body| alert.emit(AppMsg::ShowAlert { title, body }));
}

/// The browse tab's signals, as this window's inputs for the tab.
fn connect_browse(browse: &BrowseTab, tab_id: Uuid, input: &relm4::Sender<AppMsg>) {
    let state = input.clone();
    browse.connect_state_changed(move |_| state.emit(AppMsg::WorkspaceTabsChanged));
    let copy_row = input.clone();
    browse.connect_copy_row_as_insert(move |_, row_position| {
        copy_row.emit(AppMsg::CopyRowAsInsert { tab_id, row_position });
    });
    let clipboard = input.clone();
    browse.connect_copy_to_clipboard(move |_, text| clipboard.emit(AppMsg::CopyToClipboard(text)));
    let export = input.clone();
    browse.connect_export_results(move |_, ExportRequest { result, name, target }| {
        export.emit(AppMsg::ExportResults { result, name, target });
    });
    let alert = input.clone();
    browse.connect_alert(move |_, title, body| alert.emit(AppMsg::ShowAlert { title, body }));
    let toast = input.clone();
    browse.connect_toast(move |_, text| toast.emit(AppMsg::ShowToast(text)));
    let dirty = input.clone();
    browse.connect_dirty_changed(move |_, is_dirty| dirty.emit(AppMsg::BrowseTabDirtyChanged(tab_id, is_dirty)));
    let save = input.clone();
    browse.connect_save_requested(
        move |_,
              SaveRequest {
                  table,
                  columns,
                  changes,
              }| {
            save.emit(AppMsg::ExecuteBrowseTransaction {
                tab_id,
                table,
                columns,
                changes,
            });
        },
    );
}

/// Forward an editor tab's signals into the window. The toast overlay
/// is the window's, so a replaced query's Undo button lives there.
fn connect_editor(
    editor: &SqlEditor,
    tab_id: Uuid,
    input: &relm4::Sender<AppMsg>,
    toasts: &glib::WeakRef<adw::ToastOverlay>,
) {
    let run_state = input.clone();
    editor.connect_run_state_changed(move |_, running| {
        run_state.emit(AppMsg::EditorTabRunStateChanged(tab_id, running));
    });
    let content = input.clone();
    editor.connect_content_changed(move |_| content.emit(AppMsg::EditorTabContentChanged(tab_id)));
    let clipboard = input.clone();
    editor.connect_copy_to_clipboard(move |_, text| clipboard.emit(AppMsg::CopyToClipboard(text)));
    let toast = input.clone();
    editor.connect_toast(move |_, text| toast.emit(AppMsg::ShowToast(text)));
    let export = input.clone();
    editor.connect_export_results(move |_, result, name| {
        export.emit(AppMsg::ExportResults {
            result,
            name,
            target: None,
        });
    });
    // The overlay is an ancestor of the editor, so a strong capture
    // would keep both alive once the window lets go of them.
    let toasts = toasts.clone();
    editor.connect_undoable_toast(move |editor, title| {
        let Some(toasts) = toasts.upgrade() else {
            return;
        };
        let toast = adw::Toast::new(&title);
        toast.set_button_label(Some(&crate::i18n::gettext("Undo")));
        let editor = editor.downgrade();
        toast.connect_button_clicked(move |_| {
            if let Some(editor) = editor.upgrade() {
                editor.undo();
            }
        });
        toasts.add_toast(toast);
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{drain_main_context, find_by_action_name};

    fn blank_page(view: &adw::TabView) -> adw::TabPage {
        view.append(&gtk::Label::new(None))
    }

    fn overview_new_tab_button(overview: &adw::TabOverview) -> gtk::Button {
        crate::test_support::descendants(overview)
            .into_iter()
            .find_map(|widget| {
                let button = widget.downcast::<gtk::Button>().ok()?;
                let content = button.child()?.downcast::<adw::ButtonContent>().ok()?;
                (content.icon_name() == "adw-tab-new-symbolic").then_some(button)
            })
            .expect("the overview's new-tab button")
    }

    fn editor_chrome(
        runtime: &crate::runtime::AppRuntime,
        settings: &crate::test_support::MemorySettings,
        tabs: &Rc<RefCell<HashMap<Uuid, WorkspaceTab>>>,
        toasts: &adw::ToastOverlay,
        input: &relm4::Sender<AppMsg>,
    ) -> WorkspaceChrome {
        adw::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        let settings = settings.get().clone();
        let tasks = runtime.tasks();
        let editor_init = move || SqlEditorInit {
            initial_query: None,
            settings: settings.clone(),
            history: None,
            tasks: tasks.clone(),
            session: crate::services::active_session::ActiveSession::new(),
            hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
            close_timeout: std::time::Duration::from_secs(5),
        };
        let create_tab = overview_editor_tab(tabs.clone(), editor_init, input.clone(), toasts.downgrade());
        build_workspace_chrome(input, create_tab)
    }

    #[gtk4::test]
    fn a_closed_tab_from_the_overview_is_freed() {
        let runtime = crate::test_support::test_runtime();
        let settings = crate::test_support::MemorySettings::new();
        let tabs = Rc::new(RefCell::new(HashMap::new()));
        let toasts = adw::ToastOverlay::new();
        let (input, _receiver) = relm4::channel::<AppMsg>();
        let chrome = editor_chrome(&runtime, &settings, &tabs, &toasts, &input);
        toasts.set_child(Some(&chrome.overview));

        overview_new_tab_button(&chrome.overview).emit_clicked();
        let page = chrome.view.selected_page().expect("the new-tab button made a page");
        let id = read_workspace_tab_id(&page).expect("the page names its tab");
        assert!(tabs.borrow().contains_key(&id), "the window does not know the new tab");
        let editor = page.child().downgrade();
        let freed_page = page.downgrade();

        // What the window does once the tab may close.
        chrome.view.close_page(&page);
        let removed = tabs.borrow_mut().remove(&id);
        if let Some(WorkspaceTab::Editor(slot)) = &removed {
            slot.editor.shutdown();
        }
        chrome.view.close_page_finish(&page, true);
        drop((removed, page));
        drain_main_context();

        assert!(freed_page.upgrade().is_none(), "the closed page is still alive");
        assert!(editor.upgrade().is_none(), "the closed page's editor is still alive");
    }

    #[gtk4::test]
    fn tab_view_freed_after_teardown() {
        let runtime = crate::test_support::test_runtime();
        let settings = crate::test_support::MemorySettings::new();
        let tabs = Rc::new(RefCell::new(HashMap::new()));
        let toasts = adw::ToastOverlay::new();
        let (input, _receiver) = relm4::channel::<AppMsg>();
        let chrome = editor_chrome(&runtime, &settings, &tabs, &toasts, &input);
        let stack = gtk::Stack::new();
        stack.add_named(&chrome.overview, Some("tabs"));
        toasts.set_child(Some(&stack));
        overview_new_tab_button(&chrome.overview).emit_clicked();
        overview_new_tab_button(&chrome.overview).emit_clicked();
        assert_eq!(chrome.view.n_pages(), 2);
        let selected = chrome.view.selected_page().expect("a selected page");
        let editor = selected.child().downgrade();
        let page = selected.downgrade();
        drop(selected);
        let view = chrome.view.downgrade();
        let overview = chrome.overview.downgrade();

        // What the window does on disconnect.
        for tab in tabs.borrow().values() {
            if let WorkspaceTab::Editor(slot) = tab {
                slot.editor.shutdown();
            }
        }
        stack.remove(&chrome.overview);
        drop(chrome);
        tabs.borrow_mut().clear();
        drain_main_context();

        assert!(view.upgrade().is_none(), "the tab view outlived its teardown");
        assert!(overview.upgrade().is_none(), "the overview outlived its teardown");
        assert!(page.upgrade().is_none(), "a page outlived its teardown");
        assert!(editor.upgrade().is_none(), "an editor outlived its teardown");
    }

    #[gtk4::test]
    fn overview_button_shows_from_the_second_tab() {
        adw::init().expect("libadwaita initialises under the test backend");
        let (input, _receiver) = relm4::channel::<AppMsg>();
        let chrome = build_workspace_chrome(&input, blank_page);
        let button = find_by_action_name(&chrome.overview, "overview.open").expect("the overview button");
        assert!(!button.is_visible(), "shown with no tabs");

        let first = blank_page(&chrome.view);
        assert!(!button.is_visible(), "shown with one tab");
        blank_page(&chrome.view);
        assert!(button.is_visible(), "hidden with two tabs");

        chrome.view.close_page(&first);
        chrome.view.close_page_finish(&first, true);
        assert!(!button.is_visible(), "still shown after closing back to one tab");
    }

    #[gtk4::test]
    fn an_editor_tab_is_named_from_the_start_of_its_script_only() {
        let buffer = gtk::TextBuffer::new(None);
        buffer.set_text(&format!("SELECT 1;\n{}", "-- é\n".repeat(10_000)));

        let preview = EditorPreview::read(&buffer);

        let limit = usize::try_from(PREVIEW_CHARS).expect("a positive limit");
        assert_eq!(preview.text.chars().count(), limit);
        assert!(preview.truncated);
        let tooltip = editor_tab_tooltip(&preview, "SELECT 1;").expect("a tooltip");
        assert!(tooltip.starts_with("SELECT 1;"), "{tooltip}");
        assert!(tooltip.ends_with('…'), "{tooltip}");
    }

    #[gtk4::test]
    fn a_script_its_label_shows_whole_has_no_tooltip() {
        let buffer = gtk::TextBuffer::new(None);
        buffer.set_text("SELECT 1;");

        let preview = EditorPreview::read(&buffer);

        assert!(!preview.truncated);
        assert_eq!(editor_tab_tooltip(&preview, &derive_tab_label(&preview.text)), None);
    }

    #[gtk4::test]
    fn an_editor_tab_leaves_the_toast_overlay_free() {
        crate::register_test_resources();
        let runtime = crate::test_support::test_runtime();
        let settings = crate::test_support::MemorySettings::new();
        let editor = SqlEditor::new(SqlEditorInit {
            initial_query: None,
            settings: settings.get().clone(),
            history: None,
            tasks: runtime.tasks(),
            session: crate::services::active_session::ActiveSession::new(),
            hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
            close_timeout: std::time::Duration::from_secs(5),
        });
        let toasts = adw::ToastOverlay::new();
        toasts.set_child(Some(&editor));
        let (input, _receiver) = relm4::channel::<AppMsg>();
        connect_editor(&editor, Uuid::new_v4(), &input, &toasts.downgrade());
        let overlay = toasts.downgrade();

        drop(editor);
        drop(toasts);
        drain_main_context();

        assert!(
            overlay.upgrade().is_none(),
            "an editor tab kept the window's toast overlay alive"
        );
    }
}
