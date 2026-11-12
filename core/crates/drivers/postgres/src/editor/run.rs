use std::sync::Arc;
use std::sync::atomic::Ordering;

use futures_util::StreamExt;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptToken};
use tablepro_core::sql_syntax::{SourceTable, SqlGrammar};
use tablepro_core::{DriverError, ResultEvent, ResultSink, RowBatch, RowLimit, RunEnd, SinkFlow, Truncation, Value};
use tokio_postgres::SimpleQueryMessage;
use tracing::debug;

use super::cursor_flight::{
    CLOSE, RELEASE_SAVEPOINT, ROLLBACK_TO_SAVEPOINT, SAVEPOINT, correct_position, declare, fetch, needs_plain_statement,
};
use super::editor_dispatch::{CursorOwner, Flight, Wrap, fallback, plan};
use super::result_origin::{self, TracedTable, traceable};
use super::session_core::{Lost, SessionCore};
use super::statement_class::{StatementClass, classify};
use super::stop_watch::{Interrupt, StopWatch};
use super::transaction_tracker::{KnownState, Next, PROBE_RELEASE, PROBE_SAVEPOINT, probe_answer};
use crate::cancel::acknowledges_stop;
use crate::catalog::text_column;
use crate::errors::{map_error, read_only_refusal, sqlstate};

/// What a message is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Role {
    /// The driver's own statement: its results and notices are not the
    /// user's data.
    Control,
    /// The driver's own statement around the user's, as the cursor's
    /// DECLARE and the COMMIT that ends it: no rows of its own, but what
    /// the server says while it runs belongs to the user's statement.
    Wrapper,
    User {
        class: StatementClass,
        cursor: bool,
    },
}

pub(crate) struct Run<'a> {
    core: &'a mut SessionCore,
    sink: &'a mut dyn ResultSink,
    watch: StopWatch,
    limit: RowLimit,
    sink_gone: bool,
    notices_sent: u64,
    notice_limit_reported: bool,
    // Set only while a cursor's FETCH is read, for its RowDescription.
    traced: Option<TracedTable>,
}

/// The result set an exchange is reading.
#[derive(Debug, Default)]
struct ResultSet {
    open: bool,
    retained: u64,
    total: u64,
    batch: RowBatch,
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
            notices_sent: 0,
            notice_limit_reported: false,
            traced: None,
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

