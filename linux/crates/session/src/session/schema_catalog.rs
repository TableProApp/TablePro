use std::collections::HashMap;
use std::hash::Hash;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use futures::FutureExt;
use futures::future::{BoxFuture, Shared};
use tablepro_core::meta::{ObjectInfo, ObjectScope, SchemaInfo};
use tablepro_core::{CallOptions, ColumnInfo, DriverError, TableRef};
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use super::ObjectListSnapshot;
use crate::link::ConnectionLease;
use crate::operation::{OperationError, OperationKind, OperationRunner};
use crate::runtime::Tasks;

type Fetched<T> = Result<Arc<[T]>, Arc<OperationError>>;
type SharedFetch<T> = Shared<BoxFuture<'static, Fetched<T>>>;

/// What the session knows about its database's schemas, objects and
/// columns, shared by every view of the window.
///
/// Callers that ask for the same thing at once share one fetch, and a
/// fetch runs as its own task, so a view that goes away does not stop
/// the read another view is waiting on. A failed read keeps what was
/// there and records the error: nothing here ever empties a list a view
/// is showing.
#[derive(Clone)]
pub struct SchemaCatalog {
    state: Arc<Mutex<CatalogState>>,
    runner: OperationRunner,
    tasks: Tasks,
}

#[derive(Default)]
struct CatalogState {
    next_fetch: u64,
    schemas: HashMap<(), Entry<SchemaInfo>>,
    objects: HashMap<ObjectScope, Entry<ObjectInfo>>,
    columns: HashMap<TableRef, Entry<ColumnInfo>>,
    watchers: HashMap<ObjectScope, watch::Sender<ObjectListSnapshot>>,
}

struct Entry<T> {
    data: Option<Arc<[T]>>,
    /// Known out of date: the next read fetches again, and the data
    /// stays until that fetch lands.
    stale: bool,
    last_error: Option<Arc<OperationError>>,
    generation: u64,
    /// Bumped by a commit or an invalidation. A fetch that began under
    /// an older epoch answers its own callers but does not land.
    epoch: u64,
    inflight: Option<Inflight<T>>,
}

impl<T> Default for Entry<T> {
    fn default() -> Self {
        Self {
            data: None,
            stale: false,
            last_error: None,
            generation: 0,
            epoch: 0,
            inflight: None,
        }
    }
}

struct Inflight<T> {
    id: u64,
    epoch: u64,
    fetch: SharedFetch<T>,
    /// Set once the fetch has asked the server. A refresh that arrives
    /// before then joins it; one after waits for it and asks again.
    started: Arc<AtomicBool>,
}

/// One kind of thing the catalog holds, and how to read it.
trait CatalogItem: Clone + Send + Sync + Sized + 'static {
    type Key: Clone + Eq + Hash + Send + Sync + 'static;

    fn entries(state: &mut CatalogState) -> &mut HashMap<Self::Key, Entry<Self>>;

    fn fetch(
        lease: ConnectionLease,
        key: Self::Key,
        options: CallOptions,
    ) -> BoxFuture<'static, Result<Vec<Self>, DriverError>>;

    fn changed(_state: &CatalogState, _key: &Self::Key) {}
}

impl CatalogItem for SchemaInfo {
    type Key = ();

    fn entries(state: &mut CatalogState) -> &mut HashMap<(), Entry<Self>> {
        &mut state.schemas
    }

    fn fetch(
        lease: ConnectionLease,
        _key: (),
        options: CallOptions,
    ) -> BoxFuture<'static, Result<Vec<Self>, DriverError>> {
        Box::pin(async move { lease.list_schemas(options).await })
    }
}

impl CatalogItem for ObjectInfo {
    type Key = ObjectScope;

    fn entries(state: &mut CatalogState) -> &mut HashMap<ObjectScope, Entry<Self>> {
        &mut state.objects
    }

    fn fetch(
        lease: ConnectionLease,
        scope: ObjectScope,
        options: CallOptions,
    ) -> BoxFuture<'static, Result<Vec<Self>, DriverError>> {
        Box::pin(async move { lease.list_objects(&scope, options).await })
    }

    fn changed(state: &CatalogState, scope: &ObjectScope) {
        if let Some(watcher) = state.watchers.get(scope) {
            watcher.send_replace(state.snapshot(scope));
        }
    }
}

