use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tablepro_core::ddl::TableDefinition;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{ObjectInfo, ObjectScope, RowIdentity, SchemaInfo, TableEstimate};
use tablepro_core::statement::Statement;
use tablepro_core::{
    CallOptions, ColumnInfo, CommitResolution, CommitToken, Connection, DriverError, EditorSession,
    EditorSessionOptions, ErrorCategory, ForeignKeyInfo, IndexInfo, LinkState, LinkWatch, QueryResult, ReadStatement,
    ResultSink, RowLimit, ServerInfo, SinkFlow, StreamSummary, TableRef, TimeoutPhase, WriteBatch, WriteReport,
};
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use crate::fake_reply::Stop;
use crate::{CallCounters, CloseBehaviour, ConnectionScript, FakeReply, Replies, lock};

/// A `Connection` that answers from a `ConnectionScript`.
///
/// It keeps the contract's shared rules so code under test sees them: a
/// reply in the `ConnectionLost` category marks the link lost, and
/// `close` stops every call still waiting, as a real pool would.
#[derive(Debug)]
pub struct FakeConnection {
    script: Mutex<ConnectionScript>,
    server_info: ServerInfo,
    dialect: Arc<dyn SqlDialect>,
    read_only: bool,
    close_behaviour: CloseBehaviour,
    close_started: AtomicBool,
    close_finished: AtomicBool,
    link: LinkWatch,
    closed: CancellationToken,
    counters: CallCounters,
    /// The cancel token each call was handed, by method, in call order.
    cancels: Mutex<Vec<(&'static str, CancellationToken)>>,
}

impl FakeConnection {
    pub fn new(script: ConnectionScript) -> Self {
        Self {
            server_info: script.server_info.clone(),
            dialect: script.dialect.clone(),
            read_only: script.read_only,
            close_behaviour: script.close,
            close_started: AtomicBool::new(false),
            close_finished: AtomicBool::new(false),
            script: Mutex::new(script),
            link: LinkWatch::new(),
            closed: CancellationToken::new(),
            counters: CallCounters::default(),
            cancels: Mutex::new(Vec::new()),
        }
    }

    pub fn counters(&self) -> CallCounters {
        self.counters.clone()
    }

    /// Drop the link the way a dead server would, for code that watches
    /// `link_state` or `lost`.
    pub fn mark_lost(&self) {
        self.link.mark_lost();
    }

    pub fn is_closed(&self) -> bool {
        self.closed.is_cancelled()
    }

    /// Set once the first close has run to its end, delay included. A
    /// close that hangs, or whose caller gave up on it, never sets it.
    pub fn close_finished(&self) -> bool {
        self.close_finished.load(Ordering::SeqCst)
    }

    /// The cancel token every call to `method` was handed, oldest first,
    /// so a test can tell its own stop reached the call.
    pub fn observed_cancels(&self, method: &str) -> Vec<CancellationToken> {
        lock(&self.cancels)
            .iter()
            .filter(|(called, _)| *called == method)
            .map(|(_, cancel)| cancel.clone())
            .collect()
    }

    async fn answer<T>(
        &self,
        method: &'static str,
        counter: &AtomicUsize,
        pick: impl FnOnce(&mut ConnectionScript) -> &mut Replies<FakeReply<T>>,
        sql: Option<&str>,
        options: &CallOptions,
        phase: TimeoutPhase,
    ) -> Result<T, DriverError>
    where
        T: Clone,
    {
        CallCounters::record(counter);
        lock(&self.cancels).push((method, options.cancel().clone()));
        if self.closed.is_cancelled() {
            CallCounters::record(&self.counters.stopped);
            return Err(DriverError::Cancelled);
        }
        let reply = pick(&mut lock(&self.script)).next(sql);
        let Some(reply) = reply else {
            return Err(DriverError::Protocol(format!(
                "FakeConnection has no scripted {method} result"
            )));
        };
        let stop = Stop {
            deadline: options.deadline(),
            cancel: options.cancel(),
            closed: &self.closed,
            phase,
        };
        let outcome = reply.resolve(&stop).await;
        self.observe(&outcome);
        outcome
    }

