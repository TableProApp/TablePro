use std::cell::Cell;
use std::collections::HashSet;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::meta::TableRef;
use tablepro_storage::{DraftId, DraftScope};
use uuid::Uuid;

use super::editor_label::EditorLabel;
use super::structure_target::StructureTarget;
use super::tab_index::TabIndex;
use super::tab_spec::{TabSpec, TablePage};
use super::tab_title::resolve_tab_title;
use super::table_naming::TableNaming;
use super::workspace_persistence::WorkspaceTabs;
use super::{
    DiagramTabSlot, EditorTabSlot, KeyTabSlot, OpenMode, StructureTabSlot, TableTabSlot, WorkspaceInput,
    WorkspaceSender, WorkspaceTab, apply_tab_title,
};
use crate::runtime::DeliverInput;
use crate::services::change_tracker_registry::ChangeTrackerRegistry;
use crate::services::history_service::HistoryService;
use crate::services::session_context::SessionContext;
use crate::services::structure_tracker_registry::StructureTrackerRegistry;
use crate::ui::browse_tab::{BrowseTab, BrowseTabInit, TableFilter};
use crate::ui::diagram::{DiagramTab, DiagramTabInit};
use crate::ui::editor::{SqlEditor, SqlEditorInit};
use crate::ui::key_tab::{KeyTab, KeyTabEvent, KeyTabInit};
use crate::ui::structure_tab::{StructureMode, StructureTab, StructureTabInit};
use crate::ui::tab_load::FirstLoad;
use crate::workspace::{DraftWriter, EditorFileRecord};

/// What a factory builds its tabs from: the workspace's session, stores
/// and trackers.
pub(super) struct TabFactoryParts {
    pub view: adw::TabView,
    pub tabs: WorkspaceTabs,
    pub index: Rc<TabIndex>,
    pub input: WorkspaceSender,
    pub toasts: glib::WeakRef<adw::ToastOverlay>,
    pub context: Rc<SessionContext>,
    pub settings: Rc<tablepro_storage::AppSettings>,
    pub storage: crate::storage::SharedStorage,
    pub history: Option<HistoryService>,
    pub drafts: Rc<DraftWriter>,
    pub draft_scope: DraftScope,
    pub change_trackers: Rc<ChangeTrackerRegistry>,
    pub structure_trackers: Rc<StructureTrackerRegistry>,
    /// The exports a diagram writes its images through.
    pub exports: Rc<crate::ui::export::ExportLedger>,
    pub read_only: bool,
    /// Whether a tab's title names the table's schema.
    pub naming: Rc<Cell<TableNaming>>,
    /// The window's assistant, which editor tabs ask.
    pub assistant: Rc<crate::ui::assistant::AssistantAccess>,
    pub snippets: Rc<crate::services::snippet_library::SnippetLibrary>,
}

/// The one place a tab is built: its widget, its page, its slot and its
/// index entry. The workspace's own calls and the overview's new-tab
/// button go through it alike.
pub(super) struct TabFactory {
    parts: TabFactoryParts,
}

impl TabFactory {
    pub(super) fn new(parts: TabFactoryParts) -> Rc<Self> {
        Rc::new(Self { parts })
    }

    /// Build the tab and append its page, unselected. `None` when the
    /// spec needs a session and the workspace has none any more.
    pub(super) fn create(&self, spec: TabSpec) -> Option<adw::TabPage> {
        self.build(spec, FirstLoad::Now, None)
    }

    /// As `create`, with the page placed after `parent` and its other
    /// children, so closing it goes back there.
    pub(super) fn create_beside(&self, spec: TabSpec, parent: &adw::TabPage) -> Option<adw::TabPage> {
        self.build(spec, FirstLoad::Now, Some(parent))
    }

    /// A saved tab, which reads its table the first time it is shown.
    pub(super) fn restore(&self, spec: TabSpec) -> Option<adw::TabPage> {
        self.build(spec, FirstLoad::WhenShown, None)
    }

