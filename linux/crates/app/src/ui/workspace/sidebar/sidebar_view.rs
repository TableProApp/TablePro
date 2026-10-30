use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_core::meta::TableRef;
use tablepro_session::runtime::Tasks;

use super::object_key::ObjectKey;
use super::sidebar_affordances::SidebarAffordances;
use super::sidebar_event::SidebarEvent;
use super::sidebar_index::SidebarIndex;
use super::sidebar_menu::{
    DROP_TABLE, EDIT_STRUCTURE, IMPORT_CSV, NEW_TABLE, OPEN_IN_NEW_TAB, SHOW_CREATE_TABLE, SHOW_DIAGRAM,
    SHOW_SCHEMA_DIAGRAM, offers,
};
use super::sidebar_model::{RowsAsked, RowsWorkedOut, Search, SidebarModel};
use super::tree_node::TreeNode;

/// What a session's sidebar lists.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) enum Holds {
    #[default]
    Tables,
    /// A key-value engine's keys, which its server matches against the
    /// search.
    Keys,
    /// A document engine's collections.
    Collections,
}

/// A session's tables as the window's connection tree lists them under
/// its connection, the table actions their menus name, and what the user
/// asks of them, which goes to the session's workspace.
#[derive(Clone)]
pub(crate) struct SidebarView {
    inner: Rc<SidebarInner>,
}

/// What the tree runs once a list or a search's rows land.
type RowsObserver = Rc<dyn Fn()>;

struct SidebarInner {
    model: SidebarModel,
    actions: gio::SimpleActionGroup,
    events: Box<dyn Fn(SidebarEvent)>,
    affordances: Cell<SidebarAffordances>,
    /// Where a new index or search is worked out into rows. Without it,
    /// on the GTK thread.
    tasks: Option<Tasks>,
    holds: Cell<Holds>,
    /// What a key-value engine's server is asked to match, empty while
    /// its branch does not follow the search.
    key_search: RefCell<String>,
    /// Asks the workspace for a new listing of keys.
    relist: RefCell<Option<Box<dyn Fn()>>>,
    observers: RefCell<Vec<(u64, RowsObserver)>>,
    next_observer: Cell<u64>,
}

/// What `connect_rows_shown` returns, to disconnect with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RowsObserverId(u64);

impl SidebarView {
    pub(crate) fn new(
        events: impl Fn(SidebarEvent) + 'static,
        affordances: SidebarAffordances,
        tasks: Option<Tasks>,
    ) -> Self {
        let inner = Rc::new(SidebarInner {
            model: SidebarModel::new(),
            actions: gio::SimpleActionGroup::new(),
            events: Box::new(events),
            affordances: Cell::new(affordances),
            tasks,
            holds: Cell::new(Holds::Tables),
            key_search: RefCell::new(String::new()),
            relist: RefCell::new(None),
            observers: RefCell::new(Vec::new()),
            next_observer: Cell::new(0),
        });
        install_actions(&inner);
        Self { inner }
    }

    /// The schemas the tree lists under the session's connection, then
    /// a placeholder once there are none.
    pub(crate) fn rows(&self) -> gio::ListModel {
        self.inner.model.rows()
    }

    /// Every schema, in list order, each over its tables and the ones the
    /// search finds.
    pub(crate) fn schemas(&self) -> gio::ListModel {
        self.inner.model.schemas()
    }

    /// The table actions its menus name, for the tree's menus to reach.
    pub(crate) fn actions(&self) -> &gio::SimpleActionGroup {
        &self.inner.actions
    }

    pub(crate) fn affordances(&self) -> SidebarAffordances {
        self.inner.affordances.get()
    }

    /// A reconnect can reach a server that edits less; the menus offer
    /// what it does from their next opening.
    pub(crate) fn set_affordances(&self, affordances: SidebarAffordances) {
        self.inner.affordances.set(affordances);
    }

    pub(crate) fn holds(&self) -> Holds {
        self.inner.holds.get()
    }

    /// Name what the list holds as a document engine's collections.
    pub(crate) fn hold_collections(&self) {
        self.inner.holds.set(Holds::Collections);
        self.inner
            .model
            .name_placeholder(&crate::i18n::gettext("No Collections"));
    }

