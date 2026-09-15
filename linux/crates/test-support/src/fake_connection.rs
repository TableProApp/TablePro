use std::collections::VecDeque;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;
use tablepro_core::{ColumnInfo, Connection, DriverError, ExecResult, QueryResult, TableInfo, Value};

use crate::{CallCounters, CloseBehaviour, ConnectionScript, lock};

#[derive(Debug)]
pub struct FakeConnection {
    script: Mutex<ConnectionScript>,
    counters: CallCounters,
}

impl FakeConnection {
    pub fn new(script: ConnectionScript) -> Self {
        Self {
            script: Mutex::new(script),
            counters: CallCounters::default(),
        }
    }

    pub fn counters(&self) -> CallCounters {
        self.counters.clone()
    }
}

fn record(counter: &AtomicUsize) {
    counter.fetch_add(1, Ordering::SeqCst);
}

fn next<T>(queue: &mut VecDeque<Result<T, DriverError>>, method: &str) -> Result<T, DriverError> {
    queue.pop_front().unwrap_or_else(|| Err(unscripted(method)))
}

fn unscripted(method: &str) -> DriverError {
    DriverError::Protocol(format!("FakeConnection has no scripted {method} result"))
}

#[async_trait]
impl Connection for FakeConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        record(&self.counters.list_tables);
        next(&mut lock(&self.script).list_tables, "list_tables")
    }

    async fn fetch_columns(&self, _schema: Option<&str>, _table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        record(&self.counters.fetch_columns);
        next(&mut lock(&self.script).fetch_columns, "fetch_columns")
    }

    async fn fetch_rows(
        &self,
        _schema: Option<&str>,
        _table: &str,
        _offset: u64,
        _limit: u64,
    ) -> Result<QueryResult, DriverError> {
        record(&self.counters.fetch_rows);
        Err(unscripted("fetch_rows"))
    }

    async fn query(&self, _sql: &str) -> Result<QueryResult, DriverError> {
        record(&self.counters.query);
        next(&mut lock(&self.script).query, "query")
    }

    async fn execute(&self, _sql: &str) -> Result<ExecResult, DriverError> {
        record(&self.counters.execute);
        Err(unscripted("execute"))
    }

    async fn execute_params(&self, _sql: &str, _params: &[Value]) -> Result<ExecResult, DriverError> {
        record(&self.counters.execute_params);
        Err(unscripted("execute_params"))
    }

    async fn execute_in_transaction(&self, _statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        record(&self.counters.execute_in_transaction);
        next(&mut lock(&self.script).execute_in_transaction, "execute_in_transaction")
    }

    async fn ping(&self) -> Result<(), DriverError> {
        record(&self.counters.ping);
        next(&mut lock(&self.script).ping, "ping")
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        record(&self.counters.close);
        let behaviour = lock(&self.script).close;
        match behaviour {
            CloseBehaviour::Immediate => Ok(()),
            CloseBehaviour::Delay(delay) => {
                tokio::time::sleep(delay).await;
                Ok(())
            }
            CloseBehaviour::Hang => std::future::pending().await,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[tokio::test]
    async fn fake_connection_counts_each_call() {
        let connection = FakeConnection::new(
            ConnectionScript::default()
                .with_list_tables(Ok(Vec::new()))
                .with_list_tables(Err(DriverError::ConnectionLost {
                    during: tablepro_core::LossPhase::Idle,
                }))
                .with_ping(Ok(())),
        );
        let counters = connection.counters();

        assert_eq!(connection.list_tables().await.unwrap(), Vec::new());
        assert!(matches!(
            connection.list_tables().await,
            Err(DriverError::ConnectionLost { .. })
        ));
        assert!(matches!(connection.list_tables().await, Err(DriverError::Protocol(_))));
        connection.ping().await.unwrap();
        assert!(connection.fetch_rows(None, "items", 0, 10).await.is_err());
        Box::new(connection).close().await.unwrap();

        assert_eq!(counters.list_tables.load(Ordering::SeqCst), 3);
        assert_eq!(counters.ping.load(Ordering::SeqCst), 1);
        assert_eq!(counters.fetch_rows.load(Ordering::SeqCst), 1);
        assert_eq!(counters.close.load(Ordering::SeqCst), 1);
        assert_eq!(counters.query.load(Ordering::SeqCst), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn close_hang_stays_pending_under_paused_clock() {
        let hanging: Box<dyn Connection> = Box::new(FakeConnection::new(
            ConnectionScript::default().with_close(CloseBehaviour::Hang),
        ));
        let outcome = tokio::time::timeout(Duration::from_secs(600), hanging.close()).await;
        assert!(outcome.is_err());

        let delayed: Box<dyn Connection> = Box::new(FakeConnection::new(
            ConnectionScript::default().with_close(CloseBehaviour::Delay(Duration::from_secs(5))),
        ));
        let started = tokio::time::Instant::now();
        delayed.close().await.unwrap();
        assert!(started.elapsed() >= Duration::from_secs(5));
    }
}
