// T-MOV (0054, Moving between providers; Verification): devices on a fake CloudKit zone and the in-memory `/v2`
// server, each with one connection store both engines sync. Another device already on TablePro Sync stands for the
// service side's own edits.

use std::sync::Arc;

use serde_json::{Value, json};
use tablepro_records::Kind;
use tablepro_records::cloudkit::{CloudFields, from_wire, record_name, record_type_of, to_wire};
use tablepro_records::move_marker::MEMBER;
use tablepro_sync::api::adapter::RecordAdapter;
use tablepro_sync::api::cloudkit::CloudKitTransport;
use tablepro_sync::api::control::{MovePlan, PassReason};
use tablepro_sync::api::ids::{RecordKey, ScopeName};
use tablepro_sync::api::state::{MovePhase, Row, RowKey, RowRange, StateFiles, StateIdentity, Table};
use tablepro_sync::cloudkit::fetch::Categories;
use tablepro_sync::cloudkit::modify::{CloudKitParts, CloudKitSync};
use tablepro_sync::engine::{Clock, Journal, StopSignal};
use tablepro_sync::moves::{MoveParts, Mover};
use tablepro_sync::service::ServiceMode;
use tablepro_sync_testing::service::Policies;
use tablepro_sync_testing::{FakeCloudKit, FakeServer, MemoryStateFiles};

use super::harness::{Device, DeviceBuilder, TestClock, id, personal};

const USER: &str = "_icloud_user";

// What iCloud carries of a connection, which is what both engines then agree on.
fn carried(n: u8, name: &str, sort_order: i64) -> Value {
    let id = id(n);
    let wire = json!({"name": name, "icon_name": "database", "sort_order": sort_order});
    let fields: CloudFields = from_wire(Kind::Connection, &id, &wire, 1_700_000_000_000)
        .unwrap()
        .unwrap()
        .into_iter()
        .filter_map(|(member, value)| Some((member.to_owned(), value?)))
        .collect();
    to_wire(
        record_type_of(Kind::Connection).unwrap().name,
        &record_name(Kind::Connection, &id).unwrap(),
        &fields,
    )
    .unwrap()
    .fields
}

fn with(mut fields: Value, member: &str, value: Value) -> Value {
    fields[member] = value;
    fields
}

fn icloud_file() -> StateIdentity {
    StateIdentity::ICloud {
        user_record_name: USER.to_owned(),
    }
}

// The service's live copy, None once it is a tombstone or was never there.
fn live(server: &FakeServer, n: u8) -> Option<Value> {
    server
        .stored(personal(), "connection", &id(n))
        .and_then(|record| record.fields)
}

fn in_zone(cloud: &FakeCloudKit, n: u8) -> bool {
    cloud
        .record(USER, &record_name(Kind::Connection, &id(n)).unwrap())
        .is_some()
}

struct Apple {
    device: Device,
    icloud: Arc<CloudKitSync>,
    files: Arc<MemoryStateFiles>,
    cloud: Arc<FakeCloudKit>,
}

impl Apple {
    // A device whose personal provider is iCloud: the service carries only its teams and key objects.
    async fn on_icloud(server: &Arc<FakeServer>, cloud: &Arc<FakeCloudKit>, row: &str) -> Self {
        let device = DeviceBuilder::new(server, row).teams_only().build().await;
        let files = Arc::new(MemoryStateFiles::new());
        let icloud = Self::engine(&device, cloud, &files, None);
        Self {
            device,
            icloud,
            files,
            cloud: Arc::clone(cloud),
        }
    }

    fn engine(
        device: &Device,
        cloud: &Arc<FakeCloudKit>,
        files: &Arc<MemoryStateFiles>,
        last: Option<&str>,
    ) -> Arc<CloudKitSync> {
        Arc::new(CloudKitSync::new(CloudKitParts {
            transport: Arc::clone(cloud) as Arc<dyn CloudKitTransport>,
            files: Arc::clone(files) as Arc<dyn StateFiles>,
            adapters: vec![Arc::clone(&device.connections) as Arc<dyn RecordAdapter>],
            categories: Categories::new([Kind::Connection]),
            clock: Arc::new(TestClock::default()) as Arc<dyn Clock>,
            stop: StopSignal::new(),
            journal: Journal::default(),
            events: None,
            last_account: last.map(str::to_owned),
        }))
    }

