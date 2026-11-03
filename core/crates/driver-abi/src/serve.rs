// Any core `DatabaseDriver` behind the ABI. The driver runs on a runtime of its own, since a library has its own
// copy of tokio and the host's runtime context is a thread-local it cannot see.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::column::ResultColumn;
use tablepro_core::meta::{ObjectKind, ObjectScope};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, DataModel, DatabaseDriver, DriverError,
    EndpointKind, EngineCategory, FileEndpoint, LivenessPolicy, ReadStatement, ResultEvent, ResultSink, SinkFlow,
    UserSql, Value, WorkspaceSettings,
};
use tokio::runtime::{Handle, Runtime};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::export::{Completion, Driver, Host, Outcome, guarded};
use crate::ffi::{log_level, status};
use crate::proto::{self, Response, request, response};
use crate::rows;

pub struct CoreDriver<D> {
    driver: D,
    host: Host,
    // Taken on shutdown, which runs off the runtime's own threads.
    runtime: Mutex<Option<Runtime>>,
    handle: Handle,
    connections: Mutex<HashMap<u64, Arc<dyn Connection>>>,
    next_connection: AtomicU64,
    calls: Mutex<HashMap<u64, CancellationToken>>,
    // The parent of every call's token, so shutdown stops them all at once.
    stopping: CancellationToken,
    shutting_down: AtomicBool,
    threads: Arc<AtomicUsize>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl<D: DatabaseDriver + Default + 'static> Driver for CoreDriver<D> {
    fn open(host: Host, negotiated_minor: u16) -> Result<Self, String> {
        let driver = D::default();
        let threads = Arc::new(AtomicUsize::new(0));
        let started = Arc::clone(&threads);
        let stopped = Arc::clone(&threads);
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .max_blocking_threads(16)
            .thread_name(format!("tablepro-driver-{}", driver.id()))
            .enable_all()
            .on_thread_start(move || {
                started.fetch_add(1, Ordering::SeqCst);
            })
            .on_thread_stop(move || {
                stopped.fetch_sub(1, Ordering::SeqCst);
            })
            .build()
            .map_err(|error| format!("could not start the driver's runtime: {error}"))?;
        host.log(
            log_level::DEBUG,
            &format!("{} driver open on ABI 1.{negotiated_minor}", driver.id()),
        );
        Ok(Self {
            driver,
            host,
            handle: runtime.handle().clone(),
            runtime: Mutex::new(Some(runtime)),
            connections: Mutex::new(HashMap::new()),
            next_connection: AtomicU64::new(1),
            calls: Mutex::new(HashMap::new()),
            stopping: CancellationToken::new(),
            shutting_down: AtomicBool::new(false),
            threads,
        })
    }

    fn call(self: &Arc<Self>, call_id: u64, request: request::Kind, completion: Completion) {
        if self.shutting_down.load(Ordering::SeqCst) {
            completion.finish(Outcome::fail(
                status::SHUT_DOWN,
                Response::error("abi.shut_down", "the driver is shutting down"),
            ));
            return;
        }
        if let request::Kind::Describe(_) = request {
            completion.finish(Outcome::ok(Response::of(response::Kind::Description(self.describe()))));
            return;
        }
        let token = self.stopping.child_token();
        lock(&self.calls).insert(call_id, token.clone());
        let connection = connection_of(&request);
        let driver = Arc::clone(self);
        self.handle.spawn(async move {
            let outcome = guarded(driver.serve(request, token)).await;
            lock(&driver.calls).remove(&call_id);
            // A panic may have left the connection's state half changed, so it is not used again.
            if outcome.status == status::PANIC
                && let Some(id) = connection
            {
                let open = lock(&driver.connections).remove(&id);
                if let Some(open) = open {
                    let _ = open.close().await;
                }
            }
            completion.finish(outcome);
        });
    }

    fn cancel(&self, call_id: u64) -> bool {
        lock(&self.calls).get(&call_id).map(CancellationToken::cancel).is_some()
    }

    fn shutdown(&self, timeout: Duration) -> bool {
        self.shutting_down.store(true, Ordering::SeqCst);
        self.stopping.cancel();
        let connections: Vec<Arc<dyn Connection>> = lock(&self.connections).drain().map(|(_, open)| open).collect();
        let runtime = lock(&self.runtime).take();
        if let Some(runtime) = runtime {
            let host = self.host;
            // A thread of its own: the caller may be on a runtime, the host's or this driver's, where blocking on
            // or dropping a runtime panics.
            let teardown = std::thread::Builder::new()
                .name("tablepro-driver-teardown".to_owned())
                .spawn(move || {
                    runtime.block_on(close_all(&connections, timeout, host));
                    runtime.shutdown_timeout(timeout);
                });
            match teardown {
                Ok(thread) => {
                    if thread.join().is_err() {
                        host.log(log_level::ERROR, "the driver's teardown panicked");
                    }
                }
                Err(error) => {
                    host.log(
                        log_level::ERROR,
                        &format!("could not start the driver's teardown: {error}"),
                    );
                    return false;
                }
            }
        }
        self.threads.load(Ordering::SeqCst) == 0
    }
}

