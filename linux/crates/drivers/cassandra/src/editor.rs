//! One editor tab's CQL session.
//!
//! A tab keeps a scylla session of its own, so a `USE` in one tab moves
//! only that tab, as cqlsh moves only its own connection. CQL keeps no
//! other state on a connection: no transaction, no temporary table.

use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use scylla::response::PagingState;
use scylla::statement::unprepared::Statement as CqlStatement;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};
use tablepro_core::sql_syntax::{SqlGrammar, StatementAccess, statement_access};
use tablepro_core::{
    CallOptions, DriverError, EditorSession, EditorSessionId, EditorSessionState, ErrorCategory, LossPhase,
    ReadOnlyRefusal, ResultEvent, ResultSink, RowLimit, RunEnd, RunOptions, RunSummary, ServerNotice, SinkFlow,
    TransactionState, Truncation, UserSql,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::errors::execution_error;
use crate::rows::{ColumnsRead, MAX_PAGE_ROWS, next_state, page_size};
use crate::session::{CqlLink, LinkSlot};

/// Rows per `ResultEvent::Rows`. The sink is awaited per batch, so a slow
/// grid slows the read instead of growing a queue.
const BATCH_ROWS: usize = 256;

const READY: u8 = 0;
const RUNNING: u8 = 1;
const LOST: u8 = 2;

pub(crate) struct CqlEditorSession {
    id: EditorSessionId,
    link: LinkSlot,
    read_only: bool,
    statement_timeout: Option<Duration>,
    state: Arc<AtomicU8>,
    shutdown: CancellationToken,
}

impl CqlEditorSession {
    pub(crate) fn new(link: CqlLink, read_only: bool, statement_timeout: Option<Duration>) -> Self {
        Self {
            id: EditorSessionId::new(),
            link: LinkSlot::new(link),
            read_only,
            statement_timeout,
            state: Arc::new(AtomicU8::new(READY)),
            shutdown: CancellationToken::new(),
        }
    }

    fn begin(&self) -> Result<(), DriverError> {
        match self
            .state
            .compare_exchange(READY, RUNNING, Ordering::SeqCst, Ordering::SeqCst)
        {
            Ok(_) => Ok(()),
            Err(RUNNING) => Err(DriverError::EditorSessionBusy),
            Err(_) => Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            }),
        }
    }
}

#[async_trait]
impl EditorSession for CqlEditorSession {
    fn id(&self) -> EditorSessionId {
        self.id
    }

    fn state(&self) -> EditorSessionState {
        match self.state.load(Ordering::SeqCst) {
            READY => EditorSessionState::Ready,
            RUNNING => EditorSessionState::Running,
            _ => EditorSessionState::Lost,
        }
    }

    /// The run goes on a task of its own, so a dropped caller is a
    /// cancel that still settles the session.
    async fn run(
        &self,
        sql: UserSql,
        options: RunOptions,
        sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        let link = self.link.get()?;
        self.begin()?;
        let guard = options.cancel.clone().drop_guard();
        let run = Run {
            link,
            read_only: self.read_only,
            statement_timeout: self.statement_timeout,
            shutdown: self.shutdown.clone(),
        };
        let state = self.state.clone();
        let running = tokio::spawn(async move {
            let outcome = run.run(sql, options, sink).await;
            let next = match &outcome {
                Ok(_) => READY,
                Err(_) => LOST,
            };
            let _ = state.compare_exchange(RUNNING, next, Ordering::SeqCst, Ordering::SeqCst);
            outcome
        });
        let outcome = running.await.unwrap_or_else(|_| {
            self.state.store(LOST, Ordering::SeqCst);
            Err(DriverError::ConnectionLost {
                during: LossPhase::Statement,
            })
        });
        drop(guard.disarm());
        outcome
    }

    async fn transaction_state(&self, _options: CallOptions) -> Result<TransactionState, DriverError> {
        match self.state() {
            EditorSessionState::Lost => Err(DriverError::ConnectionLost {
                during: LossPhase::Idle,
            }),
            EditorSessionState::Ready | EditorSessionState::Running => Ok(TransactionState::Idle),
        }
    }

    /// A run still going stops waiting for its statement, which the
    /// server runs to its own timeout.
    async fn close(&self) {
        self.shutdown.cancel();
        self.state.store(LOST, Ordering::SeqCst);
        self.link.release();
    }
}

/// Why a run stopped before its statement did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Interrupt {
    Cancelled,
    DeadlineElapsed,
    ConsumerGone,
}

impl Interrupt {
    /// The server was never told, so a deadline never reads as a
    /// statement the server cancelled.
    fn end(self) -> RunEnd {
        match self {
            Self::DeadlineElapsed => RunEnd::TimedOut {
                server_cancelled: false,
            },
            Self::Cancelled | Self::ConsumerGone => RunEnd::Cancelled,
        }
    }
}

struct Run {
    link: Arc<CqlLink>,
    read_only: bool,
    statement_timeout: Option<Duration>,
    shutdown: CancellationToken,
}

/// What a statement left for the script: carry on, or end the run here.
enum StatementEnd {
    Done,
    Stopped(RunEnd),
}

