use std::ops::Range;
use std::sync::Arc;

use futures_util::{Stream, TryStreamExt};
use sqlx::mysql::{MySqlColumn, MySqlConnection, MySqlQueryResult, MySqlRow};
use sqlx::{AssertSqlSafe, Either, Executor as _, Row as _, SqlSafeStr as _, Statement as _};
use tablepro_core::column::ResultColumn;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};
use tablepro_core::sql_syntax::{SourceTable, SqlGrammar, StatementAccess, source_table, statement_access};
use tablepro_core::{DriverError, ErrorCategory, ResultEvent, ResultSink, RowLimit, SinkFlow, Truncation, Value};
use tokio_util::sync::CancellationToken;

use crate::catalog::result_column;
use crate::column_origins::TracedSet;
use crate::decode::decode_row;
use crate::errors::map_error;
use crate::flavour::MySqlFlavour;
use crate::mysql_timestamp_mode::MySqlTimestampMode;
use crate::mysql_wire_format::MySqlWireFormat;
use crate::script_split;
use crate::session_statements::SelectLimit;

const ROWS_PER_EVENT: usize = 256;

const SELECT_OPENERS: [&str; 4] = ["SELECT", "WITH", "TABLE", "VALUES"];

// Ordered, so a text the server runs whole takes its strictest statement's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum TextKind {
    Other,
    // No INTO, lock or state change: the limit stops it, and its OK alone is an empty set.
    PlainRead,
    // A SELECT the limit would cut beyond what it shows, or an EXECUTE that may run one.
    CutSelect,
}

pub(crate) struct EditorLink {
    pub connection: MySqlConnection,
    // None once a SET failed, since a KILL that stopped it may have come after it took.
    pub select_limit: Option<SelectLimit>,
}

impl EditorLink {
    pub(crate) fn new(connection: MySqlConnection) -> Self {
        Self {
            connection,
            select_limit: Some(SelectLimit::Server),
        }
    }

    async fn limit_selects(&mut self, flavour: MySqlFlavour, wanted: SelectLimit) -> Result<(), DriverError> {
        if self.select_limit == Some(wanted) {
            return Ok(());
        }
        self.select_limit = None;
        self.connection
            .execute(AssertSqlSafe(wanted.statement()))
            .await
            .map_err(|error| map_error(&error, flavour))?;
        self.select_limit = Some(wanted);
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct RunOutcome {
    pub consumer_gone: bool,
    // A stop came between two statements, so the rest was not sent.
    pub halted: bool,
    pub traced: Option<TracedSet>,
}

// A sink that stops reading cancels `stopped`; the text already sent is still read to its end, unshown, since only that frees the connection.
pub(crate) async fn run_script(
    link: &mut EditorLink,
    flavour: MySqlFlavour,
    sql: &str,
    limit: RowLimit,
    sink: &mut dyn ResultSink,
    stopped: &CancellationToken,
    halt: impl Fn() -> bool,
) -> Result<RunOutcome, DriverError> {
    let texts = script_split::texts(sql);
    // The table is looked up once the run is over, when only a run of one statement still has what that statement read.
    let trace = match texts.as_slice() {
        [text] => source_table(text, SqlGrammar::MySql).ok(),
        _ => None,
    };
    let mut emitter = Emitter {
        sink,
        limit: limit.get(),
        open: None,
        held_back: None,
        sets: 0,
        gone: false,
        trace,
        traced: None,
    };
    let kinds: Vec<TextKind> = texts.iter().map(|text| text_kind(text)).collect();
    // Once, before the first statement: a SET between two would reset ROW_COUNT() and the warnings.
    if let Some(wanted) = wanted_select_limit(&kinds, limit) {
        link.limit_selects(flavour, wanted).await?;
    }
    let stopping = || stopped.is_cancelled() || halt();
    let mut halted = false;
    for (text, kind) in texts.into_iter().zip(kinds) {
        if emitter.gone {
            break;
        }
        if stopping() {
            halted = true;
            break;
        }
        let results = link
            .connection
            .fetch_many(sqlx::raw_sql(AssertSqlSafe(text.to_owned())));
        let read = emitter
            .read(results, flavour, stopped, kind == TextKind::PlainRead)
            .await;
        if read.is_err() {
            emitter.release().await;
        }
        read?;
        // sqlx gives an empty set as its OK alone, and the prepare's columns tell it from a statement that sends no rows.
        if let Some(rows_affected) = emitter.held_back.take() {
            let columns = match stopping() {
                true => Vec::new(),
                false => described(&mut link.connection, flavour, text).await?,
            };
            emitter.answered(rows_affected, &columns).await;
        }
    }
    Ok(RunOutcome {
        consumer_gone: emitter.gone,
        halted,
        traced: emitter.traced,
    })
}

// The server cuts every top-level SELECT without a LIMIT, INTO OUTFILE and locking ones too, so one of those lifts it for the run.
fn wanted_select_limit(kinds: &[TextKind], limit: RowLimit) -> Option<SelectLimit> {
    if kinds.contains(&TextKind::CutSelect) {
        return Some(SelectLimit::Server);
    }
    kinds
        .contains(&TextKind::PlainRead)
        .then_some(SelectLimit::Editor(limit.get()))
}

// Read with backslash escapes on and off, since the session's sql_mode decides where its strings end.
fn text_kind(text: &str) -> TextKind {
    [true, false]
        .into_iter()
        .map(|backslash_escapes| {
            let plan = ScriptPlan::build(text, SqlGrammar::MySql, LexicalSettings { backslash_escapes });
            plan.statements()
                .iter()
                .map(|statement| statement_kind(&plan, text, statement.range.clone()))
                .max()
                .unwrap_or(TextKind::Other)
        })
        .max()
        .unwrap_or(TextKind::Other)
}

fn statement_kind(plan: &ScriptPlan, text: &str, range: Range<usize>) -> TextKind {
    let Some(word) = opening_word(plan, text, range.clone()) else {
        return TextKind::Other;
    };
    if !SELECT_OPENERS.iter().any(|opener| opener.eq_ignore_ascii_case(word)) {
        return match word.eq_ignore_ascii_case("EXECUTE") {
            true => TextKind::CutSelect,
            false => TextKind::Other,
        };
    }
    // statement_access reads INTO, FOR UPDATE, FOR SHARE and LOCK IN SHARE MODE as writes.
    match text
        .get(range)
        .is_some_and(|statement| statement_access(statement, SqlGrammar::MySql) == StatementAccess::Read)
    {
        true => TextKind::PlainRead,
        false => TextKind::CutSelect,
    }
}

fn opening_word<'a>(plan: &ScriptPlan, text: &'a str, range: Range<usize>) -> Option<&'a str> {
    let first = plan.tokens(range).find(|token| {
        !token.kind.is_trivia()
            && !matches!(
                token.kind,
                ScriptTokenKind::OpenParen | ScriptTokenKind::ExecutableMarker
            )
    })?;
    match first.kind {
        ScriptTokenKind::Word => text.get(first.range),
        _ => None,
    }
}