    /// List a key-value engine's keys from now on. Its server matches the
    /// search, so a new search asks `relist` for a new listing.
    pub(crate) fn hold_keys(&self, relist: impl Fn() + 'static) {
        self.inner.holds.set(Holds::Keys);
        self.inner.relist.replace(Some(Box::new(relist)));
        self.inner.model.name_placeholder(&crate::i18n::gettext("No Keys"));
    }

    /// Show a new object list under the search, once its rows are worked
    /// out.
    pub(crate) fn show(&self, index: SidebarIndex) {
        let asked = self.inner.model.replace(index);
        work_out_rows(&self.inner, asked);
    }

    /// Show the keys a listing found, `searched` when the server matched
    /// them against the search: then every one is a result.
    pub(crate) fn show_keys(&self, index: SidebarIndex, searched: bool) {
        self.inner
            .model
            .hold_search(if searched { Search::Everything } else { Search::None });
        self.show(index);
    }

    /// The search typed. A key-value engine's server is asked for the
    /// keys that match it, so the tree gives it only while its branch
    /// follows the search.
    pub(crate) fn set_query(&self, query: &str) {
        if self.holds() == Holds::Keys {
            let query = query.trim();
            if *self.inner.key_search.borrow() == query {
                return;
            }
            self.inner.key_search.replace(query.to_owned());
            if let Some(relist) = self.inner.relist.borrow().as_ref() {
                relist();
            }
            return;
        }
        if let Some(asked) = self.inner.model.set_query(query) {
            work_out_rows(&self.inner, asked);
        }
    }

    /// What the next listing of keys asks the server to match.
    pub(crate) fn key_search(&self) -> String {
        self.inner.key_search.borrow().clone()
    }

    /// Open `table` in its tab, or a new one.
    pub(crate) fn open(&self, table: TableRef) {
        (self.inner.events)(SidebarEvent::Open(table));
    }

    pub(crate) fn open_in_new_tab(&self, table: TableRef) {
        (self.inner.events)(SidebarEvent::OpenInNewTab(table));
    }

    /// Whether the session lists `table`, searched for or not.
    pub(crate) fn lists(&self, table: &TableRef) -> bool {
        self.inner.model.kind_of(table).is_some()
    }

    /// The schema whose tables hold `table`, and where among them.
    pub(crate) fn locate(&self, table: &TableRef) -> Option<(TreeNode, u32)> {
        self.inner.model.locate(table)
    }

    /// The schema whose tables the search found hold `table`, and where
    /// among them.
    pub(crate) fn locate_found(&self, table: &TableRef) -> Option<(TreeNode, u32)> {
        self.inner.model.locate_found(table)
    }

    /// Whether the rows on show are the ones last asked for. A key-value
    /// engine's listing runs in the workspace, which shows it once read.
    pub(crate) fn settled(&self) -> bool {
        self.inner.model.settled()
    }

    /// Run `observer` each time a list or a search's rows land.
    pub(crate) fn connect_rows_shown(&self, observer: impl Fn() + 'static) -> RowsObserverId {
        let id = self.inner.next_observer.get();
        self.inner.next_observer.set(id + 1);
        self.inner.observers.borrow_mut().push((id, Rc::new(observer)));
        RowsObserverId(id)
    }

    pub(crate) fn disconnect_rows_shown(&self, id: RowsObserverId) {
        self.inner
            .observers
            .borrow_mut()
            .retain(|(observer, _)| *observer != id.0);
    }

    /// Let go of the tree and the workspace, which outlive nothing here.
    pub(crate) fn shutdown(&self) {
        self.inner.observers.take();
        self.inner.relist.take();
    }
}

impl SidebarInner {
    /// Run a table action whose target came through GAction: a target of
    /// the wrong shape, or for a table the list no longer has, does
    /// nothing.
    fn act_on(&self, action: &str, target: Option<&glib::Variant>) {
        let Some(ObjectKey(table)) = target.and_then(ObjectKey::from_variant) else {
            tracing::warn!(action, "a sidebar action came without a table");
            return;
        };
        let Some(kind) = self.model.kind_of(&table) else {
            tracing::warn!(action, "a sidebar action named a table the list no longer has");
            return;
        };
        if !offers(action, kind, self.affordances.get()) {
            tracing::warn!(action, "a sidebar action the table or the connection does not offer");
            return;
        }
        let event = match action {
            OPEN_IN_NEW_TAB => SidebarEvent::OpenInNewTab(table),
            EDIT_STRUCTURE => SidebarEvent::EditStructure(table),
            SHOW_CREATE_TABLE => SidebarEvent::ShowCreateTable(table),
            IMPORT_CSV => SidebarEvent::ImportCsv(table),
            DROP_TABLE => SidebarEvent::DropTable(table),
            SHOW_DIAGRAM => SidebarEvent::ShowDiagram(table.schema),
            _ => return,
        };
        (self.events)(event);
    }

