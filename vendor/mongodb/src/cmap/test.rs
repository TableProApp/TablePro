pub(crate) mod event;
mod file;
mod integration;

use std::{collections::HashMap, ops::Deref, sync::Arc, time::Duration};

use tokio::sync::{Mutex, RwLock};

use self::file::{Operation, TestFile, ThreadedOperation};

use crate::{
    cmap::{
        establish::{ConnectionEstablisher, EstablisherOptions},
        ConnectionPool,
        ConnectionPoolOptions,
    },
    error::{Error, ErrorKind, Result},
    event::cmap::{
        CmapEvent,
        ConnectionCheckoutFailedReason,
        ConnectionClosedReason,
        ConnectionPoolOptions as EventOptions,
    },
    options::TlsOptions,
    runtime::{self, AsyncJoinHandle},
    sdam::{topology::TopologyShutdown, TopologyUpdater, UpdateMessage},
    test::{
        assert_matches,
        eq_matches,
        get_client_options,
        log_uncaptured,
        run_spec_test,
        util::event_buffer::EventBuffer,
        MatchErrExt,
        Matchable,
    },
};

use super::conn::pooled::PooledConnection;

const TEST_DESCRIPTIONS_TO_SKIP: &[&str] = &[
    "must destroy checked in connection if pool has been closed",
    "must throw error if checkOut is called on a closed pool",
    // WaitQueueTimeoutMS is not supported
    "must aggressively timeout threads enqueued longer than waitQueueTimeoutMS",
    "waiting on maxConnecting is limited by WaitQueueTimeoutMS",
    // TODO DRIVERS-1785 remove this skip when test event order is fixed
    "error during minPoolSize population clears pool",
    // TODO RUST-2106: unskip this test
    "Pool clear SHOULD schedule the next background thread run immediately \
     (interruptInUseConnections = false)",
    // TODO RUST-1052: unskip this test and investigate flaky failure linked in ticket
    "threads blocked by maxConnecting check out minPoolSize connections",
];

/// Many different types of CMAP events are emitted from tasks spawned in the drop
/// implementations of various types (Connections, pools, etc.). Sometimes it takes
/// a longer amount of time for these tasks to get scheduled and thus their associated
/// events to get emitted, requiring the runner to wait for a little bit before asserting
/// the events were actually fired.
///
/// This value was purposefully chosen to be large to prevent test failures, though it is not
/// expected that the 3s timeout will regularly or ever be hit.
const EVENT_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug)]
struct Executor {
    description: String,
    operations: Vec<ThreadedOperation>,
    error: Option<self::file::Error>,
    events: Vec<CmapEvent>,
    state: Arc<State>,
    ignored_event_names: Vec<String>,
    pool_options: ConnectionPoolOptions,
}

#[derive(Debug)]
struct State {
    events: EventBuffer<CmapEvent>,
    connections: RwLock<HashMap<String, PooledConnection>>,
    unlabeled_connections: Mutex<Vec<PooledConnection>>,
    threads: RwLock<HashMap<String, CmapThread>>,

    // In order to drop the pool when performing a `close` operation, we use an `Option` so that we
    // can replace it with `None`. Since none of the tests should use the pool after its closed
    // (besides the ones we manually skip over), it's fine for us to `unwrap` the pool during these
    // tests, as panicking is sufficient to exit any aberrant test with a failure.
    pool: RwLock<Option<ConnectionPool>>,
}

impl State {
    // Counts the number of events of the given type that have occurred so far.
    fn count_events(&self, event_type: &str) -> usize {
        self.events
            .all()
            .into_iter()
            .filter(|cmap_event| cmap_event.name() == event_type)
            .count()
    }
}

#[derive(Debug)]
struct CmapThread {
    handle: AsyncJoinHandle<Result<()>>,
    dispatcher: tokio::sync::mpsc::UnboundedSender<Operation>,
}

impl CmapThread {
    fn start(state: Arc<State>) -> Self {
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel::<Operation>();
        let handle = runtime::spawn(async move {
            while let Some(operation) = receiver.recv().await {
                operation.execute(state.clone()).await?;
            }
            Ok(())
        });

        Self {
            dispatcher: sender,
            handle,
        }
    }

    async fn wait_until_complete(self) -> Result<()> {
        // hang up dispatcher so task will complete.
        drop(self.dispatcher);
        self.handle.await
    }
}