impl CatalogItem for ColumnInfo {
    type Key = TableRef;

    fn entries(state: &mut CatalogState) -> &mut HashMap<TableRef, Entry<Self>> {
        &mut state.columns
    }

    fn fetch(
        lease: ConnectionLease,
        table: TableRef,
        options: CallOptions,
    ) -> BoxFuture<'static, Result<Vec<Self>, DriverError>> {
        Box::pin(async move { lease.fetch_columns(&table, options).await })
    }
}

impl CatalogState {
    fn snapshot(&self, scope: &ObjectScope) -> ObjectListSnapshot {
        let Some(entry) = self.objects.get(scope) else {
            return ObjectListSnapshot::empty(scope.clone());
        };
        ObjectListSnapshot {
            scope: scope.clone(),
            generation: entry.generation,
            objects: entry.data.clone().unwrap_or_else(|| Arc::from([])),
            last_error: entry.last_error.clone(),
        }
    }
}

impl SchemaCatalog {
    /// A catalog that starts with what the connect already read: the
    /// schemas and the default schema's objects.
    pub fn new(schemas: Vec<SchemaInfo>, objects: Vec<ObjectInfo>, runner: OperationRunner, tasks: Tasks) -> Self {
        let catalog = Self {
            state: Arc::new(Mutex::new(CatalogState::default())),
            runner,
            tasks,
        };
        catalog.commit(schemas, objects);
        catalog
    }

    pub async fn schemas(&self) -> Fetched<SchemaInfo> {
        self.read::<SchemaInfo>(()).await
    }

    pub async fn objects(&self, scope: ObjectScope) -> Fetched<ObjectInfo> {
        self.read::<ObjectInfo>(scope).await
    }

    /// Read the scope's objects again, even when a list is cached.
    pub async fn refresh_objects(&self, scope: ObjectScope) -> Fetched<ObjectInfo> {
        self.refresh::<ObjectInfo>(scope).await
    }

    pub async fn columns(&self, table: TableRef) -> Fetched<ColumnInfo> {
        self.read::<ColumnInfo>(table).await
    }

    /// Read the table's columns again. A failure leaves the cached list
    /// in place for the next `columns`.
    pub async fn refresh_columns(&self, table: TableRef) -> Fetched<ColumnInfo> {
        self.refresh::<ColumnInfo>(table).await
    }

    /// The columns already read for a table, without asking the server.
    pub fn cached_columns(&self, table: &TableRef) -> Option<Arc<[ColumnInfo]>> {
        self.lock().columns.get(table).and_then(|entry| entry.data.clone())
    }

    /// Put in place what a new connection read, over whatever was there.
    ///
    /// Everything else becomes stale, because the catalog cannot know
    /// what changed while the connection was away. A fetch that started
    /// before this no longer lands.
    pub fn commit(&self, schemas: Vec<SchemaInfo>, objects: Vec<ObjectInfo>) {
        let mut state = self.lock();
        mark_all_stale(&mut state.schemas);
        mark_all_stale(&mut state.objects);
        mark_all_stale(&mut state.columns);
        land(state.schemas.entry(()).or_default(), Arc::from(schemas));
        land(
            state.objects.entry(ObjectScope::DefaultSchema).or_default(),
            Arc::from(objects),
        );
        ObjectInfo::changed(&state, &ObjectScope::DefaultSchema);
    }

    /// The table changed: its columns are read again on the next ask,
    /// and until then the old ones stay for whoever shows them.
    pub fn invalidate_table(&self, table: &TableRef) {
        if let Some(entry) = self.lock().columns.get_mut(table) {
            entry.stale = true;
            entry.epoch += 1;
        }
    }

    /// The scope's object list now and after every change. Subscribing
    /// does not read anything; `objects` or `refresh_objects` does.
    pub fn subscribe(&self, scope: ObjectScope) -> watch::Receiver<ObjectListSnapshot> {
        let mut state = self.lock();
        if let Some(watcher) = state.watchers.get(&scope) {
            return watcher.subscribe();
        }
        let (watcher, receiver) = watch::channel(state.snapshot(&scope));
        state.watchers.insert(scope, watcher);
        receiver
    }

