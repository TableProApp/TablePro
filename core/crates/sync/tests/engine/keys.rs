use std::sync::Arc;

use serde_json::{Value, json};
use tablepro_keys::encoding::{TeamId, Version};
use tablepro_records::Kind;
use tablepro_sync::api::ids::{KindName, ScopeName};
use tablepro_sync::api::key_flows::{ArrivalOrder, KeyChangeSet, PushBackVerdict};
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::state::{Row, RowKey};
use tablepro_sync::api::transport::{ChangeOutcome, DpopKey};
use tablepro_sync_testing::FakeServer;
use uuid::Uuid;

use super::harness::{
    ACCOUNT, Device, DeviceBuilder, KeyEvent, KeyLog, MemoryAdapter, StoreFile, account, connection, id, write,
};

fn version_id(version: u32) -> String {
    format!("{ACCOUNT}/personal/{version}")
}

fn envelope_id(n: u8) -> String {
    format!("connection/{}/password", id(n))
}

fn sealed(kv: u32) -> Value {
    json!({"suite": "tp1", "kv": kv, "nonce": "n", "ct": "c"})
}

async fn rotate(writer: &Device, version: u32) {
    let outcomes = writer
        .push_raw(
            ScopeName::Personal,
            vec![write(
                "key.version",
                &version_id(version),
                None,
                json!({"suite": "tp1"}),
            )],
        )
        .await;
    assert!(matches!(outcomes[0], ChangeOutcome::Applied { .. }), "{outcomes:?}");
}

async fn seal(writer: &Device, n: u8, kv: u32) {
    let outcomes = writer
        .push_raw(
            ScopeName::Personal,
            vec![write("secret_envelope", &envelope_id(n), None, sealed(kv))],
        )
        .await;
    assert!(matches!(outcomes[0], ChangeOutcome::Applied { .. }), "{outcomes:?}");
}

async fn key_version(device: &Device, scope: ScopeName) -> Option<Version> {
    match device.row(RowKey::Scope(scope)).await {
        Some(Row::Scope(row)) => row.key_version,
        _ => None,
    }
}

fn envelopes() -> Arc<MemoryAdapter> {
    MemoryAdapter::new(Kind::SecretEnvelope, "secrets", StoreFile::new())
}

fn arrived(order: ArrivalOrder, ids: &[String]) -> KeyEvent {
    KeyEvent::Arrived {
        scope: ScopeName::Personal,
        order,
        ids: ids.to_vec(),
    }
}

fn opened(n: u8, in_force: Option<u32>) -> KeyEvent {
    KeyEvent::Opened {
        id: envelope_id(n),
        in_force: in_force.map(|version| Version::new(version).unwrap()),
        taken: true,
    }
}

// The first pass creates the scope, the second reaches a cursor, so the next pulls are deltas.
async fn with_cursor(device: &Device) {
    device.connections.put(&id(20), connection("Seed"));
    device.sync().await;
    device.sync().await;
}

#[tokio::test]
async fn a_delta_page_applies_key_objects_in_order_and_each_envelope_under_the_version_at_its_place() {
    let server = FakeServer::new();
    let keys = Arc::new(KeyLog::default());
    let secrets = envelopes();
    let mac = DeviceBuilder::new(&server, "dev_mac")
        .keys(Arc::clone(&keys))
        .adapter(ScopeName::Personal, Arc::clone(&secrets))
        .build()
        .await;
    let other = Device::new(&server, "dev_other").await;
    with_cursor(&mac).await;

    rotate(&other, 1).await;
    seal(&other, 1, 1).await;
    rotate(&other, 2).await;
    seal(&other, 2, 2).await;
    mac.sync().await;

    assert_eq!(
        keys.events(),
        vec![
            arrived(ArrivalOrder::InOrder, &[version_id(1)]),
            opened(1, Some(1)),
            arrived(ArrivalOrder::InOrder, &[version_id(2)]),
            opened(2, Some(2)),
        ]
    );
    assert_eq!(key_version(&mac, ScopeName::Personal).await, Version::new(2).ok());
    assert_eq!(secrets.get(&envelope_id(1)), Some(sealed(1)));
    assert_eq!(secrets.get(&envelope_id(2)), Some(sealed(2)));
}

// A device pushed a rotation, then restarted before its next pull. An envelope another device wrote under the old
// version before that rotation is still taken: the version in force came from the cursor, not from the push.
#[tokio::test]
async fn after_a_pushed_rotation_and_a_restart_the_replay_uses_the_version_stored_with_the_cursor() {
    let server = FakeServer::new();
    let secrets = envelopes();
    let mac = DeviceBuilder::new(&server, "dev_mac")
        .adapter(ScopeName::Personal, Arc::clone(&secrets))
        .build()
        .await;
    let other = Device::new(&server, "dev_other").await;
    with_cursor(&mac).await;
    rotate(&other, 1).await;
    mac.sync().await;
    seal(&other, 1, 1).await;
    rotate(&mac, 2).await;
    let state = Arc::clone(&mac.state);
    let seed = Arc::clone(&mac.seed);
    let connections = (Arc::clone(&mac.connections), Arc::clone(&mac.connections_file));
    drop(mac);

    let keys = Arc::new(KeyLog::default());
    let restarted = DeviceBuilder::new(&server, "dev_mac")
        .state(state)
        .seed(seed)
        .connections(connections.0, connections.1)
        .keys(Arc::clone(&keys))
        .adapter(ScopeName::Personal, Arc::clone(&secrets))
        .build()
        .await;
    restarted.sync().await;

    assert_eq!(
        keys.events(),
        vec![opened(1, Some(1)), arrived(ArrivalOrder::InOrder, &[version_id(2)])]
    );
    assert_eq!(secrets.get(&envelope_id(1)), Some(sealed(1)));
    assert_eq!(key_version(&restarted, ScopeName::Personal).await, Version::new(2).ok());
}

