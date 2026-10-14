use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use tablepro_core::column::{ColumnDefault, ColumnKind, ColumnType, IntegerKind, IntegerWidth};
use tablepro_core::ddl::{ColumnAttributes, ColumnDefinition, TableDefinition, TableDraft, TableSource, diff_table};
use tablepro_core::meta::TableRef;
use tablepro_core::{ColumnInfo, Value, WriteAtomicity};
use tablepro_session::runtime::CountingHold;
use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};
use uuid::Uuid;

use super::{
    EngineProfile, SaveSettled, SaveStart, TabDirectory, TabEntry, WorkspaceDeps, WorkspaceEvent, WorkspaceHandle,
};
use crate::services::active_session::ActiveSession;
use crate::services::change_tracker::RowKey;
use crate::services::change_tracker_registry::ChangeTrackerRegistry;
use crate::services::pending_structure::PendingStructure;
use crate::services::save_batch::SaveTarget;
use crate::services::structure_tracker_handle::StructureTrackerHandle;
use crate::services::structure_tracker_registry::StructureTrackerRegistry;
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::{FakeSession, wait_until};

pub(crate) const WAIT: Duration = Duration::from_secs(10);

/// The tabs a test window has open.
#[derive(Default)]
pub(crate) struct Tabs(pub RefCell<Vec<TabEntry>>);

impl TabDirectory for Tabs {
    fn tabs(&self) -> Vec<TabEntry> {
        self.0.borrow().clone()
    }
}

pub(crate) fn integer(name: &str, primary_key: bool) -> ColumnInfo {
    let mut column_type = ColumnType::untyped_text("integer");
    column_type.kind = ColumnKind::Integer(IntegerKind {
        width: IntegerWidth::W32,
        signed: true,
    });
    ColumnInfo {
        name: name.to_owned(),
        column_type,
        nullable: false,
        primary_key,
        is_auto_increment: false,
        is_generated: false,
        default: ColumnDefault::None,
        comment: None,
    }
}

pub(crate) fn sqlite() -> Arc<dyn tablepro_core::dialect::SqlDialect> {
    Arc::new(drivers_sqlite::SqliteDialect::new(drivers_sqlite::SqliteVersion::new(
        3, 45, 0,
    )))
}

/// `t (id INTEGER, n INTEGER)` as SQLite reads it, edited by `edit`.
pub(crate) fn edited_table(edit: impl FnOnce(&mut TableDraft)) -> PendingStructure {
    let dialect = sqlite();
    let column = |name: &str| {
        ColumnDefinition::new(
            ColumnInfo {
                column_type: dialect.parse_type("INTEGER").expect("a SQLite type"),
                nullable: true,
                ..integer(name, false)
            },
            ColumnAttributes::default(),
        )
    };
    let original = TableDefinition {
        table: TableRef::unqualified("t"),
        columns: vec![column("id"), column("n")],
        primary_key: None,
        indexes: Vec::new(),
        foreign_keys: Vec::new(),
        inbound_foreign_keys: Vec::new(),
        source: Some(TableSource {
            create_statement: "CREATE TABLE t (id INTEGER, n INTEGER)".to_owned(),
            dependents: Vec::new(),
        }),
    };
    let mut draft = TableDraft::from_definition(&original);
    edit(&mut draft);
    PendingStructure {
        changes: diff_table(&original, &draft),
        original: Some(original),
        draft,
        unparsed_defaults: Vec::new(),
    }
}

/// A mapped window for a save's review and the close prompts.
pub(crate) fn window() -> adw::Window {
    adw::init().expect("libadwaita initialises under the test backend");
    if let Some(settings) = gtk::Settings::default() {
        settings.set_gtk_enable_animations(false);
    }
    let window = adw::Window::new();
    window.present();
    window
}

/// A workspace with one tab, over a fake connection that writes as its
/// script says: a table tab holding one edited cell, or a structure tab
/// holding a pending structure.
pub(crate) struct Workspace {
    pub handle: WorkspaceHandle,
    pub tab: Uuid,
    pub tracker: TabTrackerHandle,
    pub structure: StructureTrackerHandle,
    pub tabs: Rc<Tabs>,
    pub settled: Rc<RefCell<Vec<SaveSettled>>>,
    pub events: Rc<RefCell<Vec<WorkspaceEvent>>>,
    pub fake: FakeSession,
    pub hold: CountingHold,
    runtime: Option<crate::runtime::AppRuntime>,
}

impl Workspace {
    pub(crate) fn open(script: ConnectionScript) -> Self {
        Self::build(script, None)
    }

    pub(crate) fn open_structure(script: ConnectionScript, pending: PendingStructure) -> Self {
        Self::build(script, Some(pending))
    }

