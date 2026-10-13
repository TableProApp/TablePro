use std::sync::Arc;
use std::sync::atomic::Ordering;

use futures_util::StreamExt;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptToken};
use tablepro_core::{
    DriverError, ResultEvent, ResultSink, RowLimit, RunEnd, ServerCode, ServerNotice, SinkFlow, Truncation, Value,
};
use tokio_postgres::SimpleQueryMessage;

use super::cursor_flight::{
    CLOSE, RELEASE_SAVEPOINT, ROLLBACK_TO_SAVEPOINT, SAVEPOINT, correct_position, declare, fetch, needs_plain_statement,
};
use super::editor_dispatch::{CursorOwner, Flight, Wrap, fallback, plan};
use super::session_core::{Lost, SessionCore};
use super::statement_class::{StatementClass, classify};
use super::stop_watch::{Interrupt, StopWatch};
use super::transaction_tracker::{KnownState, Next, PROBE_RELEASE, PROBE_SAVEPOINT, probe_answer};
use crate::cancel::acknowledges_stop;
use crate::catalog::text_column;
use crate::errors::{map_error, read_only_refusal, sqlstate};

/// Rows per `ResultEvent::Rows`. The sink is awaited per batch, so a slow
/// grid slows the read instead of growing a queue.
const BATCH_ROWS: usize = 256;

/// What a message is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Role {
    /// The driver's own statement: its results and notices are not the
    /// user's data.
    Control,
    User {
        class: StatementClass,
        cursor: bool,
    },
}

/// One run of user SQL on the session.
pub(crate) struct Run<'a> {
    core: &'a mut SessionCore,
    sink: &'a mut dyn ResultSink,
    watch: StopWatch,
    limit: RowLimit,
    sink_gone: bool,
}

/// The result set an exchange is reading.
#[derive(Debug, Default)]
struct ResultSet {
    open: bool,
    retained: u64,
    total: u64,
    batch: Vec<Vec<Value>>,
    limit_reported: bool,
}

impl<'a> Run<'a> {
    pub(crate) fn new(
        core: &'a mut SessionCore,
        sink: &'a mut dyn ResultSink,
        watch: StopWatch,
        limit: RowLimit,
    ) -> Self {
        Self {
            core,
            sink,
            watch,
            limit,
            sink_gone: false,
        }
    }

    pub(crate) fn stopped(&self) -> bool {
        self.watch.fired().is_some()
    }

