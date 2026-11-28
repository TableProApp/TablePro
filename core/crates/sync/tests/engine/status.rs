// What the status keeps across passes and launches: the last sync outlives a restart and a failed pass, and another
// device joining the account reaches the app (E2E F21).

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use tablepro_keys::encoding::KeyDeviceId;
use tablepro_records::Kind;
use tablepro_sync::api::control::{SyncControl, SyncPhase};
use tablepro_sync::api::ids::{RecordKey, ScopeName};
use tablepro_sync::api::state::{Opened, Row, Standing, StandingRow, StateFiles};
use tablepro_sync::api::transport::TransportError;
use tablepro_sync::engine::EngineEvents;
use tablepro_sync::service::ServiceSync;
use tablepro_sync_testing::{FakeDeviceStore, FakeServer, MemoryStateFiles};
use uuid::Uuid;

use super::harness::{Device, DeviceBuilder, KeyLog, files_at, id, identity};

const ROW: &str = "dev_mac";

#[derive(Default)]
struct Heard {
    keys: AtomicUsize,
}

impl EngineEvents for Heard {
    fn status_changed(&self) {}

    fn keys_changed(&self) {
        self.keys.fetch_add(1, Ordering::SeqCst);
    }

    fn approvals_changed(&self) {}
}

// The phase at each status signal, read from the engine it follows.
#[derive(Default)]
struct Phases {
    sync: std::sync::OnceLock<std::sync::Weak<ServiceSync>>,
    seen: std::sync::Mutex<Vec<SyncPhase>>,
}

impl Phases {
    fn follow(&self, sync: &Arc<ServiceSync>) {
        let _ = self.sync.set(Arc::downgrade(sync));
    }

    fn take(&self) -> Vec<SyncPhase> {
        std::mem::take(&mut *self.seen.lock().unwrap())
    }
}

impl EngineEvents for Phases {
    fn status_changed(&self) {
        if let Some(sync) = self.sync.get().and_then(std::sync::Weak::upgrade) {
            self.seen.lock().unwrap().push(sync.status().phase);
        }
    }

    fn keys_changed(&self) {}

    fn approvals_changed(&self) {}
}

fn network() -> TransportError {
    TransportError::Network {
        detail: "connection timed out".to_owned(),
    }
}

// E2E F21: a Mac relaunched while its server was out of reach said "Last synced: Never".
#[tokio::test]
async fn the_last_sync_outlives_a_restart_and_no_failed_pass_moves_it() {
    let server = FakeServer::new();
    let files = MemoryStateFiles::new();
    let device = DeviceBuilder::new(&server, ROW)
        .state(files.open(identity(ROW)).await.unwrap())
        .build()
        .await;
    device.clock.advance(1_000);
    device.sync().await;
    device.clock.advance(60_000);
    server.fail_next(network());
    device.pass().await.unwrap_err();
    let before = device.sync.status();
    drop(device);

    server.fail_next(network());
    let restarted = DeviceBuilder::new(&server, ROW)
        .state(files.open(identity(ROW)).await.unwrap())
        .build()
        .await;
    let launched = restarted.sync.status();
    restarted.pass().await.unwrap_err();
    let offline = restarted.sync.status();

    assert_eq!(before.last_synced_ms, Some(1_000));
    assert_eq!(before.last_pass_ms, Some(61_000));
    assert_eq!(launched.last_synced_ms, Some(1_000));
    assert_eq!(launched.last_pass_ms, None);
    assert_eq!(offline.problem, Some("sync.network"));
    assert_ne!(offline.phase, SyncPhase::Unavailable);
    assert_eq!(offline.last_synced_ms, Some(1_000));
}

