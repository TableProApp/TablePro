//! The keyspace suite: what a key-value engine's connection does with
//! keys, and how its editor sends commands and stops them.

use std::collections::{BTreeMap, BTreeSet};
use std::num::NonZeroUsize;
use std::sync::Arc;
use std::time::Duration;

use tablepro_core::keyspace::{KeyScan, KeyWindow};
use tablepro_core::meta::{KeyKind, ObjectKind};
use tablepro_core::{
    Connection, DataModel, DriverError, EditorSession, EditorSessionOptions, EditorSessionState, ErrorCategory,
    LinkState, ReadStatement, RunEnd, RunOptions, UserSql, WorkspaceSettings,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::conformance::support::{
    CALL_DEADLINE, Collected, SCHEDULING_SLACK, dial, expect, run_completed, run_editor, run_options, unexpected,
    unique, within, writable,
};
use crate::conformance::{ConformanceFailure, KeyspaceEngine, test_liveness};

const KINDS: [KeyKind; 6] = [
    KeyKind::String,
    KeyKind::Hash,
    KeyKind::List,
    KeyKind::Set,
    KeyKind::SortedSet,
    KeyKind::Stream,
];

/// Long enough for a command to reach the server before the case stops
/// it, so the stop is tested rather than a race with sending.
const SETTLE: Duration = Duration::from_millis(500);

/// More entries than two windows hold, so every kind reads a third.
const MANY: u32 = 1_234;

fn limit(keys: usize) -> NonZeroUsize {
    NonZeroUsize::new(keys).unwrap_or(NonZeroUsize::MIN)
}

async fn connect<E: KeyspaceEngine>(
    case: &'static str,
    engine: &E,
    settings: WorkspaceSettings,
) -> Result<Arc<dyn Connection>, ConformanceFailure> {
    Ok(dial(case, E::driver(), engine.connect_options(settings, test_liveness())).await??)
}

async fn editor(
    connection: &dyn Connection,
    options: EditorSessionOptions,
) -> Result<Arc<dyn EditorSession>, ConformanceFailure> {
    Ok(connection.open_editor_session(options, CancellationToken::new()).await?)
}

async fn fill<E: KeyspaceEngine>(
    case: &'static str,
    engine: &E,
    session: &dyn EditorSession,
    key: &str,
    kind: KeyKind,
    entries: u32,
) -> Result<(), ConformanceFailure> {
    run_completed(case, session, &engine.fill_commands(key, kind, entries), run_options()).await?;
    Ok(())
}

async fn listed(
    connection: &dyn Connection,
    pattern: &str,
    keys: usize,
) -> Result<(BTreeMap<String, ObjectKind>, bool), ConformanceFailure> {
    let scan = KeyScan {
        pattern: Some(pattern.to_owned()),
        limit: limit(keys),
    };
    let listing = connection.scan_keys(&scan, within(CALL_DEADLINE)).await?;
    let found = listing.keys.into_iter().map(|key| (key.name, key.kind)).collect();
    Ok((found, listing.complete))
}

/// Wait until the server holds no command waiting on a key, or `bound`
/// passes.
async fn until_unblocked<E: KeyspaceEngine>(
    case: &'static str,
    engine: &E,
    bound: Duration,
) -> Result<(), ConformanceFailure> {
    let give_up = Instant::now() + bound;
    loop {
        let blocked = engine.blocked_commands().await?;
        if blocked == 0 {
            return Ok(());
        }
        if Instant::now() >= give_up {
            return Err(unexpected(
                case,
                format!("{blocked} commands still waited on the server after {bound:?}"),
            ));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

const LISTED_CASE: &str = "keys_are_listed_with_their_kinds";

/// Each key is listed once, with the type of value it holds.
pub async fn keys_are_listed_with_their_kinds<E: KeyspaceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(LISTED_CASE, &engine, writable()).await?;
    let session = editor(connection.as_ref(), EditorSessionOptions::default()).await?;
    let prefix = unique("kinds");
    let mut expected = BTreeMap::new();
    for (index, kind) in KINDS.into_iter().enumerate() {
        let key = format!("{prefix}:{index}");
        fill(LISTED_CASE, &engine, session.as_ref(), &key, kind, 3).await?;
        expected.insert(key, ObjectKind::Key(kind));
    }

    let (found, complete) = listed(connection.as_ref(), &format!("{prefix}:*"), 100).await?;

    expect(LISTED_CASE, found == expected, || {
        format!("listed {found:?}, not {expected:?}")
    })?;
    expect(LISTED_CASE, complete, || "a listing under its limit says it is cut short".to_owned())?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

const PATTERN_CASE: &str = "a_pattern_is_matched_on_the_server";

/// Only the keys a pattern matches come back.
pub async fn a_pattern_is_matched_on_the_server<E: KeyspaceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(PATTERN_CASE, &engine, writable()).await?;
    let session = editor(connection.as_ref(), EditorSessionOptions::default()).await?;
    let prefix = unique("pattern");
    for key in ["a:1", "a:2", "b:1"] {
        fill(
            PATTERN_CASE,
            &engine,
            session.as_ref(),
            &format!("{prefix}:{key}"),
            KeyKind::String,
            1,
        )
        .await?;
    }

    let (found, _) = listed(connection.as_ref(), &format!("{prefix}:a:*"), 100).await?;

    let names: BTreeSet<String> = found.into_keys().collect();
    let expected: BTreeSet<String> = ["a:1", "a:2"].iter().map(|key| format!("{prefix}:{key}")).collect();
    expect(PATTERN_CASE, names == expected, || {
        format!("the pattern listed {names:?}, not {expected:?}")
    })?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

const LIMIT_CASE: &str = "a_listing_stops_at_its_limit_and_says_so";

pub async fn a_listing_stops_at_its_limit_and_says_so<E: KeyspaceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let connection = connect(LIMIT_CASE, &engine, writable()).await?;
    let session = editor(connection.as_ref(), EditorSessionOptions::default()).await?;
    let prefix = unique("limit");
    let script: Vec<String> = (0..25)
        .map(|index| engine.fill_commands(&format!("{prefix}:{index}"), KeyKind::String, 1))
        .collect();
    run_completed(LIMIT_CASE, session.as_ref(), &script.join("\n"), run_options()).await?;

    let (cut, cut_complete) = listed(connection.as_ref(), &format!("{prefix}:*"), 10).await?;
    let (whole, whole_complete) = listed(connection.as_ref(), &format!("{prefix}:*"), 100).await?;

    expect(LIMIT_CASE, cut.len() == 10 && !cut_complete, || {
        format!("a limit of 10 listed {} keys, complete {cut_complete}", cut.len())
    })?;
    expect(LIMIT_CASE, whole.len() == 25 && whole_complete, || {
        format!("a limit of 100 listed {} of 25 keys, complete {whole_complete}", whole.len())
    })?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

const WINDOWS_CASE: &str = "every_kind_reads_in_windows_to_its_end";

/// Each kind's value reads a window at a time until the driver says it
/// ended, and the windows hold every entry.
pub async fn every_kind_reads_in_windows_to_its_end<E: KeyspaceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(WINDOWS_CASE, &engine, writable()).await?;
    let session = editor(connection.as_ref(), EditorSessionOptions::default()).await?;
    let prefix = unique("windows");
    for kind in KINDS {
        let key = format!("{prefix}:{kind:?}");
        fill(WINDOWS_CASE, &engine, session.as_ref(), &key, kind, MANY).await?;
        let mut window = KeyWindow::first();
        let mut entries = BTreeSet::new();
        let mut windows = 0;
        loop {
            windows += 1;
            if windows > 20 {
                return Err(unexpected(WINDOWS_CASE, format!("{kind:?} read past 20 windows")));
            }
            let Some(page) = connection.read_key(&key, &window, within(CALL_DEADLINE)).await? else {
                return Err(unexpected(WINDOWS_CASE, format!("{kind:?} was not found")));
            };
            expect(WINDOWS_CASE, page.kind == kind, || {
                format!("{kind:?} read as {:?}", page.kind)
            })?;
            // Bytes for a string, entries for every other kind.
            let length = u64::from(MANY);
            expect(WINDOWS_CASE, page.length == Some(length), || {
                format!("{kind:?} has length {:?}, not {length}", page.length)
            })?;
            entries.extend(page.rows.rows.iter().map(|row| format!("{:?}", row.first())));
            match page.next {
                Some(next) => window = KeyWindow::after(next),
                None => break,
            }
        }
        let expected = if kind == KeyKind::String { 1 } else { MANY as usize };
        expect(WINDOWS_CASE, entries.len() == expected, || {
            format!("{kind:?} read {} distinct entries, not {expected}", entries.len())
        })?;
    }
    session.close().await;
    connection.close().await?;
    Ok(())
}

const MISSING_CASE: &str = "a_missing_key_reads_as_none";

pub async fn a_missing_key_reads_as_none<E: KeyspaceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(MISSING_CASE, &engine, writable()).await?;

    let page = connection
        .read_key(&unique("missing"), &KeyWindow::first(), within(CALL_DEADLINE))
        .await?;

    expect(MISSING_CASE, page.is_none(), || format!("a missing key read as {page:?}"))?;
    connection.close().await?;
    Ok(())
}

const STOPPED_CASE: &str = "a_stopped_command_ends_and_the_session_runs_again";

/// A command waiting on the server ends as cancelled within the cancel
/// grace, the server lets it go, and the session takes the next run.
pub async fn a_stopped_command_ends_and_the_session_runs_again<E: KeyspaceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let grace = test_liveness().cancel_grace + SCHEDULING_SLACK;
    let connection = connect(STOPPED_CASE, &engine, writable()).await?;
    let session = editor(connection.as_ref(), EditorSessionOptions::default()).await?;
    let key = unique("stopped");
    let cancel = CancellationToken::new();
    let blocking = engine.blocking_command(&key);

    let running = async {
        let outcome = run_editor(session.as_ref(), &blocking, RunOptions::new(cancel.clone())).await;
        (outcome, Instant::now())
    };
    let cancelling = async {
        tokio::time::sleep(SETTLE).await;
        cancel.cancel();
        Instant::now()
    };
    let ((outcome, finished), cancelled) = tokio::join!(running, cancelling);
    let (summary, _) = outcome?;
    let after_cancel = finished.saturating_duration_since(cancelled);

    expect(STOPPED_CASE, summary.end == RunEnd::Cancelled, || {
        format!("the stopped command ended {:?}", summary.end)
    })?;
    expect(STOPPED_CASE, after_cancel <= grace, || {
        format!("the run ended {after_cancel:?} after its cancel, past the {grace:?} grace")
    })?;
    expect(STOPPED_CASE, session.state() == EditorSessionState::Ready, || {
        format!("the session is {:?} after a stop", session.state())
    })?;
    until_unblocked(STOPPED_CASE, &engine, grace).await?;
    run_completed(STOPPED_CASE, session.as_ref(), &engine.read_all_command(&key), run_options()).await?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

const DROPPED_CASE: &str = "a_dropped_editor_run_stops_the_command";

/// Dropping the caller of a run stops the command on the server rather
/// than leaving it waiting for nobody.
pub async fn a_dropped_editor_run_stops_the_command<E: KeyspaceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let bound = test_liveness().cancel_grace + Duration::from_secs(1);
    let connection = connect(DROPPED_CASE, &engine, writable()).await?;
    let session = editor(connection.as_ref(), EditorSessionOptions::default()).await?;
    let blocking = engine.blocking_command(&unique("dropped"));

    let running = run_editor(session.as_ref(), &blocking, run_options());
    let dropped = tokio::time::timeout(SETTLE, running).await;
    expect(DROPPED_CASE, dropped.is_err(), || {
        format!("the waiting command ended on its own: {dropped:?}")
    })?;

    until_unblocked(DROPPED_CASE, &engine, bound).await?;
    let state = session.state();
    expect(
        DROPPED_CASE,
        matches!(state, EditorSessionState::Ready | EditorSessionState::Lost),
        || format!("the session is {state:?} after its run was dropped"),
    )?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

const TIMEOUT_CASE: &str = "a_timed_out_command_is_stopped_by_the_server";

pub async fn a_timed_out_command_is_stopped_by_the_server<E: KeyspaceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let connection = connect(TIMEOUT_CASE, &engine, writable()).await?;
    let options = EditorSessionOptions {
        statement_timeout: Some(SETTLE),
    };
    let session = editor(connection.as_ref(), options).await?;

    let (summary, _) = run_editor(session.as_ref(), &engine.blocking_command(&unique("timeout")), run_options()).await?;

    expect(
        TIMEOUT_CASE,
        summary.end
            == RunEnd::TimedOut {
                server_cancelled: true,
            },
        || format!("the timed-out command ended {:?}", summary.end),
    )?;
    expect(TIMEOUT_CASE, session.state() == EditorSessionState::Ready, || {
        format!("the session is {:?} after a timeout", session.state())
    })?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

const READ_ONLY_CASE: &str = "a_read_only_connection_refuses_writes_before_sending";

/// On a read-only connection a write never reaches the server, in the
/// editor or in an export, and a read still runs.
pub async fn a_read_only_connection_refuses_writes_before_sending<E: KeyspaceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let read_only = connect(READ_ONLY_CASE, &engine, WorkspaceSettings::workspace(true)).await?;
    let session = editor(read_only.as_ref(), EditorSessionOptions::default()).await?;
    let key = unique("read_only");

    let (summary, _) = run_editor(session.as_ref(), &engine.write_command(&key), run_options()).await?;
    let streamed = read_only
        .stream_read(
            &ReadStatement::User(UserSql::new(engine.write_command(&key))),
            Collected::default().sink(),
            within(CALL_DEADLINE),
        )
        .await;
    let written = read_only.read_key(&key, &KeyWindow::first(), within(CALL_DEADLINE)).await?;

    let refused = |end: &RunEnd| matches!(end, RunEnd::Failed(DriverError::ReadOnly(_)));
    expect(READ_ONLY_CASE, refused(&summary.end), || {
        format!("a write on a read-only connection ended {:?}", summary.end)
    })?;
    expect(READ_ONLY_CASE, matches!(streamed, Err(DriverError::ReadOnly(_))), || {
        format!("a write streamed on a read-only connection gave {streamed:?}")
    })?;
    expect(READ_ONLY_CASE, written.is_none(), || {
        format!("the refused write left {written:?}")
    })?;
    run_completed(READ_ONLY_CASE, session.as_ref(), &engine.read_all_command(&key), run_options()).await?;
    session.close().await;
    read_only.close().await?;
    Ok(())
}

const STREAM_CASE: &str = "stream_read_streams_every_row";

pub async fn stream_read_streams_every_row<E: KeyspaceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(STREAM_CASE, &engine, writable()).await?;
    let session = editor(connection.as_ref(), EditorSessionOptions::default()).await?;
    let key = unique("stream");
    fill(STREAM_CASE, &engine, session.as_ref(), &key, KeyKind::List, MANY).await?;
    let collected = Collected::default();

    let summary = connection
        .stream_read(
            &ReadStatement::User(UserSql::new(engine.read_all_command(&key))),
            collected.sink(),
            within(CALL_DEADLINE),
        )
        .await?;

    let rows = collected.rows().len();
    expect(STREAM_CASE, rows == MANY as usize && summary.rows == u64::from(MANY), || {
        format!("streamed {rows} rows, summary {}, of {MANY}", summary.rows)
    })?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

const PROBE_CASE: &str = "a_probe_answers_while_a_command_blocks";

pub async fn a_probe_answers_while_a_command_blocks<E: KeyspaceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let liveness = test_liveness();
    let connection = connect(PROBE_CASE, &engine, writable()).await?;
    let session = editor(connection.as_ref(), EditorSessionOptions::default()).await?;
    let cancel = CancellationToken::new();
    let blocking = engine.blocking_command(&unique("probe"));

    let running = run_editor(session.as_ref(), &blocking, RunOptions::new(cancel.clone()));
    let probing = async {
        tokio::time::sleep(SETTLE).await;
        let probed = connection.probe(within(liveness.probe_timeout)).await;
        cancel.cancel();
        probed
    };
    let (_, probed) = tokio::join!(running, probing);

    expect(PROBE_CASE, probed.is_ok(), || {
        format!("a probe beside a waiting command gave {probed:?}")
    })?;
    session.close().await;
    connection.close().await?;
    Ok(())
}

