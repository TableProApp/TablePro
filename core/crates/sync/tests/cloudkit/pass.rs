// The iCloud pass as the scheduler runs it (0054, Scheduling): a wait CloudKit names for a record holds the next pass
// back, and a category turned on is read whole.

use std::sync::Arc;
use std::time::Duration;

use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::SyncError;
use tablepro_sync::api::cloudkit::{CloudKitFailure, CloudKitOutcome, CloudKitTransport};
use tablepro_sync::api::control::{HeldRecordReason, PassReason, SyncCategories, SyncControl, SyncPhase};
use tablepro_sync::api::ids::KindName;
use tablepro_sync::api::state::{HeldReason, Opened, StateFiles, SyncTrust};
use tablepro_sync::cloudkit::fetch::Categories;
use tablepro_sync::engine::{JournalEntry, Pass, StopSignal};
use tablepro_sync::state::SqliteStateFiles;
use tokio::time::timeout;

use crate::faults::{Flaky, Unreliable};
use crate::support::{A, B, KINDS, Rig, name, projected};

#[tokio::test]
async fn a_wait_cloudkit_names_for_a_record_it_could_not_return_reaches_the_fetch_report() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "Work"}));
    let transport = Unreliable::new(&rig.cloud);
    transport.leave_unfetched(&name(Kind::Group, A));
    transport.fail_reads(&name(Kind::Group, A), 1);
    transport.wait_on_failed_reads(5_000);

    let report = rig.fetch_through(&transport).await.unwrap();

    assert_eq!(report.retry_after_ms, Some(5_000));
    assert!(rig.held(Kind::Group, A).await.is_some());
}

#[tokio::test]
async fn a_wait_cloudkit_names_for_a_record_holds_the_next_pass_back_as_a_throttle() {
    let rig = Rig::new().await;
    let flaky = Flaky::new(Arc::clone(&rig.cloud));
    let sync = rig.sync_through(Arc::clone(&flaky) as Arc<dyn CloudKitTransport>, None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &json!({"name": "Work"})));
    flaky.answer_once(
        &name(Kind::Group, A),
        CloudKitOutcome::Failed {
            name: name(Kind::Group, A),
            code: 23,
            retry_after_ms: Some(30_000),
        },
    );

    let throttled = sync.pass(PassReason::Poll).await;
    rig.clock.advance(10_000);
    let early = sync.pass(PassReason::Person).await;
    let early_zone = rig.zone_fields(Kind::Group, A);
    rig.clock.advance(20_000);
    let after = sync.pass(PassReason::Poll).await;

    let throttle = |ms| {
        SyncError::CloudKit(CloudKitFailure::Throttled {
            retry_after_ms: Some(ms),
        })
    };
    assert_eq!(throttled.unwrap_err(), throttle(30_000));
    assert_eq!(early.unwrap_err(), throttle(20_000));
    assert!(early_zone.is_none());
    assert!(after.is_ok());
    assert!(rig.zone_fields(Kind::Group, A).is_some());
}