#[tokio::test]
async fn a_snapshot_applies_its_key_objects_as_one_set_once_caught_up_and_its_envelopes_after() {
    let server = FakeServer::new();
    let other = Device::new(&server, "dev_other").await;
    rotate(&other, 1).await;
    seal(&other, 1, 1).await;
    rotate(&other, 2).await;
    seal(&other, 2, 2).await;
    let keys = Arc::new(KeyLog::default());
    let secrets = envelopes();
    let mini = DeviceBuilder::new(&server, "dev_mini")
        .keys(Arc::clone(&keys))
        .adapter(ScopeName::Personal, Arc::clone(&secrets))
        .build()
        .await;

    mini.sync().await;

    let events = keys.events();
    let KeyEvent::Arrived { order, ids, .. } = &events[0] else {
        panic!("the key objects did not go first: {events:?}");
    };
    assert_eq!(*order, ArrivalOrder::Snapshot);
    let mut ids = ids.clone();
    ids.sort();
    assert_eq!(ids, vec![version_id(1), version_id(2)]);
    assert_eq!(events.len(), 3);
    assert!(events[1..].contains(&opened(1, None)));
    assert!(events[1..].contains(&opened(2, None)));
    assert_eq!(key_version(&mini, ScopeName::Personal).await, Version::new(2).ok());
    assert_eq!(secrets.get(&envelope_id(2)), Some(sealed(2)));
}

#[tokio::test]
async fn a_team_roster_is_read_once_its_pull_is_caught_up() {
    let server = FakeServer::new();
    let team = TeamId(Uuid::new_v4());
    let member = tablepro_keys::encoding::AccountId(Uuid::new_v4());
    server.add_team(team, &[(account(), Role::Owner), (member, Role::Member)]);
    let keys = Arc::new(KeyLog::default());
    let mac = DeviceBuilder::new(&server, "dev_mac")
        .keys(Arc::clone(&keys))
        .build()
        .await;

    mac.sync().await;

    let rosters = keys.rosters();
    assert_eq!(rosters.len(), 1);
    let (read, roster) = &rosters[0];
    assert_eq!(*read, team);
    assert!(roster.caught_up);
    assert_eq!(roster.role, Some(Role::Owner));
    assert_eq!(roster.members.len(), 2);
    let Some(Row::Scope(row)) = mac.row(RowKey::Scope(ScopeName::Team(team))).await else {
        panic!("no team scope row");
    };
    assert!(row.caught_up);
}

#[tokio::test]
async fn a_new_epoch_pushes_key_objects_back_first_and_a_final_refusal_holds_the_scope_s_secrets() {
    let server = FakeServer::new();
    let keys = Arc::new(KeyLog::default());
    let secrets = envelopes();
    let mac = DeviceBuilder::new(&server, "dev_mac")
        .keys(Arc::clone(&keys))
        .adapter(ScopeName::Personal, Arc::clone(&secrets))
        .build()
        .await;
    let other = Device::new(&server, "dev_other").await;
    rotate(&other, 1).await;
    with_cursor(&mac).await;
    keys.queue_push_back(
        KeyChangeSet {
            scope: ScopeName::Personal,
            changes: vec![write("key.version", &version_id(2), None, json!({"suite": "tp1"}))],
            proof: DpopKey(Arc::clone(&mac.seed)),
        },
        PushBackVerdict::Ended {
            scope: ScopeName::Personal,
        },
    );
    let epoch = server.new_epoch();
    secrets.put(&envelope_id(3), sealed(1));
    mac.connections.put(&id(5), connection("After the restore"));
    let before = mac.wire.pushed().len();

    mac.sync().await;

    assert_eq!(keys.pushed_back_at(), vec![epoch]);
    let pushed = mac.wire.pushed().split_off(before);
    assert_eq!(pushed.first(), Some(&vec!["key.version".to_owned()]));
    assert!(
        pushed
            .iter()
            .all(|kinds| !kinds.contains(&"secret_envelope".to_owned()))
    );
    assert!(
        pushed
            .iter()
            .any(|kinds| kinds.contains(&KindName::of(Kind::Connection).as_str().to_owned()))
    );
    assert!(matches!(keys.answered().as_slice(), [outcomes] if matches!(outcomes[0], ChangeOutcome::Applied { .. })));
    assert!(mac.hooks.holds_secrets(ScopeName::Personal));
}