    fn build(&self, spec: TabSpec, first_load: FirstLoad, parent: Option<&adw::TabPage>) -> Option<adw::TabPage> {
        let id = Uuid::new_v4();
        let slot = match spec {
            TabSpec::Editor {
                initial_query,
                draft,
                file,
            } => self.editor(id, initial_query, draft, file),
            TabSpec::Table { table, page, filter } => self.table(
                id,
                TableOpening {
                    table,
                    page,
                    filter,
                    first_load,
                    parent,
                },
            )?,
            TabSpec::Structure { target } => self.structure(id, target, first_load)?,
            TabSpec::Diagram { schema, places } => self.diagram(
                id,
                DiagramOpening {
                    schema,
                    places,
                    first_load,
                },
            )?,
            TabSpec::Key { key } => self.key(id, key, first_load)?,
        };
        Some(self.insert(id, slot))
    }

    /// The overview's new-tab button needs its page back at once.
    pub(super) fn create_editor(&self) -> adw::TabPage {
        let id = Uuid::new_v4();
        let slot = self.editor(id, None, None, None);
        self.insert(id, slot)
    }

    fn insert(&self, id: Uuid, slot: WorkspaceTab) -> adw::TabPage {
        let page = slot.page().clone();
        apply_tab_title(&page, &resolve_tab_title(&slot.identity(), self.parts.naming.get()));
        self.parts.tabs.borrow_mut().insert(id, slot);
        self.parts.input.deliver(WorkspaceInput::WorkspaceTabsChanged);
        page
    }

    fn append(&self, child: &impl IsA<gtk::Widget>, id: Uuid, parent: Option<&adw::TabPage>) -> adw::TabPage {
        let page = match parent {
            Some(parent) => self.parts.view.add_page(child, Some(parent)),
            None => self.parts.view.append(child),
        };
        self.parts.index.insert(&page, id);
        page
    }

    fn editor(
        &self,
        id: Uuid,
        initial_query: Option<String>,
        draft: Option<DraftId>,
        file: Option<EditorFileRecord>,
    ) -> WorkspaceTab {
        let parts = &self.parts;
        // Such a tab shows the editor's sample query, which names nothing.
        let opened_empty = initial_query.is_none();
        let editor = SqlEditor::new(SqlEditorInit {
            initial_query,
            settings: parts.settings.clone(),
            history: parts.history.clone(),
            tasks: parts.context.tasks.clone(),
            session: parts.context.active.clone(),
            hold: parts.context.hold.clone(),
            close_timeout: parts.context.close_timeout(),
            snippets: parts.snippets.clone(),
        });
        connect_editor(&editor, id, &parts.input, &parts.toasts);
        editor.attach_assistant(parts.assistant.clone());
        // After the signals are connected, so the workspace marks a tab
        // restored with unsaved changes.
        if let Some(file) = file {
            editor.restore_file(gio::File::for_uri(&file.uri), file.modified);
        }
        let ordinal = self.free_ordinal();
        let page = self.append(&editor, id, None);
        let label = match (opened_empty, editor.file()) {
            (_, Some(file)) => EditorLabel::file(&file),
            (true, None) => EditorLabel::Untitled(ordinal),
            (false, None) => EditorPreview::read(&editor.buffer()).label(ordinal),
        };
        let draft = draft.unwrap_or_else(|| {
            // Text a new tab opens with is written even if the user
            // never types in it.
            let draft = DraftId::new();
            parts.drafts.schedule(&parts.draft_scope, draft, &editor.buffer());
            draft
        });
        WorkspaceTab::Editor(EditorTabSlot {
            editor,
            page,
            draft,
            ordinal,
            label,
        })
    }

    fn table(&self, id: Uuid, opening: TableOpening<'_>) -> Option<WorkspaceTab> {
        let parts = &self.parts;
        let session = parts.context.active.get()?;
        let TableOpening {
            table: TableRef { schema, name },
            page,
            filter,
            first_load,
            parent,
        } = opening;
        let browse = BrowseTab::new(BrowseTabInit {
            tracker: parts.change_trackers.register(id),
            schema: schema.clone(),
            table: name.clone(),
            connection_id: parts.context.active.metadata().map(|metadata| metadata.id),
            read_only: parts.read_only,
            page_size: page.page_size,
            initial_offset: page.offset,
            initial_sort: page.sort,
            filter,
            column_widths: parts.storage.column_widths().clone(),
            filter_settings: parts.storage.filter_settings().clone(),
            session,
            tasks: parts.context.tasks.clone(),
            deadlines: parts.context.deadlines.clone(),
            settings: parts.settings.clone(),
            first_load,
        });
        connect_browse(&browse, id, &parts.input);
        let tab_page = self.append(&browse, id, parent);
        let follow = follow_loading(&tab_page, browse.is_loading());
        browse.connect_loading_changed(move |_, loading| follow(loading));
        Some(WorkspaceTab::Table(TableTabSlot {
            id,
            page: tab_page,
            schema,
            table: name,
            browse,
        }))
    }