    fn build(mut script: ConnectionScript, structure: Option<PendingStructure>) -> Self {
        script.dialect = sqlite();
        script.probe.always(FakeReply::ok(()));
        let runtime = crate::test_support::test_runtime();
        let fake = FakeSession::start(script, [], runtime.tasks());
        let active = ActiveSession::new();
        active.replace(fake.session.clone());
        let rows = Rc::new(ChangeTrackerRegistry::default());
        let structures = Rc::new(StructureTrackerRegistry::default());
        let tab = Uuid::new_v4();
        let (tracker, structure) = match structure {
            None => {
                let tracker = rows.register(tab);
                let _ = tracker.set_target(SaveTarget {
                    table: TableRef::unqualified("t"),
                    columns: vec![integer("id", true), integer("n", false)],
                });
                edit(&tracker, 2);
                (tracker, StructureTrackerHandle::default())
            }
            Some(pending) => {
                let structure = structures.register(tab);
                structure.set_pending(Some(pending));
                (TabTrackerHandle::default(), structure)
            }
        };
        let tabs = Rc::new(Tabs::default());
        tabs.0.borrow_mut().push(TabEntry {
            id: tab,
            title: "t".to_owned(),
            open_transaction: false,
        });
        let settled = Rc::new(RefCell::new(Vec::new()));
        let events = Rc::new(RefCell::new(Vec::new()));
        let settled_sink = settled.clone();
        let event_sink = events.clone();
        let hold = CountingHold::new();
        let handle = WorkspaceHandle::new(WorkspaceDeps {
            session: active,
            tasks: runtime.tasks(),
            hold: Rc::new(hold.clone()),
            history: None,
            rows,
            structures,
            directory: tabs.clone(),
            events: Rc::new(move |event| {
                if let WorkspaceEvent::SaveSettled(settled) = &event {
                    settled_sink.borrow_mut().push((**settled).clone());
                }
                event_sink.borrow_mut().push(event);
            }),
            engine: EngineProfile {
                name: "SQLite".to_owned(),
                ddl_writes: WriteAtomicity::Transactional,
            },
        });
        Self {
            handle,
            tab,
            tracker,
            structure,
            tabs,
            settled,
            events,
            fake,
            hold,
            runtime: Some(runtime),
        }
    }

    /// An editor tab beside the table tab, with a transaction open.
    pub(crate) fn open_transaction_tab(&self) -> Uuid {
        let id = Uuid::new_v4();
        self.tabs.0.borrow_mut().push(TabEntry {
            id,
            title: "Query 1".to_owned(),
            open_transaction: true,
        });
        id
    }

    /// Ask the tab to save, as its Save button does, for a save that
    /// needs no review.
    pub(crate) fn start(&self) -> Vec<SaveStart> {
        let parent = gtk::Label::new(None).upcast::<gtk::Widget>();
        let (handle, tab) = (self.handle.clone(), self.tab);
        crate::test_support::finish_on_main(WAIT, async move { handle.save(&parent, &[tab]).await })
            .expect("the save to be asked")
    }

    /// Ask the tab to save with `window` as the review's parent. The
    /// starts land in the cell once the review, if any, is answered.
    pub(crate) fn start_on(&self, window: &adw::Window) -> Rc<RefCell<Option<Vec<SaveStart>>>> {
        let starts = Rc::new(RefCell::new(None));
        let sink = starts.clone();
        let (handle, tab) = (self.handle.clone(), self.tab);
        let parent = window.clone().upcast::<gtk::Widget>();
        gtk::glib::spawn_future_local(async move {
            let started = handle.save(&parent, &[tab]).await;
            sink.replace(Some(started));
        });
        starts
    }

    pub(crate) fn save(&self) -> SaveSettled {
        let started = self.start();
        assert!(matches!(started.as_slice(), [SaveStart::Started(_)]), "{started:?}");
        self.settle()
    }

    pub(crate) fn settle(&self) -> SaveSettled {
        wait_until(WAIT, || !self.settled.borrow().is_empty()).expect("the save to settle");
        self.settled.borrow_mut().remove(0)
    }

    pub(crate) fn counters(&self) -> CallCounters {
        self.fake.connection.counters()
    }
}

fn edit(tracker: &TabTrackerHandle, value: i64) {
    let _ = tracker.apply(TrackerEdit::Cell {
        row_key: RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"),
        col: 1,
        original: Value::Int(1),
        value: Value::Int(value),
    });
}

impl Drop for Workspace {
    fn drop(&mut self) {
        crate::test_support::drain_main_context();
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown();
        }
    }
}