    /// Run the script one statement at a time, as psql does, stopping at
    /// the first failure.
    pub(crate) async fn script(&mut self, sql: &str) -> Result<RunEnd, Lost> {
        let mut offset = 0;
        'plans: loop {
            let conforming = self.core.standard_conforming_strings();
            let rest = sql.get(offset..).unwrap_or_default();
            let plan = ScriptPlan::build(
                rest,
                SqlGrammar::PostgreSql,
                LexicalSettings {
                    backslash_escapes: !conforming,
                },
            );
            for statement in plan.statements() {
                if let Some(interrupt) = self.watch.due() {
                    self.watch.fire(interrupt, None);
                }
                if let Some(interrupt) = self.watch.fired() {
                    return Ok(end_after_stop(interrupt, &DriverError::Cancelled));
                }
                let tokens: Vec<ScriptToken> = plan.tokens(statement.range.clone()).collect();
                let class = classify(rest, &tokens);
                self.watch.begin_statement(self.core.statement_timeout());
                if let Some(error) = self.statement(statement.text(rest), class).await? {
                    return Ok(match self.watch.fired() {
                        Some(interrupt) => end_after_stop(interrupt, &error),
                        None => RunEnd::Failed(error),
                    });
                }
                // A statement that switched standard_conforming_strings
                // changes how the rest of the script reads.
                if self.core.standard_conforming_strings() != conforming {
                    offset += statement.extent.end;
                    continue 'plans;
                }
            }
            return Ok(match self.watch.fired() {
                Some(interrupt) => end_after_stop(interrupt, &DriverError::Cancelled),
                None => RunEnd::Completed,
            });
        }
    }

    async fn statement(&mut self, text: &str, class: StatementClass) -> Result<Option<DriverError>, Lost> {
        match plan(class, self.core.tracker.state(), self.core.read_only) {
            Flight::Refuse(error) => Ok(Some(error)),
            Flight::Simple(wrap) => self.simple(text, class, wrap).await,
            Flight::Cursor(owner) => self.cursor(text, class, owner).await,
        }
    }

    async fn simple(&mut self, text: &str, class: StatementClass, wrap: Wrap) -> Result<Option<DriverError>, Lost> {
        let user = Role::User { class, cursor: false };
        match wrap {
            Wrap::None => {
                let error = self.exchange(text, user).await?;
                self.track(class, error.is_none()).await?;
                Ok(error)
            }
            Wrap::ReadOnlyTransaction => {
                if let Some(error) = self.exchange("START TRANSACTION READ ONLY", Role::Control).await? {
                    return Ok(Some(error));
                }
                let error = self.exchange(text, user).await?;
                // After a failure the COMMIT ends the aborted block as a
                // rollback, so either way the session is idle again.
                self.exchange("COMMIT", Role::Control).await?;
                self.core.tracker.set(KnownState::Idle);
                Ok(error.map(read_only_refusal))
            }
            Wrap::ReadOnlyAfterStart => {
                let error = self.exchange(text, user).await?;
                if error.is_none() {
                    self.exchange("SET TRANSACTION READ ONLY", Role::Control).await?;
                }
                self.track(class, error.is_none()).await?;
                Ok(error)
            }
        }
    }

    /// A row source read through a cursor, so a result larger than the
    /// limit stops on the server. The DECLARE and the FETCH go as
    /// separate messages.
    async fn cursor(
        &mut self,
        text: &str,
        class: StatementClass,
        owner: CursorOwner,
    ) -> Result<Option<DriverError>, Lost> {
        let open = match owner {
            CursorOwner::Driver { read_only: true } => "START TRANSACTION READ ONLY",
            CursorOwner::Driver { read_only: false } => "BEGIN",
            CursorOwner::Savepoint => SAVEPOINT,
        };
        if let Some(error) = self.exchange(open, Role::Control).await? {
            return Ok(Some(error));
        }
        if let Some(error) = self.exchange(&declare(text), Role::Control).await? {
            let error = correct_position(error);
            if needs_plain_statement(&error) && !self.stopped() {
                self.abandon_cursor(owner, true).await?;
                return self.simple(text, class, fallback(owner)).await;
            }
            self.abandon_cursor(owner, false).await?;
            return Ok(Some(error));
        }
        let fetched = self
            .exchange(&fetch(self.limit), Role::User { class, cursor: true })
            .await?;
        if let Some(error) = fetched {
            self.abandon_cursor(owner, false).await?;
            return Ok(Some(error));
        }
        self.exchange(CLOSE, Role::Control).await?;
        let closed = match owner {
            CursorOwner::Driver { .. } => self.exchange("COMMIT", Role::Control).await?,
            CursorOwner::Savepoint => self.exchange(RELEASE_SAVEPOINT, Role::Control).await?,
        };
        Ok(closed)
    }

    /// Undo the cursor's own transaction or savepoint after a failure.
    ///
    /// Inside the user's transaction a statement that really failed still
    /// aborts it, as it would without the row limit; only a DECLARE the
    /// cursor itself caused to fail is rolled back to the savepoint.
    async fn abandon_cursor(&mut self, owner: CursorOwner, refused_declare: bool) -> Result<(), Lost> {
        match (owner, refused_declare) {
            (CursorOwner::Driver { .. }, _) => {
                self.exchange("ROLLBACK", Role::Control).await?;
                self.core.tracker.set(KnownState::Idle);
            }
            (CursorOwner::Savepoint, true) => {
                self.exchange(ROLLBACK_TO_SAVEPOINT, Role::Control).await?;
                self.exchange(RELEASE_SAVEPOINT, Role::Control).await?;
            }
            (CursorOwner::Savepoint, false) => self.core.tracker.set(KnownState::Failed),
        }
        Ok(())
    }

    async fn track(&mut self, class: StatementClass, succeeded: bool) -> Result<(), Lost> {
        match self.core.tracker.after(class, succeeded) {
            Next::Known(state) => {
                self.core.tracker.set(state);
                Ok(())
            }
            Next::Probe => self.probe().await,
        }
    }

    /// Ask the server where the session stands: SAVEPOINT succeeds only
    /// inside a healthy block, and its two errors name the other states.
    pub(crate) async fn probe(&mut self) -> Result<(), Lost> {
        for _ in 0..2 {
            let error = self.exchange(PROBE_SAVEPOINT, Role::Control).await?;
            match probe_answer(error.as_ref().and_then(sqlstate)) {
                Some(KnownState::InTransaction) => {
                    self.exchange(PROBE_RELEASE, Role::Control).await?;
                    self.core.tracker.set(KnownState::InTransaction);
                    return Ok(());
                }
                Some(state) => {
                    self.core.tracker.set(state);
                    return Ok(());
                }
                // A cancel that landed on the probe itself; ask again.
                None => {}
            }
        }
        Err(Lost)
    }

    /// Send one message and read everything it returns, keeping the
    /// first error. A stop that fires meanwhile sends the cancel request
    /// and keeps reading, because the statement's answer, its 57014 or
    /// its rows, is still on the wire.
    async fn exchange(&mut self, sql: &str, role: Role) -> Result<Option<DriverError>, Lost> {
        self.watch.settle().await;
        if self.stopped() && role != Role::Control {
            return Ok(Some(DriverError::Cancelled));
        }
        let stream = match self.core.client.simple_query_raw(sql).await {
            Ok(stream) => stream,
            Err(_) => return Err(Lost),
        };
        let mut stream = std::pin::pin!(stream);
        let mut set = ResultSet::default();
        let mut first_error = None;
        loop {
            let next = tokio::select! {
                biased;
                next = stream.next() => next,
                interrupt = self.watch.triggered(), if !self.stopped() => {
                    let running = Some((Arc::clone(&self.core.endpoint), self.core.cancel_token.clone()));
                    self.watch.fire(interrupt, running);
                    continue;
                }
                () = self.watch.gave_up(), if self.stopped() => return Err(Lost),
            };
            match next {
                None => break,
                Some(Ok(message)) => {
                    if let Role::User { class, cursor } = role {
                        self.deliver(message, &mut set, class, cursor).await;
                    }
                }
                // Anything but a server error means the connection itself
                // failed, and the stream will not reach its end.
                Some(Err(error)) if error.as_db_error().is_none() => return Err(Lost),
                Some(Err(error)) => {
                    first_error.get_or_insert_with(|| map_error(&error));
                }
            }
        }
        match role {
            Role::User { .. } => self.forward_notices().await,
            Role::Control => self.core.discard_notices(),
        }
        Ok(first_error)
    }

    async fn deliver(&mut self, message: SimpleQueryMessage, set: &mut ResultSet, class: StatementClass, cursor: bool) {
        match message {
            SimpleQueryMessage::RowDescription(columns) => {
                set.open = true;
                let columns = columns.iter().map(|column| text_column(column.name())).collect();
                self.send(ResultEvent::ResultSetStarted { columns }).await;
            }
            SimpleQueryMessage::Row(row) => {
                set.total += 1;
                if set.retained < self.limit.get() {
                    let values = (0..row.len())
                        .map(|index| match row.get(index) {
                            Some(text) => Value::Text(text.to_owned()),
                            None => Value::Null,
                        })
                        .collect();
                    set.batch.push(values);
                    set.retained += 1;
                    if set.batch.len() >= BATCH_ROWS {
                        self.flush(set).await;
                    }
                } else if !set.limit_reported {
                    set.limit_reported = true;
                    self.flush(set).await;
                    self.send(ResultEvent::RowLimitReached { retained: set.retained }).await;
                }
            }
            SimpleQueryMessage::CommandComplete(count) => {
                if set.open {
                    self.flush(set).await;
                    let truncated = set.total > set.retained;
                    self.send(ResultEvent::ResultSetFinished {
                        retained: set.retained,
                        // A cursor stops one row past the limit, so how
                        // many rows there were in all is not known.
                        total_rows: (!(cursor && truncated)).then_some(set.total),
                        truncation: if truncated {
                            Truncation::ReadPastLimit
                        } else {
                            Truncation::Complete
                        },
                    })
                    .await;
                    *set = ResultSet::default();
                } else {
                    self.send(ResultEvent::CommandCompleted {
                        rows_affected: class.reports_rows().then_some(count),
                    })
                    .await;
                }
            }
            _ => {}
        }
    }

    async fn flush(&mut self, set: &mut ResultSet) {
        if set.batch.is_empty() {
            return;
        }
        let rows = std::mem::take(&mut set.batch);
        self.send(ResultEvent::Rows(rows)).await;
    }

    async fn send(&mut self, event: ResultEvent) {
        self.forward_notices().await;
        self.accept(event).await;
    }

    async fn accept(&mut self, event: ResultEvent) {
        if self.sink_gone {
            return;
        }
        if self.sink.accept(event).await == SinkFlow::ConsumerGone {
            self.sink_gone = true;
            let running = Some((Arc::clone(&self.core.endpoint), self.core.cancel_token.clone()));
            self.watch.fire(Interrupt::ConsumerGone, running);
        }
    }

    pub(crate) async fn forward_notices(&mut self) {
        while let Some(notice) = self.core.next_notice() {
            self.accept(ResultEvent::Notice(ServerNotice {
                severity: notice.severity().to_owned(),
                message: notice.message().to_owned(),
                code: Some(ServerCode::SqlState(notice.code().code().to_owned())),
            }))
            .await;
        }
    }
}