    fn lock(&self) -> MutexGuard<'_, CatalogState> {
        lock(&self.state)
    }

    fn read<T: CatalogItem>(&self, key: T::Key) -> BoxFuture<'static, Fetched<T>> {
        let mut state = self.lock();
        let entry = T::entries(&mut state).entry(key.clone()).or_default();
        if let (Some(data), false) = (&entry.data, entry.stale) {
            return futures::future::ready(Ok(data.clone())).boxed();
        }
        let after = match &entry.inflight {
            Some(inflight) if inflight.epoch == entry.epoch => return inflight.fetch.clone().boxed(),
            Some(inflight) => Some(inflight.fetch.clone()),
            None => None,
        };
        self.start::<T>(&mut state, key, after).boxed()
    }

    fn refresh<T: CatalogItem>(&self, key: T::Key) -> BoxFuture<'static, Fetched<T>> {
        let mut state = self.lock();
        let entry = T::entries(&mut state).entry(key.clone()).or_default();
        let after = match &entry.inflight {
            Some(inflight) if inflight.epoch == entry.epoch && !inflight.started.load(Ordering::SeqCst) => {
                return inflight.fetch.clone().boxed();
            }
            Some(inflight) => Some(inflight.fetch.clone()),
            None => None,
        };
        self.start::<T>(&mut state, key, after).boxed()
    }

    /// Spawn one fetch, after `after` when one is already asking, so a
    /// key never has two reads on the server at once.
    fn start<T: CatalogItem>(
        &self,
        state: &mut CatalogState,
        key: T::Key,
        after: Option<SharedFetch<T>>,
    ) -> SharedFetch<T> {
        let id = state.next_fetch;
        state.next_fetch += 1;
        let entry = T::entries(state).entry(key.clone()).or_default();
        let epoch = entry.epoch;
        let started = Arc::new(AtomicBool::new(false));
        let runner = self.runner.clone();
        let catalog = self.state.clone();
        let started_flag = started.clone();
        let work = async move {
            if let Some(after) = after {
                let _ = after.await;
            }
            started_flag.store(true, Ordering::SeqCst);
            let fetch_key = key.clone();
            // The catalog's reads belong to no one view, so only the
            // session shutting down stops them.
            let result = runner
                .run_cancellable(
                    OperationKind::Metadata,
                    &CancellationToken::new(),
                    move |lease, options| {
                        let key = fetch_key.clone();
                        async move { Ok(T::fetch(lease, key, options).await?) }
                    },
                )
                .await
                .map(Arc::from)
                .map_err(Arc::new);
            settle::<T>(&catalog, &key, id, epoch, &result);
            result
        };
        let running = self.tasks.spawn_task(work);
        let fetch = async move {
            running
                .await
                .unwrap_or_else(|failure| Err(Arc::new(OperationError::from(failure))))
        }
        .boxed()
        .shared();
        entry.inflight = Some(Inflight {
            id,
            epoch,
            fetch: fetch.clone(),
            started,
        });
        fetch
    }
}

impl std::fmt::Debug for SchemaCatalog {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let state = self.lock();
        f.debug_struct("SchemaCatalog")
            .field("scopes", &state.objects.len())
            .field("tables", &state.columns.len())
            .finish_non_exhaustive()
    }
}

fn lock(state: &Mutex<CatalogState>) -> MutexGuard<'_, CatalogState> {
    state.lock().unwrap_or_else(PoisonError::into_inner)
}

fn mark_all_stale<K, T>(entries: &mut HashMap<K, Entry<T>>) {
    for entry in entries.values_mut() {
        entry.stale = true;
        entry.epoch += 1;
    }
}

fn land<T>(entry: &mut Entry<T>, data: Arc<[T]>) {
    entry.data = Some(data);
    entry.stale = false;
    entry.last_error = None;
    entry.generation += 1;
}