    fn structure(&self, id: Uuid, target: StructureTarget, first_load: FirstLoad) -> Option<WorkspaceTab> {
        let parts = &self.parts;
        let session = parts.context.active.get()?;
        let (schema, table, mode) = match target {
            StructureTarget::Existing(TableRef { schema, name }) => (schema, name, StructureMode::Edit),
            StructureTarget::NewDraft { schema } => (schema, String::new(), StructureMode::New),
        };
        let structure = StructureTab::new(StructureTabInit {
            tracker: parts.structure_trackers.register(id),
            schema: schema.clone(),
            table: table.clone(),
            mode,
            session,
            tasks: parts.context.tasks.clone(),
            first_load,
        });
        connect_structure(&structure, id, &parts.input);
        let page = self.append(&structure, id, None);
        let follow = follow_loading(&page, structure.is_loading());
        structure.connect_loading_changed(move |_, loading| follow(loading));
        Some(WorkspaceTab::Structure(StructureTabSlot {
            id,
            structure,
            page,
            schema,
            table,
            mode,
        }))
    }

    fn diagram(&self, id: Uuid, opening: DiagramOpening) -> Option<WorkspaceTab> {
        let parts = &self.parts;
        let session = parts.context.active.get()?;
        let DiagramOpening {
            schema,
            places,
            first_load,
        } = opening;
        let diagram = DiagramTab::new(DiagramTabInit {
            schema: schema.clone(),
            session,
            tasks: parts.context.tasks.clone(),
            exports: parts.exports.clone(),
            tab_id: id,
            first_load,
            places,
        });
        connect_diagram(&diagram, &parts.input);
        let page = self.append(&diagram, id, None);
        let follow = follow_loading(&page, diagram.is_loading());
        diagram.connect_loading_changed(move |_, loading| follow(loading));
        Some(WorkspaceTab::Diagram(DiagramTabSlot { page, schema, diagram }))
    }

    fn key(&self, id: Uuid, key: String, first_load: FirstLoad) -> Option<WorkspaceTab> {
        let parts = &self.parts;
        let session = parts.context.active.get()?;
        let tab = KeyTab::new(KeyTabInit {
            key,
            session,
            tasks: parts.context.tasks.clone(),
            first_load,
        });
        let page = self.append(tab.widget(), id, None);
        let follow = follow_loading(&page, tab.is_loading());
        let input = parts.input.clone();
        tab.connect_events(move |event| match event {
            KeyTabEvent::LoadingChanged(loading) => follow(loading),
            KeyTabEvent::Toast(text) => input.deliver(WorkspaceInput::ShowToast(text)),
            KeyTabEvent::Export(offer) => input.deliver(WorkspaceInput::ExportResults { tab: id, offer }),
        });
        Some(WorkspaceTab::Key(KeyTabSlot { page, tab }))
    }

    /// The lowest number no open editor tab has, so two never share one.
    fn free_ordinal(&self) -> usize {
        let tabs = self.parts.tabs.borrow();
        let taken: HashSet<usize> = tabs
            .values()
            .filter_map(|tab| match tab {
                WorkspaceTab::Editor(slot) => Some(slot.ordinal),
                _ => None,
            })
            .collect();
        let mut ordinal = 1;
        while taken.contains(&ordinal) {
            ordinal += 1;
        }
        ordinal
    }
}

/// What a diagram tab opens on.
struct DiagramOpening {
    schema: Option<String>,
    places: Vec<crate::workspace::DiagramPlace>,
    first_load: FirstLoad,
}