impl<D: DatabaseDriver + Default + 'static> CoreDriver<D> {
    fn describe(&self) -> proto::Description {
        let capabilities = self.driver.capabilities();
        let data_model = match capabilities.data_model {
            DataModel::Relational => proto::DataModel::Relational,
            DataModel::KeyValue => proto::DataModel::KeyValue,
            DataModel::Document => proto::DataModel::Document,
        };
        let category = match self.driver.category() {
            EngineCategory::Relational => proto::Category::Relational,
            EngineCategory::Document => proto::Category::Document,
            EngineCategory::KeyValue => proto::Category::KeyValue,
            EngineCategory::Analytical => proto::Category::Analytical,
            EngineCategory::WideColumn => proto::Category::WideColumn,
        };
        let endpoint = match &capabilities.endpoint {
            EndpointKind::Network { default_port } => proto::description::Endpoint::Network(proto::NetworkEndpoint {
                default_port: u32::from(*default_port),
            }),
            EndpointKind::File(format) => proto::description::Endpoint::File(proto::FileEndpoint {
                suffixes: format.suffixes.iter().map(|suffix| (*suffix).to_owned()).collect(),
            }),
        };
        proto::Description {
            id: self.driver.id().to_owned(),
            display_name: self.driver.display_name().to_owned(),
            data_model: data_model.into(),
            category: category.into(),
            endpoint: Some(endpoint),
        }
    }

    fn connection(&self, id: u64) -> Option<Arc<dyn Connection>> {
        lock(&self.connections).get(&id).cloned()
    }

    async fn serve(&self, request: request::Kind, token: CancellationToken) -> Outcome {
        let result = match request {
            request::Kind::Describe(_) => Ok(Outcome::ok(Response::of(response::Kind::Description(self.describe())))),
            request::Kind::OpenFile(open) => self.open_file(open, token.clone()).await,
            request::Kind::Probe(probe) => match self.connection(probe.connection) {
                Some(open) => open
                    .probe(CallOptions::new(None, token.clone()))
                    .await
                    .map(|()| Outcome::ok(Response::of(response::Kind::Probed(proto::Probed {})))),
                None => return unknown_connection(probe.connection),
            },
            request::Kind::ListSchemas(list) => match self.connection(list.connection) {
                Some(open) => open
                    .list_schemas(CallOptions::new(None, token.clone()))
                    .await
                    .map(|schemas| {
                        Outcome::ok(Response::of(response::Kind::Schemas(proto::Schemas {
                            schemas: schemas
                                .into_iter()
                                .map(|schema| proto::Schema {
                                    name: schema.name,
                                    is_default: schema.is_default,
                                    is_system: schema.is_system,
                                })
                                .collect(),
                        })))
                    }),
                None => return unknown_connection(list.connection),
            },
            request::Kind::ListObjects(list) => match self.connection(list.connection) {
                Some(open) => {
                    let scope = list.schema.map_or(ObjectScope::DefaultSchema, ObjectScope::Schema);
                    open.list_objects(&scope, CallOptions::new(None, token.clone()))
                        .await
                        .map(|objects| {
                            Outcome::ok(Response::of(response::Kind::Objects(proto::Objects {
                                objects: objects.into_iter().map(object).collect(),
                            })))
                        })
                }
                None => return unknown_connection(list.connection),
            },
            request::Kind::Read(read) => return self.read(read, token).await,
            request::Kind::Close(close) => {
                let open = lock(&self.connections).remove(&close.connection);
                match open {
                    Some(open) => open
                        .close()
                        .await
                        .map(|()| Outcome::ok(Response::of(response::Kind::Closed(proto::Closed {})))),
                    None => return unknown_connection(close.connection),
                }
            }
        };
        result.unwrap_or_else(|error| failure(&error, &token))
    }

    async fn open_file(&self, open: proto::OpenFile, token: CancellationToken) -> Result<Outcome, DriverError> {
        let path = std::path::PathBuf::from(open.path);
        let endpoint = if open.create {
            FileEndpoint::create_new(path)
        } else {
            FileEndpoint::open_existing(path)
        }?;
        let options = ConnectOptions {
            target: ConnectTarget::File(endpoint),
            workspace_settings: WorkspaceSettings::workspace(open.read_only),
            liveness: LivenessPolicy::DESKTOP,
            environment: ConnectEnvironment::new(open.client_version),
        };
        let connection = self.driver.connect(options, token).await?;
        let server_version = connection.server_info().version.clone();
        let id = self.next_connection.fetch_add(1, Ordering::SeqCst);
        lock(&self.connections).insert(id, connection);
        Ok(Outcome::ok(Response::of(response::Kind::Opened(proto::Opened {
            connection: id,
            server_version,
        }))))
    }

    async fn read(&self, read: proto::Read, token: CancellationToken) -> Outcome {
        let Some(open) = self.connection(read.connection) else {
            return unknown_connection(read.connection);
        };
        let limit = if read.row_limit == 0 { u64::MAX } else { read.row_limit };
        let collected = Arc::new(Mutex::new(Collected::default()));
        let sink = Box::new(BatchSink {
            collected: Arc::clone(&collected),
            limit,
        });
        let deadline = (read.timeout_ms > 0).then(|| Instant::now() + Duration::from_millis(read.timeout_ms));
        let statement = ReadStatement::User(UserSql::new(read.sql));
        let result = open
            .stream_read(&statement, sink, CallOptions::new(deadline, token.clone()))
            .await;
        let collected = std::mem::take(&mut *lock(&collected));
        match result {
            Ok(_) => {}
            // The sink stopped the read itself, at the row limit or at the end of the first statement.
            Err(DriverError::Cancelled) if collected.stopped && !token.is_cancelled() => {}
            Err(error) => return failure(&error, &token),
        }
        match rows::batch(&collected.columns, &collected.rows) {
            Ok(batch) => Outcome::with_rows(
                Response::of(response::Kind::ReadDone(proto::ReadDone {
                    rows: collected.rows.len() as u64,
                    truncated: collected.truncated,
                })),
                batch,
            ),
            Err(error) => Outcome::fail(status::DRIVER, Response::error("abi.rows", error.to_string())),
        }
    }
}

