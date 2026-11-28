use std::collections::HashSet;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::adapter::{LocalChange, LocalRecord, LocalRecords};
use tablepro_sync::api::control::PassReason;
use tablepro_sync::api::error::{StateError, SyncError};
use tablepro_sync::api::ids::{ChangeTag, KindName, RecordKey, ScopeName};
use tablepro_sync::api::scopes::ServerLimits;
use tablepro_sync::api::state::{BaseRow, Standing};
use tablepro_sync::api::transport::{Change, ChangeOp, DeletedReason, PulledRecord, TransportError};
use tablepro_sync::engine::{
    Backoff, Journal, JournalEntry, Judgement, Pass, PendingOp, StopSignal, Wake, change_bytes, diff, retry_after_ms,
    retryable, settle, spawn, split,
};
use tokio::sync::Notify;

use super::harness::id;

#[test]
fn backoff_doubles_with_jitter_up_to_its_ceiling_and_never_under_retry_after() {
    let mut backoff = Backoff::new(1_000, 8_000);

    let mut floors = vec![backoff.delay(None, 0)];
    for _ in 0..5 {
        assert!(backoff.failed(None) <= 8_000);
        assert!(backoff.delay(None, u64::MAX) <= 8_000);
        floors.push(backoff.delay(None, 0));
    }
    let honored = backoff.delay(Some(60_000), 0);
    backoff.succeeded();

    assert_eq!(floors, vec![500, 1_000, 2_000, 4_000, 4_000, 4_000]);
    assert_eq!(honored, 60_000);
    assert_eq!(backoff.failures(), 0);
    assert_eq!(backoff.delay(None, 0), 500);
}

#[test]
fn a_failure_backs_off_only_when_a_later_pass_can_get_past_it() {
    let limited = SyncError::Transport(TransportError::RateLimited {
        retry_after_ms: Some(1_500),
    });
    let server = SyncError::Transport(TransportError::Server {
        status: 503,
        code: "unavailable".to_owned(),
        retry_after_ms: None,
    });

    assert!(retryable(&limited));
    assert_eq!(retry_after_ms(&limited), Some(1_500));
    assert!(retryable(&server));
    assert!(retryable(&SyncError::State(StateError::Busy)));
    assert!(!retryable(&SyncError::Transport(TransportError::DeviceRemoved)));
    assert!(!retryable(&SyncError::Transport(TransportError::LicenseExpired)));
    assert!(!retryable(&SyncError::Cancelled));
}

fn change(record: &str, bytes: usize) -> Change {
    let fields = json!({"name": "x".repeat(bytes)});
    Change {
        kind: KindName::of(Kind::Connection),
        record_id: record.to_owned(),
        base: None,
        op: ChangeOp::Write {
            fields: fields.clone(),
            patch: fields,
        },
    }
}

#[test]
fn a_push_splits_by_count_and_by_bytes() {
    let limits = ServerLimits {
        changes_per_push: 2,
        body_bytes: 2_000,
        ..ServerLimits::ADR_0051
    };
    let small: Vec<Change> = (0..5).map(|n| change(&n.to_string(), 10)).collect();
    let large = vec![change("a", 900), change("b", 900), change("c", 5_000), change("d", 10)];

    let by_count: Vec<usize> = split(small, &limits, change_bytes).iter().map(Vec::len).collect();
    let by_bytes: Vec<Vec<String>> = split(large, &limits, change_bytes)
        .iter()
        .map(|batch| batch.iter().map(|change| change.record_id.clone()).collect())
        .collect();

    assert_eq!(by_count, vec![2, 2, 1]);
    assert_eq!(by_bytes, vec![vec!["a"], vec!["b"], vec!["c"], vec!["d"]]);
}

fn base(record: &str, fields: Option<serde_json::Value>) -> BaseRow {
    BaseRow {
        key: RecordKey::new(ScopeName::Personal, Kind::Connection, record),
        tag: ChangeTag::Service(format!("tag-{record}")),
        version: Some(1),
        revision: Some(1),
        epoch: None,
        deleted: None,
        fields,
        created_ms: None,
    }
}

fn local(record: &str, fields: serde_json::Value) -> LocalRecord {
    LocalRecord {
        record_id: record.to_owned(),
        fields,
        standing: Standing::Syncs,
    }
}

#[test]
fn the_diff_sends_creates_patches_and_deletions_and_skips_what_waits() {
    let records = LocalRecords {
        records: vec![
            local(&id(1), json!({"name": "new"})),
            local(&id(2), json!({"name": "edited", "host": "a"})),
            local(&id(3), json!({"name": "same"})),
            local(&id(6), json!({"name": "held"})),
        ],
        unreadable: vec![id(5)],
        tombstones: Vec::new(),
    };
    let bases = vec![
        base(&id(2), Some(json!({"name": "old", "host": "a"}))),
        base(&id(3), Some(json!({"name": "same"}))),
        base(&id(4), Some(json!({"name": "gone"}))),
        base(&id(5), Some(json!({"name": "unreadable"}))),
    ];
    let skip = HashSet::from([id(6)]);

    let diffed = diff(ScopeName::Personal, Kind::Connection, &records, &bases, &skip);

    let ops: Vec<(String, PendingOp)> = diffed
        .pending
        .iter()
        .map(|pending| (pending.key.record_id.clone(), pending.op.clone()))
        .collect();
    assert_eq!(
        ops,
        vec![
            (
                id(1),
                PendingOp::Write {
                    fields: json!({"name": "new"}),
                    patch: json!({"name": "new"})
                }
            ),
            (
                id(2),
                PendingOp::Write {
                    fields: json!({"name": "edited", "host": "a"}),
                    patch: json!({"name": "edited"})
                }
            ),
            (id(4), PendingOp::Delete),
        ]
    );
}