/// What a table tab opens on, and where its page goes.
struct TableOpening<'a> {
    table: TableRef,
    page: TablePage,
    filter: TableFilter,
    first_load: FirstLoad,
    parent: Option<&'a adw::TabPage>,
}

pub(super) const PREVIEW_CHARS: i32 = 200;

/// The start of an editor's script, read without copying the rest.
pub(super) struct EditorPreview {
    pub text: String,
    pub truncated: bool,
}

impl EditorPreview {
    pub(super) fn read(buffer: &gtk::TextBuffer) -> Self {
        let end = buffer.iter_at_offset(PREVIEW_CHARS);
        Self {
            text: buffer.text(&buffer.start_iter(), &end, false).to_string(),
            truncated: !end.is_end(),
        }
    }

    /// What tab number `ordinal` with this script is named after.
    pub(super) fn label(&self, ordinal: usize) -> EditorLabel {
        EditorLabel::of(ordinal, &self.text, self.truncated)
    }
}

/// The structure tab's signals, as the workspace's inputs for the tab.
fn connect_structure(structure: &StructureTab, tab_id: Uuid, input: &WorkspaceSender) {
    let dirty = input.clone();
    structure.connect_dirty_changed(move |_, _| dirty.deliver(WorkspaceInput::TabDirtyChanged));
    let save = input.clone();
    structure.connect_save_requested(move |_| save.deliver(WorkspaceInput::SaveTab(tab_id)));
    let stop = input.clone();
    structure.connect_stop_save_requested(move |_| stop.deliver(WorkspaceInput::StopSaving(tab_id)));
    let drop_table = input.clone();
    structure.connect_drop_table_requested(move |_, schema, table| {
        drop_table.deliver(WorkspaceInput::DropTablePrompt { schema, table });
    });
    let toast = input.clone();
    structure.connect_toast(move |_, text| toast.deliver(WorkspaceInput::ShowToast(text)));
    let alert = input.clone();
    structure.connect_alert(move |_, title, body| alert.deliver(WorkspaceInput::ShowAlert { title, body }));
}

/// The diagram's signals, as the workspace's inputs: a table it names
/// opens in a table or structure tab of its own.
fn connect_diagram(diagram: &DiagramTab, input: &WorkspaceSender) {
    let open = input.clone();
    diagram.connect_open_table(move |_, table| {
        open.deliver(WorkspaceInput::SelectTable {
            schema: table.schema,
            name: table.name,
            open_mode: OpenMode::SwitchOrAppend,
        });
    });
    let structure = input.clone();
    diagram.connect_show_structure(move |_, table| {
        structure.deliver(WorkspaceInput::EditStructureTab {
            schema: table.schema,
            table: table.name,
        });
    });
    let layout = input.clone();
    diagram.connect_layout_changed(move |_| layout.deliver(WorkspaceInput::WorkspaceTabsChanged));
}

/// The tab bar spins on a tab's page while the tab reads. The tab
/// started reading before it had a page, so the page starts from where
/// the read stands. The tab holds the handler and the page holds the
/// tab, so the handler holds the page weakly.
fn follow_loading(page: &adw::TabPage, loading: bool) -> impl Fn(bool) + 'static {
    page.set_loading(loading);
    let page = page.downgrade();
    move |loading| {
        if let Some(page) = page.upgrade() {
            page.set_loading(loading);
        }
    }
}