/// Record what a fetch read. A failure keeps the data and only says
/// why; a fetch overtaken by a commit or an invalidation records
/// nothing.
fn settle<T: CatalogItem>(state: &Mutex<CatalogState>, key: &T::Key, id: u64, epoch: u64, result: &Fetched<T>) {
    let mut state = lock(state);
    let entry = T::entries(&mut state).entry(key.clone()).or_default();
    if entry.inflight.as_ref().is_some_and(|inflight| inflight.id == id) {
        entry.inflight = None;
    }
    if entry.epoch != epoch {
        return;
    }
    match result {
        Ok(data) => land(entry, data.clone()),
        Err(error) => entry.last_error = Some(error.clone()),
    }
    T::changed(&state, key);
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::LivenessPolicy;
    use tablepro_core::meta::ObjectKind;
    use tablepro_test_support::{CallCounters, ConnectionScript, FakeConnection, FakeReply};

    use super::*;
    use crate::health::{MonitorMailbox, SessionHealth};
    use crate::link::{ConnectionLink, EstablishedConnection};
    use crate::operation::DefaultDeadlines;
    use crate::test_support::paused_tasks;

    const SLOW: Duration = Duration::from_secs(1);

    fn object(name: &str) -> ObjectInfo {
        ObjectInfo {
            schema: Some("public".to_owned()),
            name: name.to_owned(),
            kind: ObjectKind::Table,
        }
    }

    fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: tablepro_core::column::ColumnType::untyped_text("text"),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: tablepro_core::column::ColumnDefault::None,
            comment: None,
        }
    }

    fn names<T>(items: &[T], name: impl Fn(&T) -> &str) -> Vec<String> {
        items.iter().map(|item| name(item).to_owned()).collect()
    }

    struct Harness {
        catalog: SchemaCatalog,
        connection: Arc<FakeConnection>,
        _health: watch::Sender<SessionHealth>,
        session: CancellationToken,
    }

    fn harness(script: ConnectionScript) -> Harness {
        let connection = Arc::new(FakeConnection::new(script));
        let link = Arc::new(ConnectionLink::new(EstablishedConnection {
            connection: connection.clone(),
            ssh_session: None,
        }));
        let (health, health_receiver) = watch::channel(SessionHealth::Online);
        let session = CancellationToken::new();
        let runner = OperationRunner::new(
            link,
            Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
            Arc::new(MonitorMailbox::new()),
            health_receiver,
            session.clone(),
        );
        let catalog = SchemaCatalog::new(Vec::new(), vec![object("first")], runner, paused_tasks());
        Harness {
            catalog,
            connection,
            _health: health,
            session,
        }
    }

    fn sales() -> ObjectScope {
        ObjectScope::Schema("sales".to_owned())
    }

    #[tokio::test(start_paused = true)]
    async fn ten_concurrent_objects_calls_one_list_objects() {
        let mut script = ConnectionScript::default();
        script.list_objects.always(FakeReply::Bounded {
            after: SLOW,
            outcome: Ok(vec![object("orders")]),
        });
        let harness = harness(script);

        let lists = futures::future::join_all((0..10).map(|_| harness.catalog.objects(sales()))).await;

        assert_eq!(CallCounters::get(&harness.connection.counters().list_objects), 1);
        for list in lists {
            assert_eq!(names(&list.unwrap(), |o| &o.name), ["orders"]);
        }
        let cached = harness.catalog.objects(sales()).await.unwrap();
        assert_eq!(names(&cached, |o| &o.name), ["orders"]);
        assert_eq!(CallCounters::get(&harness.connection.counters().list_objects), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn refresh_during_fetch_reruns_once() {
        let mut script = ConnectionScript::default();
        script
            .list_objects
            .once(FakeReply::Bounded {
                after: SLOW,
                outcome: Ok(vec![object("before")]),
            })
            .once(FakeReply::Bounded {
                after: SLOW,
                outcome: Ok(vec![object("after")]),
            });
        let harness = harness(script);
        let first = paused_tasks().spawn_task(harness.catalog.read::<ObjectInfo>(sales()));
        tokio::time::sleep(Duration::from_millis(10)).await;

        let (one, two) = tokio::join!(
            harness.catalog.refresh_objects(sales()),
            harness.catalog.refresh_objects(sales())
        );

        assert_eq!(names(&first.await.unwrap().unwrap(), |o| &o.name), ["before"]);
        assert_eq!(names(&one.unwrap(), |o| &o.name), ["after"]);
        assert_eq!(names(&two.unwrap(), |o| &o.name), ["after"]);
        assert_eq!(
            CallCounters::get(&harness.connection.counters().list_objects),
            2,
            "two refreshes during one fetch ran more than one more read"
        );
        assert_eq!(harness.catalog.subscribe(sales()).borrow().generation, 2);
    }

    #[tokio::test(start_paused = true)]
    async fn failed_refresh_keeps_objects_sets_last_error() {
        let mut script = ConnectionScript::default();
        script
            .list_objects
            .always(FakeReply::err(DriverError::server("denied")));
        let harness = harness(script);
        let watcher = harness.catalog.subscribe(ObjectScope::DefaultSchema);

        let refreshed = harness.catalog.refresh_objects(ObjectScope::DefaultSchema).await;

        assert!(refreshed.is_err());
        let snapshot = watcher.borrow().clone();
        assert_eq!(names(&snapshot.objects, |o| &o.name), ["first"]);
        assert_eq!(snapshot.generation, 1, "a failed read counted as a new list");
        assert!(snapshot.last_error.is_some());
        let cached = harness.catalog.objects(ObjectScope::DefaultSchema).await.unwrap();
        assert_eq!(names(&cached, |o| &o.name), ["first"]);
    }

    #[tokio::test(start_paused = true)]
    async fn failed_column_refresh_returns_the_error_and_keeps_the_list() {
        let mut script = ConnectionScript::default();
        script
            .fetch_columns
            .once(FakeReply::ok(vec![column("id")]))
            .always(FakeReply::err(DriverError::server("denied")));
        let harness = harness(script);
        let table = TableRef::unqualified("users");
        harness.catalog.columns(table.clone()).await.unwrap();

        let refreshed = harness.catalog.refresh_columns(table.clone()).await;

        assert!(refreshed.is_err());
        let cached = harness.catalog.columns(table).await.unwrap();
        assert_eq!(names(&cached, |c| &c.name), ["id"]);
        assert_eq!(CallCounters::get(&harness.connection.counters().fetch_columns), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn columns_coalesce_per_table() {
        let mut script = ConnectionScript::default();
        script
            .fetch_columns
            .when_sql_contains(
                "users",
                FakeReply::Bounded {
                    after: SLOW,
                    outcome: Ok(vec![column("id")]),
                },
            )
            .when_sql_contains(
                "orders",
                FakeReply::Bounded {
                    after: SLOW,
                    outcome: Ok(vec![column("total")]),
                },
            );
        let harness = harness(script);
        let users = TableRef::unqualified("users");
        let orders = TableRef::unqualified("orders");

        let (a, b, c) = tokio::join!(
            harness.catalog.columns(users.clone()),
            harness.catalog.columns(users),
            harness.catalog.columns(orders)
        );

        assert_eq!(names(&a.unwrap(), |c| &c.name), ["id"]);
        assert_eq!(names(&b.unwrap(), |c| &c.name), ["id"]);
        assert_eq!(names(&c.unwrap(), |c| &c.name), ["total"]);
        assert_eq!(CallCounters::get(&harness.connection.counters().fetch_columns), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn invalidate_keeps_data_until_refetch() {
        let mut script = ConnectionScript::default();
        script
            .fetch_columns
            .once(FakeReply::ok(vec![column("id")]))
            .once(FakeReply::Bounded {
                after: SLOW,
                outcome: Ok(vec![column("id"), column("email")]),
            });
        let harness = harness(script);
        let table = TableRef::unqualified("users");
        harness.catalog.columns(table.clone()).await.unwrap();

        harness.catalog.invalidate_table(&table);
        let refetch = paused_tasks().spawn_task(harness.catalog.read::<ColumnInfo>(table.clone()));
        tokio::time::sleep(SLOW / 2).await;
        let during = harness.catalog.cached_columns(&table).unwrap();
        let after = refetch.await.unwrap().unwrap();

        assert_eq!(
            names(&during, |c| &c.name),
            ["id"],
            "the refetch emptied the list early"
        );
        assert_eq!(names(&after, |c| &c.name), ["id", "email"]);
        assert_eq!(
            names(&harness.catalog.cached_columns(&table).unwrap(), |c| &c.name),
            ["id", "email"]
        );
        assert_eq!(CallCounters::get(&harness.connection.counters().fetch_columns), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn a_fetch_started_before_an_invalidation_does_not_land() {
        let mut script = ConnectionScript::default();
        script
            .fetch_columns
            .once(FakeReply::ok(vec![column("id")]))
            .once(FakeReply::Bounded {
                after: SLOW,
                outcome: Ok(vec![column("old")]),
            })
            .once(FakeReply::ok(vec![column("new")]));
        let harness = harness(script);
        let table = TableRef::unqualified("users");
        harness.catalog.columns(table.clone()).await.unwrap();
        let early = paused_tasks().spawn_task(harness.catalog.refresh::<ColumnInfo>(table.clone()));
        tokio::time::sleep(Duration::from_millis(10)).await;

        harness.catalog.invalidate_table(&table);
        let late = harness.catalog.columns(table.clone()).await.unwrap();

        assert_eq!(names(&early.await.unwrap().unwrap(), |c| &c.name), ["old"]);
        assert_eq!(names(&late, |c| &c.name), ["new"]);
        assert_eq!(
            names(&harness.catalog.cached_columns(&table).unwrap(), |c| &c.name),
            ["new"]
        );
    }

    #[tokio::test(start_paused = true)]
    async fn dropped_awaiter_does_not_cancel_fetch() {
        let mut script = ConnectionScript::default();
        script.fetch_columns.always(FakeReply::Bounded {
            after: SLOW,
            outcome: Ok(vec![column("id")]),
        });
        let harness = harness(script);
        let table = TableRef::unqualified("users");

        let waiting = paused_tasks().spawn_task(harness.catalog.read::<ColumnInfo>(table.clone()));
        tokio::time::sleep(Duration::from_millis(10)).await;
        waiting.abort();
        tokio::time::sleep(SLOW * 2).await;

        assert_eq!(
            names(&harness.catalog.cached_columns(&table).unwrap(), |c| &c.name),
            ["id"],
            "the fetch stopped with its caller"
        );
        harness.catalog.columns(table).await.unwrap();
        assert_eq!(CallCounters::get(&harness.connection.counters().fetch_columns), 1);
        assert_eq!(CallCounters::get(&harness.connection.counters().stopped), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn commit_replaces_the_default_list_and_marks_the_rest_stale() {
        let mut script = ConnectionScript::default();
        script.fetch_columns.always(FakeReply::ok(vec![column("id")]));
        let harness = harness(script);
        let table = TableRef::unqualified("users");
        harness.catalog.columns(table.clone()).await.unwrap();
        let watcher = harness.catalog.subscribe(ObjectScope::DefaultSchema);

        harness.catalog.commit(Vec::new(), vec![object("second")]);
        harness.catalog.columns(table.clone()).await.unwrap();

        let snapshot = watcher.borrow().clone();
        assert_eq!(names(&snapshot.objects, |o| &o.name), ["second"]);
        assert_eq!(snapshot.generation, 2);
        assert_eq!(
            CallCounters::get(&harness.connection.counters().fetch_columns),
            2,
            "a column list from before the reconnect was trusted"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_closed_session_fails_the_read_and_keeps_the_list() {
        let mut script = ConnectionScript::default();
        script
            .list_objects
            .always(FakeReply::err(DriverError::server("unreachable")));
        let harness = harness(script);
        harness.session.cancel();

        let refreshed = harness.catalog.refresh_objects(ObjectScope::DefaultSchema).await;

        assert_eq!(refreshed.map_err(|error| (*error).clone()), Err(OperationError::Closed));
        let cached = harness.catalog.objects(ObjectScope::DefaultSchema).await.unwrap();
        assert_eq!(names(&cached, |o| &o.name), ["first"]);
    }
}
