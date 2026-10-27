use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use libadwaita as adw;
use libadwaita::prelude::*;

use tablepro_core::meta::TableRef;
use tablepro_session::SessionKey;
use tablepro_storage::{DraftId, DraftScope};
use uuid::Uuid;

use crate::ui::browse_tab::{BrowseTabInput, PagingInput, SaveInput, TableFilter};
use crate::ui::structure_tab::StructureMode;
use crate::workspace::{
    EditorFileRecord, RestoredDrafts, TabRecord, WorkspaceFileName, WorkspaceLoad, WorkspaceRecord, WorkspaceSaveError,
};

use super::editor_label::EditorLabel;
use super::structure_target::StructureTarget;
use super::tab_factory::EditorPreview;
use super::tab_index::TabIndex;
use super::tab_spec::{TabSpec, TablePage};
use super::workspace_persistence::reopen;
use super::{
    CLOSED_TABS_CAPACITY, ClosedTabDescriptor, OpenMode, WorkspaceInput, WorkspaceModel, WorkspaceSender, WorkspaceTab,
};
use crate::runtime::DeliverInput;

impl WorkspaceModel {
    /// Read the saved tabs of the session just adopted, and the editor
    /// text that goes with them, off the GTK thread.
    pub(super) fn restore_workspace_tabs(&mut self, key: SessionKey) {
        let input = self.input.clone();
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
            input.deliver(WorkspaceInput::WorkspaceLoaded(LoadedWorkspace { key, load, drafts }));
        });
    }

    /// Rebuild the saved tabs, then start writing the tab list.
    ///
    /// Nothing is written for the session before this: a write would
    /// replace the saved tabs before they were read.
    pub(super) fn on_workspace_loaded(&mut self, loaded: LoadedWorkspace) {
        let LoadedWorkspace { key, load, drafts } = loaded;
        let RestoredDrafts { mut texts, unreadable } = drafts;
        match load {
            WorkspaceLoad::Restored(record) => {
                self.retain_drafts(&key, saved_drafts(&record));
                let view = self.tab_view.clone();
                reopen(&view, record, |tab| self.reopen_tab(tab, &mut texts));
            }
            WorkspaceLoad::Empty => self.retain_drafts(&key, std::iter::empty()),
            // Which drafts the file names is unknown, so none is deleted.
            WorkspaceLoad::Blocked(_) => self.layout_banner.set_revealed(true),
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
        self.workspace
            .attach(key, &self.tab_view, self.workspace_tabs.clone(), self.index.clone());
        self.persist_workspace_state();
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

    fn reopen_tab(&mut self, tab: TabRecord, drafts: &mut HashMap<DraftId, String>) -> Option<adw::TabPage> {
        let spec = match tab {
            TabRecord::Table {
                schema,
                table,
                offset,
                page_size,
                sort,
                filter,
            } => TabSpec::Table {
                table: TableRef::new(schema, table),
                page: TablePage {
                    offset,
                    page_size,
                    sort: sort.map(|sort| (sort.column, sort.ascending)),
                },
                filter: filter.map_or(TableFilter::Remembered, TableFilter::Kept),
            },
            TabRecord::Structure { schema, table } => TabSpec::Structure {
                target: StructureTarget::Existing(TableRef::new(schema, table)),
            },
            TabRecord::Diagram { schema, places } => TabSpec::Diagram { schema, places },
            // Its text is on disk already, or there is none to keep, so
            // nothing is written until the user types.
            TabRecord::Editor { draft, file } => TabSpec::Editor {
                initial_query: Some(drafts.remove(&draft).unwrap_or_default()),
                draft: Some(draft),
                file,
            },
            TabRecord::Key { key } => TabSpec::Key { key },
        };
        // Selecting each tab as it opens would show, and so load, every
        // one of them; `reopen` selects the one that was active.
        self.factory.restore(spec)
    }

    /// Move the unreadable saved tabs aside, so the open ones can be
    /// saved in their place.
    pub(super) fn on_reset_workspace_layout(&self) {
        let resetting = self.storage.workspaces().reset(&self.key);
        let input = self.input.clone();
        glib::spawn_future_local(async move {
            let outcome = resetting.await;
            input.deliver(WorkspaceInput::WorkspaceLayoutReset(outcome));
        });
    }

    pub(super) fn on_workspace_layout_reset(&self, outcome: Result<Option<std::path::PathBuf>, WorkspaceSaveError>) {
        match outcome {
            Ok(moved) => {
                if let Some(moved) = moved {
                    tracing::info!(moved = %moved.display(), "moved the unreadable saved tabs aside");
                }
                self.layout_banner.set_revealed(false);
                self.persist_workspace_state();
            }
            // The banner stays, so Reset can be tried again.
            Err(error) => {
                tracing::warn!(%error, "could not move the saved tabs aside");
                self.show_error_alert(
                    &crate::i18n::gettext("Could Not Reset Saved Tabs"),
                    &crate::i18n::gettext(
                        "The unreadable file could not be moved aside, so the open tabs are still not saved.",
                    ),
                );
            }
        }
    }

    /// Build the tab `spec` names and select it.
    pub(super) fn open_tab(&mut self, spec: TabSpec) -> Option<adw::TabPage> {
        let page = self.factory.create(spec)?;
        self.tab_view.set_selected_page(&page);
        Some(page)
    }

    pub(super) fn open_editor_tab(&mut self, initial_query: Option<String>) {
        self.open_editor(TabSpec::Editor {
            initial_query,
            draft: None,
            file: None,
        });
    }

    // AdwTabView moves the focus to the page it selects only from the page
    // that held it, so an editor opened from the sidebar, a header button
    // or a key pressed there would leave the typing where it was.
    fn open_editor(&mut self, spec: TabSpec) {
        if self.open_tab(spec).is_none() {
            return;
        }
        if let Some(id) = self.selected_workspace_tab_id()
            && let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow().get(&id)
        {
            slot.editor.focus_text();
        }
    }

    /// The directory this session's editor drafts live in.
    fn draft_scope(&self) -> DraftScope {
        WorkspaceFileName::for_key(&self.key).draft_scope()
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
            }
            WorkspaceTab::Table(slot) => {
                slot.browse.shutdown();
                self.change_trackers.unregister(slot.id);
            }
            WorkspaceTab::Diagram(slot) => slot.diagram.shutdown(),
            WorkspaceTab::Key(slot) => slot.tab.shutdown(),
        }
        let page = removed.page().clone();
        self.index.remove(&page);
        self.move_focus_off(&page);
        tab_view.close_page_finish(&page, true);
        drop(removed);
        self.persist_workspace_state();
        self.refresh_window_title();
        self.refresh_unsaved();
        self.refresh_transaction_banner();
        self.report_tabs_changed();
    }

    /// The view's close-page handler takes it from there, as for the
    /// tab's close button. A tab already gone has nothing to close.
    pub(super) fn close_workspace_tab(&mut self, id: Uuid) {
        let page = self.workspace_tabs.borrow().get(&id).map(|tab| tab.page().clone());
        if let Some(page) = page {
            self.tab_view.close_page(&page);
        }
    }

    /// With no tab open, Ctrl+W closes the window, as in GNOME Text
    /// Editor.
    pub(super) fn close_active_workspace_tab(&mut self) {
        match self.tab_view.selected_page() {
            Some(page) => {
                self.tab_view.close_page(&page);
            }
            // The window's close asks this workspace what it would
            // lose, which it cannot answer in the middle of handling
            // this, so the close waits for the main loop.
            None => {
                if let Some(window) = self.window() {
                    glib::idle_add_local_once(move || window.close());
                }
            }
        }
    }

    /// Close every workspace tab except `keep_id`. Each close goes
    /// through the per-tab close path so dirty browse tabs still
    /// trigger the unsaved-changes alert; the user can cancel the
    /// dialog and the tab stays open while the others continue
    /// closing in the background.
    pub(super) fn close_other_workspace_tabs(&mut self, keep_id: Uuid) {
        let tab_view = self.tab_view.clone();
        let pages = tab_view.pages();
        let mut targets: Vec<adw::TabPage> = Vec::with_capacity(pages.n_items() as usize);
        for i in 0..pages.n_items() {
            let Some(page) = pages.item(i).and_downcast::<adw::TabPage>() else {
                continue;
            };
            // Another session's tab, which this close leaves alone.
            if self.index.id_of(&page).is_none_or(|id| id == keep_id) {
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
    pub(super) fn close_workspace_tabs_to_right(&mut self, anchor_id: Uuid) {
        let tab_view = self.tab_view.clone();
        let pages = tab_view.pages();
        let mut anchor_idx: Option<u32> = None;
        for i in 0..pages.n_items() {
            let Some(page) = pages.item(i).and_downcast::<adw::TabPage>() else {
                continue;
            };
            if self.index.id_of(&page) == Some(anchor_id) {
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
            if self.index.id_of(&page).is_none() {
                continue;
            }
            targets.push(page);
        }
        for page in targets {
            tab_view.close_page(&page);
        }
    }

    /// A sidebar click never replaces the active tab: AdwTabView's
    /// close animation overlapped the append and flashed both tabs.
    pub(super) fn dispatch_select_table(&mut self, schema: Option<String>, name: String, open_mode: OpenMode) {
        if self.keys.is_some() {
            self.open_key(name, open_mode);
            return;
        }
        if matches!(open_mode, OpenMode::SwitchOrAppend) {
            // Multiple tabs may be open for the same (schema, table)
            // pair (Ctrl+click duplicates). Prefer the currently-
            // selected tab when it matches, then any other match.
            let existing = {
                let tabs = self.workspace_tabs.borrow();
                let selected_page = self.tab_view.selected_page();
                let matches_slot = |t: &WorkspaceTab| match t {
                    WorkspaceTab::Table(s) if s.schema.as_deref() == schema.as_deref() && s.table == name => {
                        Some(s.page.clone())
                    }
                    _ => None,
                };
                let selected_match = selected_page.and_then(|sp| {
                    let id = self.index.id_of(&sp)?;
                    matches_slot(tabs.get(&id)?)
                });
                selected_match.or_else(|| tabs.values().find_map(matches_slot))
            };
            if let Some(page) = existing {
                self.tab_view.set_selected_page(&page);
                return;
            }
        }
        // Default open path appends a Data-view Browse tab. Structure
        // for the same table opens as its own separate tab via the
        // sidebar right-click "Edit Structure" action.
        let page_size = u64::from(self.settings.default_page_size());
        self.open_tab(TabSpec::Table {
            table: TableRef::new(schema, name),
            page: TablePage::first(page_size),
            filter: TableFilter::Remembered,
        });
    }

    /// A key opens in its tab, the one in front first; a new tab only
    /// when asked for one.
    fn open_key(&mut self, key: String, open_mode: OpenMode) {
        if matches!(open_mode, OpenMode::SwitchOrAppend) {
            let existing = {
                let tabs = self.workspace_tabs.borrow();
                let shows_key = |tab: &WorkspaceTab| match tab {
                    WorkspaceTab::Key(slot) if slot.tab.key() == key => Some(slot.page.clone()),
                    _ => None,
                };
                let selected = self
                    .selected_workspace_tab_id()
                    .and_then(|id| shows_key(tabs.get(&id)?));
                selected.or_else(|| tabs.values().find_map(shows_key))
            };
            if let Some(page) = existing {
                self.tab_view.set_selected_page(&page);
                return;
            }
        }
        self.open_tab(TabSpec::Key { key });
    }

    pub(super) fn on_refresh_active_tab(&self) {
        let Some(id) = self.selected_workspace_tab_id() else {
            return;
        };
        let key = match self.workspace_tabs.borrow().get(&id) {
            Some(WorkspaceTab::Key(slot)) => Some(slot.tab.clone()),
            _ => None,
        };
        match key {
            Some(tab) => tab.refresh(),
            None => {
                if let Some(id) = self.selected_browse_tab_id() {
                    self.on_refresh_tab(id);
                }
            }
        }
    }

    pub(super) fn on_refresh_tab(&self, id: Uuid) {
        let dirty = self
            .change_trackers
            .get(id)
            .is_some_and(|tracker| tracker.pending_count() > 0);
        if !dirty {
            self.dispatch_to_tab(id, PagingInput::Refresh);
            return;
        }
        // A refetch replaces the rows and with them every pending edit,
        // so F5 mid-edit asks first, as closing a dirty tab does.
        let dialog = adw::AlertDialog::new(
            Some(&crate::i18n::gettext("Discard Pending Changes?")),
            Some(&crate::i18n::gettext(
                "Refreshing reloads the table from the database and drops every unsaved edit on this tab.",
            )),
        );
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("discard", &crate::i18n::gettext("Discard and Refresh"));
        dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let workspace_tabs = self.workspace_tabs.clone();
        dialog.connect_response(None, move |_, response| {
            if response != "discard" {
                return;
            }
            let browse = workspace_tabs
                .borrow()
                .get(&id)
                .and_then(|tab| tab.browse_tab())
                .cloned();
            if let Some(browse) = browse {
                browse.send(SaveInput::DiscardAndRefresh);
            }
        });
        dialog.present(self.window().as_ref());
    }

    /// Write the tab list a moment after the last change.
    pub(super) fn persist_workspace_state(&self) {
        self.workspace.request();
    }
}

impl WorkspaceModel {
    /// Single handler for `WorkspaceTabsChanged`. Persists tab state,
    /// refreshes the window title (so tab switches update the subtitle),
    /// and syncs the sidebar selection to the active Browse tab's table.
    pub(super) fn on_workspace_tabs_changed(&self) {
        self.persist_workspace_state();
        self.refresh_window_title();
        self.refresh_transaction_banner();
        self.sync_sidebar_selection();
        self.report_tabs_changed();
    }

    pub(super) fn selected_workspace_tab_id(&self) -> Option<Uuid> {
        self.index.id_of(&self.tab_view.selected_page()?)
    }

    pub(super) fn selected_browse_tab_id(&self) -> Option<Uuid> {
        let id = self.selected_workspace_tab_id()?;
        let tabs = self.workspace_tabs.borrow();
        let slot = tabs.get(&id)?;
        if slot.browse_tab().is_some() { Some(id) } else { None }
    }

    /// Stop every tab and let go of the tab view. The pending edits
    /// name rows of the connection going away, so they cannot be saved
    /// after it.
    pub(super) fn close_tabs(&mut self) {
        for tab in self.workspace_tabs.borrow().values() {
            match tab {
                WorkspaceTab::Editor(slot) => slot.editor.shutdown(),
                WorkspaceTab::Structure(slot) => {
                    slot.structure.shutdown();
                    self.structure_trackers.unregister(slot.id);
                }
                WorkspaceTab::Table(slot) => {
                    slot.browse.shutdown();
                    self.change_trackers.unregister(slot.id);
                }
                WorkspaceTab::Diagram(slot) => slot.diagram.shutdown(),
                WorkspaceTab::Key(slot) => slot.tab.shutdown(),
            }
        }
        self.index.clear();
        self.workspace_tabs.borrow_mut().clear();
    }

    /// Forward a per-tab Browse input to the right slot. Routes to the
    /// Browse-side controller in both legacy `Browse` slots and the
    /// unified `Table` slot.
    pub(super) fn dispatch_to_tab(&self, tab_id: Uuid, msg: impl Into<BrowseTabInput>) {
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
        {
            let mut tabs = self.workspace_tabs.borrow_mut();
            let Some(WorkspaceTab::Editor(slot)) = tabs.get_mut(&id) else {
                return;
            };
            let buffer = slot.editor.buffer();
            if slot.editor.file().is_none() {
                slot.label = EditorPreview::read(&buffer).label(slot.ordinal);
            }
            self.drafts.schedule(&self.draft_scope(), slot.draft, &buffer);
        }
        self.retitle_tab(id);
    }

    /// A tab saved to a file is named after it, shows whether its text
    /// is saved, and is restored with it.
    pub(super) fn on_editor_tab_file_changed(&self, id: Uuid) {
        {
            let mut tabs = self.workspace_tabs.borrow_mut();
            let Some(WorkspaceTab::Editor(slot)) = tabs.get_mut(&id) else {
                return;
            };
            if let Some(file) = slot.editor.file() {
                slot.label = EditorLabel::file(&file);
            }
        }
        self.retitle_tab(id);
        self.refresh_unsaved();
        self.persist_workspace_state();
    }

    pub(super) fn on_editor_tab_run_state_changed(&self, id: Uuid, running: bool) {
        if let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow().get(&id) {
            slot.page.set_loading(running);
        }
    }

    pub(super) fn on_replace_active_tab_query(&mut self, text: String) {
        if let Some(id) = self.selected_workspace_tab_id()
            && let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow().get(&id)
        {
            slot.editor.replace_query(&text);
            return;
        }
        self.open_editor_tab(Some(text));
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
}

/// The tab view's own signals, as the workspace's inputs. The view is
/// the shell's, which every session of the window shares, so a session
/// closes only its own pages and leaves the others to theirs.
pub(super) fn connect_tab_view(tab_view: &adw::TabView, index: &Rc<TabIndex>, input: &WorkspaceSender) -> TabViewWatch {
    let leaving: Rc<RefCell<Vec<adw::TabPage>>> = Rc::default();
    // A tab with unsaved work asks first, so the workspace finishes the
    // close. A page of a session going away asked with the session.
    let close_input = input.clone();
    let close_index = index.clone();
    let close_leaving = leaving.clone();
    let close = tab_view.connect_close_page(move |view, page| {
        if close_leaving.borrow().contains(page) {
            view.close_page_finish(page, true);
            return glib::Propagation::Stop;
        }
        match close_index.id_of(page) {
            Some(id) => {
                close_input.deliver(WorkspaceInput::WorkspaceTabClosed(id));
                glib::Propagation::Stop
            }
            None => glib::Propagation::Proceed,
        }
    });

    // Every session hears the shared view, and only one whose tab came
    // or left the front, or whose tabs moved, has anything to do.
    let selected_input = input.clone();
    let selected_index = index.clone();
    let was_selected = Cell::new(false);
    let selected = tab_view.connect_selected_page_notify(move |view| {
        let page = view.selected_page();
        let ours = page.as_ref().is_some_and(|page| selected_index.id_of(page).is_some());
        selected_index.note_selected(page.as_ref());
        if ours || was_selected.replace(ours) {
            selected_input.deliver(WorkspaceInput::WorkspaceTabsChanged);
        }
    });
    // A drag reorder changes only `pages`, and it has to persist too.
    let pages_input = input.clone();
    let pages_index = index.clone();
    let order: RefCell<Vec<Uuid>> = RefCell::default();
    let pages = tab_view.connect_pages_notify(move |view| {
        let now = pages_index.order_in(view);
        if *order.borrow() != now {
            order.replace(now);
            pages_input.deliver(WorkspaceInput::WorkspaceTabsChanged);
        }
    });
    TabViewWatch {
        view: tab_view.downgrade(),
        handlers: vec![close, selected, pages],
        leaving,
    }
}

/// What a session hooked on the shared tab view, which outlives it.
pub(super) struct TabViewWatch {
    view: glib::WeakRef<adw::TabView>,
    handlers: Vec<glib::SignalHandlerId>,
    leaving: Rc<RefCell<Vec<adw::TabPage>>>,
}

impl TabViewWatch {
    /// Stop hearing the view, closing `pages` first when the window
    /// keeps its other sessions. The session's prompts asked about them
    /// already, so they close without asking again and without going on
    /// the closed-tab list, which would discard the drafts its reopen
    /// restores.
    pub(super) fn release(self, pages: Vec<adw::TabPage>) {
        let Some(view) = self.view.upgrade() else {
            return;
        };
        let mut handlers = self.handlers.into_iter();
        let close = handlers.next();
        // Its own selection handlers would persist a session going away.
        for handler in handlers {
            view.disconnect(handler);
        }
        self.leaving.replace(pages.clone());
        for page in &pages {
            view.close_page(page);
        }
        // A page whose own close prompt is still open was closing
        // already, and `close_page` passes it by.
        for page in &pages {
            if view.page_position(page) >= 0 {
                view.close_page_finish(page, true);
            }
        }
        self.leaving.replace(Vec::new());
        if let Some(close) = close {
            view.disconnect(close);
        }
    }
}

fn describe_closed_tab(slot: &WorkspaceTab) -> Option<ClosedTabDescriptor> {
    match slot {
        WorkspaceTab::Editor(s) => Some(ClosedTabDescriptor::Editor {
            query: whole_text(&s.editor.buffer()),
            file: editor_file_record(&s.editor),
        }),
        WorkspaceTab::Table(s) => Some(ClosedTabDescriptor::Table {
            schema: s.schema.clone(),
            table: s.table.clone(),
            offset: s.browse.current_offset(),
            page_size: s.browse.page_size(),
            sort: s.browse.current_sort(),
            filter: s.browse.applied_filter(),
        }),
        WorkspaceTab::Structure(s) => match s.mode {
            // A draft names no table to reopen.
            StructureMode::New => None,
            StructureMode::Edit => Some(ClosedTabDescriptor::Structure {
                schema: s.schema.clone(),
                table: s.table.clone(),
            }),
        },
        WorkspaceTab::Diagram(s) => Some(ClosedTabDescriptor::Diagram {
            schema: s.schema.clone(),
            places: s.diagram.places(),
        }),
        WorkspaceTab::Key(s) => Some(ClosedTabDescriptor::Key {
            key: s.tab.key().to_owned(),
        }),
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

impl WorkspaceModel {
    pub(super) fn on_reopen_closed_tab(&mut self) {
        let descriptor = self.closed_tabs_stack.borrow_mut().pop_back();
        let Some(descriptor) = descriptor else {
            // Without a toast the shortcut would read as broken.
            self.show_toast(&crate::i18n::gettext("No recently closed tab"));
            return;
        };
        match descriptor {
            ClosedTabDescriptor::Editor { query, file } => {
                let initial = if query.is_empty() { None } else { Some(query) };
                self.open_editor(TabSpec::Editor {
                    initial_query: initial,
                    draft: None,
                    file,
                });
            }
            ClosedTabDescriptor::Table {
                schema,
                table,
                offset,
                page_size,
                sort,
                filter,
            } => {
                self.open_tab(TabSpec::Table {
                    table: TableRef::new(schema, table),
                    page: TablePage {
                        offset,
                        page_size,
                        sort,
                    },
                    filter: TableFilter::Kept(filter),
                });
            }
            ClosedTabDescriptor::Structure { schema, table } => {
                self.open_tab(TabSpec::Structure {
                    target: StructureTarget::Existing(TableRef::new(schema, table)),
                });
            }
            ClosedTabDescriptor::Diagram { schema, places } => self.show_diagram(schema, places),
            ClosedTabDescriptor::Key { key } => {
                self.open_tab(TabSpec::Key { key });
            }
        }
    }
}

/// The file an editor tab is saved to, as its record keeps it.
pub(super) fn editor_file_record(editor: &crate::ui::editor::SqlEditor) -> Option<EditorFileRecord> {
    editor.file().map(|file| EditorFileRecord {
        uri: file.uri().to_string(),
        modified: editor.has_unsaved_file_changes(),
    })
}

/// The whole script, for the few places that need all of it at once.
fn whole_text(buffer: &gtk::TextBuffer) -> String {
    buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string()
}

#[derive(Debug)]
pub(crate) struct LoadedWorkspace {
    key: SessionKey,
    load: WorkspaceLoad,
    drafts: RestoredDrafts,
}

fn saved_drafts(record: &WorkspaceRecord) -> impl Iterator<Item = DraftId> + '_ {
    record.tabs.iter().filter_map(|tab| match tab {
        TabRecord::Editor { draft, .. } => Some(*draft),
        _ => None,
    })
}

#[cfg(test)]
mod tests {
    use gtk4::subclass::prelude::*;

    use super::*;
    use crate::test_support::{descendants, drain_main_context, wait_until};
    use crate::ui::SessionWindowInput;
    use crate::ui::session_window::tests::{TestWindow, WAIT, editors};

    fn overview_new_tab_button(overview: &adw::TabOverview) -> gtk::Button {
        descendants(overview)
            .into_iter()
            .find_map(|widget| {
                let button = widget.downcast::<gtk::Button>().ok()?;
                let content = button.child()?.downcast::<adw::ButtonContent>().ok()?;
                (content.icon_name() == "adw-tab-new-symbolic").then_some(button)
            })
            .expect("the overview's new-tab button")
    }

    #[gtk4::test]
    fn a_closed_tab_from_the_overview_is_freed() {
        let test = TestWindow::connected("OverviewTabFreed");
        let workspace = test.workspace();
        let (view, overview) = (
            workspace.chrome().imp().tab_view.get(),
            workspace.chrome().imp().tab_overview.get(),
        );

        overview_new_tab_button(&overview).emit_clicked();
        let page = view.selected_page().expect("the new-tab button made a page");
        let known = workspace
            .read(|model| {
                model
                    .index
                    .id_of(&page)
                    .is_some_and(|id| model.workspace_tabs.borrow().contains_key(&id))
            })
            .unwrap_or_default();
        assert!(known, "the workspace does not know the new tab");
        let editor = page.child().downgrade();
        let freed_page = page.downgrade();

        view.close_page(&page);
        drop(page);
        wait_until(WAIT, || freed_page.upgrade().is_none()).expect("the closed page to be freed");

        assert!(editor.upgrade().is_none(), "the closed page's editor is still alive");
    }

    #[gtk4::test]
    fn unreadable_saved_tabs_are_announced_until_reset() {
        let test = TestWindow::picker("UnreadableSavedTabs");
        let dir = test.services.storage.paths().workspaces_dir();
        std::fs::create_dir_all(&dir).expect("the workspaces folder");
        std::fs::write(
            dir.join(crate::workspace::WorkspaceFileName::for_key(&test.key()).file_name()),
            b"{ not json",
        )
        .expect("an unreadable file");

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("workspace");
        let banner = test.workspace().imp().layout_banner.get();
        wait_until(WAIT, || banner.is_revealed()).expect("the banner says the tabs are not saved");
        assert_eq!(banner.action_name().as_deref(), Some("win.reset-workspace-layout"));

        WidgetExt::activate_action(&test.window, "win.reset-workspace-layout", None).expect("Reset");

        wait_until(WAIT, || !banner.is_revealed()).expect("the banner goes once the file is moved aside");
    }

    #[gtk4::test]
    fn a_new_editor_tab_takes_the_focus_from_outside_the_tabs() {
        let test = TestWindow::connected("NewEditorFocus");
        let button = test.workspace().chrome().imp().new_tab_button.get();
        button.grab_focus();
        assert!(button.is_focus(), "the header button holds the focus");

        button.emit_clicked();

        wait_until(WAIT, || editors(&test.window).len() == 1).expect("an editor tab");
        let text = crate::test_support::first_descendant_of_type::<sourceview5::View>(&editors(&test.window)[0])
            .expect("the editor's text");
        wait_until(WAIT, || text.is_focus()).expect("the new editor's text takes the focus");
    }

    #[gtk4::test]
    fn a_reopened_editor_tab_takes_the_focus() {
        let test = TestWindow::connected("ReopenedEditorFocus");
        WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");
        wait_until(WAIT, || editors(&test.window).len() == 1).expect("an editor tab");
        WidgetExt::activate_action(&test.window, "win.close-current", None).expect("win.close-current");
        wait_until(WAIT, || editors(&test.window).is_empty()).expect("the tab closes");
        let button = test.workspace().chrome().imp().new_tab_button.get();
        button.grab_focus();

        WidgetExt::activate_action(&test.window, "win.reopen-closed-tab", None).expect("win.reopen-closed-tab");

        wait_until(WAIT, || editors(&test.window).len() == 1).expect("the tab comes back");
        let text = crate::test_support::first_descendant_of_type::<sourceview5::View>(&editors(&test.window)[0])
            .expect("the editor's text");
        wait_until(WAIT, || text.is_focus()).expect("the reopened editor's text takes the focus");
    }

    #[gtk4::test]
    fn tab_view_freed_after_teardown() {
        let test = TestWindow::connected("TabViewFreed");
        for _ in 0..2 {
            WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");
        }
        wait_until(WAIT, || editors(&test.window).len() == 2).expect("two editor tabs");
        let workspace = test.workspace();
        let view = workspace.chrome().imp().tab_view.downgrade();
        let overview = workspace.chrome().imp().tab_overview.downgrade();
        let pages: Vec<_> = editors(&test.window).iter().map(|editor| editor.downgrade()).collect();
        drop(workspace);

        test.window.send(SessionWindowInput::Disconnect);
        test.wait_for_page("picker");
        drain_main_context();

        assert!(view.upgrade().is_none(), "the tab view outlived its teardown");
        assert!(overview.upgrade().is_none(), "the overview outlived its teardown");
        assert!(
            pages.iter().all(|editor| editor.upgrade().is_none()),
            "an editor outlived its teardown"
        );
    }

    /// A restored session reads only the tab in front; each other tab
    /// reads its table the first time it is shown, so they do not all
    /// wait on the pool at once.
    #[gtk4::test]
    fn restored_tabs_read_their_tables_when_first_shown() {
        let test = TestWindow::with_script(
            "RestoreReadsWhenShown",
            crate::ui::session_window::tests::Script {
                connection: super::super::shell::tests::served_table(),
                ..Default::default()
            },
        );
        let store = test.services.storage.workspaces().clone();
        let table = |name: &str| TabRecord::Table {
            schema: None,
            table: name.to_owned(),
            offset: 0,
            page_size: 100,
            filter: None,
            sort: None,
        };
        store
            .schedule(
                &test.key(),
                WorkspaceRecord {
                    active_tab: Some(1),
                    tabs: vec![table("users"), table("orders"), table("items")],
                },
            )
            .expect("the record to queue");
        crate::test_support::finish_on_main(WAIT, store.flush(&test.key()))
            .expect("the flush to end")
            .expect("the record written");

        test.window
            .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
        test.wait_for_page("workspace");
        let workspace = test.workspace();
        let view = workspace.chrome().imp().tab_view.get();
        wait_until(WAIT, || view.n_pages() == 3).expect("the saved tabs");
        let column_reads = || tablepro_test_support::CallCounters::get(&test.connection().counters().fetch_columns);
        let _ = wait_until(WAIT, || column_reads() > 0);
        // Long enough for a tab not shown to have read its table too.
        let _ = wait_until(std::time::Duration::from_millis(500), || false);
        assert_eq!(column_reads(), 1, "only the tab in front reads its table");

        view.set_selected_page(&view.nth_page(2));

        wait_until(WAIT, || column_reads() == 2).expect("the tab read its table once shown");
    }
}