    fn observe<T>(&self, outcome: &Result<T, DriverError>) {
        let Err(error) = outcome else {
            return;
        };
        match error.category() {
            ErrorCategory::ConnectionLost => self.link.mark_lost(),
            ErrorCategory::Interrupted | ErrorCategory::Timeout => CallCounters::record(&self.counters.stopped),
            _ => {}
        }
    }
}

#[async_trait]
impl Connection for FakeConnection {
    fn server_info(&self) -> &ServerInfo {
        &self.server_info
    }

    fn dialect(&self) -> Arc<dyn SqlDialect> {
        self.dialect.clone()
    }

    fn read_only(&self) -> bool {
        self.read_only
    }

    fn link_state(&self) -> LinkState {
        self.link.state()
    }

    fn lost(&self) -> WaitForCancellationFutureOwned {
        self.link.lost()
    }

    async fn probe(&self, options: CallOptions) -> Result<(), DriverError> {
        let counter = &self.counters.probe;
        self.answer("probe", counter, |s| &mut s.probe, None, &options, TimeoutPhase::Probe)
            .await
    }

    async fn list_schemas(&self, options: CallOptions) -> Result<Vec<SchemaInfo>, DriverError> {
        let counter = &self.counters.list_schemas;
        self.answer(
            "list_schemas",
            counter,
            |s| &mut s.list_schemas,
            None,
            &options,
            TimeoutPhase::Statement,
        )
        .await
    }

    async fn list_objects(&self, _scope: &ObjectScope, options: CallOptions) -> Result<Vec<ObjectInfo>, DriverError> {
        let counter = &self.counters.list_objects;
        self.answer(
            "list_objects",
            counter,
            |s| &mut s.list_objects,
            None,
            &options,
            TimeoutPhase::Statement,
        )
        .await
    }

    async fn fetch_columns(&self, table: &TableRef, options: CallOptions) -> Result<Vec<ColumnInfo>, DriverError> {
        let counter = &self.counters.fetch_columns;
        let name = Some(table.name.as_str());
        self.answer(
            "fetch_columns",
            counter,
            |s| &mut s.fetch_columns,
            name,
            &options,
            TimeoutPhase::Statement,
        )
        .await
    }

    async fn fetch_indexes(&self, table: &TableRef, options: CallOptions) -> Result<Vec<IndexInfo>, DriverError> {
        let counter = &self.counters.fetch_indexes;
        let name = Some(table.name.as_str());
        self.answer(
            "fetch_indexes",
            counter,
            |s| &mut s.fetch_indexes,
            name,
            &options,
            TimeoutPhase::Statement,
        )
        .await
    }

    async fn fetch_foreign_keys(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        let counter = &self.counters.fetch_foreign_keys;
        let name = Some(table.name.as_str());
        self.answer(
            "fetch_foreign_keys",
            counter,
            |s| &mut s.fetch_foreign_keys,
            name,
            &options,
            TimeoutPhase::Statement,
        )
        .await
    }

