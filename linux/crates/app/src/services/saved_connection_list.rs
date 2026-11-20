//! The saved connections every picker shows, as one list model that
//! follows the connection store and the active project.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeSet, HashSet};
use std::rc::{Rc, Weak};
use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_core::DriverRegistry;
use tablepro_storage::{
    ConnectionGroup, ConnectionList, ConnectionListState, ConnectionProject, ConnectionStore, ConnectionTag,
    SavedConnection,
};
use uuid::Uuid;

use super::library_outline::{LibraryItem, LibraryOutline};
use super::saved_connection_object::SavedConnectionObject;
use super::saved_connection_order::{self, GroupLabels};

type StateObserver = Rc<dyn Fn(&ConnectionListState)>;
type ScopeObserver = Rc<dyn Fn()>;

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
    // The project the setting names, which the list may no longer hold.
    active: Cell<Option<Uuid>>,
    // What the pickers list: the active project's part of the library.
    outline: RefCell<Rc<LibraryOutline>>,
    listed: RefCell<Arc<[SavedConnection]>>,
    // The whole library, for lookups by id whatever the project.
    whole: RefCell<Rc<LibraryOutline>>,
    state: RefCell<ConnectionListState>,
    watch: RefCell<Option<glib::JoinHandle<()>>>,
    observers: RefCell<Vec<(u64, StateObserver)>>,
    // What the scope observers were last told of.
    scoped: RefCell<ScopedSet>,
    scope_observers: RefCell<Vec<(u64, ScopeObserver)>>,
    next_observer: Cell<u64>,
}

// The project also when the ids match: two empty projects list the same nothing under different names.
#[derive(Debug, Default, PartialEq, Eq)]
struct ScopedSet {
    project: Option<(Uuid, String)>,
    connections: BTreeSet<Uuid>,
}

// The active project as the lists keyed by connection id read it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectScope {
    pub name: String,
    pub connections: Vec<Uuid>,
}

impl ProjectScope {
    // The presenting window's own connection is listed whatever its project, as its tab title is.
    #[must_use]
    pub fn with(mut self, connection: Option<Uuid>) -> Self {
        if let Some(id) = connection
            && !self.connections.contains(&id)
        {
            self.connections.push(id);
        }
        self
    }
}