    async fn icloud_pass(&self) {
        self.icloud.run_pass(PassReason::Person).await.unwrap();
    }

    // iCloud is the provider while `on_icloud` holds, and TablePro Sync once a move went through.
    fn mover(&self, on_icloud: bool) -> Mover {
        Mover::new(MoveParts {
            service: Arc::clone(&self.device.sync),
            icloud: on_icloud.then(|| Arc::clone(&self.icloud)),
            cloudkit: Some(Arc::clone(&self.cloud) as Arc<dyn CloudKitTransport>),
            files: Arc::clone(&self.files) as Arc<dyn StateFiles>,
            icloud_account: Some(USER.to_owned()),
            allowed: Arc::new(|_| true),
            gate: Arc::default(),
        })
    }

    // As `mover`, under values that allow iCloud for the first `calls` checks only.
    fn mover_revoked_after(&self, calls: usize) -> Mover {
        let seen = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        Mover::new(MoveParts {
            service: Arc::clone(&self.device.sync),
            icloud: None,
            cloudkit: Some(Arc::clone(&self.cloud) as Arc<dyn CloudKitTransport>),
            files: Arc::clone(&self.files) as Arc<dyn StateFiles>,
            icloud_account: Some(USER.to_owned()),
            allowed: Arc::new(move |provider| {
                provider != tablepro_sync::api::state::Provider::ICloud
                    || seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst) < calls
            }),
            gate: Arc::default(),
        })
    }

    // As `mover`, off iCloud, under values a test flips, behind a policy gate the test holds; `calls` counts the checks.
    fn mover_gated(
        &self,
        gate: &Arc<tokio::sync::RwLock<()>>,
        allows: &Arc<std::sync::atomic::AtomicBool>,
        calls: &Arc<std::sync::atomic::AtomicUsize>,
    ) -> Mover {
        let (allows, calls) = (Arc::clone(allows), Arc::clone(calls));
        Mover::new(MoveParts {
            service: Arc::clone(&self.device.sync),
            icloud: None,
            cloudkit: Some(Arc::clone(&self.cloud) as Arc<dyn CloudKitTransport>),
            files: Arc::clone(&self.files) as Arc<dyn StateFiles>,
            icloud_account: Some(USER.to_owned()),
            allowed: Arc::new(move |provider| {
                if provider != tablepro_sync::api::state::Provider::ICloud {
                    return true;
                }
                calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                allows.load(std::sync::atomic::Ordering::SeqCst)
            }),
            gate: Arc::clone(gate),
        })
    }

    fn put(&self, n: u8, fields: Value) {
        self.device.connections.put(&id(n), fields);
    }

    fn get(&self, n: u8) -> Option<Value> {
        self.device.connections.get(&id(n))
    }
}

// The device already on TablePro Sync, caught up.
async fn on_the_service(server: &Arc<FakeServer>) -> Device {
    let web = Device::new(server, "dev_web").await;
    web.sync().await;
    web
}