async fn close_all(connections: &[Arc<dyn Connection>], timeout: Duration, host: Host) {
    let close = futures::future::join_all(connections.iter().map(|open| open.close()));
    match tokio::time::timeout(timeout, close).await {
        Ok(results) => {
            for error in results.into_iter().filter_map(Result::err) {
                host.log(log_level::WARN, &format!("a connection did not close cleanly: {error}"));
            }
        }
        Err(_) => host.log(log_level::WARN, "connections were still closing at shutdown"),
    }
}

fn connection_of(request: &request::Kind) -> Option<u64> {
    match request {
        request::Kind::Probe(probe) => Some(probe.connection),
        request::Kind::ListSchemas(list) => Some(list.connection),
        request::Kind::ListObjects(list) => Some(list.connection),
        request::Kind::Read(read) => Some(read.connection),
        request::Kind::Close(close) => Some(close.connection),
        request::Kind::Describe(_) | request::Kind::OpenFile(_) => None,
    }
}

fn unknown_connection(id: u64) -> Outcome {
    Outcome::fail(
        status::BAD_REQUEST,
        Response::error("abi.unknown_connection", format!("no open connection {id}")),
    )
}

fn failure(error: &DriverError, token: &CancellationToken) -> Outcome {
    let status = if matches!(error, DriverError::Cancelled) || token.is_cancelled() {
        status::CANCELLED
    } else {
        status::DRIVER
    };
    Outcome::fail(status, Response::error(error.code(), error.to_string()))
}

fn object(info: tablepro_core::meta::ObjectInfo) -> proto::Object {
    let kind = match info.kind {
        ObjectKind::Table => proto::ObjectKind::Table,
        ObjectKind::PartitionedTable => proto::ObjectKind::PartitionedTable,
        ObjectKind::View => proto::ObjectKind::View,
        ObjectKind::MaterializedView => proto::ObjectKind::MaterializedView,
        ObjectKind::ForeignTable => proto::ObjectKind::ForeignTable,
        ObjectKind::Sequence => proto::ObjectKind::Sequence,
        ObjectKind::Function => proto::ObjectKind::Function,
        ObjectKind::Procedure => proto::ObjectKind::Procedure,
        ObjectKind::Trigger => proto::ObjectKind::Trigger,
        ObjectKind::Dictionary => proto::ObjectKind::Dictionary,
        ObjectKind::Key(_) => proto::ObjectKind::Key,
        _ => proto::ObjectKind::Unspecified,
    };
    proto::Object {
        schema: info.schema,
        name: info.name,
        kind: kind.into(),
        parent_table: info.parent_table,
    }
}

#[derive(Default)]
struct Collected {
    columns: Vec<ResultColumn>,
    rows: Vec<Vec<Value>>,
    truncated: bool,
    stopped: bool,
}

struct BatchSink {
    collected: Arc<Mutex<Collected>>,
    limit: u64,
}

#[async_trait]
impl ResultSink for BatchSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        let mut collected = lock(&self.collected);
        match event {
            ResultEvent::ResultSetStarted { columns } => collected.columns = columns.to_vec(),
            ResultEvent::ColumnsResolved { set_index: 0, columns } => collected.columns = columns.to_vec(),
            // Read answers one statement: what follows its result, or a statement with none, is never run.
            ResultEvent::ResultSetFinished { .. } | ResultEvent::CommandCompleted { .. } => {
                collected.stopped = true;
                return SinkFlow::ConsumerGone;
            }
            ResultEvent::Rows(rows) => {
                for row in rows {
                    if collected.rows.len() as u64 >= self.limit {
                        collected.truncated = true;
                        collected.stopped = true;
                        return SinkFlow::ConsumerGone;
                    }
                    collected.rows.push(row);
                }
            }
            _ => {}
        }
        SinkFlow::Continue
    }
}
