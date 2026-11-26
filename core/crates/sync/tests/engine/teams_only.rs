// A device whose personal provider is iCloud or Off still runs the service for Team Library: the team scopes, and the
// key objects of the personal scope that team secrets rest on (0054, Providers). Nothing personal is taken or sent.

use std::sync::Arc;

use serde_json::{Value, json};
use tablepro_keys::encoding::TeamId;
use tablepro_records::Kind;
use tablepro_sync::api::adapter::RecordAdapter;
use tablepro_sync::api::control::SyncControl;
use tablepro_sync::api::ids::{KindName, RecordKey, ScopeName};
use tablepro_sync::api::key_flows::ArrivalOrder;
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::state::{Row, RowKey, RowRange, Table};
use tablepro_sync::api::transport::ChangeOutcome;
use tablepro_sync::service::ServiceMode;
use tablepro_sync_testing::FakeServer;
use uuid::Uuid;

use super::harness::{
    ACCOUNT, Device, DeviceBuilder, KeyEvent, KeyLog, MemoryAdapter, StoreFile, account, connection, id, personal,
    write,
};

fn team() -> TeamId {
    TeamId(Uuid::from_u128(0x0191_0000_0000_7000_8000_0000_0000_00C6))
}

fn personal_version() -> String {
    format!("{ACCOUNT}/personal/1")
}

fn personal_envelope(n: u8) -> String {
    format!("connection/{}/password", id(n))
}

fn team_envelope(n: u8) -> String {
    format!("library_connection/{}/password", id(n).to_lowercase())
}

fn sealed(kv: u32) -> Value {
    json!({"suite": "tp1", "kv": kv, "nonce": "n", "ct": "c"})
}

fn query(name: &str) -> Value {
    json!({"name": name, "query": "select 1", "sort_order": 1})
}

fn stored(server: &FakeServer, kind: &str, record: &str) -> Option<Value> {
    server.stored(personal(), kind, record).and_then(|record| record.fields)
}

fn applied(outcomes: &[ChangeOutcome]) {
    assert!(
        outcomes
            .iter()
            .all(|outcome| matches!(outcome, ChangeOutcome::Applied { .. })),
        "{outcomes:?}"
    );
}

// Another device of the account on TablePro Sync: a connection, the personal key version and an envelope under it,
// and in the team, a query, the team key version and an envelope under that.
async fn writer(server: &Arc<FakeServer>) -> (Device, Arc<MemoryAdapter>) {
    server.add_team(team(), &[(account(), Role::Owner)]);
    let queries = MemoryAdapter::new(Kind::LibraryQuery, "team_library", StoreFile::new());
    let mac = DeviceBuilder::new(server, "dev_mac")
        .adapter(ScopeName::Team(team()), Arc::clone(&queries))
        .build()
        .await;
    mac.connections.put(&id(1), connection("Prod"));
    queries.put("q1", query("Report"));
    mac.sync().await;
    applied(
        &mac.push_raw(
            ScopeName::Personal,
            vec![write("key.version", &personal_version(), None, json!({"suite": "tp1"}))],
        )
        .await,
    );
    applied(
        &mac.push_raw(
            ScopeName::Personal,
            vec![write("secret_envelope", &personal_envelope(2), None, sealed(1))],
        )
        .await,
    );
    // A kind a newer build syncs, which this build holds by id when personal data is its own.
    applied(
        &mac.push_raw(
            ScopeName::Personal,
            vec![write("newer_kind", "n1", None, json!({"name": "Later"}))],
        )
        .await,
    );
    let team_version = format!("{}/team/1", tablepro_keys::encoding::uuid_to_wire(team().0));
    applied(
        &mac.push_raw(
            ScopeName::Team(team()),
            vec![write(
                "key.version",
                &team_version,
                None,
                json!({"suite": "tp1", "signer": account().to_wire()}),
            )],
        )
        .await,
    );
    applied(
        &mac.push_raw(
            ScopeName::Team(team()),
            vec![write("secret_envelope", &team_envelope(5), None, sealed(1))],
        )
        .await,
    );
    (mac, queries)
}

struct TeamsOnly {
    device: Device,
    keys: Arc<KeyLog>,
    secrets: Arc<MemoryAdapter>,
    queries: Arc<MemoryAdapter>,
}

// Personal envelopes are the secrets store's own scope; the team's envelopes go to the same store under the team.
async fn teams_only(server: &Arc<FakeServer>) -> TeamsOnly {
    let keys = Arc::new(KeyLog::default());
    let secrets = MemoryAdapter::new(Kind::SecretEnvelope, "secrets", StoreFile::new());
    let queries = MemoryAdapter::new(Kind::LibraryQuery, "team_library", StoreFile::new());
    let device = DeviceBuilder::new(server, "dev_mini")
        .teams_only()
        .keys(Arc::clone(&keys))
        .adapter(ScopeName::Personal, Arc::clone(&secrets))
        .adapter(ScopeName::Team(team()), Arc::clone(&queries))
        .build()
        .await;
    TeamsOnly {
        device,
        keys,
        secrets,
        queries,
    }
}