impl Executor {
    async fn new(test_file: TestFile) -> Self {
        let events = EventBuffer::new();
        let error = test_file.error;

        let mut pool_options = test_file.pool_options.unwrap_or_default();
        pool_options.cmap_event_handler = Some(events.handler());

        let state = State {
            events,
            pool: RwLock::new(None),
            connections: Default::default(),
            threads: Default::default(),
            unlabeled_connections: Mutex::new(Default::default()),
        };

        Self {
            description: test_file.description,
            error,
            events: test_file.events,
            operations: test_file.operations,
            state: Arc::new(state),
            ignored_event_names: test_file.ignore,
            pool_options,
        }
    }

    async fn execute_test(self) {
        let mut event_stream = self.state.events.stream();

        let (updater, mut receiver) = TopologyUpdater::channel();

        let pool = ConnectionPool::new(
            get_client_options().await.hosts[0].clone(),
            ConnectionEstablisher::new(EstablisherOptions::from(get_client_options().await))
                .unwrap(),
            updater,
            Some(self.pool_options),
            TopologyShutdown::new(),
            #[cfg(feature = "tracing-unstable")]
            crate::bson::oid::ObjectId::new(),
        );

        // Mock a monitoring task responding to errors reported by the pool.
        let manager = pool.manager.clone();
        runtime::spawn(async move {
            while let Some(update) = receiver.recv().await {
                let (update, ack) = update.into_parts();
                if let UpdateMessage::ApplicationError { error, .. } = update {
                    manager.clear(error, None).await;
                }
                ack.acknowledge(true);
            }
        });

        *self.state.pool.write().await = Some(pool);

        let mut error: Option<Error> = None;
        let operations = self.operations;

        println!("Executing {}", self.description);

        for operation in operations {
            let err = operation.execute(self.state.clone()).await.err();
            if error.is_none() {
                error = err;
            }
        }

        match (self.error, error) {
            (Some(ref expected), None) => {
                panic!("Expected {}, but no error occurred", expected.type_)
            }
            (None, Some(ref actual)) => panic!(
                "Expected no error to occur, but the following error was returned: {actual:?}"
            ),
            (None, None) | (Some(_), Some(_)) => {}
        }

        let ignored_event_names = self.ignored_event_names;
        let description = self.description;
        let filter = |e: &CmapEvent| !ignored_event_names.iter().any(|name| e.name() == name);
        for expected_event in self.events {
            let actual_event = event_stream
                .next_match(EVENT_TIMEOUT, filter)
                .await
                .unwrap_or_else(|| {
                    panic!("{description}: did not receive expected event: {expected_event:?}")
                });
            assert_matches(&actual_event, &expected_event, Some(description.as_str()));
        }

        assert_eq!(
            event_stream.collect_now(filter),
            Vec::new(),
            "{description}"
        );
    }
}

impl Operation {
    /// Execute this operation.
    async fn execute(self, state: Arc<State>) -> Result<()> {
        match self {
            Operation::Wait { ms } => tokio::time::sleep(Duration::from_millis(ms)).await,
            Operation::WaitForThread { target } => {
                state
                    .threads
                    .write()
                    .await
                    .remove(&target)
                    .unwrap()
                    .wait_until_complete()
                    .await?
            }
            Operation::WaitForEvent {
                event,
                count,
                timeout,
            } => {
                let event_name = event.clone();
                let task = async move {
                    while state.count_events(&event) < count {
                        tokio::time::sleep(Duration::from_millis(100)).await;
                    }
                };
                runtime::timeout(timeout.unwrap_or(EVENT_TIMEOUT), task)
                    .await
                    .unwrap_or_else(|_| {
                        panic!("waiting for {count} {event_name} event(s) timed out")
                    });
            }
            Operation::CheckOut { label } => {
                if let Some(pool) = state.pool.read().await.deref() {
                    let conn = pool.check_out().await?;

                    if let Some(label) = label {
                        state.connections.write().await.insert(label, conn);
                    } else {
                        state.unlabeled_connections.lock().await.push(conn);
                    }
                }
            }
            Operation::CheckIn { connection } => {
                let mut event_stream = state.events.stream();
                let conn = state.connections.write().await.remove(&connection).unwrap();
                let id = conn.id;
                // connections are checked in via tasks spawned in their drop implementation,
                // they are not checked in explicitly.
                drop(conn);

                // wait for event to be emitted to ensure check in has completed.
                event_stream
                    .next_match(EVENT_TIMEOUT, |e| {
                        matches!(e, CmapEvent::ConnectionCheckedIn(event) if event.connection_id == id)
                    })
                    .await
                    .unwrap_or_else(|| {
                        panic!(
                            "did not receive checkin event after dropping connection (id={connection})"
                        )
                    });
            }
            Operation::Clear {
                interrupt_in_use_connections,
            } => {
                let error = if interrupt_in_use_connections == Some(true) {
                    Error::network_timeout()
                } else {
                    ErrorKind::Internal {
                        message: "test error".to_string(),
                    }
                    .into()
                };

                if let Some(pool) = state.pool.read().await.as_ref() {
                    pool.clear(error, None).await;
                }
            }
            Operation::Ready => {
                if let Some(pool) = state.pool.read().await.deref() {
                    pool.mark_as_ready().await;
                }
            }
            Operation::Close => {
                let mut event_stream = state.events.stream();

                // pools are closed via their drop implementation
                state.pool.write().await.take();

                // wait for event to be emitted to ensure drop has completed.
                event_stream
                    .next_match(EVENT_TIMEOUT, |e| matches!(e, CmapEvent::PoolClosed(_)))
                    .await
                    .expect("did not receive ConnectionPoolClosed event after closing pool");
            }
            Operation::Start { target } => {
                state
                    .threads
                    .write()
                    .await
                    .insert(target, CmapThread::start(state.clone()));
            }
        }
        Ok(())
    }
}

