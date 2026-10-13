use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use tablepro_core::column::{ColumnDefault, ColumnKind, ColumnType, IntegerKind, IntegerWidth};
use tablepro_core::meta::TableRef;
use tablepro_core::{ColumnInfo, Value};
use tablepro_session::runtime::CountingHold;
use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};
use uuid::Uuid;

use super::{SaveSettled, SaveStart, TabDirectory, TabEntry, WorkspaceDeps, WorkspaceEvent, WorkspaceHandle};
use crate::services::active_session::ActiveSession;
use crate::services::change_tracker::RowKey;
use crate::services::change_tracker_registry::ChangeTrackerRegistry;
use crate::services::save_batch::SaveTarget;
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

/// A workspace with one table tab holding one edited cell, over a fake
/// connection that writes as its script says.
pub(crate) struct Workspace {
    pub handle: WorkspaceHandle,
    pub tab: Uuid,
    pub tracker: TabTrackerHandle,
    pub tabs: Rc<Tabs>,
    pub settled: Rc<RefCell<Vec<SaveSettled>>>,
    pub events: Rc<RefCell<Vec<WorkspaceEvent>>>,
    pub fake: FakeSession,
    pub hold: CountingHold,
    runtime: Option<crate::runtime::AppRuntime>,
}

impl Workspace {
    pub(crate) fn open(mut script: ConnectionScript) -> Self {
        script.dialect = sqlite();
        script.probe.always(FakeReply::ok(()));
        let runtime = crate::test_support::test_runtime();
        let fake = FakeSession::start(script, [], runtime.tasks());
        let active = ActiveSession::new();
        active.replace(fake.session.clone());
        let rows = Rc::new(ChangeTrackerRegistry::default());
        let tab = Uuid::new_v4();
        let tracker = rows.register(tab);
        let _ = tracker.set_target(SaveTarget {
            table: TableRef::unqualified("t"),
            columns: vec![integer("id", true), integer("n", false)],
        });
        edit(&tracker, 2);
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
            structures: Rc::new(StructureTrackerRegistry::default()),
            directory: tabs.clone(),
            events: Rc::new(move |event| {
                if let WorkspaceEvent::SaveSettled(settled) = &event {
                    settled_sink.borrow_mut().push((**settled).clone());
                }
                event_sink.borrow_mut().push(event);
            }),
        });
        Self {
            handle,
            tab,
            tracker,
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

    pub(crate) fn save(&self) -> SaveSettled {
        let started = self.handle.save(&[self.tab]);
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