async fn team_secrets(secrets: &MemoryAdapter) -> Vec<String> {
    secrets
        .records(ScopeName::Team(team()))
        .await
        .unwrap()
        .records
        .into_iter()
        .map(|record| record.record_id)
        .collect()
}

#[tokio::test]
async fn teams_only_takes_the_team_and_the_personal_key_objects_and_nothing_else_personal() {
    let server = FakeServer::new();
    writer(&server).await;
    let mini = teams_only(&server).await;
    mini.device.connections.put(&id(3), connection("Local"));
    mini.secrets.put(&personal_envelope(4), sealed(1));

    mini.device.sync().await;
    mini.device.sync().await;

    assert_eq!(mini.queries.get("q1"), Some(query("Report")));
    assert_eq!(team_secrets(&mini.secrets).await, [team_envelope(5)]);
    assert!(mini.keys.events().contains(&KeyEvent::Arrived {
        scope: ScopeName::Personal,
        order: ArrivalOrder::Snapshot,
        ids: vec![personal_version()],
    }));
    assert_eq!(mini.device.connections.get(&id(1)), None);
    assert_eq!(mini.secrets.get(&personal_envelope(2)), None);
    assert_eq!(stored(&server, "connection", &id(3)), None);
    assert_eq!(stored(&server, "secret_envelope", &personal_envelope(4)), None);
    assert_eq!((mini.device.connections.applies(), mini.secrets.applies()), (0, 0));
    let mut personal_rows = Vec::new();
    for table in [Table::Bases, Table::Held, Table::Approvals] {
        personal_rows.extend(mini.device.rows(RowRange::Scope(table, ScopeName::Personal)).await);
    }
    assert!(
        personal_rows.iter().all(|row| match row {
            Row::Base(base) => base.key.kind.is_key(),
            _ => false,
        }),
        "{personal_rows:?}"
    );
}

#[tokio::test]
async fn teams_only_never_reaches_the_history_scope() {
    let server = FakeServer::new();
    writer(&server).await;
    let everything = Device::new(&server, "dev_other").await;
    let mini = teams_only(&server).await;

    everything.sync().await;
    mini.device.sync().await;

    assert!(everything.row(RowKey::Scope(ScopeName::History)).await.is_some());
    assert!(mini.device.row(RowKey::Scope(ScopeName::History)).await.is_none());
    assert!(!mini.device.sync.load_older_history().await.unwrap());
}

#[tokio::test]
async fn turning_personal_sync_on_reads_the_personal_scope_again_and_sends_what_the_device_holds() {
    let server = FakeServer::new();
    writer(&server).await;
    let mini = teams_only(&server).await;
    mini.device.connections.put(&id(3), connection("Local"));
    mini.device.sync().await;

    mini.device.sync.set_mode(ServiceMode::Personal).await;
    mini.device.sync().await;

    assert_eq!(mini.device.sync.mode(), ServiceMode::Personal);
    assert_eq!(mini.device.connections.get(&id(1)), Some(connection("Prod")));
    assert_eq!(mini.secrets.get(&personal_envelope(2)), Some(sealed(1)));
    assert_eq!(stored(&server, "connection", &id(3)), Some(connection("Local")));
}

// The copies last agreed stay while personal data rests, so both sides' edits meanwhile merge when it syncs again.
#[tokio::test]
async fn a_spell_of_teams_only_keeps_the_agreed_copies_so_both_sides_edits_merge_afterwards() {
    let server = FakeServer::new();
    let (mac, _) = writer(&server).await;
    let mini = DeviceBuilder::new(&server, "dev_mini").build().await;
    mini.sync().await;
    mini.sync.set_mode(ServiceMode::TeamsOnly).await;

    mac.connections.put(
        &id(1),
        json!({"name": "Prod 2", "icon_name": "database", "sort_order": 1}),
    );
    mac.sync().await;
    mini.connections
        .put(&id(1), json!({"name": "Prod", "icon_name": "server", "sort_order": 1}));
    mini.sync().await;
    let resting = (mini.connections.get(&id(1)), stored(&server, "connection", &id(1)));
    mini.sync.set_mode(ServiceMode::Personal).await;
    mini.sync().await;

    assert_eq!(
        resting,
        (
            Some(json!({"name": "Prod", "icon_name": "server", "sort_order": 1})),
            Some(json!({"name": "Prod 2", "icon_name": "database", "sort_order": 1}))
        )
    );
    let merged = json!({"name": "Prod 2", "icon_name": "server", "sort_order": 1});
    assert_eq!(mini.connections.get(&id(1)), Some(merged.clone()));
    assert_eq!(stored(&server, "connection", &id(1)), Some(merged));
}

