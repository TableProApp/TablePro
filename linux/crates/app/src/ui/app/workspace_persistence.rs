use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::time::Duration;

use relm4::adw;
use relm4::adw::prelude::*;
use relm4::gtk::glib;
use tablepro_session::SessionKey;
use uuid::Uuid;

use super::{WorkspaceTab, read_workspace_tab_id};
use crate::ui::structure_tab::StructureMode;
use crate::workspace::{PersistDebouncer, SortRecord, TabRecord, WorkspaceRecord, WorkspaceSaveError, WorkspaceStore};

/// How long after the last tab change the tab list is written.
const PERSIST_DELAY: Duration = Duration::from_millis(500);

pub(super) type WorkspaceTabs = Rc<RefCell<HashMap<Uuid, WorkspaceTab>>>;

/// Keeps the tab list of the session a window shows on disk, behind the
/// user.
pub(super) struct WorkspacePersistence {
    store: WorkspaceStore,
    debouncer: PersistDebouncer,
    target: RefCell<Option<Target>>,
}

/// The session the tabs belong to. It is set only once that session's
/// saved tabs have been read, so nothing is written over them first.
struct Target {
    key: SessionKey,
    view: glib::WeakRef<adw::TabView>,
    tabs: WorkspaceTabs,
}

impl Target {
    fn record(&self) -> Option<WorkspaceRecord> {
        let view = self.view.upgrade()?;
        Some(workspace_record(&view, &self.tabs.borrow()))
    }
}

impl WorkspacePersistence {
    pub fn new(store: WorkspaceStore) -> Rc<Self> {
        Rc::new(Self {
            store,
            debouncer: PersistDebouncer::new(PERSIST_DELAY),
            target: RefCell::new(None),
        })
    }

    /// Start writing the tabs of `key`, whose saved tabs have been read.
    pub fn attach(&self, key: SessionKey, view: &adw::TabView, tabs: WorkspaceTabs) {
        self.debouncer.cancel();
        *self.target.borrow_mut() = Some(Target {
            key,
            view: view.downgrade(),
            tabs,
        });
    }

    /// Write the tab list a moment after the last change.
    pub fn request(self: &Rc<Self>) {
        // Taken now: the write belongs to the session open now, even if
        // it fires after a switch to another one.
        let Some(key) = self.target.borrow().as_ref().map(|target| target.key.clone()) else {
            return;
        };
        let this = Rc::downgrade(self);
        self.debouncer.request(move || {
            if let Some(this) = this.upgrade() {
                this.write(&key);
            }
        });
    }

    /// Write the tabs as they are now and stop writing for this session.
    /// The future resolves once the record is on disk.
    pub fn detach(&self) -> Option<impl Future<Output = Result<(), WorkspaceSaveError>> + use<>> {
        // Taking the target is what keeps a pending request from saving
        // the emptied tabs; this only stops its timer.
        self.debouncer.cancel();
        let target = self.target.borrow_mut().take()?;
        if let Some(record) = target.record() {
            self.schedule(&target.key, record);
        }
        Some(self.store.flush(&target.key))
    }

    fn write(&self, key: &SessionKey) {
        let record = match self.target.borrow().as_ref() {
            Some(target) if &target.key == key => target.record(),
            _ => None,
        };
        if let Some(record) = record {
            self.schedule(key, record);
        }
    }

    fn schedule(&self, key: &SessionKey, record: WorkspaceRecord) {
        match self.store.schedule(key, record) {
            Ok(()) => {}
            Err(WorkspaceSaveError::Blocked) => {
                tracing::debug!("the saved tabs could not be read, so the open ones are not written over them");
            }
            Err(error) => tracing::warn!(%error, "could not save the open tabs"),
        }
    }
}

pub(super) fn workspace_record(view: &adw::TabView, tabs: &HashMap<Uuid, WorkspaceTab>) -> WorkspaceRecord {
    let selected = view.selected_page();
    let pages = view.pages();
    let mut record = WorkspaceRecord::default();
    for index in 0..pages.n_items() {
        let Some(page) = pages.item(index).and_downcast::<adw::TabPage>() else {
            continue;
        };
        let Some(tab) = read_workspace_tab_id(&page).and_then(|id| tabs.get(&id)) else {
            continue;
        };
        let Some(saved) = tab_record(tab) else {
            continue;
        };
        if selected.as_ref() == Some(&page) {
            record.active_tab = u32::try_from(record.tabs.len()).ok();
        }
        record.tabs.push(saved);
    }
    record
}