impl Matchable for TlsOptions {
    fn content_matches(&self, expected: &TlsOptions) -> std::result::Result<(), String> {
        self.allow_invalid_certificates
            .matches(&expected.allow_invalid_certificates)
            .prefix("allow_invalid_certificates")?;
        self.ca_file_path
            .as_ref()
            .map(|pb| pb.display().to_string())
            .matches(
                &expected
                    .ca_file_path
                    .as_ref()
                    .map(|pb| pb.display().to_string()),
            )
            .prefix("ca_file_path")?;
        self.cert_key_file_path
            .as_ref()
            .map(|pb| pb.display().to_string())
            .matches(
                &expected
                    .cert_key_file_path
                    .as_ref()
                    .map(|pb| pb.display().to_string()),
            )
            .prefix("cert_key_file_path")?;
        Ok(())
    }
}

impl Matchable for EventOptions {
    fn content_matches(&self, expected: &EventOptions) -> std::result::Result<(), String> {
        self.max_idle_time
            .matches(&expected.max_idle_time)
            .prefix("max_idle_time")?;
        self.max_pool_size
            .matches(&expected.max_pool_size)
            .prefix("max_pool_size")?;
        self.min_pool_size
            .matches(&expected.min_pool_size)
            .prefix("min_pool_size")?;
        Ok(())
    }
}