fn pulled(record: &str, fields: Option<serde_json::Value>, deleted: Option<DeletedReason>) -> PulledRecord {
    PulledRecord {
        kind: KindName::of(Kind::Connection),
        record_id: record.to_owned(),
        tag: ChangeTag::Service("pulled".to_owned()),
        fields,
        fields_json: None,
        deleted,
        service: None,
    }
}

#[test]
fn a_refill_settles_by_its_judgement_and_a_policy_tombstone_keeps_the_copy() {
    let key = RecordKey::new(ScopeName::Personal, Kind::Connection, id(1));
    let held = base(&id(1), Some(json!({"name": "base"})));
    let mine = local(&id(1), json!({"name": "mine"}));
    let theirs = pulled(&id(1), Some(json!({"name": "theirs"})), None);
    let policy = pulled(&id(1), None, Some(DeletedReason::Policy));

    let wins = settle(
        &key,
        Kind::Connection,
        Judgement::PullWins,
        Some(&held),
        Some(&mine),
        &theirs,
    );
    let keeps = settle(
        &key,
        Kind::Connection,
        Judgement::LocalWins,
        Some(&held),
        Some(&mine),
        &theirs,
    );
    let kept = settle(
        &key,
        Kind::Connection,
        Judgement::PullWins,
        Some(&held),
        Some(&mine),
        &policy,
    );

    assert_eq!(
        wins.store,
        Some(LocalChange::Put {
            record_id: id(1),
            fields: json!({"name": "theirs"})
        })
    );
    assert_eq!(keeps.store, None);
    assert_eq!(
        keeps.base.map(|base| base.tag),
        Some(ChangeTag::Service("pulled".to_owned()))
    );
    assert_eq!(kept.store, None);
    assert_eq!(kept.base.and_then(|base| base.deleted), Some(DeletedReason::Policy));
}

struct Flaky {
    calls: AtomicUsize,
    failures: usize,
    started: Mutex<Vec<tokio::time::Instant>>,
    waits: Mutex<Vec<Option<u64>>>,
    done: Notify,
    gate: Option<Arc<Notify>>,
}

impl Flaky {
    fn new(failures: usize, gate: Option<Arc<Notify>>) -> Arc<Self> {
        Arc::new(Self {
            calls: AtomicUsize::new(0),
            failures,
            started: Mutex::default(),
            waits: Mutex::default(),
            done: Notify::new(),
            gate,
        })
    }
}

#[async_trait]
impl Pass for Flaky {
    async fn pass(&self, why: PassReason) -> Result<(), SyncError> {
        let _ = why;
        self.started.lock().unwrap().push(tokio::time::Instant::now());
        if let Some(gate) = &self.gate {
            gate.notified().await;
        }
        let call = self.calls.fetch_add(1, Ordering::SeqCst);
        self.done.notify_one();
        if call < self.failures {
            return Err(SyncError::Transport(TransportError::RateLimited {
                retry_after_ms: Some(30_000),
            }));
        }
        Ok(())
    }

    fn poll_interval(&self) -> Duration {
        Duration::from_secs(24 * 3600)
    }

    fn waiting(&self, retry_in_ms: Option<u64>) {
        self.waits.lock().unwrap().push(retry_in_ms);
    }
}

#[tokio::test(start_paused = true)]
async fn the_scheduler_waits_out_retry_after_before_it_tries_again() {
    let pass = Flaky::new(1, None);
    let wake = Wake::new();
    let _scheduler = spawn(pass.clone(), wake.clone(), StopSignal::new(), Backoff::STANDARD);

    wake.pass_soon(PassReason::Launch);
    pass.done.notified().await;
    pass.done.notified().await;

    let started = pass.started.lock().unwrap().clone();
    assert_eq!(pass.calls.load(Ordering::SeqCst), 2);
    assert!(started[1] - started[0] >= Duration::from_secs(30));
    let waits = pass.waits.lock().unwrap().clone();
    assert!(matches!(waits.first(), Some(Some(wait)) if *wait >= 30_000));
}

// The events logged on this thread, each with its level, its text and its public `code`.
#[derive(Clone, Default)]
struct Logged(Arc<Mutex<Vec<(tracing::Level, String, Option<String>)>>>);

impl tracing::Subscriber for Logged {
    fn register_callsite(&self, _: &'static tracing::Metadata<'static>) -> tracing::subscriber::Interest {
        tracing::subscriber::Interest::sometimes()
    }