fn tab_record(tab: &WorkspaceTab) -> Option<TabRecord> {
    match tab {
        WorkspaceTab::Editor(slot) => Some(TabRecord::Editor { draft: slot.draft }),
        WorkspaceTab::Structure(slot) => match slot.mode {
            // A draft for a table that does not exist yet has nothing to
            // reopen.
            StructureMode::New => None,
            StructureMode::Edit => Some(TabRecord::Structure {
                schema: slot.schema.clone(),
                table: slot.table.clone(),
            }),
        },
        WorkspaceTab::Table(slot) => Some(TabRecord::Table {
            schema: slot.schema.clone(),
            table: slot.table.clone(),
            offset: slot.browse.current_offset(),
            page_size: slot.browse.page_size(),
            sort: slot
                .browse
                .current_sort()
                .map(|(column, ascending)| SortRecord { column, ascending }),
        }),
    }
}

/// Open each saved tab through `open`, in order, then select the one
/// that was selected. A tab `open` could not build leaves nothing to
/// select.
pub(super) fn reopen(
    view: &adw::TabView,
    record: WorkspaceRecord,
    mut open: impl FnMut(TabRecord) -> Option<adw::TabPage>,
) {
    let pages: Vec<Option<adw::TabPage>> = record.tabs.into_iter().map(&mut open).collect();
    let selected = record
        .active_tab
        .and_then(|index| usize::try_from(index).ok())
        .and_then(|index| pages.get(index).cloned().flatten());
    if let Some(page) = selected {
        view.set_selected_page(&page);
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use relm4::gtk;
    use tablepro_storage::DraftId;

    use super::*;
    use crate::test_support::{finish_on_main, wait_until};
    use crate::ui::app::{EditorTabSlot, write_workspace_tab_id};
    use crate::ui::editor::{SqlEditor, SqlEditorInit};
    use crate::workspace::WorkspaceLoad;

    const WAIT: Duration = Duration::from_secs(5);

    struct Fixture {
        runtime: crate::runtime::AppRuntime,
        settings: crate::test_support::MemorySettings,
        root: tempfile::TempDir,
        store: WorkspaceStore,
        view: adw::TabView,
        tabs: WorkspaceTabs,
    }

    impl Fixture {
        fn new() -> Self {
            adw::init().expect("libadwaita initialises under the test backend");
            crate::register_test_resources();
            let runtime = crate::test_support::test_runtime();
            let root = tempfile::tempdir().expect("tempdir");
            let store = WorkspaceStore::start(root.path().join("workspaces"), &runtime.tasks());
            Self {
                runtime,
                settings: crate::test_support::MemorySettings::new(),
                root,
                store,
                view: adw::TabView::new(),
                tabs: WorkspaceTabs::default(),
            }
        }

        fn add_editor(&self) -> (adw::TabPage, DraftId) {
            let editor = SqlEditor::new(SqlEditorInit {
                schema_buffer: crate::ui::editor::build_schema_buffer(),
                initial_query: None,
                settings: self.settings.get().clone(),
                history: None,
                tasks: self.runtime.tasks(),
                session: crate::services::active_session::ActiveSession::new(),
                hold: Rc::new(tablepro_session::runtime::CountingHold::new()),
                close_timeout: Duration::from_secs(5),
            });
            let page = self.view.append(&editor);
            let id = Uuid::new_v4();
            write_workspace_tab_id(&page, id);
            let draft = DraftId::new();
            self.tabs.borrow_mut().insert(
                id,
                WorkspaceTab::Editor(EditorTabSlot {
                    editor,
                    page: page.clone(),
                    draft,
                }),
            );
            (page, draft)
        }

        fn load(&self, key: &SessionKey) -> WorkspaceLoad {
            finish_on_main(WAIT, self.store.load(key)).expect("the load to end")
        }
    }

    /// Run the main loop for `duration`, long enough for a timer that
    /// must not fire to have fired.
    fn run_for(duration: Duration) {
        let _ = wait_until(duration, || false);
    }

    fn editor_drafts(record: &WorkspaceRecord) -> Vec<DraftId> {
        record
            .tabs
            .iter()
            .filter_map(|tab| match tab {
                TabRecord::Editor { draft } => Some(*draft),
                _ => None,
            })
            .collect()
    }

    #[gtk4::test]
    fn active_tab_indexes_saved_records_not_pages() {
        let fixture = Fixture::new();
        // A page with no tab behind it is not saved, so it shifts the
        // page index but not the record index.
        fixture.view.append(&gtk::Label::new(None));
        let (_, first) = fixture.add_editor();
        let (selected, second) = fixture.add_editor();
        fixture.view.set_selected_page(&selected);

        let record = workspace_record(&fixture.view, &fixture.tabs.borrow());

        assert_eq!(editor_drafts(&record), [first, second]);
        assert_eq!(record.active_tab, Some(1));
    }

    #[gtk4::test]
    fn only_a_structure_tab_of_an_existing_table_is_saved() {
        let fixture = Fixture::new();
        let session = crate::test_support::FakeSession::start(
            tablepro_test_support::ConnectionScript::default(),
            [],
            fixture.runtime.tasks(),
        );
        for (mode, table) in [(StructureMode::Edit, "users"), (StructureMode::New, "")] {
            let structure = crate::ui::structure_tab::StructureTab::new(crate::ui::structure_tab::StructureTabInit {
                tracker: Default::default(),
                schema: Some("public".to_owned()),
                table: table.to_owned(),
                mode,
                driver_id: "postgres".to_owned(),
                session: session.session.clone(),
                tasks: fixture.runtime.tasks(),
            });
            let page = fixture.view.append(&structure);
            let id = Uuid::new_v4();
            write_workspace_tab_id(&page, id);
            fixture.tabs.borrow_mut().insert(
                id,
                WorkspaceTab::Structure(crate::ui::app::StructureTabSlot {
                    id,
                    structure,
                    page,
                    schema: Some("public".to_owned()),
                    table: table.to_owned(),
                    mode,
                }),
            );
        }

        let record = workspace_record(&fixture.view, &fixture.tabs.borrow());

        assert_eq!(
            record.tabs,
            [TabRecord::Structure {
                schema: Some("public".to_owned()),
                table: "users".to_owned(),
            }]
        );
        for tab in fixture.tabs.borrow().values() {
            if let WorkspaceTab::Structure(slot) = tab {
                slot.structure.shutdown();
            }
        }
    }

    #[gtk4::test]
    fn restore_selects_active_tab_and_reopens_structure_tabs() {
        adw::init().expect("libadwaita initialises under the test backend");
        let view = adw::TabView::new();
        let record = WorkspaceRecord {
            active_tab: Some(1),
            tabs: vec![
                TabRecord::Table {
                    schema: None,
                    table: "orders".to_owned(),
                    offset: 0,
                    page_size: 1_000,
                    sort: None,
                },
                TabRecord::Structure {
                    schema: Some("public".to_owned()),
                    table: "users".to_owned(),
                },
                TabRecord::Editor { draft: DraftId::new() },
            ],
        };
        let mut opened = Vec::new();

        reopen(&view, record, |tab| {
            let name = match &tab {
                TabRecord::Table { table, .. } => format!("table {table}"),
                TabRecord::Structure { table, .. } => format!("structure {table}"),
                TabRecord::Editor { .. } => "editor".to_owned(),
            };
            let page = view.append(&gtk::Label::new(Some(&name)));
            opened.push(name);
            Some(page)
        });

        assert_eq!(opened, ["table orders", "structure users", "editor"]);
        let selected = view
            .selected_page()
            .and_then(|page| page.child().downcast::<gtk::Label>().ok())
            .map(|label| label.label().to_string());
        assert_eq!(selected.as_deref(), Some("structure users"));
    }

    #[gtk4::test]
    fn detach_writes_the_tabs_as_they_are_now() {
        let fixture = Fixture::new();
        let persistence = WorkspacePersistence::new(fixture.store.clone());
        let key = SessionKey::Saved(Uuid::new_v4());
        let (_, draft) = fixture.add_editor();
        persistence.attach(key.clone(), &fixture.view, fixture.tabs.clone());

        let flushing = persistence.detach().expect("an attached session");
        finish_on_main(WAIT, flushing)
            .expect("the flush to end")
            .expect("written");

        let WorkspaceLoad::Restored(record) = fixture.load(&key) else {
            panic!("nothing was saved");
        };
        assert_eq!(editor_drafts(&record), [draft]);
        assert!(persistence.detach().is_none(), "still attached after a detach");
    }

    #[gtk4::test]
    fn a_request_pending_at_teardown_does_not_save_the_emptied_tabs() {
        let fixture = Fixture::new();
        let persistence = WorkspacePersistence::new(fixture.store.clone());
        let key = SessionKey::Saved(Uuid::new_v4());
        let (_, draft) = fixture.add_editor();
        persistence.attach(key.clone(), &fixture.view, fixture.tabs.clone());

        persistence.request();
        let flushing = persistence.detach().expect("an attached session");
        assert!(
            !persistence.debouncer.is_pending(),
            "a write timer outlived the session"
        );
        // What the window's teardown does next.
        fixture.tabs.borrow_mut().clear();
        finish_on_main(WAIT, flushing)
            .expect("the flush to end")
            .expect("written");
        run_for(PERSIST_DELAY * 3);

        let WorkspaceLoad::Restored(record) = fixture.load(&key) else {
            panic!("nothing was saved");
        };
        assert_eq!(editor_drafts(&record), [draft]);
    }

    #[gtk4::test]
    fn nothing_is_written_before_the_saved_tabs_are_read() {
        let fixture = Fixture::new();
        let persistence = WorkspacePersistence::new(fixture.store.clone());
        fixture.add_editor();

        persistence.request();

        run_for(PERSIST_DELAY * 3);

        assert!(persistence.detach().is_none());
        assert!(
            !fixture.root.path().join("workspaces").exists(),
            "a tab list was written for no session"
        );
    }
}