// Mac A moves; iPhone B, still on iCloud, deletes records; iPad C pulls those deletions; then B and C move. Each
// deletion stands on the service unless the service copy's content changed since the move; a reorder there keeps
// nothing, and a record created on the service after the move is left alone.
#[tokio::test]
async fn deletions_made_on_icloud_after_another_device_moved_reach_the_service_when_the_later_devices_move() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    let phone = Apple::on_icloud(&server, &cloud, "dev_phone").await;
    let pad = Apple::on_icloud(&server, &cloud, "dev_pad").await;
    for (n, name) in [(1, "Deleted"), (2, "Edited"), (3, "Reordered"), (4, "Kept")] {
        mac.put(n, carried(n, name, i64::from(n)));
    }
    mac.icloud_pass().await;
    phone.icloud_pass().await;
    pad.icloud_pass().await;

    mac.mover(true).move_to_service().await.unwrap();
    let marked = server
        .stored(personal(), "connection", &id(1))
        .and_then(|record| record.fields)
        .and_then(|fields| fields.get(MEMBER).cloned());
    let kept_here = mac.get(1);
    let agreed = match mac
        .device
        .row(RowKey::Base(RecordKey::new(
            ScopeName::Personal,
            Kind::Connection,
            id(1),
        )))
        .await
    {
        Some(Row::Base(base)) => base.fields,
        _ => None,
    };
    let web = on_the_service(&server).await;
    web.connections.put(
        &id(2),
        with(carried(2, "Edited", 2), "name", json!("Edited on the web")),
    );
    web.connections.put(&id(3), carried(3, "Reordered", 30));
    web.connections.put(&id(5), carried(5, "Made on the web", 5));
    web.sync().await;
    for n in [1, 2, 3] {
        phone.device.connections.remove(&id(n));
    }
    phone.icloud_pass().await;
    pad.icloud_pass().await;

    phone.mover(true).move_to_service().await.unwrap();
    pad.mover(true).move_to_service().await.unwrap();
    mac.device.sync().await;

    assert!(marked.is_some(), "the first mover wrote no marker");
    assert_eq!(kept_here, Some(carried(1, "Deleted", 1)));
    assert_eq!(agreed, Some(carried(1, "Deleted", 1)));
    assert_eq!(live(&server, 1), None);
    assert_eq!(live(&server, 3), None);
    assert_eq!(
        live(&server, 2).and_then(|fields| fields.get("name").cloned()),
        Some(json!("Edited on the web"))
    );
    assert_eq!(
        live(&server, 4).and_then(|fields| fields.get("name").cloned()),
        Some(json!("Kept"))
    );
    assert_eq!(
        live(&server, 5).and_then(|fields| fields.get("name").cloned()),
        Some(json!("Made on the web"))
    );
    for device in [&phone, &pad, &mac] {
        assert_eq!(device.get(1), None);
        assert_eq!(device.get(3), None);
        assert!(device.get(2).is_some());
        assert!(device.get(4).is_some());
        assert!(device.get(5).is_some());
    }
    assert_eq!(phone.device.sync.mode(), ServiceMode::Personal);
}

// An edit made on iCloud after another device moved is that device's own edit when it moves, against the moved copy,
// and an edit made on the service meanwhile stays beside it.
#[tokio::test]
async fn an_icloud_edit_after_another_device_moved_merges_with_the_service_s_edit() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    let phone = Apple::on_icloud(&server, &cloud, "dev_phone").await;
    mac.put(1, carried(1, "Prod", 1));
    mac.icloud_pass().await;
    phone.icloud_pass().await;

    mac.mover(true).move_to_service().await.unwrap();
    phone.put(1, carried(1, "Prod (phone)", 1));
    phone.icloud_pass().await;
    let web = on_the_service(&server).await;
    web.connections
        .put(&id(1), with(carried(1, "Prod", 1), "icon_name", json!("server")));
    web.sync().await;
    phone.mover(true).move_to_service().await.unwrap();

    let merged = with(carried(1, "Prod (phone)", 1), "icon_name", json!("server"));
    assert_eq!(phone.get(1), Some(merged.clone()));
    assert_eq!(
        live(&server, 1).map(|fields| with(fields, MEMBER, Value::Null)),
        Some(with(merged, MEMBER, Value::Null))
    );
}