#[tokio::test]
async fn a_launch_that_never_synced_and_cannot_reach_the_server_waits_with_no_last_sync() {
    let server = FakeServer::new();
    server.fail_next(network());
    let device = Device::new(&server, ROW).await;

    let failed = device.pass().await.unwrap_err();
    let status = device.sync.status();

    assert_eq!(failed.code(), "sync.network");
    assert_eq!(status.problem, Some("sync.network"));
    assert_ne!(status.phase, SyncPhase::Unavailable);
    assert_eq!(status.last_synced_ms, None);
}

// The time sits outside the MAC, so keeping it never costs a commit, and a file that holds it still verifies.
#[tokio::test]
async fn the_last_sync_kept_on_disk_reads_back_and_the_file_still_verifies() {
    let dir = tempfile::tempdir().unwrap();
    let files = files_at(dir.path(), &Arc::new(FakeDeviceStore::new()));
    let state = files.open(identity(ROW)).await.unwrap();
    let mut txn = state.begin().await.unwrap();
    txn.put(Row::Standing(StandingRow {
        key: RecordKey::new(ScopeName::Personal, Kind::Connection, id(1)),
        standing: Standing::Syncs,
    }))
    .await
    .unwrap();
    txn.commit().await.unwrap();

    state.set_last_synced_ms(1_000).await.unwrap();
    state.set_last_synced_ms(2_000).await.unwrap();
    drop(state);
    let reopened = files.open(identity(ROW)).await.unwrap();

    assert_eq!(reopened.last_synced_ms().await.unwrap(), Some(2_000));
    assert_eq!(*reopened.opened(), Opened::FRESH);
}

// E2E F21: a device approved on another Mac stayed off this Mac's list of devices until its next pass and longer.
#[tokio::test]
async fn another_device_joining_the_account_reaches_the_app_as_a_key_change() {
    let server = FakeServer::new();
    let heard = Arc::new(Heard::default());
    let keys = Arc::new(KeyLog::default());
    let this = KeyDeviceId(Uuid::new_v4());
    keys.set_devices(&[this]);
    let device = DeviceBuilder::new(&server, ROW)
        .keys(Arc::clone(&keys))
        .events(Arc::clone(&heard) as Arc<dyn EngineEvents>)
        .build()
        .await;

    device.sync().await;
    let first = heard.keys.load(Ordering::SeqCst);
    device.sync().await;
    let unchanged = heard.keys.load(Ordering::SeqCst);
    keys.set_devices(&[this, KeyDeviceId(Uuid::new_v4())]);
    device.sync().await;
    let joined = heard.keys.load(Ordering::SeqCst);

    assert_eq!(unchanged, first);
    assert_eq!(joined, first + 1);
}

// E2E F21: through an outage the status said Syncing for as long as each retry waited out its timeout.
#[tokio::test]
async fn a_pass_after_one_the_network_failed_says_syncing_only_once_the_server_answers() {
    let server = FakeServer::new();
    let phases = Arc::new(Phases::default());
    let device = DeviceBuilder::new(&server, ROW)
        .events(Arc::clone(&phases) as Arc<dyn EngineEvents>)
        .build()
        .await;
    phases.follow(&device.sync);
    device.sync().await;
    let first = phases.take();
    server.fail_next(network());
    device.pass().await.unwrap_err();
    phases.take();

    server.fail_next(network());
    device.pass().await.unwrap_err();
    let unanswered = phases.take();
    device.sync().await;
    let answered = phases.take();

    assert_eq!(first.first(), Some(&SyncPhase::Syncing), "{first:?}");
    assert_eq!(
        unanswered.first(),
        Some(&SyncPhase::Waiting { retry_in_ms: 0 }),
        "{unanswered:?}"
    );
    assert!(!unanswered.contains(&SyncPhase::Syncing), "{unanswered:?}");
    assert_eq!(
        answered[..2],
        [SyncPhase::Waiting { retry_in_ms: 0 }, SyncPhase::Syncing],
        "{answered:?}"
    );
    assert_eq!(device.sync.status().phase, SyncPhase::Idle);
    assert_eq!(device.sync.status().problem, None);
}