const CLOSE_CASE: &str = "keyspace_close_is_idempotent";

pub async fn keyspace_close_is_idempotent<E: KeyspaceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let liveness = test_liveness();
    let connection = connect(CLOSE_CASE, &engine, writable()).await?;
    connection.probe(within(liveness.probe_timeout)).await?;
    let close_bound = liveness.close_timeout + liveness.cancel_grace + SCHEDULING_SLACK;

    for attempt in ["first", "second"] {
        let closed = tokio::time::timeout(close_bound, connection.close()).await;
        expect(CLOSE_CASE, matches!(closed, Ok(Ok(()))), || {
            format!("the {attempt} close gave {closed:?} within {close_bound:?}")
        })?;
    }
    let after = tokio::time::timeout(
        close_bound,
        connection.scan_keys(&KeyScan::sidebar(None), within(CALL_DEADLINE)),
    )
    .await;
    expect(CLOSE_CASE, matches!(after, Ok(Err(_))), || {
        format!("a listing after close gave {after:?}")
    })?;
    Ok(())
}

const LOST_CASE: &str = "a_lost_transport_reports_connection_lost_to_a_listing";
const LOST_DEADLINE: Duration = Duration::from_secs(1);

pub async fn a_lost_transport_reports_connection_lost_to_a_listing<E: KeyspaceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let liveness = test_liveness();
    let (options, fault) = engine.faulty_connect_options(writable(), liveness).await?;
    let connection = dial(LOST_CASE, E::driver(), options).await??;
    connection
        .scan_keys(&KeyScan::sidebar(None), within(CALL_DEADLINE))
        .await?;

    fault.black_hole();
    let started = Instant::now();
    let outcome = connection
        .scan_keys(&KeyScan::sidebar(None), within(LOST_DEADLINE))
        .await;
    let elapsed = started.elapsed();
    let bound = LOST_DEADLINE + liveness.cancel_grace + SCHEDULING_SLACK;

    let lost = matches!(&outcome, Err(error) if error.category() == ErrorCategory::ConnectionLost);
    expect(LOST_CASE, lost, || format!("a listing over a dropped route gave {outcome:?}"))?;
    expect(LOST_CASE, elapsed <= bound, || {
        format!("the loss was reported after {elapsed:?}, past the {bound:?} bound")
    })?;
    expect(LOST_CASE, connection.link_state() == LinkState::Lost, || {
        format!("the link is {:?} after the loss", connection.link_state())
    })?;
    drop(connection.close().await);
    Ok(())
}

const MODEL_CASE: &str = "keyspace_suite_matches_driver_capabilities";

/// Only a driver that says it holds keys runs this suite.
pub fn keyspace_suite_matches_driver_capabilities<E: KeyspaceEngine>() -> Result<(), ConformanceFailure> {
    let model = E::driver().capabilities().data_model;
    expect(MODEL_CASE, model == DataModel::KeyValue, || {
        format!("the keyspace suite runs on a driver whose data model is {model:?}")
    })
}