// A delta never sends again what earlier fetches passed over, so a category turned on is read whole.
#[tokio::test]
async fn a_category_turned_on_is_read_whole_on_the_next_pass() {
    let rig = Rig::new().await;
    rig.turn_off(Kind::Group);
    rig.save_elsewhere(Kind::Group, B, &json!({"name": "Work"}));
    let sync = rig.sync(None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    let skipped = !rig.store(Kind::Group).holds(B);
    sync.run_pass(PassReason::Poll).await.unwrap();

    sync.set_categories(Categories::new(KINDS));
    let report = sync.run_pass(PassReason::Person).await.unwrap();

    assert!(skipped);
    assert!(report.fetch.full);
    assert!(rig.store(Kind::Group).holds(B));
}

// The app's own calls: a kind it turns off sends nothing, turning it back on reads the zone whole, and a store it keeps
// names what it wrote for a journal pass.
#[tokio::test]
async fn the_categories_and_host_changes_the_app_reports_steer_the_pass() {
    let rig = Rig::new().await;
    let sync = rig.sync(None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    let group_off = SyncCategories {
        off: vec![KindName::of(Kind::Group)],
        passwords: true,
    };
    SyncControl::set_categories(&sync, group_off).await.unwrap();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &json!({"name": "Work"})));
    let off = sync.run_pass(PassReason::Poll).await.unwrap();
    let sent_while_off = rig.zone_fields(Kind::Group, A).is_some();
    SyncControl::set_categories(&sync, SyncCategories::default())
        .await
        .unwrap();
    let on = sync.run_pass(PassReason::Person).await.unwrap();
    rig.store(Kind::Group)
        .put(B, projected(Kind::Group, B, &json!({"name": "Home"})));
    sync.host_changed(KindName::of(Kind::Group), vec![B.to_owned()], Vec::new())
        .await
        .unwrap();
    let journal = sync.run_pass(PassReason::Journal).await.unwrap();
    let unknown = sync
        .host_changed(KindName::parse("future_kind").unwrap(), vec![B.to_owned()], Vec::new())
        .await;

    assert_eq!(off.push.saved, 0);
    assert!(!sent_while_off);
    assert!(on.fetch.full);
    assert_eq!(on.push.saved, 1);
    assert_eq!(journal.push.saved, 1);
    assert!(rig.zone_fields(Kind::Group, B).is_some());
    assert_eq!(unknown.unwrap_err().code(), "sync.unknown");
}

// The state file on disk keeps one connection, so a batch's two commits around its store write, the push's commits and
// the zone's row each run with no other transaction open.
#[tokio::test]
async fn a_pass_over_the_state_file_on_disk_commits_around_its_store_writes() {
    let rig = Rig::new().await;
    let dir = tempfile::tempdir().unwrap();
    let store: Arc<dyn tablepro_sync::api::device_store::HostDeviceStore> =
        Arc::new(tablepro_sync_testing::FakeDeviceStore::new());
    let files: Arc<dyn StateFiles> = Arc::new(SqliteStateFiles::at(dir.path().to_path_buf(), store));
    let sync = rig.sync_over(Arc::clone(&rig.cloud) as Arc<dyn CloudKitTransport>, files, None);
    rig.save_elsewhere(
        Kind::Connection,
        A,
        &json!({"name": "prod", "query_timeout_seconds": 30}),
    );
    rig.store(Kind::Group)
        .put(B, projected(Kind::Group, B, &json!({"name": "Work"})));

    let first = timeout(Duration::from_secs(30), sync.run_pass(PassReason::Launch))
        .await
        .unwrap()
        .unwrap();
    rig.store(Kind::Connection).put(
        A,
        projected(
            Kind::Connection,
            A,
            &json!({"name": "mine", "query_timeout_seconds": 30}),
        ),
    );
    rig.save_elsewhere(
        Kind::Connection,
        A,
        &json!({"name": "prod", "query_timeout_seconds": 60}),
    );
    let second = timeout(Duration::from_secs(30), sync.run_pass(PassReason::Poll))
        .await
        .unwrap()
        .unwrap();

    let merged = projected(
        Kind::Connection,
        A,
        &json!({"name": "mine", "query_timeout_seconds": 60}),
    );
    assert_eq!((first.fetch.counts.written, first.push.saved), (1, 1));
    assert_eq!(second.push.saved, 1);
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(merged.clone()));
    assert_eq!(rig.zone_fields(Kind::Connection, A), Some(merged));
}

// A record CloudKit could not return and asked to wait for is not asked for again before the wait ends, whichever pass
// comes next.
#[tokio::test]
async fn a_record_cloudkit_asks_to_wait_for_on_a_fetch_is_not_read_again_before_its_wait_ends() {
    let rig = Rig::new().await;
    let flaky = Flaky::new(Arc::clone(&rig.cloud));
    let sync = rig.sync_through(Arc::clone(&flaky) as Arc<dyn CloudKitTransport>, None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "Work"}));
    flaky.wait_on_read(&name(Kind::Group, A), 30_000);

    let waited = sync.run_pass(PassReason::CloudKitPush).await.unwrap();
    rig.clock.advance(10_000);
    sync.run_pass(PassReason::Person).await.unwrap();
    let reads_while_waiting = flaky.reads_of(&name(Kind::Group, A));
    rig.clock.advance(20_000);
    sync.run_pass(PassReason::Poll).await.unwrap();

    assert_eq!(waited.fetch.retry_after_ms, Some(30_000));
    assert!(waited.throttle().is_some());
    assert_eq!(reads_while_waiting, 1);
    assert!(rig.store(Kind::Group).holds(A));
}