impl Run {
    /// Each statement of the script in turn, as cqlsh splits it. A failed
    /// or stopped statement is the last.
    async fn run(
        self,
        sql: UserSql,
        options: RunOptions,
        sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        let started = Instant::now();
        let plan = ScriptPlan::build(
            sql.as_str(),
            SqlGrammar::Cql,
            LexicalSettings::default_for(SqlGrammar::Cql),
        );
        let mut emitter = Emitter {
            sink,
            consumer_gone: false,
        };
        let run_deadline = options.deadline.map(|deadline| started + deadline);
        let mut end = RunEnd::Completed;
        for statement in plan.statements() {
            let text = statement.text(sql.as_str());
            if self.read_only && statement_access(text, SqlGrammar::Cql) != StatementAccess::Read {
                end = RunEnd::Failed(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
                break;
            }
            let statement_deadline = self.statement_timeout.map(|timeout| Instant::now() + timeout);
            let deadline = match (run_deadline, statement_deadline) {
                (Some(run), Some(statement)) => Some(run.min(statement)),
                (run, statement) => run.or(statement),
            };
            let stop = Stop {
                cancel: &options.cancel,
                shutdown: &self.shutdown,
                deadline,
            };
            match self.statement(text, options.row_limit, &stop, &mut emitter).await {
                Ok(StatementEnd::Done) => {}
                Ok(StatementEnd::Stopped(stopped)) => {
                    end = stopped;
                    break;
                }
                Err(error) if lost(&error) => return Err(error),
                Err(error) => {
                    end = RunEnd::Failed(error);
                    break;
                }
            }
        }
        Ok(RunSummary {
            elapsed: started.elapsed(),
            end,
            transaction_state: TransactionState::Idle,
        })
    }

    /// One statement, page by page. A page is asked for only once the
    /// sink took the last, and once the set passes the row limit no
    /// further page is asked for, so the server never reads past it.
    async fn statement(
        &self,
        text: &str,
        limit: RowLimit,
        stop: &Stop<'_>,
        emitter: &mut Emitter,
    ) -> Result<StatementEnd, DriverError> {
        let mut statement = CqlStatement::new(text);
        let mut paging = PagingState::start();
        let mut read: Option<ColumnsRead> = None;
        let mut retained: u64 = 0;
        loop {
            let wanted = (limit.get().saturating_sub(retained) + 1).min(MAX_PAGE_ROWS);
            statement.set_page_size(page_size(wanted));
            let page = self.link.session().query_single_page(statement.clone(), (), paging);
            let (result, response) = tokio::select! {
                biased;
                interrupt = stop.triggered() => return Ok(StatementEnd::Stopped(interrupt.end())),
                page = page => page.map_err(|error| execution_error(error, LossPhase::Statement))?,
            };
            for warning in result.warnings() {
                emitter
                    .send(ResultEvent::Notice(ServerNotice {
                        severity: "WARNING".to_owned(),
                        message: warning.to_owned(),
                        code: None,
                    }))
                    .await;
            }
            if !result.is_rows() {
                emitter
                    .send(ResultEvent::CommandCompleted { rows_affected: None })
                    .await;
                return Ok(self.settled(emitter));
            }
            let rows = result
                .into_rows_result()
                .map_err(|error| DriverError::Protocol(error.to_string()))?;
            if read.is_none() {
                let columns = ColumnsRead::of(rows.column_specs());
                emitter
                    .send(ResultEvent::ResultSetStarted {
                        columns: columns.columns.clone(),
                    })
                    .await;
                read = Some(columns);
            }
            let decoded = read.as_ref().map_or(Ok(Vec::new()), |columns| columns.decode(&rows))?;
            let room = usize::try_from(limit.get().saturating_sub(retained)).unwrap_or(usize::MAX);
            let past_limit = decoded.len() > room;
            let kept: Vec<_> = decoded.into_iter().take(room).collect();
            retained += kept.len() as u64;
            for batch in kept.chunks(BATCH_ROWS) {
                emitter.send(ResultEvent::Rows(batch.to_vec())).await;
            }
            if past_limit {
                emitter.send(ResultEvent::RowLimitReached { retained }).await;
                emitter
                    .send(ResultEvent::ResultSetFinished {
                        retained,
                        total_rows: None,
                        truncation: Truncation::ServerStopped,
                    })
                    .await;
                return Ok(self.settled(emitter));
            }
            if emitter.consumer_gone {
                return Ok(StatementEnd::Stopped(Interrupt::ConsumerGone.end()));
            }
            match next_state(response) {
                Some(next) => paging = next,
                None => {
                    emitter
                        .send(ResultEvent::ResultSetFinished {
                            retained,
                            total_rows: Some(retained),
                            truncation: Truncation::Complete,
                        })
                        .await;
                    return Ok(self.settled(emitter));
                }
            }
        }
    }

    fn settled(&self, emitter: &Emitter) -> StatementEnd {
        match emitter.consumer_gone {
            true => StatementEnd::Stopped(Interrupt::ConsumerGone.end()),
            false => StatementEnd::Done,
        }
    }
}

struct Stop<'a> {
    cancel: &'a CancellationToken,
    shutdown: &'a CancellationToken,
    deadline: Option<Instant>,
}

impl Stop<'_> {
    async fn triggered(&self) -> Interrupt {
        let deadline = async {
            match self.deadline {
                Some(at) => tokio::time::sleep_until(at).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            () = self.cancel.cancelled() => Interrupt::Cancelled,
            () = self.shutdown.cancelled() => Interrupt::Cancelled,
            () = deadline => Interrupt::DeadlineElapsed,
        }
    }
}

struct Emitter {
    sink: Box<dyn ResultSink>,
    consumer_gone: bool,
}

impl Emitter {
    async fn send(&mut self, event: ResultEvent) {
        if self.consumer_gone {
            return;
        }
        if self.sink.accept(event).await == SinkFlow::ConsumerGone {
            self.consumer_gone = true;
        }
    }
}

/// A failure of the session's link rather than of the statement.
fn lost(error: &DriverError) -> bool {
    matches!(
        error.category(),
        ErrorCategory::Network | ErrorCategory::ConnectionLost | ErrorCategory::Tls
    )
}