// The session caches no statement, so sqlx closes this one at once.
async fn described(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    text: &str,
) -> Result<Vec<MySqlColumn>, DriverError> {
    let prepared = (&mut *connection)
        .prepare(AssertSqlSafe(text.to_owned()).into_sql_str())
        .await;
    match prepared {
        Ok(statement) => Ok(statement.columns().to_vec()),
        Err(error) => match map_error(&error, flavour) {
            lost if lost.category() == ErrorCategory::ConnectionLost => Err(lost),
            // Not every statement can be prepared, and text the server reads as several cannot.
            _ => Ok(Vec::new()),
        },
    }
}

struct OpenSet {
    batch: Vec<Vec<Value>>,
    retained: u64,
    seen: u64,
}

struct Emitter<'a> {
    sink: &'a mut dyn ResultSink,
    limit: u64,
    open: Option<OpenSet>,
    // The rows affected of a text's first answer, an OK with no set, kept until the text ends.
    held_back: Option<u64>,
    sets: usize,
    gone: bool,
    trace: Option<SourceTable>,
    traced: Option<TracedSet>,
}

impl Emitter<'_> {
    async fn read<S>(
        &mut self,
        results: S,
        flavour: MySqlFlavour,
        stopped: &CancellationToken,
        plain_read: bool,
    ) -> Result<(), DriverError>
    where
        S: Stream<Item = Result<Either<MySqlQueryResult, MySqlRow>, sqlx::Error>>,
    {
        let mut results = std::pin::pin!(results);
        let mut first = true;
        while let Some(item) = results.try_next().await.map_err(|error| map_error(&error, flavour))? {
            match item {
                Either::Right(row) => self.row(&row).await,
                Either::Left(done) => self.done(done.rows_affected(), first && plain_read).await,
            }
            first = false;
            if self.gone {
                stopped.cancel();
            }
        }
        Ok(())
    }

    async fn row(&mut self, row: &MySqlRow) {
        if self.gone {
            return;
        }
        if self.open.is_none() {
            self.release().await;
            self.open_set(row.columns()).await;
            self.open = Some(OpenSet {
                batch: Vec::new(),
                retained: 0,
                seen: 0,
            });
        }
        let limit = self.limit;
        let Some(set) = self.open.as_mut() else {
            return;
        };
        set.seen += 1;
        if set.retained >= limit {
            return;
        }
        set.batch
            .push(decode_row(row, MySqlWireFormat::Text, MySqlTimestampMode::SessionLocal));
        set.retained += 1;
        if set.batch.len() >= ROWS_PER_EVENT {
            let rows = std::mem::take(&mut set.batch);
            self.send(ResultEvent::Rows(rows)).await;
        }
    }

    async fn done(&mut self, rows_affected: u64, may_be_an_empty_set: bool) {
        if self.gone {
            return;
        }
        let Some(set) = self.open.take() else {
            if may_be_an_empty_set {
                self.held_back = Some(rows_affected);
                return;
            }
            self.release().await;
            self.send(ResultEvent::CommandCompleted {
                rows_affected: Some(rows_affected),
            })
            .await;
            return;
        };
        if !set.batch.is_empty() {
            self.send(ResultEvent::Rows(set.batch)).await;
        }
        let (truncation, total_rows) = truncation(set.seen, self.limit);
        if truncation != Truncation::Complete {
            self.send(ResultEvent::RowLimitReached { retained: set.retained }).await;
        }
        self.send(ResultEvent::ResultSetFinished {
            retained: set.retained,
            total_rows,
            truncation,
        })
        .await;
    }

    async fn answered(&mut self, rows_affected: u64, columns: &[MySqlColumn]) {
        if columns.is_empty() {
            self.send(ResultEvent::CommandCompleted {
                rows_affected: Some(rows_affected),
            })
            .await;
            return;
        }
        self.open_set(columns).await;
        self.send(ResultEvent::ResultSetFinished {
            retained: 0,
            total_rows: Some(0),
            truncation: Truncation::Complete,
        })
        .await;
    }

    // A held back OK that another answer of the same text followed was no empty set of its own.
    async fn release(&mut self) {
        if let Some(rows_affected) = self.held_back.take() {
            self.send(ResultEvent::CommandCompleted {
                rows_affected: Some(rows_affected),
            })
            .await;
        }
    }

    async fn open_set(&mut self, wire_columns: &[MySqlColumn]) {
        let columns: Arc<[ResultColumn]> = wire_columns
            .iter()
            .map(|column| result_column(column, MySqlTimestampMode::SessionLocal))
            .collect();
        // Taken at the first set, so a second one leaves none.
        let set_index = self.sets;
        self.traced = self
            .trace
            .take()
            .map(|statement| TracedSet::new(set_index, columns.clone(), wire_columns, statement));
        self.sets += 1;
        self.send(ResultEvent::ResultSetStarted { columns }).await;
    }

    async fn send(&mut self, event: ResultEvent) {
        if self.gone {
            return;
        }
        self.gone = self.sink.accept(event).await == SinkFlow::ConsumerGone;
    }
}