// TablePro Sync forced with iCloud traffic forbidden (0055): the move makes no iCloud call, no last pass and no zone
// fetch, and the device's iCloud edit it never sent merges against its CloudKit base with the service's edit rather
// than losing to the server's copy.
#[tokio::test]
async fn a_move_with_icloud_forbidden_merges_the_unsent_icloud_edit_without_an_icloud_call() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    let phone = Apple::on_icloud(&server, &cloud, "dev_phone").await;
    mac.put(1, carried(1, "Prod", 1));
    mac.icloud_pass().await;
    phone.icloud_pass().await;
    mac.mover(true).move_to_service().await.unwrap();
    let web = on_the_service(&server).await;
    web.connections
        .put(&id(1), with(carried(1, "Prod", 1), "icon_name", json!("server")));
    web.sync().await;
    phone.put(1, carried(1, "Prod (phone)", 1));
    // One failure waits for the first call, so a move that made any reads it.
    cloud.fail_next(tablepro_sync::api::cloudkit::CloudKitFailure::Network);

    phone.mover(true).move_to_service_without_icloud().await.unwrap();

    let merged = with(carried(1, "Prod (phone)", 1), "icon_name", json!("server"));
    assert_eq!(phone.get(1), Some(merged.clone()));
    assert_eq!(
        live(&server, 1).map(|fields| with(fields, MEMBER, Value::Null)),
        Some(with(merged, MEMBER, Value::Null))
    );
    assert!(cloud.account_status().await.is_err(), "the move called CloudKit");
}

// The forced move with no iCloud call still reads this device's own deletion: a record its CloudKit base names that
// its store no longer holds is deleted on the service, unless its content changed there since the first mover.
#[tokio::test]
async fn a_move_with_icloud_forbidden_takes_the_device_s_own_deletion_from_its_bases() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    let phone = Apple::on_icloud(&server, &cloud, "dev_phone").await;
    mac.put(1, carried(1, "Prod", 1));
    mac.icloud_pass().await;
    phone.icloud_pass().await;
    mac.mover(true).move_to_service().await.unwrap();
    phone.device.connections.remove(&id(1));

    phone.mover(true).move_to_service_without_icloud().await.unwrap();

    assert_eq!(phone.get(1), None);
    assert_eq!(live(&server, 1), None);
}

// A connection this device kept off sync and then deleted is no deletion of the device's to take to the service, even
// with no zone listing to read.
#[tokio::test]
async fn a_move_with_icloud_forbidden_keeps_a_deleted_local_only_connection_on_the_service() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    let phone = Apple::on_icloud(&server, &cloud, "dev_phone").await;
    mac.put(1, carried(1, "Prod", 1));
    mac.icloud_pass().await;
    phone.icloud_pass().await;
    mac.mover(true).move_to_service().await.unwrap();
    phone.device.connections.put_local_only(&id(1), carried(1, "Prod", 1));
    phone.icloud_pass().await;
    phone.device.connections.remove(&id(1));

    phone.mover(true).move_to_service_without_icloud().await.unwrap();

    assert!(live(&server, 1).is_some());
}

#[tokio::test]
async fn local_only_records_stay_behind_and_the_plan_counts_them() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    mac.put(1, carried(1, "Synced", 1));
    mac.device
        .connections
        .put_local_only(&id(2), carried(2, "Here only", 2));
    mac.icloud_pass().await;

    let plan = mac.mover(true).plan_move_to_service().await.unwrap();
    mac.mover(true).move_to_service().await.unwrap();

    assert_eq!(
        plan,
        MovePlan {
            records: 1,
            staying_behind: 1,
            secrets_to_seal: 0,
        }
    );
    assert!(live(&server, 1).is_some());
    assert_eq!(live(&server, 2), None);
    assert!(mac.icloud.stop_signal().is_stopped());
}