    async fn fetch_table_definition(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<TableDefinition, DriverError> {
        let counter = &self.counters.fetch_table_definition;
        let name = Some(table.name.as_str());
        self.answer(
            "fetch_table_definition",
            counter,
            |s| &mut s.fetch_table_definition,
            name,
            &options,
            TimeoutPhase::Statement,
        )
        .await
    }

    async fn row_identity(&self, table: &TableRef, options: CallOptions) -> Result<RowIdentity, DriverError> {
        let counter = &self.counters.row_identity;
        let name = Some(table.name.as_str());
        self.answer(
            "row_identity",
            counter,
            |s| &mut s.row_identity,
            name,
            &options,
            TimeoutPhase::Statement,
        )
        .await
    }

    async fn table_estimate(&self, table: &TableRef, options: CallOptions) -> Result<TableEstimate, DriverError> {
        let counter = &self.counters.table_estimate;
        let name = Some(table.name.as_str());
        self.answer(
            "table_estimate",
            counter,
            |s| &mut s.table_estimate,
            name,
            &options,
            TimeoutPhase::Statement,
        )
        .await
    }

    async fn query_bound(
        &self,
        statement: &Statement,
        limit: RowLimit,
        options: CallOptions,
    ) -> Result<QueryResult, DriverError> {
        let counter = &self.counters.query_bound;
        let result = self
            .answer(
                "query_bound",
                counter,
                |s| &mut s.query_bound,
                Some(statement.sql()),
                &options,
                TimeoutPhase::Statement,
            )
            .await?;
        Ok(apply_limit(result, limit))
    }

    async fn count_rows(&self, statement: &Statement, options: CallOptions) -> Result<u64, DriverError> {
        let counter = &self.counters.count_rows;
        self.answer(
            "count_rows",
            counter,
            |s| &mut s.count_rows,
            Some(statement.sql()),
            &options,
            TimeoutPhase::Statement,
        )
        .await
    }

    async fn stream_read(
        &self,
        read: &ReadStatement,
        mut sink: Box<dyn ResultSink>,
        options: CallOptions,
    ) -> Result<StreamSummary, DriverError> {
        let counter = &self.counters.stream_read;
        let sql = match read {
            ReadStatement::Generated(statement) => statement.sql(),
            ReadStatement::User(sql) => sql.as_str(),
        };
        let events = self
            .answer(
                "stream_read",
                counter,
                |s| &mut s.stream_read,
                Some(sql),
                &options,
                TimeoutPhase::Statement,
            )
            .await?;
        let mut rows = 0_u64;
        for event in events {
            if let tablepro_core::ResultEvent::Rows(batch) = &event {
                rows += batch.len() as u64;
            }
            if sink.accept(event).await == SinkFlow::ConsumerGone {
                return Err(DriverError::Cancelled);
            }
        }
        Ok(StreamSummary::new(rows))
    }

    async fn write_batch(&self, batch: &WriteBatch, options: CallOptions) -> Result<WriteReport, DriverError> {
        let counter = &self.counters.write_batch;
        let sql = batch
            .steps
            .iter()
            .map(|step| step.statement.sql())
            .collect::<Vec<_>>()
            .join(";\n");
        self.answer(
            "write_batch",
            counter,
            |s| &mut s.write_batch,
            Some(&sql),
            &options,
            TimeoutPhase::Statement,
        )
        .await
    }

    async fn resolve_commit(
        &self,
        _token: &CommitToken,
        options: CallOptions,
    ) -> Result<CommitResolution, DriverError> {
        let counter = &self.counters.resolve_commit;
        self.answer(
            "resolve_commit",
            counter,
            |s| &mut s.resolve_commit,
            None,
            &options,
            TimeoutPhase::Statement,
        )
        .await
    }

    async fn open_editor_session(
        &self,
        _options: EditorSessionOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<dyn EditorSession>, DriverError> {
        let counter = &self.counters.open_editor_session;
        let options = CallOptions::new(None, cancel);
        self.answer(
            "open_editor_session",
            counter,
            |s| &mut s.open_editor_session,
            None,
            &options,
            TimeoutPhase::Login,
        )
        .await
    }

    async fn close(&self) -> Result<(), DriverError> {
        CallCounters::record(&self.counters.close);
        let first = !self.close_started.swap(true, Ordering::SeqCst);
        self.closed.cancel();
        if first {
            self.close_behaviour.run().await;
            self.close_finished.store(true, Ordering::SeqCst);
        }
        Ok(())
    }
}

/// Keep at most `limit` rows and mark the result truncated when there
/// were more, as the contract asks of every driver.
fn apply_limit(mut result: QueryResult, limit: RowLimit) -> QueryResult {
    let keep = usize::try_from(limit.get()).unwrap_or(usize::MAX);
    if result.rows.len() > keep {
        result.rows.truncate(keep);
        result.truncated = true;
    }
    result
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use futures::future::BoxFuture;
    use tablepro_core::LossPhase;
    use tablepro_core::meta::ObjectKind;
    use tablepro_core::statement::{Statement, StatementBuilder};
    use tablepro_core::value::Value;
    use tokio::time::Instant;

    use super::*;
    use crate::close_race::{ROUNDS, pending_closes};

    fn select(sql: &str) -> Statement {
        let mut builder = StatementBuilder::new();
        builder.push_sql(sql);
        builder.finish()
    }

    fn unbounded() -> CallOptions {
        CallOptions::new(None, CancellationToken::new())
    }

    #[tokio::test]
    async fn fake_connection_counts_each_call() {
        let mut script = ConnectionScript::default();
        script
            .list_objects
            .once(FakeReply::ok(vec![ObjectInfo {
                schema: None,
                name: "items".to_owned(),
                kind: ObjectKind::Table,
            }]))
            .once(FakeReply::err(DriverError::Busy));
        script.probe.always(FakeReply::ok(()));
        let connection = FakeConnection::new(script);
        let counters = connection.counters();

        let listed = connection
            .list_objects(&ObjectScope::DefaultSchema, unbounded())
            .await
            .unwrap();
        assert_eq!(listed.len(), 1);
        assert!(matches!(
            connection.list_objects(&ObjectScope::DefaultSchema, unbounded()).await,
            Err(DriverError::Busy)
        ));
        assert!(matches!(
            connection.list_objects(&ObjectScope::DefaultSchema, unbounded()).await,
            Err(DriverError::Protocol(_))
        ));
        connection.probe(unbounded()).await.unwrap();
        connection.close().await.unwrap();

        assert_eq!(CallCounters::get(&counters.list_objects), 3);
        assert_eq!(CallCounters::get(&counters.probe), 1);
        assert_eq!(CallCounters::get(&counters.close), 1);
        assert_eq!(CallCounters::get(&counters.query_bound), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn close_hang_stays_pending_under_paused_clock() {
        let hanging = FakeConnection::new(ConnectionScript {
            close: CloseBehaviour::Hang,
            ..ConnectionScript::default()
        });
        let outcome = tokio::time::timeout(Duration::from_secs(3600), hanging.close()).await;
        assert!(outcome.is_err(), "a hanging close returned");
        assert!(hanging.is_closed() && !hanging.close_finished());

        let delayed = FakeConnection::new(ConnectionScript {
            close: CloseBehaviour::Delay(Duration::from_secs(5)),
            ..ConnectionScript::default()
        });
        let started = Instant::now();
        delayed.close().await.unwrap();
        assert!(started.elapsed() >= Duration::from_secs(5));
        assert!(delayed.close_finished());
        let again = Instant::now();
        delayed.close().await.unwrap();
        assert_eq!(again.elapsed(), Duration::ZERO, "a second close waited again");
    }

    fn close_connection(connection: &FakeConnection) -> BoxFuture<'_, ()> {
        Box::pin(async move { drop(connection.close().await) })
    }

    #[test]
    fn concurrent_closes_run_the_close_behaviour_once() {
        let pending = pending_closes(
            ROUNDS,
            || {
                FakeConnection::new(ConnectionScript {
                    close: CloseBehaviour::Hang,
                    ..ConnectionScript::default()
                })
            },
            close_connection,
        );

        assert!(pending.iter().all(|&hung| hung == 1), "{pending:?}");
    }

    #[tokio::test(start_paused = true)]
    async fn a_bounded_reply_stops_at_the_deadline_and_a_late_one_does_not() {
        let mut script = ConnectionScript::default();
        script.query_bound.when_sql_contains(
            "bounded",
            FakeReply::Bounded {
                after: Duration::from_secs(60),
                outcome: Ok(QueryResult::empty()),
            },
        );
        script.query_bound.when_sql_contains(
            "late",
            FakeReply::Late {
                after: Duration::from_secs(60),
                outcome: Ok(QueryResult::empty()),
            },
        );
        let connection = FakeConnection::new(script);
        let within = || CallOptions::new(Some(Instant::now() + Duration::from_secs(1)), CancellationToken::new());

        let started = Instant::now();
        let bounded = connection
            .query_bound(&select("bounded"), RowLimit::EDITOR_DEFAULT, within())
            .await;
        assert!(matches!(
            bounded,
            Err(DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                ..
            })
        ));
        assert_eq!(started.elapsed(), Duration::from_secs(1));

        let started = Instant::now();
        let late = connection
            .query_bound(&select("late"), RowLimit::EDITOR_DEFAULT, within())
            .await;
        assert!(late.is_ok());
        assert_eq!(started.elapsed(), Duration::from_secs(60));
        assert_eq!(CallCounters::get(&connection.counters().stopped), 1);
    }

    #[tokio::test]
    async fn a_lost_reply_marks_the_link_lost_and_close_stops_waiting_calls() {
        let mut script = ConnectionScript::default();
        script.probe.once(FakeReply::err(DriverError::ConnectionLost {
            during: LossPhase::Idle,
        }));
        script.query_bound.always(FakeReply::UntilStopped);
        let connection = Arc::new(FakeConnection::new(script));
        let lost = connection.lost();

        assert!(connection.probe(unbounded()).await.is_err());
        assert_eq!(connection.link_state(), LinkState::Lost);
        lost.await;

        let waiting = {
            let connection = connection.clone();
            tokio::spawn(async move {
                connection
                    .query_bound(&select("SELECT 1"), RowLimit::EDITOR_DEFAULT, unbounded())
                    .await
            })
        };
        tokio::task::yield_now().await;
        connection.close().await.unwrap();
        assert!(matches!(waiting.await.unwrap(), Err(DriverError::Cancelled)));
    }

    #[tokio::test]
    async fn query_bound_keeps_the_row_limit() {
        let rows = (0..5).map(|n| vec![Value::Int(n)]).collect();
        let mut script = ConnectionScript::default();
        script
            .query_bound
            .always(FakeReply::ok(QueryResult::new(Vec::new(), rows)));
        let connection = FakeConnection::new(script);
        let limit = RowLimit::new(3).unwrap();

        let result = connection
            .query_bound(&select("SELECT n"), limit, unbounded())
            .await
            .unwrap();

        assert_eq!(result.row_count(), 3);
        assert!(result.truncated);
    }

    #[tokio::test]
    async fn a_stopped_with_reply_answers_its_outcome_only_once_cancelled() {
        let mut script = ConnectionScript::default();
        script
            .query_bound
            .always(FakeReply::StoppedWith(Err(DriverError::Busy)));
        let connection = Arc::new(FakeConnection::new(script));
        let cancel = CancellationToken::new();

        let waiting = {
            let connection = connection.clone();
            let options = CallOptions::new(None, cancel.clone());
            tokio::spawn(async move {
                connection
                    .query_bound(&select("SELECT 1"), RowLimit::EDITOR_DEFAULT, options)
                    .await
            })
        };
        tokio::task::yield_now().await;
        assert!(!waiting.is_finished(), "the call answered before it was stopped");
        let observed = connection.observed_cancels("query_bound");
        assert_eq!(observed.len(), 1);
        assert!(!observed[0].is_cancelled());

        cancel.cancel();

        assert!(matches!(waiting.await.unwrap(), Err(DriverError::Busy)));
        assert!(observed[0].is_cancelled(), "the call was handed another token");
        assert!(connection.observed_cancels("write_batch").is_empty());
    }
}