/// What `connect_state_changed` returns, to disconnect with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StateObserverId(u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScopeObserverId(u64);

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
            active: Cell::new(None),
            outline: RefCell::new(Rc::new(LibraryOutline::new(&ConnectionList::default()))),
            listed: RefCell::new(Arc::from([])),
            whole: RefCell::new(Rc::new(LibraryOutline::new(&ConnectionList::default()))),
            state: RefCell::new(ConnectionListState::Loading),
            watch: RefCell::new(None),
            observers: RefCell::new(Vec::new()),
            scoped: RefCell::new(ScopedSet::default()),
            scope_observers: RefCell::new(Vec::new()),
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

    // In any project: an open tab, a restored session and a link name a connection by id.
    pub fn get(&self, id: Uuid) -> Option<SavedConnection> {
        self.whole.borrow().connection(id).cloned()
    }

    // Every saved connection of every project, in display order.
    pub fn connections(&self) -> Arc<[SavedConnection]> {
        self.connections.borrow().clone()
    }

    // The active project's connections, in display order.
    pub fn listed(&self) -> Arc<[SavedConnection]> {
        self.listed.borrow().clone()
    }

    // `None` is All Connections, also once the project the setting names is deleted.
    pub fn active_project(&self) -> Option<ConnectionProject> {
        let library = self.library.borrow();
        let library = library.as_ref()?;
        library
            .resolved_scope(self.active.get())
            .and_then(|id| library.project(id).cloned())
    }

    pub fn projects(&self) -> Vec<ConnectionProject> {
        self.library
            .borrow()
            .as_ref()
            .map(|library| library.projects_in_order().into_iter().cloned().collect())
            .unwrap_or_default()
    }

    // What history and saved queries are narrowed to; `None` in All Connections, which also shows deleted connections' rows.
    pub fn scope(&self) -> Option<ProjectScope> {
        let project = self.active_project()?;
        Some(ProjectScope {
            name: project.name.as_str().to_owned(),
            connections: self.listed.borrow().iter().map(|saved| saved.id).collect(),
        })
    }

    pub fn project_of(&self, connection: Uuid) -> Option<Uuid> {
        let library = self.library.borrow();
        let library = library.as_ref()?;
        let saved = library.connections.iter().find(|saved| saved.id == connection)?;
        library.effective_project(saved)
    }

    pub fn project_of_group(&self, group: Uuid) -> Option<Uuid> {
        self.library
            .borrow()
            .as_ref()
            .and_then(|library| library.effective_group_project(group))
    }

    pub fn group_label(&self, saved: &SavedConnection) -> Option<String> {
        self.labels.borrow().of(saved).map(str::to_owned)
    }

    // Follows the setting; a project the list does not hold yet applies once it does.
    pub fn set_active_project(&self, project: Option<Uuid>) {
        if self.active.replace(project) == project {
            return;
        }
        let library = self.library.borrow().clone();
        if let Some(library) = library {
            let ordered = self.connections.borrow().clone();
            self.rescope(&library, &ordered);
        }
        self.notify_scope();
    }

    /// Every tag, by name.
    pub fn tags(&self) -> Arc<[ConnectionTag]> {
        self.tags.borrow().clone()
    }

    pub fn library(&self) -> Option<ConnectionList> {
        self.library.borrow().clone()
    }

    // The active project's part of the library; a write still names its items by id in the whole one.
    pub(crate) fn outline(&self) -> Rc<LibraryOutline> {
        self.outline.borrow().clone()
    }

    #[cfg(test)]
    pub(crate) fn whole(&self) -> Rc<LibraryOutline> {
        self.whole.borrow().clone()
    }

    pub fn group(&self, id: Uuid) -> Option<ConnectionGroup> {
        self.whole.borrow().group(id).cloned()
    }

    pub fn is_favourite(&self, id: Uuid) -> bool {
        self.whole.borrow().favourites().contains(&id)
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

    // The one signal for scope: a switch, a move, a delete or an import that changes what is listed.
    pub fn connect_scope_changed(&self, observer: impl Fn() + 'static) -> ScopeObserverId {
        let id = self.next_observer.get();
        self.next_observer.set(id + 1);
        self.scope_observers.borrow_mut().push((id, Rc::new(observer)));
        ScopeObserverId(id)
    }

    pub fn disconnect_scope_changed(&self, id: ScopeObserverId) {
        self.scope_observers
            .borrow_mut()
            .retain(|(observer, _)| *observer != id.0);
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
            self.whole.replace(outline);
            self.rescope(list, &ordered);
            if regrouped || retagged || self.store.n_items() == 0 {
                let objects: Vec<SavedConnectionObject> = ordered.iter().map(|saved| self.object(saved)).collect();
                self.store.splice(0, self.store.n_items(), &objects);
            } else {
                let labels = self.labels.borrow();
                patch(&self.store, &ordered, &labels, |saved| self.object(saved));
            }
        }
        self.notify();
        self.notify_scope();
    }
}

impl SavedConnectionList {
    fn rescope(&self, list: &ConnectionList, ordered: &Arc<[SavedConnection]>) {
        let Some(project) = list.resolved_scope(self.active.get()) else {
            self.outline.replace(self.whole.borrow().clone());
            self.listed.replace(ordered.clone());
            return;
        };
        let outline = Rc::new(LibraryOutline::of_project(list, project));
        self.listed.replace(Arc::from(in_tree_order(outline.list(), &outline)));
        self.outline.replace(outline);
    }

