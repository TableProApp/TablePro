//! The saved connections every picker shows, as one list model that
//! follows the connection store.

use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};
use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_storage::{ConnectionListState, ConnectionStore, SavedConnection};
use uuid::Uuid;

use super::saved_connection_object::SavedConnectionObject;
use super::saved_connection_order;

type StateObserver = Rc<dyn Fn(&ConnectionListState)>;

/// One model for every window. Each store write publishes a new list,
/// so a save in the connect dialog, a connect's last-opened stamp, a
/// delete or an edit reaches every picker without anyone asking.
pub struct SavedConnectionList {
    store: gio::ListStore,
    /// The last list the store had ready, in display order. A list that
    /// cannot be read keeps it, as the rows do.
    connections: RefCell<Arc<[SavedConnection]>>,
    state: RefCell<ConnectionListState>,
    watch: RefCell<Option<glib::JoinHandle<()>>>,
    observers: RefCell<Vec<(u64, StateObserver)>>,
    next_observer: Cell<u64>,
}

/// What `connect_state_changed` returns, to disconnect with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StateObserverId(u64);

impl SavedConnectionList {
    /// Follow `connections` from its list now. The watch runs on the GTK
    /// thread and polls nothing but the store's channel, and it ends
    /// with the store or with this list.
    pub fn follow(connections: &ConnectionStore) -> Rc<Self> {
        let mut receiver = connections.subscribe();
        let current = receiver.borrow_and_update().state.clone();
        let list = Rc::new(Self {
            store: gio::ListStore::new::<SavedConnectionObject>(),
            connections: RefCell::new(Arc::from([])),
            state: RefCell::new(ConnectionListState::Loading),
            watch: RefCell::new(None),
            observers: RefCell::new(Vec::new()),
            next_observer: Cell::new(0),
        });
        list.apply(current);
        let following: Weak<Self> = Rc::downgrade(&list);
        let watch = glib::spawn_future_local(async move {
            while receiver.changed().await.is_ok() {
                let state = receiver.borrow_and_update().state.clone();
                let Some(list) = following.upgrade() else {
                    return;
                };
                list.apply(state);
            }
        });
        list.watch.replace(Some(watch));
        list
    }

    pub fn model(&self) -> gio::ListModel {
        self.store.clone().upcast()
    }

    pub fn state(&self) -> ConnectionListState {
        self.state.borrow().clone()
    }

    /// The saved connection `id` as the list holds it now.
    pub fn get(&self, id: Uuid) -> Option<SavedConnection> {
        self.connections.borrow().iter().find(|saved| saved.id == id).cloned()
    }

    /// Every saved connection, in display order.
    pub fn connections(&self) -> Arc<[SavedConnection]> {
        self.connections.borrow().clone()
    }

    /// The groups the list files connections under, in display order.
    pub fn groups(&self) -> Vec<String> {
        saved_connection_order::groups(&self.connections.borrow())
    }

    /// Run `observer` on every state the store publishes, as the banner
    /// that says the list cannot be read needs.
    pub fn connect_state_changed(&self, observer: impl Fn(&ConnectionListState) + 'static) -> StateObserverId {
        let id = self.next_observer.get();
        self.next_observer.set(id + 1);
        self.observers.borrow_mut().push((id, Rc::new(observer)));
        StateObserverId(id)
    }

    pub fn disconnect_state_changed(&self, id: StateObserverId) {
        self.observers.borrow_mut().retain(|(observer, _)| *observer != id.0);
    }

    /// A ready list replaces every row in one splice. A list that is
    /// loading or cannot be read keeps the rows it had, and only its
    /// state changes, for the banner.
    pub(crate) fn apply(&self, state: ConnectionListState) {
        // The state first: the rows the splice builds read it.
        self.state.replace(state.clone());
        if let ConnectionListState::Ready(list) = &state {
            let mut sorted = list.to_vec();
            saved_connection_order::sort(&mut sorted);
            let objects: Vec<SavedConnectionObject> = sorted.iter().cloned().map(SavedConnectionObject::new).collect();
            self.connections.replace(Arc::from(sorted));
            self.store.splice(0, self.store.n_items(), &objects);
        }
        let observers: Vec<StateObserver> = self
            .observers
            .borrow()
            .iter()
            .map(|(_, observer)| observer.clone())
            .collect();
        for observer in observers {
            observer(&state);
        }
    }
}

impl Drop for SavedConnectionList {
    fn drop(&mut self) {
        if let Some(watch) = self.watch.take() {
            watch.abort();
        }
    }
}

impl std::fmt::Debug for SavedConnectionList {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SavedConnectionList")
            .field("rows", &self.store.n_items())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_storage::{DocumentProblem, DocumentProblemKind, StoragePaths};

    use super::*;
    use crate::test_support::wait_until;

    const WAIT: Duration = Duration::from_secs(10);

    fn connection(name: &str) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: name.to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db".to_owned(),
            port: 5432,
            database: "app".to_owned(),
            username: "postgres".to_owned(),
            tls: tablepro_core::TlsConfig::verify_full(),
            read_only: false,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
        }
    }

    fn names(list: &SavedConnectionList) -> Vec<String> {
        let model = list.model();
        (0..model.n_items())
            .filter_map(|position| model.item(position).and_downcast::<SavedConnectionObject>())
            .map(|object| object.name())
            .collect()
    }

    #[gtk4::test]
    fn a_write_to_the_store_reaches_the_list() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store);
        assert!(matches!(list.state(), ConnectionListState::Loading));
        let corp = connection("Corp");

        store.upsert_blocking(corp.clone()).expect("the write");

        wait_until(WAIT, || names(&list) == ["Corp"]).expect("the new row");
        assert_eq!(list.get(corp.id).map(|saved| saved.name), Some("Corp".to_owned()));
        store.remove_blocking(corp.id).expect("the delete");
        wait_until(WAIT, || names(&list).is_empty()).expect("the row to go");
        assert_eq!(list.get(corp.id), None);
    }

    #[gtk4::test]
    fn unreadable_list_keeps_rows_and_reports_its_state() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store);
        let seen = Rc::new(RefCell::new(Vec::new()));
        let sink = seen.clone();
        let observer = list.connect_state_changed(move |state| {
            sink.borrow_mut()
                .push(matches!(state, ConnectionListState::Unavailable(_)));
        });
        let corp = connection("Corp");
        list.apply(ConnectionListState::Ready(Arc::from([corp.clone()])));

        list.apply(ConnectionListState::Unavailable(Arc::new(DocumentProblem::new(
            "/tmp/connections.json",
            DocumentProblemKind::Unreadable {
                detail: "denied".to_owned(),
            },
        ))));

        assert_eq!(names(&list), ["Corp"], "an unreadable list emptied the picker");
        assert_eq!(list.get(corp.id).map(|saved| saved.id), Some(corp.id));
        assert!(matches!(list.state(), ConnectionListState::Unavailable(_)));
        assert_eq!(*seen.borrow(), [false, true]);
        list.disconnect_state_changed(observer);
        list.apply(ConnectionListState::Loading);
        assert_eq!(seen.borrow().len(), 2, "a disconnected observer still ran");
    }

    #[gtk4::test]
    fn a_dropped_list_stops_following() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store);
        let model = list.model();

        drop(list);
        store.upsert_blocking(connection("Corp")).expect("the write");
        crate::test_support::drain_main_context();

        assert_eq!(model.n_items(), 0, "a dropped list still followed the store");
    }
}