// The pass that follows a wait is a journal pass, and still sends what the throttled one left.
#[tokio::test]
async fn a_journal_pass_after_a_throttle_sends_what_the_throttled_pass_left() {
    let rig = Rig::new().await;
    let flaky = Flaky::new(Arc::clone(&rig.cloud));
    let sync = rig.sync_through(Arc::clone(&flaky) as Arc<dyn CloudKitTransport>, None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &json!({"name": "Work"})));
    sync.journal().changed(&[JournalEntry {
        kind: Kind::Group,
        written: vec![A.to_owned()],
        deleted: Vec::new(),
    }]);
    flaky.answer_once(
        &name(Kind::Group, A),
        CloudKitOutcome::Failed {
            name: name(Kind::Group, A),
            code: 7,
            retry_after_ms: Some(30_000),
        },
    );

    let throttled = sync.pass(PassReason::Journal).await;
    rig.clock.advance(30_000);
    let again = sync.run_pass(PassReason::Journal).await.unwrap();

    assert!(throttled.is_err());
    assert_eq!(again.push.saved, 1);
}

// A pass that stops drops the call in flight, which cancels the Swift task and its CloudKit operation (0054).
#[tokio::test]
async fn a_stop_drops_a_call_that_never_answers() {
    let rig = Rig::new().await;
    let flaky = Flaky::new(Arc::clone(&rig.cloud));
    let sync = rig.sync_through(Arc::clone(&flaky) as Arc<dyn CloudKitTransport>, None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &json!({"name": "Work"})));
    flaky.hang_next_modify();

    let (stopped, ()) = tokio::join!(sync.run_pass(PassReason::Person), async {
        flaky.modifying.notified().await;
        sync.stop_signal().stop();
    });

    assert_eq!(stopped.unwrap_err(), SyncError::Cancelled);
    assert_eq!(sync.status().phase, SyncPhase::Off);
    assert!(rig.zone_fields(Kind::Group, A).is_none());
    assert!(rig.base(Kind::Group, A).await.is_none());
}

// A stop during a fetch ends it before its next commit, so a later page writes nothing.
#[tokio::test]
async fn a_stop_during_a_fetch_writes_nothing_more() {
    let rig = Rig::new().await;
    rig.fetch().await.unwrap();
    rig.cloud.set_limits(1, 400, 1 << 20);
    for id in [A, B] {
        rig.save_elsewhere(Kind::Group, id, &json!({"name": id}));
    }
    let stop = StopSignal::new();
    let transport = Unreliable::new(&rig.cloud);
    let stopping = stop.clone();
    transport.before_call(1, Box::new(move || stopping.stop()));

    let stopped = rig.fetcher(&transport).stopped_by(stop).fetch().await;

    assert_eq!(stopped.unwrap_err(), SyncError::Cancelled);
    assert!(rig.store(Kind::Group).holds(A));
    assert!(!rig.store(Kind::Group).holds(B));
}

// CloudKit asked to be tried again later for a record and named no wait: the pass ends as a throttle.
#[tokio::test]
async fn a_read_cloudkit_asks_to_try_later_without_a_wait_ends_the_fetch_as_a_throttle() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "Work"}));
    let transport = Unreliable::new(&rig.cloud);
    transport.leave_unfetched(&name(Kind::Group, A));
    transport.fail_reads(&name(Kind::Group, A), 2);
    transport.failed_reads_answer(23);

    let report = rig.fetch_through(&transport).await.unwrap();

    assert!(report.throttled);
    assert_eq!(report.retry_after_ms, None);
}