    fn notify(&self) {
        let state = self.state.borrow().clone();
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

    // An edit that leaves the listed ids alone tells no one, so an open dialog keeps its place.
    fn notify_scope(&self) {
        let scoped = ScopedSet {
            project: self
                .active_project()
                .map(|project| (project.id, project.name.as_str().to_owned())),
            connections: self.listed.borrow().iter().map(|saved| saved.id).collect(),
        };
        if *self.scoped.borrow() == scoped {
            return;
        }
        self.scoped.replace(scoped);
        let observers: Vec<ScopeObserver> = self
            .scope_observers
            .borrow()
            .iter()
            .map(|(_, observer)| observer.clone())
            .collect();
        for observer in observers {
            observer();
        }
    }

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
            project_id: None,
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

    fn project(name: &str, order: u32) -> ConnectionProject {
        ConnectionProject {
            order,
            ..ConnectionProject::new(tablepro_storage::ConnectionProjectName::new(name).expect("a project name"))
        }
    }

    // Acme holds the group Work with W1 and the loose A1; Side holds S1; N1 is in no project.
    fn projects() -> (
        ConnectionList,
        ConnectionProject,
        ConnectionProject,
        [SavedConnection; 4],
    ) {
        let (acme, side) = (project("Acme", 1), project("Side", 0));
        let work = ConnectionGroup {
            project_id: Some(acme.id),
            ..ConnectionGroup::new(
                tablepro_storage::ConnectionGroupName::new("Work").expect("a group name"),
                None,
            )
        };
        let w1 = SavedConnection {
            group_id: Some(work.id),
            ..connection("W1")
        };
        let a1 = SavedConnection {
            project_id: Some(acme.id),
            ..connection("A1")
        };
        let s1 = SavedConnection {
            project_id: Some(side.id),
            order: 1,
            ..connection("S1")
        };
        let n1 = SavedConnection {
            order: 2,
            ..connection("N1")
        };
        let list = ConnectionList::new(vec![w1.clone(), a1.clone(), s1.clone(), n1.clone()], Vec::new())
            .with_groups(vec![work])
            .with_favorites(vec![s1.id, a1.id])
            .with_projects(vec![acme.clone(), side.clone()]);
        (list, acme, side, [w1, a1, s1, n1])
    }

    fn listed(list: &SavedConnectionList) -> Vec<String> {
        list.listed().iter().map(|saved| saved.name.clone()).collect()
    }

    #[gtk4::test]
    fn the_outline_is_the_active_projects_and_the_lookup_by_id_is_every_projects() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let (library, acme, side, [w1, a1, s1, n1]) = projects();
        list.apply(ConnectionListState::Ready(library));
        assert_eq!(listed(&list), ["W1", "A1", "S1", "N1"]);
        assert_eq!(list.active_project(), None);
        assert_eq!(list.scope(), None);
        assert_eq!(
            list.projects()
                .iter()
                .map(|project| project.name.as_str().to_owned())
                .collect::<Vec<_>>(),
            ["Side", "Acme"],
            "the projects are not in their order"
        );
        let before = objects(&list);

        list.set_active_project(Some(acme.id));

        assert_eq!(list.active_project(), Some(acme.clone()));
        assert_eq!(listed(&list), ["W1", "A1"]);
        assert_eq!(group_labels(&list), ["Work"]);
        assert_eq!(list.outline().favourites(), [a1.id]);
        assert_eq!(list.outline().landing(), Some(acme.id));
        assert!(
            list.outline().connection(s1.id).is_none(),
            "the outline lists another project"
        );
        assert_eq!(
            list.scope(),
            Some(ProjectScope {
                name: "Acme".to_owned(),
                connections: vec![w1.id, a1.id],
            })
        );
        // By id, whatever the project: a tab title, a restored session, a link and the dedupe of an import.
        for saved in [&w1, &a1, &s1, &n1] {
            assert_eq!(list.get(saved.id).map(|held| held.id), Some(saved.id), "{}", saved.name);
        }
        assert_eq!(list.connections().len(), 4);
        assert_eq!(
            names(&list),
            ["W1", "A1", "S1", "N1"],
            "the model the sessions watch lost rows"
        );
        assert_eq!(objects(&list), before, "a switch rebuilt the rows");
        assert!(list.is_favourite(s1.id), "a favourite of another project reads as none");
        assert_eq!(list.whole().children(None).len(), 4);
        assert_eq!(
            list.project_of(w1.id),
            Some(acme.id),
            "a grouped connection has its group's project"
        );
        assert_eq!(list.project_of(s1.id), Some(side.id));
        assert_eq!(list.project_of(n1.id), None);
        assert_eq!(list.group_label(&w1).as_deref(), Some("Work"));

        list.set_active_project(Some(side.id));
        assert_eq!(listed(&list), ["S1"]);
        assert!(group_labels(&list).is_empty(), "another project's group is listed");
        list.set_active_project(None);
        assert_eq!(listed(&list), ["W1", "A1", "S1", "N1"]);
        assert_eq!(group_labels(&list), ["Work"]);
    }

    #[gtk4::test]
    fn a_switch_and_a_change_of_the_projects_reach_the_observers() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let (library, acme, side, _) = projects();
        let seen = Rc::new(Cell::new(0));
        let counted = seen.clone();
        list.connect_scope_changed(move || counted.set(counted.get() + 1));

        // Before the list is read, as at launch: the setting is applied once the project shows up.
        list.set_active_project(Some(acme.id));
        assert_eq!(list.active_project(), None);
        list.apply(ConnectionListState::Ready(library.clone()));
        assert_eq!(list.active_project().map(|project| project.id), Some(acme.id));
        let after_load = seen.get();

        list.set_active_project(Some(acme.id));
        assert_eq!(
            seen.get(),
            after_load,
            "a switch to the active project told the observers"
        );
        list.set_active_project(Some(side.id));
        assert_eq!(seen.get(), after_load + 1);