    fn new_table(&self, target: Option<&glib::Variant>) {
        let Some(schema) = target.and_then(|target| target.get::<Option<String>>()) else {
            tracing::warn!("a new table was asked for without a schema");
            return;
        };
        if !self.affordances.get().offers_new_table() {
            return;
        }
        (self.events)(SidebarEvent::NewTable(schema.filter(|schema| !schema.is_empty())));
    }

    fn show_schema_diagram(&self, target: Option<&glib::Variant>) {
        let Some(schema) = target.and_then(|target| target.get::<Option<String>>()) else {
            tracing::warn!("a diagram was asked for without a schema");
            return;
        };
        if !self.affordances.get().speaks_sql || self.holds.get() == Holds::Keys {
            return;
        }
        (self.events)(SidebarEvent::ShowDiagram(schema.filter(|schema| !schema.is_empty())));
    }

    fn show_rows(&self, worked_out: RowsWorkedOut) {
        let previous = match self.model.show(worked_out) {
            Ok(previous) => previous,
            Err(overtaken) => {
                self.release(overtaken);
                return;
            }
        };
        let observers: Vec<RowsObserver> = self
            .observers
            .borrow()
            .iter()
            .map(|(_, observer)| observer.clone())
            .collect();
        for observer in observers {
            observer();
        }
        // After the observers: the tree lets go of the lists of what an
        // older search found, which hold the index too.
        if !Arc::ptr_eq(&previous, &self.model.shown_index()) {
            self.release(previous);
        }
    }

    /// Let go of what may hold the last reference to an index on the
    /// blocking threads: an index frees a few strings per table, which
    /// takes a catalog of 50,000 longer than a frame.
    fn release(&self, unused: impl Send + 'static) {
        if let Some(tasks) = self.tasks.as_ref() {
            drop(tasks.spawn_blocking_task(move || drop(unused)));
        }
    }
}

/// Work out the rows on the blocking threads, then show them unless a
/// newer index or search overtook them.
fn work_out_rows(inner: &Rc<SidebarInner>, asked: RowsAsked) {
    let Some(tasks) = inner.tasks.as_ref() else {
        inner.show_rows(asked.work_out());
        return;
    };
    let working = tasks.spawn_blocking_task(move || asked.work_out());
    let view = Rc::downgrade(inner);
    glib::spawn_future_local(async move {
        match working.await {
            Ok(worked_out) => {
                if let Some(view) = view.upgrade() {
                    view.show_rows(worked_out);
                }
            }
            Err(failure) => tracing::debug!(%failure, "the sidebar's rows were not worked out"),
        }
    });
}

fn install_actions(inner: &Rc<SidebarInner>) {
    for name in [
        OPEN_IN_NEW_TAB,
        SHOW_DIAGRAM,
        EDIT_STRUCTURE,
        SHOW_CREATE_TABLE,
        IMPORT_CSV,
        DROP_TABLE,
    ] {
        let action = gio::SimpleAction::new(name, Some(&ObjectKey::variant_type()));
        let view = Rc::downgrade(inner);
        action.connect_activate(move |_, target| {
            if let Some(view) = view.upgrade() {
                view.act_on(name, target);
            }
        });
        inner.actions.add_action(&action);
    }
    let new_table = gio::SimpleAction::new(NEW_TABLE, Some(&Option::<String>::static_variant_type()));
    let view = Rc::downgrade(inner);
    new_table.connect_activate(move |_, target| {
        if let Some(view) = view.upgrade() {
            view.new_table(target);
        }
    });
    inner.actions.add_action(&new_table);
    let diagram = gio::SimpleAction::new(SHOW_SCHEMA_DIAGRAM, Some(&Option::<String>::static_variant_type()));
    let view = Rc::downgrade(inner);
    diagram.connect_activate(move |_, target| {
        if let Some(view) = view.upgrade() {
            view.show_schema_diagram(target);
        }
    });
    inner.actions.add_action(&diagram);
}