// Another pass runs while a record waits: it ends as a throttle too, so the journal keeps the record for the pass
// that follows the wait.
#[tokio::test]
async fn a_pass_while_a_record_waits_keeps_it_for_the_journal_pass_after_the_wait() {
    let rig = Rig::new().await;
    let flaky = Flaky::new(Arc::clone(&rig.cloud));
    let sync = rig.sync_through(Arc::clone(&flaky) as Arc<dyn CloudKitTransport>, None);
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &json!({"name": "Work"})));
    sync.journal().changed(&[JournalEntry {
        kind: Kind::Group,
        written: vec![A.to_owned()],
        deleted: Vec::new(),
    }]);
    flaky.answer_once(
        &name(Kind::Group, A),
        CloudKitOutcome::Failed {
            name: name(Kind::Group, A),
            code: 7,
            retry_after_ms: Some(30_000),
        },
    );

    sync.run_pass(PassReason::Journal).await.unwrap();
    rig.clock.advance(5_000);
    let meanwhile = sync.run_pass(PassReason::CloudKitPush).await.unwrap();
    rig.clock.advance(25_000);
    let after = sync.run_pass(PassReason::Journal).await.unwrap();

    assert_eq!(
        meanwhile.throttle(),
        Some(CloudKitFailure::Throttled {
            retry_after_ms: Some(25_000)
        })
    );
    assert_eq!(after.push.saved, 1);
}

// The state file went back while the store did not: the open trusts none of its sync tables, so the first fetch after
// it reads the zone whole and the pull wins, and the next pass of the same open merges as usual (0054, A stale file).
#[tokio::test]
async fn a_state_file_the_open_found_restored_refills_once() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "Work"}));
    rig.sync(None).run_pass(PassReason::Launch).await.unwrap();
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "Newer"}));
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &json!({"name": "Restored with the file"})));
    rig.files.set_opened(
        Rig::identity(),
        Opened {
            sync_tables: SyncTrust::Refill,
            ..Opened::FRESH
        },
    );
    let sync = rig.sync(None);

    let first = sync.run_pass(PassReason::Launch).await.unwrap();
    let refilled = rig.store(Kind::Group).fields(A);
    rig.store(Kind::Group)
        .put(A, projected(Kind::Group, A, &json!({"name": "Mine"})));
    let second = sync.run_pass(PassReason::Poll).await.unwrap();

    assert!(first.fetch.full);
    assert!(first.fetch.refilled.contains(&Kind::Group));
    assert_eq!(refilled, Some(projected(Kind::Group, A, &json!({"name": "Newer"}))));
    assert!(second.fetch.refilled.is_empty());
    assert_eq!(second.push.saved, 1);
    assert_eq!(
        rig.zone_fields(Kind::Group, A),
        Some(projected(Kind::Group, A, &json!({"name": "Mine"})))
    );
}

#[tokio::test]
async fn the_records_a_pass_held_by_id_are_listed_with_why() {
    let rig = Rig::new().await;
    let sync = rig.sync(None);
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    sync.run_pass(PassReason::Launch).await.unwrap();
    rig.store(Kind::Connection).make_unreadable(A);
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "renamed"}));

    let before = sync.held_records().await.unwrap();
    sync.run_pass(PassReason::CloudKitPush).await.unwrap();
    let held = sync.held_records().await.unwrap();

    assert!(before.is_empty(), "{before:?}");
    assert_eq!(held.len(), 1, "{held:?}");
    assert_eq!(held[0].key.record_id, A);
    assert_eq!(held[0].reason, HeldRecordReason::Held(HeldReason::Unreadable));
}

// A record the store refused is held, and each pass that tries it again and holds it again says so in the status.
#[tokio::test]
async fn a_pass_that_holds_a_value_the_store_refused_says_so() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    rig.store(Kind::Connection).refuse_value(A, true);
    let sync = rig.sync(None);

    sync.run_pass(PassReason::Launch).await.unwrap();
    let problem = sync.status().problem;
    let held = sync.status().held;
    sync.run_pass(PassReason::Poll).await.unwrap();
    let still = sync.status().problem;
    rig.store(Kind::Connection).refuse_value(A, false);
    sync.run_pass(PassReason::Poll).await.unwrap();

    assert_eq!(problem, Some("sync.adapter.unreadable"));
    assert_eq!(held, 1);
    assert_eq!(still, Some("sync.adapter.unreadable"));
    assert_eq!(sync.status().problem, None);
    assert!(rig.store(Kind::Connection).holds(A));
}