// Back to iCloud: a record the person deleted on the service goes from the zone once the person confirmed the count;
// one another device changed on iCloud since stays, and so does one a policy removed.
#[tokio::test]
async fn the_move_back_deletes_on_icloud_only_what_the_person_confirmed_and_keeps_changed_and_policy_copies() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    let phone = Apple::on_icloud(&server, &cloud, "dev_phone").await;
    for (n, name) in [(1, "Deleted"), (2, "Changed on iCloud"), (3, "Policy")] {
        mac.put(n, carried(n, name, i64::from(n)));
    }
    mac.icloud_pass().await;
    phone.icloud_pass().await;
    mac.mover(true).move_to_service().await.unwrap();
    let web = on_the_service(&server).await;
    web.connections.remove(&id(1));
    web.connections.remove(&id(2));
    web.sync().await;
    phone.put(
        2,
        with(carried(2, "Changed on iCloud", 2), "name", json!("Phone's edit")),
    );
    phone.icloud_pass().await;
    mac.device.sync().await;
    server.set_policies(Policies {
        personal_sync: false,
        ..Policies::default()
    });
    mac.device.sync().await;

    let plan = mac.mover(false).plan_move_to_icloud().await.unwrap();
    let unconfirmed = mac.mover(false).move_to_icloud(0).await;
    let in_zone_before = in_zone(&cloud, 1);
    mac.mover(false).move_to_icloud(plan.icloud_deletions).await.unwrap();
    let resumed = Apple::engine(&mac.device, &cloud, &mac.files, Some(USER));
    resumed.run_pass(PassReason::Launch).await.unwrap();

    assert_eq!(plan.icloud_deletions, 1);
    assert_eq!(unconfirmed.unwrap_err().code(), "sync.not_allowed");
    assert!(in_zone_before);
    assert!(!in_zone(&cloud, 1));
    assert!(in_zone(&cloud, 2));
    assert!(in_zone(&cloud, 3));
    assert_eq!(mac.get(1), None);
    assert_eq!(
        mac.get(2).and_then(|fields| fields.get("name").cloned()),
        Some(json!("Phone's edit"))
    );
    assert!(mac.get(3).is_some());
    assert_eq!(mac.device.sync.mode(), ServiceMode::TeamsOnly);
}

#[tokio::test]
async fn the_zone_a_move_left_goes_only_when_the_person_deletes_it_and_never_while_icloud_is_the_provider() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    mac.put(1, carried(1, "Prod", 1));
    mac.icloud_pass().await;

    let while_on_icloud = mac.mover(true).delete_icloud_zone().await;
    mac.mover(true).move_to_service().await.unwrap();
    let after_the_move = in_zone(&cloud, 1);
    mac.mover(false).delete_icloud_zone().await.unwrap();

    assert_eq!(while_on_icloud.unwrap_err().code(), "sync.not_allowed");
    assert!(after_the_move);
    assert!(cloud.record_names(USER).is_empty());
    assert!(!mac.files.exists(&icloud_file()));
    assert!(mac.get(1).is_some());
}

// From no provider, with an iCloud state file left from long ago: no base to merge against, so the server's copy wins,
// what it lacks goes up, and the old iCloud file goes.
#[tokio::test]
async fn a_first_upload_from_off_takes_the_server_s_copy_and_sends_what_the_server_lacks() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let web = on_the_service(&server).await;
    web.connections.put(&id(1), carried(1, "Server's", 1));
    web.sync().await;
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    mac.put(1, carried(1, "Device's", 1));
    mac.put(2, carried(2, "Only here", 2));
    mac.icloud_pass().await;
    mac.icloud.stop_signal().stop();

    mac.mover(false).first_upload().await.unwrap();

    assert_eq!(mac.get(1), Some(carried(1, "Server's", 1)));
    assert_eq!(live(&server, 1), Some(carried(1, "Server's", 1)));
    assert_eq!(live(&server, 2), Some(carried(2, "Only here", 2)));
    assert!(!mac.files.exists(&icloud_file()));
    assert_eq!(mac.device.sync.mode(), ServiceMode::Personal);
}

// The first upload's refill is a mark per kind in the state file, written before its pull, so a restart refills them
// again; only the kinds the personal scope alone holds take it, and the snapshot that ends it clears them.
#[tokio::test]
async fn a_first_upload_refills_by_per_kind_marks_that_its_snapshot_clears() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let web = on_the_service(&server).await;
    web.connections.put(&id(1), carried(1, "Server's", 1));
    web.sync().await;
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    mac.put(1, carried(1, "Device's", 1));
    mac.icloud.stop_signal().stop();
    let (reached, release) = mac.device.wire.hold_next_pull(ScopeName::Personal);

    let marks = || async {
        mac.device
            .rows(RowRange::Table(Table::StoresKinds))
            .await
            .into_iter()
            .filter_map(|row| match row {
                Row::StoresKind(row) => Some((row.store, row.kind.as_str().to_owned())),
                _ => None,
            })
            .collect::<Vec<_>>()
    };
    let meanwhile = async {
        reached.notified().await;
        let during = marks().await;
        release.notify_one();
        during
    };
    let mover = mac.mover(false);
    let (uploaded, during) = tokio::join!(mover.first_upload(), meanwhile);

    uploaded.unwrap();
    assert_eq!(during, [("connections".to_owned(), "connection".to_owned())]);
    assert!(marks().await.is_empty());
    assert_eq!(mac.get(1), Some(carried(1, "Server's", 1)));
}

