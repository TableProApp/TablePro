use std::io::Read;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
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
use crate::value::Value;

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
    let settings = session_settings(editor, grammar, cancel).await;
    let reader = SqlFileReader::new(file, grammar, dialect.insert_overriding_clause()).with_settings(settings);
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
    let mut first = None;
    if let Some(dump) = transaction {
        // SQLite takes `foreign_keys` only outside a transaction, so a file
        // that opens with it off, as a dump does, has it run first.
        if grammar == SqlGrammar::Sqlite {
            first = units.recv().await;
            if let Some(Ok(unit)) = &first
                && foreign_keys_off(&unit.text)
            {
                match run.execute(&unit.text, cancel).await {
                    Ok(()) => {
                        run.report.statements += 1;
                        first = None;
                    }
                    Err(fault) => {
                        run.fail_on_setup(&unit.text, fault);
                        opened = false;
                    }
                }
            }
        }
        if opened {
            for statement in std::iter::once(dump.begin()).chain(dump.after_begin().iter().copied()) {
                if let Err(fault) = run.execute(statement, cancel).await {
                    run.fail_on_setup(statement, fault);
                    opened = false;
                    break;
                }
                began = true;
            }
        }
    }

    while opened && matches!(run.report.end, SqlImportEnd::Completed) {
        let next = match first.take() {
            Some(unit) => Some(unit),
            None => tokio::select! {
                () = cancel.cancelled() => {
                    run.report.end = SqlImportEnd::Cancelled;
                    break;
                }
                next = units.recv() => next,
            },
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
            SqlImportEnd::Completed => match run.finish(dump.commit(), TransactionOutcome::Committed).await {
                // A SQL Server file that opened a transaction of its own and
                // never committed it leaves one open past the import's
                // COMMIT, which closing the session would roll back.
                TransactionOutcome::Committed if run.open_state().await == Some(true) => {
                    run.report.end = SqlImportEnd::Stopped;
                    run.finish(dump.rollback(), TransactionOutcome::OpenRolledBack).await
                }
                outcome => outcome,
            },
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
        // import's transaction and leave what came before it kept. A
        // PostgreSQL PREPARE TRANSACTION hands it to two-phase commit.
        if self.wrapped && (ends_transaction(&unit.text, self.grammar) || two_phase(&unit.text, self.grammar)) {
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
            Err(Fault::Cancelled) => {
                if matches!(self.report.end, SqlImportEnd::Completed) {
                    self.report.end = SqlImportEnd::Stopped;
                }
                TransactionOutcome::Unknown(DriverError::Cancelled)
            }
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

/// How the session reads a backslash in a string as the import starts.
/// The server's configuration decides it, and a file need not set it:
/// MySQL's `NO_BACKSLASH_ESCAPES` and PostgreSQL's
/// `standard_conforming_strings`. The default when the read fails.
async fn session_settings(
    editor: &dyn EditorSession,
    grammar: SqlGrammar,
    cancel: &CancellationToken,
) -> LexicalSettings {
    let default = LexicalSettings::default_for(grammar);
    let (query, escapes): (&str, fn(&str) -> bool) = match grammar {
        SqlGrammar::MySql => ("SELECT @@SESSION.sql_mode", |mode| {
            !mode.to_ascii_uppercase().contains("NO_BACKSLASH_ESCAPES")
        }),
        SqlGrammar::PostgreSql => ("SHOW standard_conforming_strings", |value| {
            value.trim().eq_ignore_ascii_case("off")
        }),
        _ => return default,
    };
    let seen = Arc::new(Mutex::new(None));
    let sink = FirstText {
        seen: Arc::clone(&seen),
    };
    let options = RunOptions::new(cancel.child_token());
    let ran = editor.run(UserSql::new(query), options, Box::new(sink)).await;
    if !matches!(ran.map(|summary| summary.end), Ok(RunEnd::Completed)) {
        return default;
    }
    let value = seen.lock().ok().and_then(|mut seen| seen.take());
    match value {
        Some(value) => LexicalSettings {
            backslash_escapes: escapes(&value),
        },
        None => default,
    }
}

/// The first value of the first row, as text.
struct FirstText {
    seen: Arc<Mutex<Option<String>>>,
}

#[async_trait]
impl ResultSink for FirstText {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        if let ResultEvent::Rows(rows) = event {
            let text = rows
                .into_iter()
                .next()
                .and_then(|row| row.into_iter().next())
                .and_then(|value| match value {
                    Value::Text(text) => Some(text),
                    Value::Bytes(bytes) => String::from_utf8(bytes).ok(),
                    _ => None,
                });
            if let (Some(text), Ok(mut seen)) = (text, self.seen.lock())
                && seen.is_none()
            {
                *seen = Some(text);
            }
        }
        SinkFlow::Continue
    }
}

/// `PRAGMA foreign_keys = OFF`, however it is spelled.
fn foreign_keys_off(text: &str) -> bool {
    let compact: String = text
        .chars()
        .filter(|character| !character.is_whitespace() && *character != ';')
        .collect::<String>()
        .to_ascii_lowercase();
    matches!(
        compact.as_str(),
        "pragmaforeign_keys=off" | "pragmaforeign_keys=0" | "pragmaforeign_keys=false" | "pragmaforeign_keys=no"
    )
}

/// Whether a SQL Server batch runs a COMMIT or ROLLBACK. A batch that
/// makes a procedure, function or trigger only stores its body. One that
/// builds the statement in a string and runs it is not seen here.
/// PostgreSQL, SQLite and DuckDB send a statement at a time, each told
/// apart by `transaction_control` before it runs.
fn ends_transaction(text: &str, grammar: SqlGrammar) -> bool {
    if grammar != SqlGrammar::MsSql {
        return false;
    }
    let plan = ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar));
    let words: Vec<String> = plan
        .tokens(0..text.len())
        .filter(|token| token.kind == ScriptTokenKind::Word)
        .filter_map(|token| text.get(token.range).map(str::to_ascii_uppercase))
        .collect();
    let module = words.first().is_some_and(|word| word == "CREATE" || word == "ALTER")
        && words
            .iter()
            .skip(1)
            .take(3)
            .any(|word| matches!(word.as_str(), "PROC" | "PROCEDURE" | "FUNCTION" | "TRIGGER"));
    !module && words.iter().any(|word| word == "COMMIT" || word == "ROLLBACK")
}