// A value pulled while TablePro Sync held personal data waits for that provider: while personal data rests, the person
// is not asked about it and cannot apply it.
#[tokio::test]
async fn a_personal_approval_rests_unlisted_and_undecided_while_teams_only() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    let mini = Device::new(&server, "dev_mini").await;
    mac.connections
        .put(&id(1), json!({"name": "Prod", "host": "db.example.com"}));
    mac.sync().await;
    mini.sync().await;
    let waiting = mini.sync.approvals().await.unwrap();
    let key = RecordKey::new(ScopeName::Personal, Kind::Connection, id(1));

    mini.sync.set_mode(ServiceMode::TeamsOnly).await;
    let resting = mini.sync.approvals().await.unwrap();
    let seen = waiting.first().map_or([0; 32], |approval| approval.digest);
    let decided = mini
        .sync
        .decide_approval(key.clone(), "/host".to_owned(), seen, true)
        .await;
    let held = mini.sync.held_records().await.unwrap();
    mini.sync().await;
    let status = mini.sync.status();
    mini.sync.set_mode(ServiceMode::Personal).await;

    assert!(!waiting.is_empty());
    assert!(resting.is_empty(), "{resting:?}");
    assert_eq!(decided.unwrap_err().code(), "sync.not_allowed");
    assert!(held.is_empty(), "{held:?}");
    assert_eq!((status.waiting_approvals, status.held), (0, 0));
    assert_eq!(mini.sync.approvals().await.unwrap(), waiting);
    assert_eq!(mini.connections.get(&id(1)), None);
    assert!(
        mini.rows(RowRange::ScopeKind(
            Table::Held,
            ScopeName::Personal,
            KindName::of(Kind::Connection)
        ))
        .await
        .iter()
        .any(|row| matches!(row, Row::Held(held) if held.key == key))
    );
}

// Personal sync stops at once: the pass in flight writes nothing personal more and sends nothing more, and an answer
// the server gave before the switch is dropped (0055, Leaving a provider).
#[tokio::test]
async fn a_switch_to_teams_only_ends_the_pass_in_flight_before_it_writes_what_it_pulled() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.connections.put(&id(1), connection("Prod"));
    mac.sync().await;
    let mini = Device::new(&server, "dev_mini").await;
    mini.connections.put(&id(3), connection("Local"));
    let (reached, release) = mini.wire.hold_next_pull(ScopeName::Personal);

    let switch = async {
        reached.notified().await;
        let let_go = async {
            tokio::task::yield_now().await;
            release.notify_one();
        };
        tokio::join!(mini.sync.set_mode(ServiceMode::TeamsOnly), let_go);
    };
    let (ended, ()) = tokio::join!(mini.pass(), switch);
    let status = mini.sync.status();
    mini.sync().await;

    assert_eq!(ended.unwrap_err().code(), "sync.cancelled");
    assert_eq!(status.problem, None);
    assert_eq!(status.queued_changes, 0);
    assert_eq!(mini.sync.mode(), ServiceMode::TeamsOnly);
    assert_eq!(mini.connections.get(&id(1)), None);
    assert_eq!(stored(&server, "connection", &id(3)), None);
}

// The count of what waits to go up leaves out personal data once it rests, even before another pass runs.
#[tokio::test]
async fn the_queued_count_leaves_out_the_personal_scope_once_it_rests() {
    let server = FakeServer::new();
    server.add_team(team(), &[(account(), Role::Owner)]);
    let queries = MemoryAdapter::new(Kind::LibraryQuery, "team_library", StoreFile::new());
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .adapter(ScopeName::Team(team()), Arc::clone(&queries))
        .build()
        .await;
    mini.sync().await;
    mini.connections.put(&id(3), connection("Local"));
    queries.put("q1", query("Report"));
    mini.sync().await;
    let both = mini.sync.status().queued_changes;

    mini.sync.set_mode(ServiceMode::TeamsOnly).await;

    assert_eq!(both, 2);
    assert_eq!(mini.sync.status().queued_changes, 1);
}

// A switch to teams-only that waits behind a switch to personal still holds back every pass queued before it, so no
// pass runs with personal data while the person's last word was to stop it.
#[tokio::test]
async fn a_pass_queued_between_a_switch_on_and_a_later_switch_off_carries_nothing_personal() {
    let server = FakeServer::new();
    let mac = Device::new(&server, "dev_mac").await;
    mac.connections.put(&id(1), connection("Prod"));
    mac.sync().await;
    let mini = DeviceBuilder::new(&server, "dev_mini").teams_only().build().await;
    let (reached, release) = mini.wire.hold_next_pull(ScopeName::Personal);

    let queued = async {
        reached.notified().await;
        let let_go = async {
            tokio::task::yield_now().await;
            release.notify_one();
        };
        tokio::join!(
            mini.sync.set_mode(ServiceMode::Personal),
            mini.pass(),
            mini.sync.set_mode(ServiceMode::TeamsOnly),
            let_go,
        )
    };
    let (first, ((), between, (), ())) = tokio::join!(mini.pass(), queued);

    assert_eq!(first.unwrap_err().code(), "sync.cancelled");
    assert_eq!(between.unwrap_err().code(), "sync.cancelled");
    assert_eq!(mini.sync.mode(), ServiceMode::TeamsOnly);
    assert_eq!(mini.connections.get(&id(1)), None);
}