/// The browse tab's signals, as the workspace's inputs for the tab.
fn connect_browse(browse: &BrowseTab, tab_id: Uuid, input: &WorkspaceSender) {
    let state = input.clone();
    browse.connect_state_changed(move |_| state.deliver(WorkspaceInput::WorkspaceTabsChanged));
    let export = input.clone();
    browse.connect_export_results(move |_, offer| {
        export.deliver(WorkspaceInput::ExportResults {
            tab: tab_id,
            offer: Box::new(offer),
        });
    });
    let alert = input.clone();
    browse.connect_alert(move |_, title, body| alert.deliver(WorkspaceInput::ShowAlert { title, body }));
    let toast = input.clone();
    browse.connect_toast(move |_, text| toast.deliver(WorkspaceInput::ShowToast(text)));
    let dirty = input.clone();
    browse.connect_dirty_changed(move |_, _| dirty.deliver(WorkspaceInput::TabDirtyChanged));
    let save = input.clone();
    browse.connect_save_requested(move |_| save.deliver(WorkspaceInput::SaveTab(tab_id)));
    let stop = input.clone();
    browse.connect_stop_save_requested(move |_| stop.deliver(WorkspaceInput::StopSaving(tab_id)));
    let refresh = input.clone();
    browse.connect_refresh_requested(move |_| refresh.deliver(WorkspaceInput::RefreshTab(tab_id)));
    let follow = input.clone();
    browse.connect_follow_reference(move |_, reference| {
        follow.deliver(WorkspaceInput::FollowReference {
            tab: tab_id,
            reference: Box::new(reference),
        });
    });
}

/// Forward an editor tab's signals into the workspace. The toast
/// overlay is the workspace's, so a replaced query's Undo button lives
/// there.
pub(super) fn connect_editor(
    editor: &SqlEditor,
    tab_id: Uuid,
    input: &WorkspaceSender,
    toasts: &glib::WeakRef<adw::ToastOverlay>,
) {
    let run_state = input.clone();
    editor.connect_run_state_changed(move |_, running| {
        run_state.deliver(WorkspaceInput::EditorTabRunStateChanged(tab_id, running));
    });
    let finished = input.clone();
    editor.connect_run_finished(move |_, outcome| {
        finished.deliver(WorkspaceInput::EditorTabRunFinished(tab_id, outcome))
    });
    let content = input.clone();
    editor.connect_content_changed(move |_| content.deliver(WorkspaceInput::EditorTabContentChanged(tab_id)));
    let file = input.clone();
    editor.connect_file_changed(move |_| file.deliver(WorkspaceInput::EditorTabFileChanged(tab_id)));
    let transaction = input.clone();
    editor.connect_transaction_changed(move |_, _| transaction.deliver(WorkspaceInput::EditorTransactionChanged));
    let toast = input.clone();
    editor.connect_toast(move |_, text| toast.deliver(WorkspaceInput::ShowToast(text)));
    let close = input.clone();
    editor.connect_close_requested(move |_| close.deliver(WorkspaceInput::CloseWorkspaceTab(tab_id)));
    let assistant = input.clone();
    editor.connect_assistant_requested(move |_, request| {
        assistant.deliver(WorkspaceInput::AskAssistant(Box::new(request)));
    });
    let export = input.clone();
    editor.connect_export_results(move |_, offer| {
        export.deliver(WorkspaceInput::ExportResults {
            tab: tab_id,
            offer: Box::new(offer),
        });
    });
    // The overlay is an ancestor of the editor, so a strong capture
    // would keep both alive once the window lets go of them.
    let toasts = toasts.clone();
    editor.connect_undoable_toast(move |editor, title| {
        let Some(toasts) = toasts.upgrade() else {
            return;
        };
        let toast = crate::ui::plain_toast(&title);
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
    use crate::test_support::drain_main_context;

    #[gtk4::test]
    fn an_editor_tab_is_named_from_the_start_of_its_script_only() {
        let buffer = gtk::TextBuffer::new(None);
        buffer.set_text(&format!("SELECT 1;\n{}", "-- é\n".repeat(10_000)));

        let preview = EditorPreview::read(&buffer);

        let limit = usize::try_from(PREVIEW_CHARS).expect("a positive limit");
        assert_eq!(preview.text.chars().count(), limit);
        assert!(preview.truncated);
        assert!(matches!(preview.label(1), EditorLabel::Query { truncated: true, .. }));
    }

    #[gtk4::test]
    fn a_blank_script_is_named_by_its_number() {
        let buffer = gtk::TextBuffer::new(None);
        buffer.set_text("  \n");

        assert_eq!(EditorPreview::read(&buffer).label(4), EditorLabel::Untitled(4));
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
            snippets: crate::test_support::builtin_snippets_only(),
        });
        let toasts = adw::ToastOverlay::new();
        toasts.set_child(Some(&editor));
        let (input, _receiver) = crate::runtime::input_queue::<WorkspaceInput>();
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