/// PostgreSQL's PREPARE TRANSACTION, COMMIT PREPARED or ROLLBACK
/// PREPARED, which take a transaction out of the session.
fn two_phase(text: &str, grammar: SqlGrammar) -> bool {
    if grammar != SqlGrammar::PostgreSql {
        return false;
    }
    let plan = ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar));
    let words: Vec<String> = plan
        .tokens(0..text.len())
        .filter(|token| !token.kind.is_trivia())
        .take(2)
        .filter_map(|token| text.get(token.range).map(str::to_ascii_uppercase))
        .collect();
    matches!(
        words.iter().map(String::as_str).collect::<Vec<_>>().as_slice(),
        ["PREPARE", "TRANSACTION"] | ["COMMIT" | "ROLLBACK", "PREPARED"]
    )
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
    fn a_dump_turning_foreign_keys_off_is_told_from_other_pragmas() {
        assert!(foreign_keys_off("PRAGMA foreign_keys=OFF"));
        assert!(foreign_keys_off("pragma foreign_keys = 0;"));
        assert!(!foreign_keys_off("PRAGMA foreign_keys=ON"));
        assert!(!foreign_keys_off("PRAGMA defer_foreign_keys=OFF"));
    }

    #[test]
    fn a_two_phase_command_is_told_from_a_prepared_statement() {
        let pg = SqlGrammar::PostgreSql;

        assert!(two_phase("PREPARE TRANSACTION 'load'", pg));
        assert!(two_phase("commit prepared 'load'", pg));
        assert!(two_phase("ROLLBACK PREPARED 'load'", pg));
        assert!(!two_phase("PREPARE fetch_one AS SELECT 1", pg));
        assert!(!two_phase("COMMIT", pg));
        assert!(!two_phase("PREPARE TRANSACTION 'load'", SqlGrammar::MySql));
    }

    #[test]
    fn a_sql_server_batch_that_ends_a_transaction_is_found_before_it_runs() {
        let ms = SqlGrammar::MsSql;

        assert!(ends_transaction("DELETE FROM t; COMMIT; BEGIN TRANSACTION;", ms));
        assert!(ends_transaction("rollback tran", ms));
        assert!(!ends_transaction("INSERT INTO t VALUES (N'commitment', N'COMMIT')", ms));
        assert!(!ends_transaction("CREATE PROCEDURE p AS BEGIN COMMIT END", ms));
        assert!(!ends_transaction(
            "CREATE OR ALTER TRIGGER t ON x AFTER INSERT AS ROLLBACK",
            ms
        ));
        assert!(!ends_transaction("COMMIT", SqlGrammar::PostgreSql));
    }
}
