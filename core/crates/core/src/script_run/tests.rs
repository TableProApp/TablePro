use std::sync::{Arc, Mutex, PoisonError};

use crate::column::{ColumnType, ResultColumn};
use crate::editor_session::EditorSessionState;
use crate::error::DriverError;
use crate::result_event::{ResultEvent, RunEnd, RunSummary, ServerNotice, Truncation};
use crate::server_diagnostics::{ServerCode, ServerDiagnostics};
use crate::transaction_state::TransactionState;
use crate::value::Value;
use crate::{ByteLimit, RowLimit};

use super::*;

// A store that keeps each set's rows, so a test can read what the loop
// kept after the budget trimmed it.
#[derive(Default)]
struct TestStore {
    sets: Mutex<Vec<Vec<Vec<Value>>>>,
}

impl TestStore {
    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Vec<Vec<Value>>>> {
        self.sets.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn row_count(&self, set_index: usize) -> usize {
        self.lock().get(set_index).map_or(0, Vec::len)
    }

    fn set_count(&self) -> usize {
        self.lock().len()
    }
}

impl ScriptResultStore for TestStore {
    fn start_set(&self, _columns: Arc<[ResultColumn]>) -> usize {
        let mut sets = self.lock();
        sets.push(Vec::new());
        sets.len() - 1
    }

    fn resolve_columns(&self, _set_index: usize, _columns: Arc<[ResultColumn]>) {}

    fn append(&self, set_index: usize, rows: Vec<Vec<Value>>) {
        if let Some(set) = self.lock().get_mut(set_index) {
            set.extend(rows);
        }
    }