        // Deleted here or by another window: the setting still names it, and the list falls back.
        list.apply(ConnectionListState::Ready(library.clone().with_projects(vec![acme])));
        assert_eq!(list.active_project(), None);
        assert_eq!(listed(&list).len(), 4);
        assert_eq!(seen.get(), after_load + 2, "the fallback told no one");
        list.apply(ConnectionListState::Ready(library));
        assert_eq!(seen.get(), after_load + 3);
        assert_eq!(
            list.active_project().map(|project| project.id),
            Some(side.id),
            "a project that came back is not active again"
        );
    }

    #[gtk4::test]
    fn the_scope_signal_fires_when_the_listed_ids_change_and_only_then() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let (library, acme, side, [w1, a1, s1, n1]) = projects();
        list.apply(ConnectionListState::Ready(library.clone()));
        list.set_active_project(Some(acme.id));
        let seen = Rc::new(Cell::new(0));
        let counted = seen.clone();
        let observer = list.connect_scope_changed(move || counted.set(counted.get() + 1));
        let with = |connections: Vec<SavedConnection>| {
            ConnectionListState::Ready(
                ConnectionList::new(connections, Vec::new())
                    .with_groups(library.groups.to_vec())
                    .with_projects(vec![acme.clone(), side.clone()]),
            )
        };

        // An edit inside the project and one outside it: the listed ids stand.
        let renamed = SavedConnection {
            name: "A1 renamed".to_owned(),
            ..a1.clone()
        };
        list.apply(with(vec![w1.clone(), renamed.clone(), s1.clone(), n1.clone()]));
        list.apply(with(vec![w1.clone(), renamed.clone(), s1.clone()]));
        assert_eq!(seen.get(), 0, "an edit that left the scope alone fired the signal");

        let moved = SavedConnection {
            project_id: Some(acme.id),
            ..s1.clone()
        };
        list.apply(with(vec![w1.clone(), renamed.clone(), moved.clone()]));
        assert_eq!(seen.get(), 1, "a move into the project");
        list.apply(with(vec![w1.clone(), moved.clone()]));
        assert_eq!(seen.get(), 2, "a delete inside the project");
        let ungrouped = SavedConnection {
            group_id: None,
            ..w1.clone()
        };
        list.apply(with(vec![ungrouped, moved.clone()]));
        assert_eq!(seen.get(), 3, "a connection that left the project's group");
        list.apply(with(vec![moved.clone()]));
        assert_eq!(seen.get(), 3, "a delete outside the project fired the signal");

        list.disconnect_scope_changed(observer);
        list.set_active_project(None);
        assert_eq!(seen.get(), 3, "a disconnected observer still ran");
    }

    #[gtk4::test]
    fn a_switch_between_two_empty_projects_fires_the_scope_signal() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let (one, two) = (project("One", 0), project("Two", 1));
        list.apply(ConnectionListState::Ready(
            ConnectionList::new(Vec::new(), Vec::new()).with_projects(vec![one.clone(), two.clone()]),
        ));
        list.set_active_project(Some(one.id));
        let seen = Rc::new(Cell::new(0));
        let counted = seen.clone();
        list.connect_scope_changed(move || counted.set(counted.get() + 1));

        list.set_active_project(Some(two.id));

        assert_eq!(seen.get(), 1);
    }

    #[gtk4::test]
    fn the_list_follows_the_store_inside_a_project() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        let acme = store.create_project_blocking(project("Acme", 0)).expect("the project");
        list.set_active_project(Some(acme.id));
        let (inside, outside) = (
            SavedConnection {
                project_id: Some(acme.id),
                ..connection("Inside")
            },
            connection("Outside"),
        );

        store.upsert_blocking(inside.clone()).expect("the write");
        store.upsert_blocking(outside.clone()).expect("the write");

        wait_until(WAIT, || list.get(outside.id).is_some()).expect("both connections");
        assert_eq!(listed(&list), ["Inside"]);
        store
            .move_connections_to_project_blocking(&[outside.id], Some(acme.id))
            .expect("the move");
        wait_until(WAIT, || listed(&list) == ["Inside", "Outside"]).expect("the moved connection");
        store.delete_project_blocking(acme.id).expect("the delete");
        wait_until(WAIT, || list.active_project().is_none()).expect("the fallback");
        assert_eq!(
            listed(&list),
            ["Inside", "Outside"],
            "a deleted project took its connections"
        );
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