// A value the move took from the service is the device's base from then on: a change made on the service while the
// move ran, which a conflict pulls in the same pass, wins over it rather than meeting the marker again.
#[tokio::test]
async fn a_service_change_pulled_again_during_the_move_merges_against_what_the_move_took() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    let phone = Apple::on_icloud(&server, &cloud, "dev_phone").await;
    mac.put(1, carried(1, "Prod", 1));
    mac.icloud_pass().await;
    phone.icloud_pass().await;
    mac.mover(true).move_to_service().await.unwrap();
    let web = on_the_service(&server).await;
    web.connections
        .put(&id(1), with(carried(1, "Prod", 1), "icon_name", json!("server")));
    web.sync().await;
    phone.put(1, carried(1, "Prod (phone)", 1));
    phone.icloud_pass().await;
    let (reached, release) = phone.device.wire.hold_next_pull(ScopeName::Personal);

    let meanwhile = async {
        reached.notified().await;
        web.connections
            .put(&id(1), with(carried(1, "Prod", 1), "icon_name", json!("cloud")));
        web.sync().await;
        release.notify_one();
    };
    let mover = phone.mover(true);
    let (moved, ()) = tokio::join!(mover.move_to_service(), meanwhile);

    moved.unwrap();
    let merged = with(carried(1, "Prod (phone)", 1), "icon_name", json!("cloud"));
    assert_eq!(phone.get(1), Some(merged.clone()));
    assert_eq!(
        live(&server, 1).map(|fields| with(fields, MEMBER, Value::Null)),
        Some(with(merged, MEMBER, Value::Null))
    );
}

// A move that stops short leaves iCloud stopped, so nothing the service brought reaches the zone, and the next call
// finishes it.
#[tokio::test]
async fn a_move_that_stops_short_keeps_icloud_stopped_and_finishes_when_called_again() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let web = on_the_service(&server).await;
    web.connections.put(&id(9), carried(9, "Only on the service", 9));
    web.sync().await;
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    mac.put(1, carried(1, "Prod", 1));
    mac.icloud_pass().await;
    mac.device.wire.drop_next_push();

    let first = mac.mover(true).move_to_service().await;
    let held_back = mac.icloud.run_pass(PassReason::Poll).await;
    let after_the_failure = (in_zone(&cloud, 9), mac.device.sync.mode());
    mac.mover(true).move_to_service().await.unwrap();

    assert!(first.is_err());
    assert_eq!(held_back.unwrap_err().code(), "sync.cancelled");
    assert_eq!(after_the_failure, (false, ServiceMode::TeamsOnly));
    assert!(
        live(&server, 1)
            .and_then(|fields| fields.get(MEMBER).cloned())
            .is_some()
    );
    assert_eq!(mac.get(9), Some(carried(9, "Only on the service", 9)));
    assert!(!in_zone(&cloud, 9));
    assert_eq!(mac.device.sync.mode(), ServiceMode::Personal);
}