/// How a run that was stopped ends. The server's 57014 is the
/// acknowledgement; any other error was the statement's own.
fn end_after_stop(interrupt: Interrupt, error: &DriverError) -> RunEnd {
    match interrupt {
        Interrupt::Cancelled | Interrupt::ConsumerGone => RunEnd::Cancelled,
        Interrupt::DeadlineElapsed => RunEnd::TimedOut {
            server_cancelled: acknowledges_stop(error),
        },
    }
}

impl SessionCore {
    fn standard_conforming_strings(&self) -> bool {
        self.conforming.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::TimeoutPhase;

    use super::*;

    #[test]
    fn a_stopped_run_ends_by_what_stopped_it() {
        let acknowledged = DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        };

        assert_eq!(end_after_stop(Interrupt::Cancelled, &acknowledged), RunEnd::Cancelled);
        assert_eq!(
            end_after_stop(Interrupt::ConsumerGone, &DriverError::Cancelled),
            RunEnd::Cancelled
        );
        assert_eq!(
            end_after_stop(Interrupt::DeadlineElapsed, &acknowledged),
            RunEnd::TimedOut { server_cancelled: true }
        );
        assert_eq!(
            end_after_stop(Interrupt::DeadlineElapsed, &DriverError::Cancelled),
            RunEnd::TimedOut {
                server_cancelled: false
            }
        );
    }
}
