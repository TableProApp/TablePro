//! The saved connections every picker shows, as one list model that
//! follows the connection store.

use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::{Rc, Weak};
use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_core::DriverRegistry;
use tablepro_storage::{
    ConnectionGroup, ConnectionList, ConnectionListState, ConnectionStore, ConnectionTag, SavedConnection,
};
use uuid::Uuid;

use super::library_outline::{LibraryItem, LibraryOutline};
use super::saved_connection_object::SavedConnectionObject;
use super::saved_connection_order::{self, GroupLabels};

type StateObserver = Rc<dyn Fn(&ConnectionListState)>;

/// One model for every window. Each store write publishes a new list,
/// so a save in the connect dialog, a connect's last-opened stamp, a
/// delete or an edit reaches every picker without anyone asking.
pub struct SavedConnectionList {
    store: gio::ListStore,
    /// Says which connections open a file, which their rows name.
    drivers: Arc<DriverRegistry>,
    /// The last list the store had ready, in display order. A list that
    /// cannot be read keeps it, as the rows do.
    connections: RefCell<Arc<[SavedConnection]>>,
    /// The tags of that list, by name.
    tags: RefCell<Arc<[ConnectionTag]>>,
    labels: RefCell<GroupLabels>,
    library: RefCell<Option<ConnectionList>>,
    outline: RefCell<Rc<LibraryOutline>>,
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
    pub fn follow(connections: &ConnectionStore, drivers: Arc<DriverRegistry>) -> Rc<Self> {
        let mut receiver = connections.subscribe();
        let current = receiver.borrow_and_update().state.clone();
        let list = Rc::new(Self {
            store: gio::ListStore::new::<SavedConnectionObject>(),
            drivers,
            connections: RefCell::new(Arc::from([])),
            tags: RefCell::new(Arc::from([])),
            labels: RefCell::new(GroupLabels::default()),
            library: RefCell::new(None),
            outline: RefCell::new(Rc::new(LibraryOutline::new(&ConnectionList::default()))),
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

    /// Every tag, by name.
    pub fn tags(&self) -> Arc<[ConnectionTag]> {
        self.tags.borrow().clone()
    }

    pub fn library(&self) -> Option<ConnectionList> {
        self.library.borrow().clone()
    }

    pub(crate) fn outline(&self) -> Rc<LibraryOutline> {
        self.outline.borrow().clone()
    }

    pub fn group(&self, id: Uuid) -> Option<ConnectionGroup> {
        self.outline.borrow().group(id).cloned()
    }

    pub fn is_favourite(&self, id: Uuid) -> bool {
        self.outline.borrow().favourites().contains(&id)
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

    // Keeps the objects of unchanged connections, so a write from another window leaves a row's menu and focus alone.
    pub(crate) fn apply(&self, state: ConnectionListState) {
        // The state first: the rows the splice builds read it.
        self.state.replace(state.clone());
        if let ConnectionListState::Ready(list) = &state {
            let outline = Rc::new(LibraryOutline::new(list));
            let labels = GroupLabels::new(&list.groups);
            let ordered: Arc<[SavedConnection]> = Arc::from(in_tree_order(list, &outline));
            let mut tags = list.tags.to_vec();
            saved_connection_order::sort_tags(&mut tags);
            // Every row's menu offers the groups and shows the tags, so a change to either rebuilds every row.
            let regrouped = labels != *self.labels.borrow();
            let retagged = *tags != **self.tags.borrow();
            self.connections.replace(ordered.clone());
            self.tags.replace(Arc::from(tags));
            self.labels.replace(labels);
            self.library.replace(Some(list.clone()));
            self.outline.replace(outline);
            if regrouped || retagged || self.store.n_items() == 0 {
                let objects: Vec<SavedConnectionObject> = ordered.iter().map(|saved| self.object(saved)).collect();
                self.store.splice(0, self.store.n_items(), &objects);
            } else {
                let labels = self.labels.borrow();
                patch(&self.store, &ordered, &labels, |saved| self.object(saved));
            }
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

impl SavedConnectionList {
    fn object(&self, saved: &SavedConnection) -> SavedConnectionObject {
        let file_based = self
            .drivers
            .get(&saved.driver_id)
            .is_some_and(|driver| driver.capabilities().is_file_based());
        let label = self.labels.borrow().of(saved).map(str::to_owned);
        SavedConnectionObject::new(saved.clone(), label, file_based)
    }
}

fn patch(
    store: &gio::ListStore,
    wanted: &[SavedConnection],
    labels: &GroupLabels,
    object: impl Fn(&SavedConnection) -> SavedConnectionObject,
) {
    let mut position = 0;
    for saved in wanted {
        let kept = (position..store.n_items()).find(|&at| {
            store
                .item(at)
                .and_downcast::<SavedConnectionObject>()
                .is_some_and(|object| {
                    object.saved().is_some_and(|held| unchanged(held, saved))
                        && object.group().as_deref() == labels.of(saved)
                })
        });
        match kept {
            Some(at) if at > position => store.splice(position, at - position, &[] as &[SavedConnectionObject]),
            Some(_) => {}
            None => store.insert(position, &object(saved)),
        }
        position += 1;
    }
    let extra = store.n_items().saturating_sub(position);
    if extra > 0 {
        store.splice(position, extra, &[] as &[SavedConnectionObject]);
    }
}

// Every write numbers a group's connections from 0 again, and a row does not show the number.
fn unchanged(held: &SavedConnection, wanted: &SavedConnection) -> bool {
    held.id == wanted.id
        && SavedConnection {
            order: wanted.order,
            ..held.clone()
        } == *wanted
}

// Depth first, each group's subgroups before its connections, then the top level's connections.
fn in_tree_order(list: &ConnectionList, outline: &LibraryOutline) -> Vec<SavedConnection> {
    let mut ordered = Vec::with_capacity(list.connections.len());
    let mut listed = HashSet::with_capacity(list.connections.len());
    let mut pending: Vec<LibraryItem> = outline.children(None).into_iter().rev().collect();
    while let Some(item) = pending.pop() {
        match item {
            LibraryItem::Group(id) => pending.extend(outline.children(Some(id)).into_iter().rev()),
            LibraryItem::Connection(id) => {
                if let Some(saved) = outline.connection(id)
                    && listed.insert(id)
                {
                    ordered.push(saved.clone());
                }
            }
        }
    }
    // Only a list built by hand files a connection under a group it lacks; the store clears such a group.
    ordered.extend(list.connections.iter().filter(|saved| listed.insert(saved.id)).cloned());
    ordered
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
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            query_timeout_secs: None,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group_id: None,
            order: 0,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    fn objects(list: &SavedConnectionList) -> Vec<SavedConnectionObject> {
        let model = list.model();
        (0..model.n_items())
            .filter_map(|position| model.item(position).and_downcast::<SavedConnectionObject>())
            .collect()
    }

    fn group_labels(list: &SavedConnectionList) -> Vec<String> {
        list.outline().groups().into_iter().map(|(_, label, _)| label).collect()
    }

    fn names(list: &SavedConnectionList) -> Vec<String> {
        objects(list).iter().map(|object| object.name()).collect()
    }

    fn ready(connections: &[SavedConnection]) -> ConnectionListState {
        ConnectionListState::Ready(crate::test_support::library(connections.to_vec(), Vec::new()))
    }

    #[gtk4::test]
    fn a_write_to_the_store_reaches_the_list() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
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
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let seen = Rc::new(RefCell::new(Vec::new()));
        let sink = seen.clone();
        let observer = list.connect_state_changed(move |state| {
            sink.borrow_mut()
                .push(matches!(state, ConnectionListState::Unavailable(_)));
        });
        let corp = connection("Corp");
        list.apply(ready(std::slice::from_ref(&corp)));

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
    fn a_write_keeps_the_objects_of_unchanged_connections() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let (alpha, beta, gamma) = (connection("Alpha"), connection("Beta"), connection("Gamma"));
        list.apply(ready(&[alpha.clone(), beta.clone(), gamma.clone()]));
        let before = objects(&list);

        let mut stamped = gamma.clone();
        stamped.last_opened_at = Some(chrono::Utc::now());
        list.apply(ready(&[alpha.clone(), beta.clone(), stamped]));
        let after = objects(&list);

        assert_eq!(names(&list), ["Alpha", "Beta", "Gamma"], "a connect moved a row");
        assert_eq!(after[0], before[0], "the stamp rebuilt Alpha's row");
        assert_eq!(after[1], before[1], "the stamp rebuilt Beta's row");
        assert_ne!(after[2], before[2], "the stamped row shows the old connection");

        list.apply(ready(&[alpha, beta]));
        assert_eq!(objects(&list), [after[0].clone(), after[1].clone()]);
    }

    #[gtk4::test]
    fn a_renumbering_write_keeps_the_objects() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let (alpha, beta, gamma) = (connection("Alpha"), connection("Beta"), connection("Gamma"));
        for saved in [&alpha, &beta, &gamma] {
            store.upsert_blocking(saved.clone()).expect("the write");
        }
        wait_until(WAIT, || names(&list) == ["Alpha", "Beta", "Gamma"]).expect("the rows");
        let before = objects(&list);

        store.remove_blocking(alpha.id).expect("the delete");
        wait_until(WAIT, || names(&list) == ["Beta", "Gamma"]).expect("Alpha's row to go");

        assert_eq!(
            list.get(gamma.id).map(|saved| saved.order),
            Some(1),
            "the store kept Gamma's number"
        );
        assert_eq!(
            objects(&list),
            before[1..].to_vec(),
            "a renumbered connection got a new row"
        );
        store
            .move_connections_blocking(&[beta.id], None, None)
            .expect("the move");
        wait_until(WAIT, || names(&list) == ["Gamma", "Beta"]).expect("Beta to move down");
        assert_eq!(objects(&list)[0], before[2], "the renumbered Gamma got a new row");
    }

    #[gtk4::test]
    fn the_model_lists_connections_in_the_trees_order() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let mut library = crate::test_support::NestedLibrary::default();
        library.connection("Zeta", None);
        let work = library.group("Work", None);
        let staging = library.group("Staging", Some(work));
        let home = library.group("Home", None);
        library.connection("H1", Some(home));
        library.connection("W1", Some(work));
        library.connection("S1", Some(staging));
        library.connection("Alpha", None);

        list.apply(ConnectionListState::Ready(library.list()));

        assert_eq!(names(&list), ["S1", "W1", "H1", "Zeta", "Alpha"]);
        assert_eq!(list.connections().len(), 5);
    }

    #[gtk4::test]
    fn a_favourites_only_change_reaches_the_observers() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let (alpha, beta) = (connection("Alpha"), connection("Beta"));
        store.upsert_blocking(alpha.clone()).expect("the write");
        store.upsert_blocking(beta.clone()).expect("the write");
        wait_until(WAIT, || names(&list) == ["Alpha", "Beta"]).expect("the rows");
        let before = objects(&list);
        let seen = Rc::new(RefCell::new(Vec::new()));
        let sink = seen.clone();
        list.connect_state_changed(move |state| {
            if let ConnectionListState::Ready(library) = state {
                sink.borrow_mut().push(library.is_favorite(beta.id));
            }
        });

        store.add_favorites_blocking(&[beta.id], None).expect("the favourite");
        wait_until(WAIT, || list.is_favourite(beta.id)).expect("the favourite to reach the list");

        assert_eq!(seen.borrow().last(), Some(&true), "the observers missed the favourite");
        assert!(!list.is_favourite(alpha.id));
        assert_eq!(list.outline().favourites(), [beta.id]);
        assert_eq!(
            list.library().map(|library| library.favorites.to_vec()),
            Some(vec![beta.id])
        );
        assert_eq!(objects(&list), before, "a favourite rebuilt the rows");
    }

    #[gtk4::test]
    fn the_outline_shows_a_nested_empty_group() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let paths = StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID);
        let mut library = crate::test_support::NestedLibrary::default();
        let work = library.group("Work", None);
        let staging = library.group("Staging", Some(work));
        let alpha = library.connection("Alpha", None);
        library.favourite(alpha);
        library.seed(&paths);
        let store = ConnectionStore::new(&paths);
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        assert!(list.library().is_none(), "a list before the store read one");
        assert!(list.outline().is_empty());

        store.load_blocking().expect("the saved connections");
        wait_until(WAIT, || list.library().is_some()).expect("the list to be read");

        let outline = list.outline();
        assert_eq!(
            outline.children(None),
            [LibraryItem::Group(work), LibraryItem::Connection(alpha)]
        );
        assert_eq!(outline.children(Some(work)), [LibraryItem::Group(staging)]);
        assert!(outline.children(Some(staging)).is_empty());
        assert_eq!(outline.label(staging).as_deref(), Some("Work / Staging"));
        assert_eq!(list.group(staging).and_then(|group| group.parent_id), Some(work));
        assert!(list.is_favourite(alpha));
        assert_eq!(names(&list), ["Alpha"]);
    }

    #[gtk4::test]
    fn a_new_group_replaces_every_object() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let (alpha, beta) = (connection("Alpha"), connection("Beta"));
        list.apply(ready(&[alpha.clone(), beta.clone()]));
        let before = objects(&list);

        let mut filed = beta;
        filed.group_id = Some(crate::test_support::group_id("Work"));
        list.apply(ready(&[alpha, filed]));

        let after = objects(&list);
        assert_eq!(group_labels(&list), ["Work"]);
        assert_eq!(
            names(&list),
            ["Beta", "Alpha"],
            "a group's connections lead the top level's"
        );
        assert_ne!(after[1], before[0], "Alpha's menu does not offer the new group");
    }