    fn enabled(&self, _: &tracing::Metadata<'_>) -> bool {
        true
    }

    fn new_span(&self, _: &tracing::span::Attributes<'_>) -> tracing::span::Id {
        tracing::span::Id::from_u64(1)
    }

    fn record(&self, _: &tracing::span::Id, _: &tracing::span::Record<'_>) {}

    fn record_follows_from(&self, _: &tracing::span::Id, _: &tracing::span::Id) {}

    fn event(&self, event: &tracing::Event<'_>) {
        #[derive(Default)]
        struct Fields {
            text: String,
            code: Option<String>,
        }
        impl tracing::field::Visit for Fields {
            fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
                if field.name() == "code" {
                    self.code = Some(value.to_owned());
                }
            }

            fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
                if field.name() == "message" {
                    self.text = format!("{value:?}");
                }
            }
        }
        let mut fields = Fields::default();
        event.record(&mut fields);
        self.0
            .lock()
            .unwrap()
            .push((*event.metadata().level(), fields.text, fields.code));
    }

    fn enter(&self, _: &tracing::span::Id) {}

    fn exit(&self, _: &tracing::span::Id) {}
}

// A device offline for hours warns with the failure's code once, when its passes start failing, not on every retry.
#[tokio::test(start_paused = true)]
async fn failed_passes_warn_once_with_their_code_until_one_succeeds() {
    let logged = Logged::default();
    let _logging = tracing::subscriber::set_default(logged.clone());
    let pass = Flaky::new(3, None);
    let wake = Wake::new();
    let _scheduler = spawn(pass.clone(), wake.clone(), StopSignal::new(), Backoff::STANDARD);

    wake.pass_soon(PassReason::Launch);
    for _ in 0..4 {
        pass.done.notified().await;
    }

    let code = SyncError::Transport(TransportError::RateLimited {
        retry_after_ms: Some(30_000),
    })
    .code();
    let lines = logged.0.lock().unwrap().clone();
    let passes: Vec<_> = lines
        .iter()
        .filter(|(_, text, _)| text.starts_with("sync pass"))
        .collect();
    assert_eq!(passes.len(), 3, "{passes:?}");
    assert_eq!(passes[0].0, tracing::Level::WARN);
    assert!(passes[1..].iter().all(|(level, _, _)| *level == tracing::Level::DEBUG));
    assert!(passes.iter().all(|(_, _, logged)| logged.as_deref() == Some(code)));
}

#[tokio::test]
async fn wakes_during_a_pass_run_one_more_and_a_stop_holds_the_next() {
    let gate = Arc::new(Notify::new());
    let pass = Flaky::new(0, Some(Arc::clone(&gate)));
    let wake = Wake::new();
    let stop = StopSignal::new();
    let _scheduler = spawn(pass.clone(), wake.clone(), stop.clone(), Backoff::STANDARD);

    wake.pass_soon(PassReason::Launch);
    tokio::time::sleep(Duration::from_millis(20)).await;
    wake.pass_soon(PassReason::Journal);
    wake.pass_soon(PassReason::Journal);
    wake.pass_soon(PassReason::Foreground);
    gate.notify_one();
    pass.done.notified().await;
    gate.notify_one();
    pass.done.notified().await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    let after_coalescing = pass.calls.load(Ordering::SeqCst);
    stop.stop();
    wake.pass_soon(PassReason::Person);
    tokio::time::sleep(Duration::from_millis(50)).await;
    let while_stopped = pass.calls.load(Ordering::SeqCst);
    stop.resume();
    wake.pass_soon(PassReason::Person);
    gate.notify_one();
    pass.done.notified().await;

    assert_eq!(after_coalescing, 2);
    assert_eq!(while_stopped, 2);
    assert_eq!(pass.calls.load(Ordering::SeqCst), 3);
}

#[tokio::test]
async fn a_journal_entry_that_names_records_asks_for_a_pass_and_keeps_the_ids() {
    let pass = Flaky::new(0, None);
    let wake = Wake::new();
    let journal = Journal::new(wake.clone());
    let _scheduler = spawn(pass.clone(), wake.clone(), StopSignal::new(), Backoff::STANDARD);

    journal.changed(&[JournalEntry {
        kind: Kind::Connection,
        written: Vec::new(),
        deleted: Vec::new(),
    }]);
    tokio::time::sleep(Duration::from_millis(50)).await;
    let after_empty = pass.calls.load(Ordering::SeqCst);
    journal.changed(&[JournalEntry {
        kind: Kind::Connection,
        written: vec![id(1)],
        deleted: vec![id(2)],
    }]);
    pass.done.notified().await;
    let taken = journal.take();
    journal.give_back(taken.clone());

    assert_eq!(after_empty, 0);
    assert_eq!(pass.calls.load(Ordering::SeqCst), 1);
    assert_eq!(taken.get(&Kind::Connection), Some(&HashSet::from([id(1), id(2)])));
    assert_eq!(journal.take(), taken);
}