// A restart in the middle of a move keeps iCloud from syncing the file it moved, with no CloudKit call, and the move
// goes on from what its first try committed when called again: the `moves` rows hold it open across the restart.
#[tokio::test]
async fn a_move_a_restart_cut_short_keeps_icloud_stopped_and_goes_on_from_its_bases() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let web = on_the_service(&server).await;
    web.connections.put(&id(9), carried(9, "Only on the service", 9));
    web.sync().await;
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    mac.put(1, carried(1, "Prod", 1));
    mac.icloud_pass().await;
    mac.device.wire.drop_next_push();
    let first = mac.mover(true).move_to_service().await;

    let device = DeviceBuilder::new(&server, "dev_mac")
        .teams_only()
        .state(Arc::clone(&mac.device.state))
        .connections(
            Arc::clone(&mac.device.connections),
            Arc::clone(&mac.device.connections_file),
        )
        .keys(Arc::clone(&mac.device.keys))
        .seed(Arc::clone(&mac.device.seed))
        .build()
        .await;
    let icloud = Apple::engine(&device, &cloud, &mac.files, Some(USER));
    cloud.fail_next(tablepro_sync::api::cloudkit::CloudKitFailure::Network);
    let held_back = icloud.run_pass(PassReason::Poll).await;
    let called = cloud.account_status().await.is_ok();
    let restarted = Apple {
        device,
        icloud,
        files: Arc::clone(&mac.files),
        cloud: Arc::clone(&cloud),
    };
    let open = restarted.icloud.open_move().await.unwrap();
    restarted.mover(true).move_to_service().await.unwrap();

    assert!(first.is_err());
    assert_eq!(held_back.unwrap_err().code(), "sync.not_allowed");
    assert!(!called, "the moved file reached CloudKit");
    assert_eq!(open.map(|row| row.phase), Some(MovePhase::Open));
    assert_eq!(
        restarted.icloud.open_move().await.unwrap().map(|row| row.phase),
        Some(MovePhase::Done)
    );
    assert_eq!(restarted.get(9), Some(carried(9, "Only on the service", 9)));
    assert!(!in_zone(&cloud, 9));
    assert_eq!(restarted.device.sync.mode(), ServiceMode::Personal);
    assert_eq!(
        restarted.device.sync.move_row().await.unwrap().map(|row| row.phase),
        Some(MovePhase::Done)
    );
}

// A move back that a restart cut short keeps personal data resting on TablePro Sync until the person moves it again.
#[tokio::test]
async fn a_move_back_cut_short_keeps_personal_data_resting_on_the_service() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    mac.put(1, carried(1, "Prod", 1));
    mac.icloud_pass().await;
    mac.mover(true).move_to_service().await.unwrap();
    let web = on_the_service(&server).await;
    web.connections.remove(&id(1));
    web.sync().await;
    mac.device.sync().await;
    let plan = mac.mover(false).plan_move_to_icloud().await.unwrap();
    cloud.fail_record(&record_name(Kind::Connection, &id(1)).unwrap(), 4);

    let back = mac.mover(false).move_to_icloud(plan.icloud_deletions).await;
    let device = DeviceBuilder::new(&server, "dev_mac")
        .state(Arc::clone(&mac.device.state))
        .connections(
            Arc::clone(&mac.device.connections),
            Arc::clone(&mac.device.connections_file),
        )
        .keys(Arc::clone(&mac.device.keys))
        .seed(Arc::clone(&mac.device.seed))
        .build()
        .await;
    mac.put(2, carried(2, "Edited while the move back waits", 2));
    device.sync().await;

    assert_eq!(plan.icloud_deletions, 1);
    assert!(back.is_err());
    assert_eq!(device.sync.mode(), ServiceMode::TeamsOnly);
    assert!(live(&server, 2).is_none());
}

// The values forbid iCloud between the move back's CloudKit deletion and its commit: the move commits nothing more,
// and personal data keeps resting on TablePro Sync with the move still open.
#[tokio::test]
async fn a_move_back_revoked_between_its_steps_commits_nothing_more() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    mac.put(1, carried(1, "Prod", 1));
    mac.icloud_pass().await;
    mac.mover(true).move_to_service().await.unwrap();
    let web = on_the_service(&server).await;
    web.connections.remove(&id(1));
    web.sync().await;
    mac.device.sync().await;
    let plan = mac.mover(false).plan_move_to_icloud().await.unwrap();

    // The first three checks pass (the move's start, its open row and the deletion's request), the commit after does not.
    let back = mac.mover_revoked_after(3).move_to_icloud(plan.icloud_deletions).await;
    let row = mac.device.sync.move_row().await.unwrap();

    assert_eq!(back.unwrap_err().code(), "sync.not_allowed");
    assert_eq!(
        row.map(|row| (row.target, row.phase)),
        Some((tablepro_sync::api::state::Provider::ICloud, MovePhase::Open))
    );
    assert_eq!(mac.device.sync.mode(), ServiceMode::TeamsOnly);
}

