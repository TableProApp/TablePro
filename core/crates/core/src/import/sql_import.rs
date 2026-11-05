use std::io::Read;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::call_options::CallOptions;
use crate::dialect::SqlDialect;
use crate::editor_session::EditorSession;
use crate::error::DriverError;
use crate::result_event::{ResultEvent, RunEnd};
use crate::result_sink::{ResultSink, SinkFlow};
use crate::row_limit::RowLimit;
use crate::run_options::RunOptions;
use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::{
    LexicalSettings, RefusedUnit, ScriptPlan, ScriptTokenKind, ScriptUnit, ScriptUnitKind, TransactionControl,
    transaction_control,
};
use crate::timeout_phase::TimeoutPhase;
use crate::transaction_state::TransactionState;
use crate::user_sql::UserSql;

use super::sql_file::{SqlFileError, SqlFileReader};

/// Failures a report keeps with their text. A run that continues past
/// errors counts the rest.
pub const MAX_KEPT_FAILURES: usize = 1_000;

/// Characters of a failed statement a report keeps.
const KEPT_STATEMENT_CHARS: usize = 2_000;

/// Units read ahead of the one running.
const UNITS_AHEAD: usize = 8;

/// How long a rollback or commit after the file may take.
const FINISH_DEADLINE: Duration = Duration::from_secs(120);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SqlImportErrorPolicy {
    /// Stop at the first statement that fails, as the mysql client and
    /// psql with `ON_ERROR_STOP` do.
    Stop,
    /// Note it and go on, as `mysql --force` does.
    Continue,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SqlImportOptions {
    pub on_error: SqlImportErrorPolicy,
    /// Run the whole file as one transaction, on an engine whose DDL rolls
    /// back. Only with `Stop`: a statement that failed leaves a
    /// PostgreSQL transaction refusing the rest.
    pub one_transaction: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SqlImportProgress {
    /// Bytes of the file read, before any gunzip.
    pub bytes_read: u64,
    pub statements: u64,
    pub failed: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SqlImportFailure {
    pub line: u64,
    pub statement: String,
    pub fault: SqlImportFault,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SqlImportFault {
    /// The server refused the statement.
    Statement(DriverError),
    /// A line nothing here can run.
    Refused(RefusedUnit),
    /// The file ends the transaction the import runs it in, with a
    /// ROLLBACK that would undo everything before it, or a SQL Server
    /// COMMIT or ROLLBACK that leaves the rest outside it.
    FileEndsTransaction,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SqlImportEnd {
    Completed,
    /// A statement failed and the import stopped there.
    Stopped,
    Cancelled,
    File(SqlFileError),
    /// The editor session itself failed, as on a lost connection.
    Session(DriverError),
}

#[derive(Debug, Clone, PartialEq)]
pub enum TransactionOutcome {
    /// Every statement committed as it ran, or the file's own
    /// transactions decided.
    AsWritten,
    Committed,
    RolledBack,
    /// The file left a transaction of its own open, and it was rolled
    /// back, as a client closing its connection does.
    OpenRolledBack,
    /// The commit or rollback failed, so what the server kept is unknown.
    Unknown(DriverError),
}

#[derive(Debug, Clone, PartialEq)]
pub struct SqlImportReport {
    pub end: SqlImportEnd,
    /// Statements the server ran, each `GO n` repeat counted.
    pub statements: u64,
    /// Lines passed over: psql-only lines, and the file's own transaction
    /// statements inside the import's transaction.
    pub skipped: u64,
    pub failures: Vec<SqlImportFailure>,
    pub failed: u64,
    pub transaction: TransactionOutcome,
    pub elapsed: Duration,
}

/// Run a SQL file on `editor`, a unit at a time, as the engine's own
/// client would.
///
/// The file is read on a blocking thread a piece at a time and never held
/// whole. `editor` should be a session of the import's own, so what the
/// file sets on its session stays there.
pub async fn run_sql_import(
    editor: &dyn EditorSession,
    dialect: &dyn SqlDialect,
    file: Box<dyn Read + Send>,
    options: SqlImportOptions,
    progress: &mut (dyn FnMut(SqlImportProgress) + Send),
    cancel: &CancellationToken,
) -> SqlImportReport {
    let started = Instant::now();
    let grammar = dialect.grammar();
    let reader = SqlFileReader::new(file, grammar, dialect.insert_overriding_clause());
    let consumed = reader.consumed();
    let (sender, mut units) = mpsc::channel(UNITS_AHEAD);
    let reading = tokio::task::spawn_blocking(move || {
        for unit in reader {
            if sender.blocking_send(unit).is_err() {
                return;
            }
        }
    });

    let transaction = dialect.dump().filter(|dump| {
        options.one_transaction && dump.transactional_ddl() && options.on_error == SqlImportErrorPolicy::Stop
    });
    let mut run = Run {
        editor,
        grammar,
        policy: options.on_error,
        wrapped: transaction.is_some(),
        report: SqlImportReport {
            end: SqlImportEnd::Completed,
            statements: 0,
            skipped: 0,
            failures: Vec::new(),
            failed: 0,
            transaction: TransactionOutcome::AsWritten,
            elapsed: Duration::ZERO,
        },
    };

    let mut opened = true;
    let mut began = false;
    if let Some(dump) = transaction {
        for statement in std::iter::once(dump.begin()).chain(dump.after_begin().iter().copied()) {
            if let Err(fault) = run.execute(statement, cancel).await {
                run.fail_on_setup(statement, fault);
                opened = false;
                break;
            }
            began = true;
        }
    }

    while opened && matches!(run.report.end, SqlImportEnd::Completed) {
        let next = tokio::select! {
            () = cancel.cancelled() => {
                run.report.end = SqlImportEnd::Cancelled;
                break;
            }
            next = units.recv() => next,
        };
        let Some(next) = next else {
            break;
        };
        match next {
            Ok(unit) => run.unit(unit, cancel).await,
            Err(error) => run.report.end = SqlImportEnd::File(error),
        }
        progress(SqlImportProgress {
            bytes_read: consumed.load(Ordering::Relaxed),
            statements: run.report.statements,
            failed: run.report.failed,
        });
    }
    drop(units);
    let _ = reading.await;

    run.report.transaction = match transaction {
        Some(dump) if began => match run.report.end {
            SqlImportEnd::Completed => run.finish(dump.commit(), TransactionOutcome::Committed).await,
            // SQL Server's XACT_ABORT has already rolled back after an
            // error, and a ROLLBACK then would fail for want of one.
            _ => match run.open_state().await {
                Some(false) => TransactionOutcome::RolledBack,
                Some(true) | None => run.finish(dump.rollback(), TransactionOutcome::RolledBack).await,
            },
        },
        Some(_) => TransactionOutcome::AsWritten,
        None => match run.open_state().await == Some(true) {
            true => {
                let rollback = dialect.dump().map_or("ROLLBACK", |dump| dump.rollback());
                match run.finish(rollback, TransactionOutcome::OpenRolledBack).await {
                    TransactionOutcome::OpenRolledBack if matches!(run.report.end, SqlImportEnd::Completed) => {
                        run.report.end = SqlImportEnd::Stopped;
                        TransactionOutcome::OpenRolledBack
                    }
                    outcome => outcome,
                }
            }
            false => TransactionOutcome::AsWritten,
        },
    };
    run.report.elapsed = started.elapsed();
    progress(SqlImportProgress {
        bytes_read: consumed.load(Ordering::Relaxed),
        statements: run.report.statements,
        failed: run.report.failed,
    });
    run.report
}

struct Run<'a> {
    editor: &'a dyn EditorSession,
    grammar: SqlGrammar,
    policy: SqlImportErrorPolicy,
    wrapped: bool,
    report: SqlImportReport,
}

enum Fault {
    Statement(DriverError),
    Cancelled,
    Session(DriverError),
}

impl Run<'_> {
    async fn unit(&mut self, unit: ScriptUnit, cancel: &CancellationToken) {
        let refused = match &unit.kind {
            ScriptUnitKind::ClientOnly => {
                self.report.skipped += 1;
                return;
            }
            ScriptUnitKind::Refused(refused) => Some(refused.clone()),
            ScriptUnitKind::Run => None,
        };
        if let Some(refused) = refused {
            self.failure(&unit, SqlImportFault::Refused(refused));
            return;
        }
        if self.wrapped
            && matches!(
                self.grammar,
                SqlGrammar::PostgreSql | SqlGrammar::Sqlite | SqlGrammar::DuckDb
            )
        {
            match transaction_control(&unit.text, self.grammar) {
                Some(TransactionControl::Begin | TransactionControl::Commit) => {
                    self.report.skipped += 1;
                    return;
                }
                Some(TransactionControl::Rollback) => {
                    self.failure(&unit, SqlImportFault::FileEndsTransaction);
                    self.report.end = SqlImportEnd::Stopped;
                    return;
                }
                None => {}
            }
        }
        // A SQL Server batch can hold a COMMIT or ROLLBACK among other
        // statements, or run one from a string; either would end the
        // import's transaction and leave what came before it kept.
        if self.wrapped && ends_transaction(&unit.text, self.grammar) {
            self.failure(&unit, SqlImportFault::FileEndsTransaction);
            self.report.end = SqlImportEnd::Stopped;
            return;
        }
        for _ in 0..unit.repeat.max(1) {
            match self.execute(&unit.text, cancel).await {
                Ok(()) => self.report.statements += 1,
                Err(Fault::Statement(error)) => {
                    self.failure(&unit, SqlImportFault::Statement(error));
                    return;
                }
                Err(Fault::Cancelled) => {
                    self.report.end = SqlImportEnd::Cancelled;
                    return;
                }
                Err(Fault::Session(error)) => {
                    self.report.end = SqlImportEnd::Session(error);
                    return;
                }
            }
        }
    }

    fn failure(&mut self, unit: &ScriptUnit, fault: SqlImportFault) {
        self.report.failed += 1;
        if self.report.failures.len() < MAX_KEPT_FAILURES {
            self.report.failures.push(SqlImportFailure {
                line: unit.line,
                statement: unit.text.chars().take(KEPT_STATEMENT_CHARS).collect(),
                fault,
            });
        }
        if self.policy == SqlImportErrorPolicy::Stop {
            self.report.end = SqlImportEnd::Stopped;
        }
    }

    fn fail_on_setup(&mut self, statement: &str, fault: Fault) {
        self.report.end = match fault {
            Fault::Statement(error) => {
                self.report.failed += 1;
                self.report.failures.push(SqlImportFailure {
                    line: 0,
                    statement: statement.to_owned(),
                    fault: SqlImportFault::Statement(error),
                });
                SqlImportEnd::Stopped
            }
            Fault::Cancelled => SqlImportEnd::Cancelled,
            Fault::Session(error) => SqlImportEnd::Session(error),
        };
    }

    async fn execute(&self, sql: &str, cancel: &CancellationToken) -> Result<(), Fault> {
        if cancel.is_cancelled() {
            return Err(Fault::Cancelled);
        }
        // The rows go nowhere, but a limit would stop a statement early on
        // an engine that reads through a cursor, and with it what it does.
        let options = RunOptions::new(cancel.child_token()).with_row_limit(RowLimit::LARGEST);
        match self.editor.run(UserSql::new(sql), options, Box::new(Discard)).await {
            Ok(summary) => match summary.end {
                RunEnd::Completed => Ok(()),
                RunEnd::Failed(error) => Err(Fault::Statement(error)),
                RunEnd::Cancelled => Err(Fault::Cancelled),
                RunEnd::TimedOut { server_cancelled } => Err(Fault::Statement(DriverError::Timeout {
                    phase: TimeoutPhase::Statement,
                    server_cancelled,
                })),
            },
            Err(error) => Err(Fault::Session(error)),
        }
    }

    /// Run the commit or rollback that closes the import, past a stop.
    async fn finish(&mut self, sql: &str, done: TransactionOutcome) -> TransactionOutcome {
        let cancel = CancellationToken::new();
        let watchdog = cancel.clone();
        let deadline = tokio::time::sleep(FINISH_DEADLINE);
        let outcome = tokio::select! {
            outcome = self.execute(sql, &cancel) => outcome,
            () = deadline => {
                watchdog.cancel();
                Err(Fault::Cancelled)
            }
        };
        match outcome {
            Ok(()) => done,
            Err(Fault::Statement(error) | Fault::Session(error)) => {
                if matches!(self.report.end, SqlImportEnd::Completed) {
                    self.report.end = SqlImportEnd::Stopped;
                }
                TransactionOutcome::Unknown(error)
            }
            Err(Fault::Cancelled) => TransactionOutcome::Unknown(DriverError::Cancelled),
        }
    }

    /// Whether a transaction is open on the session, where the engine
    /// can tell.
    async fn open_state(&self) -> Option<bool> {
        let options = CallOptions::new(
            Some(tokio::time::Instant::now() + FINISH_DEADLINE),
            CancellationToken::new(),
        );
        match self.editor.transaction_state(options).await {
            Ok(TransactionState::InTransaction | TransactionState::Failed) => Some(true),
            Ok(TransactionState::Idle) => Some(false),
            Ok(TransactionState::Unknown) | Err(_) => None,
        }
    }
}

/// Whether a SQL Server batch could end a transaction: a COMMIT or
/// ROLLBACK as a word, or inside a string it could run. PostgreSQL,
/// SQLite and DuckDB send a statement at a time, each told apart by
/// `transaction_control` before it runs.
fn ends_transaction(text: &str, grammar: SqlGrammar) -> bool {
    if grammar != SqlGrammar::MsSql {
        return false;
    }
    let plan = ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar));
    plan.tokens(0..text.len()).any(|token| {
        let Some(code) = text.get(token.range) else {
            return false;
        };
        let upper = code.to_ascii_uppercase();
        match token.kind {
            ScriptTokenKind::Word => upper == "COMMIT" || upper == "ROLLBACK",
            ScriptTokenKind::StringLiteral => upper.contains("COMMIT") || upper.contains("ROLLBACK"),
            _ => false,
        }
    })
}

/// The import keeps no rows: a dump's SELECTs, such as `setval`, are run
/// for what they do.
struct Discard;

#[async_trait]
impl ResultSink for Discard {
    async fn accept(&mut self, _event: ResultEvent) -> SinkFlow {
        SinkFlow::Continue
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sql_server_batch_that_ends_a_transaction_is_found_before_it_runs() {
        let ms = SqlGrammar::MsSql;

        assert!(ends_transaction("DELETE FROM t; COMMIT; BEGIN TRANSACTION;", ms));
        assert!(ends_transaction("EXEC('rollback tran')", ms));
        assert!(!ends_transaction("INSERT INTO t VALUES (1)", ms));
        assert!(!ends_transaction("COMMIT", SqlGrammar::PostgreSql));
    }
}