    // A row source goes through a cursor, so a result larger than the limit stops on the server. The DECLARE and the
    // FETCH go as separate messages.
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
        let declared = self.read(&declare(text), Role::Wrapper).await?.map(correct_position);
        if declared
            .as_ref()
            .is_some_and(|error| needs_plain_statement(error) && !self.stopped())
        {
            // The statement raises the same notices again when it goes plain.
            self.core.discard_notices();
            self.abandon_cursor(owner, true).await?;
            return self.simple(text, class, fallback(owner)).await;
        }
        self.forward_notices().await;
        if let Some(error) = declared {
            self.abandon_cursor(owner, false).await?;
            return Ok(Some(error));
        }
        // With backslash escapes on, the statement the parser reads may not be the one the server ran.
        self.traced = match traceable(text, owner) {
            Some(statement) if self.core.standard_conforming_strings() => self.trace(statement).await?,
            _ => None,
        };
        let fetched = self
            .exchange(&fetch(self.limit), Role::User { class, cursor: true })
            .await?;
        self.traced = None;
        if let Some(error) = fetched {
            self.abandon_cursor(owner, false).await?;
            return Ok(Some(error));
        }
        self.exchange(CLOSE, Role::Control).await?;
        // Deferred triggers fire at the COMMIT, for the user's statement.
        let closed = match owner {
            CursorOwner::Driver { .. } => self.exchange("COMMIT", Role::Wrapper).await?,
            CursorOwner::Savepoint => self.exchange(RELEASE_SAVEPOINT, Role::Wrapper).await?,
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

    // The lookup goes in one round trip between a savepoint of the driver's own and its release, so one that fails
    // is rolled back to the savepoint and leaves the cursor's transaction and the user's rows as they were.
    async fn trace(&mut self, statement: SourceTable) -> Result<Option<TracedTable>, Lost> {
        if self.stopped() || self.watch.due().is_some() {
            return Ok(None);
        }
        self.watch.settle().await;
        let (saved, found, released) = {
            let client = &self.core.client;
            let mut flight = std::pin::pin!(async move {
                futures_util::join!(
                    client.batch_execute(result_origin::SAVEPOINT),
                    result_origin::lookup(client, statement),
                    client.batch_execute(result_origin::RELEASE_SAVEPOINT),
                )
            });
            loop {
                tokio::select! {
                    biased;
                    answers = &mut flight => break answers,
                    interrupt = self.watch.triggered(), if self.watch.fired().is_none() => {
                        let running = Some((Arc::clone(&self.core.endpoint), self.core.cancel_token.clone()));
                        self.watch.fire(interrupt, running);
                    }
                    () = self.watch.gave_up(), if self.watch.fired().is_some() => return Err(Lost),
                }
            }
        };
        self.core.discard_notices();
        if saved.is_ok() && released.is_err() && !self.stopped() {
            self.exchange(result_origin::ROLLBACK_TO_SAVEPOINT, Role::Control)
                .await?;
        }
        match (found, released) {
            (Ok(traced), Ok(())) => Ok(traced),
            (Ok(_), Err(_)) => Ok(None),
            (Err(error), _) => {
                debug!(%error, "the origin lookup of a result failed");
                Ok(None)
            }
        }
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

    /// Send one message and read everything it returns, keeping the first
    /// error. Its notices reach the sink unless it is the driver's own.
    async fn exchange(&mut self, sql: &str, role: Role) -> Result<Option<DriverError>, Lost> {
        let error = self.read(sql, role).await?;
        match role {
            Role::User { .. } | Role::Wrapper => self.forward_notices().await,
            Role::Control => self.core.discard_notices(),
        }
        Ok(error)
    }

    /// An exchange that leaves its notices queued. A stop that fires
    /// meanwhile sends the cancel request and keeps reading, because the
    /// statement's answer, its 57014 or its rows, is still on the wire.
    async fn read(&mut self, sql: &str, role: Role) -> Result<Option<DriverError>, Lost> {
        self.watch.settle().await;
        if self.stopped() && matches!(role, Role::User { .. }) {
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
        Ok(first_error)
    }

    async fn deliver(&mut self, message: SimpleQueryMessage, set: &mut ResultSet, class: StatementClass, cursor: bool) {
        match message {
            SimpleQueryMessage::RowDescription(columns) => {
                set.open = true;
                let names: Vec<String> = columns.iter().map(|column| column.name().to_owned()).collect();
                let mut origins = self
                    .traced
                    .take()
                    .map(|traced| traced.origins(&names))
                    .unwrap_or_default()
                    .into_iter();
                let columns = names
                    .iter()
                    .map(|name| text_column(name).with_origin(origins.next().flatten()))
                    .collect();
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
                    let full = set.batch.push(values);
                    set.retained += 1;
                    if full {
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
                        truncation: truncation(truncated, cursor),
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
        let rows = set.batch.take();
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
        // Read first: a drop comes after every notice queued before it.
        let dropped = self.core.notices_dropped();
        while let Some(notice) = self.core.next_notice() {
            self.notices_sent += 1;
            self.accept(ResultEvent::Notice(notice)).await;
        }
        if dropped && !self.notice_limit_reported {
            self.notice_limit_reported = true;
            self.accept(ResultEvent::NoticeLimitReached {
                retained: self.notices_sent,
            })
            .await;
        }
    }
}

/// Why a set ended where it did. A cursor that stopped at the limit
/// stopped the statement with it: what the statement does per row, a
/// function it calls in its select list included, never happened for the
/// rows past the limit, and that is what the result has to say.
fn truncation(truncated: bool, cursor: bool) -> Truncation {
    match (truncated, cursor) {
        (false, _) => Truncation::Complete,
        (true, true) => Truncation::ServerStopped,
        (true, false) => Truncation::ReadPastLimit,
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
    fn a_cursor_cut_at_the_limit_says_the_statement_stopped() {
        assert_eq!(truncation(true, true), Truncation::ServerStopped);
        assert_eq!(truncation(true, false), Truncation::ReadPastLimit);
        assert_eq!(truncation(false, true), Truncation::Complete);
    }

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