    #[gtk4::test]
    fn a_nested_group_reads_by_its_path_and_a_renamed_parent_renames_it() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let work = tablepro_storage::ConnectionGroup::new(
            tablepro_storage::ConnectionGroupName::new("Work").expect("a group name"),
            None,
        );
        let staging = tablepro_storage::ConnectionGroup::new(
            tablepro_storage::ConnectionGroupName::new("Staging").expect("a group name"),
            Some(work.id),
        );
        let alpha = SavedConnection {
            group_id: Some(staging.id),
            ..connection("Alpha")
        };
        let state = |work: &tablepro_storage::ConnectionGroup| {
            ConnectionListState::Ready(
                tablepro_storage::ConnectionList::new(vec![alpha.clone()], Vec::new())
                    .with_groups(vec![work.clone(), staging.clone()]),
            )
        };
        list.apply(state(&work));
        let before = objects(&list);

        assert_eq!(group_labels(&list), ["Work", "Work / Staging"]);
        assert_eq!(before[0].group().as_deref(), Some("Work / Staging"));
        let renamed = tablepro_storage::ConnectionGroup {
            name: tablepro_storage::ConnectionGroupName::new("Office").expect("a group name"),
            ..work.clone()
        };
        list.apply(state(&renamed));

        assert_eq!(group_labels(&list), ["Office", "Office / Staging"]);
        assert_eq!(objects(&list)[0].group().as_deref(), Some("Office / Staging"));
    }

    #[gtk4::test]
    fn a_changed_tag_replaces_every_object_and_the_tags_read_by_name() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let (alpha, beta) = (connection("Alpha"), connection("Beta"));
        let name = |name: &str| tablepro_storage::ConnectionTagName::new(name).expect("a tag name");
        let zeta = ConnectionTag::new(name("zeta"), tablepro_storage::ConnectionColor::Red);
        let acme = ConnectionTag::new(name("Acme"), tablepro_storage::ConnectionColor::Blue);
        let tagged = |tags: Vec<ConnectionTag>| {
            ConnectionListState::Ready(tablepro_storage::ConnectionList::new(
                vec![alpha.clone(), beta.clone()],
                tags,
            ))
        };
        list.apply(tagged(vec![zeta.clone(), acme.clone()]));
        let before = objects(&list);

        assert_eq!(list.tags().to_vec(), vec![acme.clone(), zeta.clone()]);
        list.apply(tagged(vec![zeta.clone(), acme.clone()]));
        assert_eq!(objects(&list), before, "an unchanged tag list rebuilt the rows");

        let recoloured = ConnectionTag {
            color: tablepro_storage::ConnectionColor::Green,
            ..zeta
        };
        list.apply(tagged(vec![recoloured, acme]));
        assert_ne!(objects(&list)[0], before[0], "a recoloured tag left a row as it was");
    }

    #[gtk4::test]
    fn a_dropped_list_stops_following() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let model = list.model();

        drop(list);
        store.upsert_blocking(connection("Corp")).expect("the write");
        crate::test_support::drain_main_context();

        assert_eq!(model.n_items(), 0, "a dropped list still followed the store");
    }
}