    fn finish_set(&self, _set_index: usize, _total_rows: Option<u64>, _cut: bool) {}
}

fn run_spec(run_row_limit: u64, row_limit: RowLimit, byte_limit: ByteLimit) -> ScriptRun {
    ScriptRun {
        batches: Vec::new(),
        policy: BatchErrorPolicy::StopScript,
        statement_timeout: None,
        row_limit,
        run_row_limit,
        byte_limit,
    }
}

fn columns(names: &[&str]) -> Arc<[ResultColumn]> {
    names
        .iter()
        .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
        .collect()
}

fn summary(end: RunEnd) -> Result<RunSummary, DriverError> {
    Ok(RunSummary {
        elapsed: std::time::Duration::from_millis(3),
        end,
        transaction_state: TransactionState::Idle,
    })
}

fn collect(events: Vec<ResultEvent>, end: RunEnd) -> (Vec<ScriptEntry>, Verdict) {
    let (entries, verdict, _) = collect_in(RowRoom::UNLIMITED, events, end);
    (entries, verdict)
}

fn collect_in(room: RowRoom, events: Vec<ResultEvent>, end: RunEnd) -> (Vec<ScriptEntry>, Verdict, Arc<TestStore>) {
    let store = Arc::new(TestStore::default());
    let dyn_store: Arc<dyn ScriptResultStore> = store.clone();
    let mut collector = BatchCollector::new(dyn_store).within(room);
    for event in events {
        collector.record(event);
    }
    let outcome = collector.finish(summary(end), EditorSessionState::Ready, false, 0);
    (outcome.entries, outcome.verdict, store)
}

fn first_summary(entries: &[ScriptEntry]) -> ResultSetSummary {
    match entries.first() {
        Some(ScriptEntry::ResultSet { summary, .. }) => *summary,
        other => panic!("expected a result set: {other:?}"),
    }
}

#[test]
fn a_statement_reads_only_the_rows_its_run_has_room_for() {
    let run = run_spec(100_000, RowLimit::EDITOR_DEFAULT, ByteLimit::EDITOR_DEFAULT);
    let limit = |rows| {
        let (room, limit, _) = room_after(&run, rows, 0);
        (room.left, room.limits_statement, limit.get())
    };

    assert_eq!(limit(0), (100_000, false, 10_000));
    assert_eq!(limit(95_000), (5_000, true, 5_000));
    assert_eq!(limit(100_000), (0, true, 1));
    assert_eq!(limit(250_000), (0, true, 1));
}

#[test]
fn a_statement_goes_out_with_the_bytes_its_run_has_left() {
    let run = run_spec(100_000, RowLimit::EDITOR_DEFAULT, ByteLimit::new(1_000).unwrap());
    let bytes = |bytes| {
        let (room, _, limit) = room_after(&run, 0, bytes);
        (room.run_bytes, room.bytes_left, limit.get())
    };

    assert_eq!(bytes(0), (1_000, 1_000, 1_000));
    assert_eq!(bytes(600), (1_000, 400, 400));
    assert_eq!(bytes(1_000), (1_000, 0, 1));
    assert_eq!(bytes(5_000), (1_000, 0, 1));
}

#[test]
fn a_timed_out_run_is_a_stop() {
    assert!(!continues(Verdict::Stopped, BatchErrorPolicy::ContinueNextBatch));
    let (entries, verdict) = collect(Vec::new(), RunEnd::TimedOut { server_cancelled: true });
    assert_eq!(verdict, Verdict::Stopped);
    assert!(matches!(
        entries.as_slice(),
        [ScriptEntry::TimedOut { server_cancelled: true }]
    ));
}

#[test]
fn continue_policy_runs_the_next_batch_but_not_after_a_stop() {
    assert!(continues(Verdict::Failed, BatchErrorPolicy::ContinueNextBatch));
    assert!(!continues(Verdict::Stopped, BatchErrorPolicy::ContinueNextBatch));
    assert!(continues(Verdict::Completed, BatchErrorPolicy::StopScript));
    assert!(!continues(Verdict::Failed, BatchErrorPolicy::StopScript));
}

#[test]
fn collector_maps_events() {
    let (entries, verdict, store) = collect_in(
        RowRoom::UNLIMITED,
        vec![
            ResultEvent::ResultSetStarted {
                columns: columns(&["a"]),
            },
            ResultEvent::Rows(vec![vec![Value::Int(1)], vec![Value::Int(2)]]),
            ResultEvent::RowLimitReached { retained: 2 },
            ResultEvent::ResultSetFinished {
                retained: 2,
                total_rows: Some(5),
                truncation: Truncation::ServerStopped,
            },
            ResultEvent::Notice(ServerNotice {
                severity: "NOTICE".to_owned(),
                message: "vacuumed".to_owned(),
                code: None,
            }),
            ResultEvent::CommandCompleted { rows_affected: Some(4) },
        ],
        RunEnd::Completed,
    );

    assert_eq!(verdict, Verdict::Completed);
    assert_eq!(entries.len(), 3, "{entries:?}");
    assert_eq!(store.row_count(0), 2);
    assert_eq!(
        first_summary(&entries),
        ResultSetSummary {
            retained: 2,
            total_rows: Some(5),
            truncation: Truncation::ServerStopped,
            run_limit: None,
            size_limit: None,
        }
    );
    assert!(
        matches!(&entries[1], ScriptEntry::Notice { severity, message, .. } if severity == "NOTICE" && message == "vacuumed")
    );
    assert!(matches!(entries[2], ScriptEntry::Command { rows_affected: Some(4) }));
}

#[test]
fn notices_past_the_runs_limit_end_in_their_own_entry() {
    let notice = |message: &str| {
        ResultEvent::Notice(ServerNotice {
            severity: "NOTICE".to_owned(),
            message: message.to_owned(),
            code: None,
        })
    };

    let (entries, _) = collect(
        vec![
            notice("row 1"),
            notice("row 2"),
            ResultEvent::NoticeLimitReached { retained: 2 },
            ResultEvent::CommandCompleted { rows_affected: None },
        ],
        RunEnd::Completed,
    );

    assert!(matches!(&entries[0], ScriptEntry::Notice { message, .. } if message == "row 1"));
    assert!(matches!(&entries[1], ScriptEntry::Notice { message, .. } if message == "row 2"));
    assert!(matches!(entries[2], ScriptEntry::NoticeLimitReached { retained: 2 }));
    assert!(matches!(entries[3], ScriptEntry::Command { rows_affected: None }));
}

#[test]
fn a_set_the_driver_cut_at_the_runs_room_names_the_run_limit() {
    let room = RowRoom {
        run_limit: 100,
        left: 1,
        limits_statement: true,
        ..RowRoom::UNLIMITED
    };
    let (entries, _, store) = collect_in(
        room,
        vec![
            ResultEvent::ResultSetStarted {
                columns: columns(&["a"]),
            },
            ResultEvent::Rows(vec![vec![Value::Int(1)]]),
            ResultEvent::RowLimitReached { retained: 1 },
            ResultEvent::ResultSetFinished {
                retained: 1,
                total_rows: None,
                truncation: Truncation::ReadPastLimit,
            },
        ],
        RunEnd::Completed,
    );

    assert_eq!(store.row_count(0), 1);
    assert_eq!(first_summary(&entries).run_limit, Some(100));
}

#[test]
fn a_set_cut_for_size_says_so_before_and_after_it_ends() {
    let cut = || {
        vec![
            ResultEvent::ResultSetStarted {
                columns: columns(&["a"]),
            },
            ResultEvent::Rows(vec![vec![Value::Int(1)], vec![Value::Int(2)]]),
            ResultEvent::ByteLimitReached { retained: 2 },
        ]
    };
    let mut finished = cut();
    finished.push(ResultEvent::ResultSetFinished {
        retained: 2,
        total_rows: Some(9),
        truncation: Truncation::ByteLimit,
    });

    let (stopped, _) = collect(cut(), RunEnd::Cancelled);
    let (ended, _) = collect(finished, RunEnd::Completed);

    let size_limit = Some(ByteLimit::EDITOR_DEFAULT.get());
    assert_eq!(
        first_summary(&stopped),
        ResultSetSummary {
            retained: 2,
            total_rows: None,
            truncation: Truncation::ByteLimit,
            run_limit: None,
            size_limit,
        }
    );
    assert_eq!(
        first_summary(&ended),
        ResultSetSummary {
            retained: 2,
            total_rows: Some(9),
            truncation: Truncation::ByteLimit,
            run_limit: None,
            size_limit,
        }
    );
}

#[test]
fn a_batch_with_no_bytes_left_keeps_no_rows_and_says_why() {
    let room = RowRoom {
        run_bytes: 1_000,
        bytes_left: 0,
        ..RowRoom::UNLIMITED
    };
    let (entries, _, store) = collect_in(
        room,
        vec![
            ResultEvent::ResultSetStarted {
                columns: columns(&["a"]),
            },
            ResultEvent::Rows(vec![vec![Value::Int(1)]]),
            ResultEvent::ByteLimitReached { retained: 1 },
            ResultEvent::ResultSetFinished {
                retained: 1,
                total_rows: Some(3),
                truncation: Truncation::ByteLimit,
            },
        ],
        RunEnd::Completed,
    );

    let kept = first_summary(&entries);
    assert_eq!((kept.retained, kept.size_limit, kept.run_limit), (0, Some(1_000), None));
    assert_eq!(store.row_count(0), 0);
}

#[test]
fn a_set_cut_by_the_limit_and_then_stopped_stays_truncated() {
    let (entries, _) = collect(
        vec![
            ResultEvent::ResultSetStarted {
                columns: columns(&["a"]),
            },
            ResultEvent::Rows(vec![vec![Value::Int(1)]]),
            ResultEvent::RowLimitReached { retained: 1 },
        ],
        RunEnd::Cancelled,
    );

    let summary = first_summary(&entries);
    assert_eq!(summary.truncation, Truncation::ServerStopped);
    assert_eq!(summary.total_rows, None);
}

#[test]
fn a_statement_with_nothing_to_say_still_gets_a_line() {
    let (entries, _) = collect(Vec::new(), RunEnd::Completed);

    assert!(matches!(
        entries.as_slice(),
        [ScriptEntry::Command { rows_affected: None }]
    ));
}

#[test]
fn a_server_error_position_becomes_a_buffer_position() {
    let diagnostics = ServerDiagnostics {
        position: Some(8),
        ..ServerDiagnostics::new(Some(ServerCode::SqlState("42601".to_owned())), "syntax error")
    };
    let store = Arc::new(TestStore::default());
    let dyn_store: Arc<dyn ScriptResultStore> = store;
    let collector = BatchCollector::new(dyn_store);

    let outcome = collector.finish(
        summary(RunEnd::Failed(DriverError::reported(diagnostics))),
        EditorSessionState::Ready,
        false,
        100,
    );

    assert_eq!(outcome.verdict, Verdict::Failed);
    assert!(
        matches!(
            outcome.entries.as_slice(),
            [ScriptEntry::Failed {
                error_char: Some(107),
                ..
            }]
        ),
        "{:?}",
        outcome.entries
    );
}

#[test]
fn each_result_set_keeps_the_index_the_store_handed_back() {
    let (entries, _, store) = collect_in(
        RowRoom::UNLIMITED,
        vec![
            ResultEvent::ResultSetStarted {
                columns: columns(&["a"]),
            },
            ResultEvent::Rows(vec![vec![Value::Int(1)]]),
            ResultEvent::ResultSetFinished {
                retained: 1,
                total_rows: None,
                truncation: Truncation::Complete,
            },
            ResultEvent::ResultSetStarted {
                columns: columns(&["b"]),
            },
            ResultEvent::Rows(vec![vec![Value::Int(2)], vec![Value::Int(3)]]),
            ResultEvent::ResultSetFinished {
                retained: 2,
                total_rows: None,
                truncation: Truncation::Complete,
            },
        ],
        RunEnd::Completed,
    );

    let indices: Vec<usize> = entries
        .iter()
        .filter_map(|entry| match entry {
            ScriptEntry::ResultSet { set_index, .. } => Some(*set_index),
            _ => None,
        })
        .collect();
    assert_eq!(indices, [0, 1]);
    assert_eq!(store.set_count(), 2);
    assert_eq!((store.row_count(0), store.row_count(1)), (1, 2));
}