// The values forbid iCloud right after the move back starts: its open row is refused at its commit, so personal data
// stays on TablePro Sync with no move back recorded (Codex round 4).
#[tokio::test]
async fn a_move_back_revoked_before_its_open_row_commits_records_no_move() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    mac.put(1, carried(1, "Prod", 1));
    mac.icloud_pass().await;
    mac.mover(true).move_to_service().await.unwrap();
    let plan = mac.mover(false).plan_move_to_icloud().await.unwrap();

    let back = mac.mover_revoked_after(1).move_to_icloud(plan.icloud_deletions).await;
    let row = mac.device.sync.move_row().await.unwrap();

    assert_eq!(back.unwrap_err().code(), "sync.not_allowed");
    assert_ne!(
        row.map(|row| row.target),
        Some(tablepro_sync::api::state::Provider::ICloud)
    );
    assert_eq!(mac.device.sync.mode(), ServiceMode::Personal);
}

// A policy change holds the move's commits: one waiting on it reads the values it left, so a revocation applied
// meanwhile refuses that commit, and nothing of the move back is recorded (orchestrator ruling on 0055).
#[tokio::test]
async fn a_move_commit_waits_for_a_policy_change_and_reads_what_it_left() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    mac.put(1, carried(1, "Prod", 1));
    mac.icloud_pass().await;
    mac.mover(true).move_to_service().await.unwrap();
    let plan = mac.mover(false).plan_move_to_icloud().await.unwrap();
    let gate = Arc::new(tokio::sync::RwLock::new(()));
    let allows = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let mover = mac.mover_gated(&gate, &allows, &calls);

    let changing = gate.write().await;
    let back = tokio::spawn(async move { mover.move_to_icloud(plan.icloud_deletions).await });
    for _ in 0..500 {
        if calls.load(std::sync::atomic::Ordering::SeqCst) > 0 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let checked_while_changing = calls.load(std::sync::atomic::Ordering::SeqCst);
    allows.store(false, std::sync::atomic::Ordering::SeqCst);
    drop(changing);
    let back = back.await.unwrap();
    let row = mac.device.sync.move_row().await.unwrap();

    // The move's start passed; its first commit waited out the change, then read the revocation.
    assert_eq!(checked_while_changing, 1);
    assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 2);
    assert_eq!(back.unwrap_err().code(), "sync.not_allowed");
    assert_ne!(
        row.map(|row| row.target),
        Some(tablepro_sync::api::state::Provider::ICloud)
    );
    assert_eq!(mac.device.sync.mode(), ServiceMode::Personal);
}

// Only what the person confirmed leaves the zone: a record the device no longer holds for any other reason, as one
// deleted here while a policy kept the service from taking the deletion, stays on iCloud and comes back.
#[tokio::test]
async fn the_move_back_deletes_on_icloud_nothing_the_person_did_not_confirm() {
    let server = FakeServer::new();
    let cloud = Arc::new(FakeCloudKit::signed_in(USER));
    let mac = Apple::on_icloud(&server, &cloud, "dev_mac").await;
    mac.put(1, carried(1, "Prod", 1));
    mac.icloud_pass().await;
    mac.mover(true).move_to_service().await.unwrap();
    server.set_policies(Policies {
        personal_sync: false,
        ..Policies::default()
    });
    mac.device.sync().await;
    mac.device.connections.remove(&id(1));
    mac.device.sync().await;

    let plan = mac.mover(false).plan_move_to_icloud().await.unwrap();
    mac.mover(false).move_to_icloud(0).await.unwrap();
    let resumed = Apple::engine(&mac.device, &cloud, &mac.files, Some(USER));
    resumed.run_pass(PassReason::Launch).await.unwrap();

    assert_eq!(plan.icloud_deletions, 0);
    assert!(in_zone(&cloud, 1));
    assert_eq!(mac.get(1), Some(carried(1, "Prod", 1)));
}