// One row past the limit is where sql_select_limit stops the server, so the total is unknown there.
pub(crate) fn truncation(seen: u64, limit: u64) -> (Truncation, Option<u64>) {
    match seen {
        seen if seen <= limit => (Truncation::Complete, Some(seen)),
        seen if seen == limit.saturating_add(1) => (Truncation::ServerStopped, None),
        seen => (Truncation::ReadPastLimit, Some(seen)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limit() -> RowLimit {
        RowLimit::new(100).expect("a limit")
    }

    fn run_wants(script: &[&str]) -> Option<SelectLimit> {
        let kinds: Vec<TextKind> = script.iter().map(|text| text_kind(text)).collect();
        wanted_select_limit(&kinds, limit())
    }

    #[derive(Default)]
    struct Kept(Vec<ResultEvent>);

    #[async_trait::async_trait]
    impl ResultSink for Kept {
        async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
            self.0.push(event);
            SinkFlow::Continue
        }
    }

    fn command(rows_affected: u64) -> ResultEvent {
        ResultEvent::CommandCompleted {
            rows_affected: Some(rows_affected),
        }
    }

    #[tokio::test]
    async fn an_ok_held_back_for_its_columns_keeps_its_place() {
        let mut kept = Kept::default();
        let mut emitter = Emitter {
            sink: &mut kept,
            limit: 100,
            open: None,
            held_back: None,
            sets: 0,
            gone: false,
            trace: None,
            traced: None,
        };

        emitter.done(0, true).await;
        let held = emitter.held_back;
        emitter.done(2, false).await;
        emitter.done(5, true).await;
        let last = emitter.held_back.take().unwrap();
        emitter.answered(last, &[]).await;

        assert_eq!(held, Some(0));
        assert_eq!(kept.0, [command(0), command(2), command(5)]);
    }

    #[test]
    fn a_set_cut_by_the_server_is_told_from_one_read_past_the_limit() {
        assert_eq!(truncation(40, 100), (Truncation::Complete, Some(40)));
        assert_eq!(truncation(100, 100), (Truncation::Complete, Some(100)));
        assert_eq!(truncation(101, 100), (Truncation::ServerStopped, None));
        assert_eq!(truncation(150_000, 100), (Truncation::ReadPastLimit, Some(150_000)));
    }

    #[test]
    fn the_opening_word_is_past_comments_markers_and_parentheses() {
        fn first_word(text: &str) -> Option<&str> {
            let plan = ScriptPlan::build(text, SqlGrammar::MySql, LexicalSettings::default_for(SqlGrammar::MySql));
            opening_word(&plan, text, 0..text.len())
        }
        assert_eq!(first_word("SELECT 1"), Some("SELECT"));
        assert_eq!(
            first_word("  -- note\n/* more */ (select 1) UNION (SELECT 2)"),
            Some("select")
        );
        assert_eq!(first_word("/*!50000 SHOW */ TABLES"), Some("SHOW"));
        assert_eq!(first_word("# note\nWITH x AS (SELECT 1) SELECT * FROM x"), Some("WITH"));
        assert_eq!(first_word("'text'"), None);
        assert_eq!(first_word(""), None);
    }

    // script_split sends these whole, for the backslash, the `/*!` comment and the string the session's sql_mode decides.
    #[test]
    fn a_text_the_server_runs_whole_takes_its_strictest_statement() {
        for cut in [
            r"INSERT INTO log VALUES ('C:\\tmp'); SELECT * FROM big INTO OUTFILE '/tmp/big.csv'",
            "/*!40101 SET NAMES utf8mb4 */; SELECT id FROM big FOR UPDATE",
            r"INSERT INTO log VALUES ('C:\'); SELECT * FROM big INTO OUTFILE '/tmp/big.csv'",
        ] {
            assert_eq!(text_kind(cut), TextKind::CutSelect, "{cut}");
        }
        assert_eq!(
            text_kind(r"INSERT INTO log VALUES ('C:\\tmp'); SELECT id FROM big"),
            TextKind::PlainRead
        );
        assert_eq!(
            text_kind(r"INSERT INTO log VALUES ('C:\\tmp'); DELETE FROM log"),
            TextKind::Other
        );
    }

    #[test]
    fn a_select_is_a_plain_read_only_without_into_a_lock_or_a_write() {
        for read in [
            "SELECT * FROM big",
            "(SELECT id FROM big) UNION ALL (SELECT id FROM big)",
            "WITH ids AS (SELECT id FROM big) SELECT id FROM ids",
            "TABLE big",
            "VALUES ROW(1), ROW(2)",
            "SELECT share, mode FROM big",
        ] {
            assert_eq!(text_kind(read), TextKind::PlainRead, "{read}");
        }
        for cut in [
            "SELECT * FROM big INTO OUTFILE '/tmp/big.csv'",
            "SELECT * FROM big INTO DUMPFILE '/tmp/big.bin'",
            "SELECT COUNT(*) FROM big INTO @rows",
            "SELECT * FROM big FOR UPDATE",
            "SELECT * FROM big FOR SHARE",
            "SELECT * FROM big for share skip locked",
            "SELECT * FROM big LOCK IN SHARE MODE",
            "TABLE big INTO OUTFILE '/tmp/big.csv'",
            "EXECUTE every_id",
        ] {
            assert_eq!(text_kind(cut), TextKind::CutSelect, "{cut}");
        }
        for other in [
            "SHOW PROCESSLIST",
            "DESC big",
            "EXPLAIN SELECT * FROM big",
            "INSERT INTO copied SELECT id FROM big",
            "CREATE TABLE copied AS SELECT id FROM big",
            "CALL every_id()",
            "SET SESSION sql_select_limit = 5",
            "UPDATE big SET id = id",
            "BEGIN",
        ] {
            assert_eq!(text_kind(other), TextKind::Other, "{other}");
        }
    }

    #[test]
    fn a_run_sets_the_limit_once_and_only_when_a_select_needs_it() {
        let editor = Some(SelectLimit::Editor(100));
        assert_eq!(
            run_wants(&["UPDATE t SET a = 1 WHERE id < 3", "SELECT ROW_COUNT()"]),
            editor
        );
        assert_eq!(
            run_wants(&["SET SESSION sql_select_limit = 5", "SELECT * FROM t"]),
            editor
        );
        assert_eq!(run_wants(&["INSERT INTO t VALUES ('long')", "SHOW WARNINGS"]), None);
        assert_eq!(run_wants(&["CALL every_id()", "BEGIN", "COMMIT"]), None);
        assert_eq!(run_wants(&[]), None);
        assert_eq!(
            run_wants(&["SELECT * FROM big", "SELECT * FROM big INTO OUTFILE '/tmp/big.csv'"]),
            Some(SelectLimit::Server)
        );
        assert_eq!(
            run_wants(&[r"INSERT INTO log VALUES ('C:\\tmp'); SELECT * FROM big INTO OUTFILE '/tmp/big.csv'"]),
            Some(SelectLimit::Server)
        );
    }
}