impl Matchable for CmapEvent {
    fn content_matches(&self, expected: &CmapEvent) -> std::result::Result<(), String> {
        match (self, expected) {
            (CmapEvent::PoolCreated(actual), CmapEvent::PoolCreated(ref expected)) => {
                actual.options.matches(&expected.options)
            }
            (CmapEvent::ConnectionCreated(actual), CmapEvent::ConnectionCreated(ref expected)) => {
                actual.connection_id.matches(&expected.connection_id)
            }
            (CmapEvent::ConnectionReady(actual), CmapEvent::ConnectionReady(ref expected)) => {
                actual.connection_id.matches(&expected.connection_id)
            }
            (CmapEvent::ConnectionClosed(actual), CmapEvent::ConnectionClosed(ref expected)) => {
                if expected.reason != ConnectionClosedReason::Unset {
                    eq_matches("reason", &actual.reason, &expected.reason)?;
                }
                // 0 is used as a placeholder for test events that do not specify a value; the
                // driver will never actually generate a connection ID with this value.
                if expected.connection_id != 0 {
                    actual
                        .connection_id
                        .matches(&expected.connection_id)
                        .prefix("connection_id")?;
                }
                Ok(())
            }
            (
                CmapEvent::ConnectionCheckedOut(actual),
                CmapEvent::ConnectionCheckedOut(ref expected),
            ) => actual.connection_id.matches(&expected.connection_id),
            (
                CmapEvent::ConnectionCheckedIn(actual),
                CmapEvent::ConnectionCheckedIn(ref expected),
            ) => actual.connection_id.matches(&expected.connection_id),
            (
                CmapEvent::ConnectionCheckoutFailed(actual),
                CmapEvent::ConnectionCheckoutFailed(ref expected),
            ) => {
                if expected.reason != ConnectionCheckoutFailedReason::Unset {
                    eq_matches("reason", &actual.reason, &expected.reason)?;
                }
                Ok(())
            }
            (CmapEvent::ConnectionCheckoutStarted(_), CmapEvent::ConnectionCheckoutStarted(_)) => {
                Ok(())
            }
            (CmapEvent::PoolCleared(_), CmapEvent::PoolCleared(_)) => Ok(()),
            (CmapEvent::PoolReady(_), CmapEvent::PoolReady(_)) => Ok(()),
            (CmapEvent::PoolClosed(_), CmapEvent::PoolClosed(_)) => Ok(()),
            (actual, expected) => Err(format!("expected event {actual:?}, got {expected:?}")),
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn cmap_spec_tests() {
    async fn run_cmap_spec_tests(mut test_file: TestFile) {
        if TEST_DESCRIPTIONS_TO_SKIP.contains(&test_file.description.as_str()) {
            return;
        }

        if let Some(ref run_on) = test_file.run_on {
            let mut can_run_on = false;
            for requirement in run_on {
                if requirement.can_run_on().await {
                    can_run_on = true;
                }
            }
            if !can_run_on {
                log_uncaptured("skipping due to runOn requirements");
                return;
            }
        }

        let mut options = get_client_options().await.clone();
        if options.load_balanced.unwrap_or(false) {
            log_uncaptured(format!(
                "skipping {:?} due to load balanced topology",
                test_file.description
            ));
            return;
        }
        options.hosts.drain(1..);
        options.direct_connection = Some(true);
        let client = crate::Client::for_test().options(options).await;

        let _guard = if let Some(fail_point) = test_file.fail_point.take() {
            Some(client.enable_fail_point(fail_point).await.unwrap())
        } else {
            None
        };

        let executor = Executor::new(test_file).await;
        executor.execute_test().await;
    }

    run_spec_test(
        &["connection-monitoring-and-pooling", "cmap-format"],
        run_cmap_spec_tests,
    )
    .await;
}

// TODO RUST-2074: investigate why this test is flaky
// #[tokio::test(flavor = "multi_thread")]
// async fn pool_cleared_error_has_transient_transaction_error_label() {
//     if !block_connection_supported().await {
//         log_uncaptured(
//             "skipping pool_cleared_error_has_transient_transaction_error_label: block connection
// \              unsupported",
//         );
//         return;
//     }
//     if !transactions_supported().await {
//         log_uncaptured(
//             "skipping pool_cleared_error_has_transient_transaction_error_label: transactions \
//              unsupported",
//         );
//         return;
//     }
//     if topology_is_load_balanced().await {
//         log_uncaptured(
//             "skipping pool_cleared_error_has_transient_transaction_error_label: load balanced \
//              topology",
//         );
//     }

//     let app_name = "pool_cleared_error_has_transient_transaction_error_label";

//     let mut client_options = get_client_options().await.clone();
//     if topology_is_sharded().await {
//         client_options.hosts.drain(1..);
//     }
//     client_options.connect_timeout = Some(Duration::from_millis(500));
//     client_options.heartbeat_freq = Some(Duration::from_millis(500));
//     client_options.app_name = Some(app_name.to_string());
//     let client = Client::for_test()
//         .options(client_options)
//         .monitor_events()
//         .await;

//     let mut session = client.start_session().await.unwrap();
//     session.start_transaction().await.unwrap();

//     let fail_point = FailPoint::fail_command(&["insert"], FailPointMode::Times(1))
//         .block_connection(Duration::from_secs(15))
//         .app_name(app_name);
//     let _guard = client.enable_fail_point(fail_point).await.unwrap();

//     let insert_client = client.clone();
//     let insert_handle = tokio::spawn(async move {
//         insert_client
//             .database("db")
//             .collection("coll")
//             .insert_one(doc! { "x": 1 })
//             .session(&mut session)
//             .await
//     });

//     let fail_point = FailPoint::fail_command(
//         &["hello", LEGACY_HELLO_COMMAND_NAME],
//         // The RTT hellos may encounter this failpoint, so use FailPointMode::AlwaysOn to ensure
//         // that the server monitors hit it as well.
//         FailPointMode::AlwaysOn,
//     )
//     .block_connection(Duration::from_millis(1500))
//     .app_name(app_name);
//     let _guard = client.enable_fail_point(fail_point).await.unwrap();

//     let insert_error = insert_handle.await.unwrap().unwrap_err();
//     assert!(insert_error.is_pool_cleared(), "{:?}", insert_error);
//     assert!(insert_error.contains_label(TRANSIENT_TRANSACTION_ERROR));
// }
