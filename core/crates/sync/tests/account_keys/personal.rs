use secrecy::{ExposeSecret, SecretString};
use serde_json::json;
use tablepro_keys::encoding::{HistoryId, KeyPurpose, Origin, Scope, Version, random_uuid, uuid_to_wire};
use tablepro_keys::envelope::{EnvelopeId, ParentKind, SecretKind, check_destination, seal_envelope};
use tablepro_keys::json;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::key_flows::AccountFlows;
use tablepro_sync::api::state::{KeyVersionState, Row, RowKey};
use tablepro_sync_testing::FakeServer;

use crate::harness::{Device, new_account, typed_back};

fn connection() -> EnvelopeId {
    EnvelopeId::new(
        ParentKind::Connection,
        &uuid_to_wire(random_uuid().unwrap()),
        SecretKind::Password,
    )
    .unwrap()
}

fn av(value: u32) -> Version {
    Version::new(value).unwrap()
}

async fn approved() -> (std::sync::Arc<FakeServer>, Device, SecretString) {
    let server = FakeServer::new();
    let device = Device::new(&server, new_account(), "dev_b").await;
    let text = device.genesis().await;
    (server, device, text)
}

async fn rotate(device: &Device, text: &SecretString) -> SecretString {
    device.pull().await;
    let draft = device.service.begin_replace(text.clone()).await.unwrap();
    device
        .service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), Vec::new())
        .await
        .unwrap();
    device.pull().await;
    draft.recovery.text
}

#[tokio::test]
async fn an_envelope_seals_under_the_current_version_and_opens_with_its_destination() {
    let (_server, device, _) = approved().await;
    let id = connection();
    let dest = json!({"engine": "postgres", "host": "db.internal", "port": 5432});

    let fields = device
        .service
        .seal_personal_envelope(id.clone(), SecretString::from("s3cret"), dest.clone())
        .await
        .unwrap();

    assert_eq!(fields["suite"], "tp1");
    assert_eq!(fields["kv"], 1);
    let opened = device
        .service
        .open_personal_envelope(id.clone(), fields, Some(Version::FIRST))
        .await
        .unwrap();
    assert_eq!(opened.secret.expose_secret(), "s3cret");
    assert_eq!(opened.dest, dest);
    assert_eq!(opened.kv, Version::FIRST);
    let Some(Row::KeyEnvelope(row)) = device.get(RowKey::KeyEnvelope(ScopeName::Personal, id.to_wire())).await else {
        panic!("no envelope row");
    };
    assert_eq!(row.kv, Version::FIRST);
}

#[tokio::test]
async fn a_rewritten_destination_is_the_approval_case() {
    let (_server, device, _) = approved().await;
    let id = connection();
    let fields = device
        .service
        .seal_personal_envelope(id.clone(), SecretString::from("s3cret"), json!({"host": "db.internal"}))
        .await
        .unwrap();
    let opened = device.service.open_personal_envelope(id, fields, None).await.unwrap();

    let sealed = json::parse(opened.dest.to_string().as_bytes()).unwrap();
    let current = json::parse(br#"{"host":"attacker.example"}"#).unwrap();

    assert_eq!(
        check_destination(&sealed, &current).unwrap_err().code(),
        "keys.destination"
    );
    check_destination(&sealed, &json::parse(br#"{"host":"db.internal"}"#).unwrap()).unwrap();
}

#[tokio::test]
async fn an_envelope_is_bound_to_its_record_and_origin_and_suite() {
    let (_server, device, _) = approved().await;
    let id = connection();
    let fields = device
        .service
        .seal_personal_envelope(id.clone(), SecretString::from("s3cret"), json!({}))
        .await
        .unwrap();

    let moved = device
        .service
        .open_personal_envelope(connection(), fields.clone(), None)
        .await
        .unwrap_err();
    assert_eq!(moved.code(), "keys.open");
    let other_kind = EnvelopeId::new(id.parent_kind, &id.parent_id, SecretKind::SshPassword).unwrap();
    let rekinded = device
        .service
        .open_personal_envelope(other_kind, fields.clone(), None)
        .await
        .unwrap_err();
    assert_eq!(rekinded.code(), "keys.open");
    let mut downgraded = fields.clone();
    downgraded["suite"] = json!("tp0");
    let suite = device
        .service
        .open_personal_envelope(id.clone(), downgraded, None)
        .await
        .unwrap_err();
    assert_eq!(suite.code(), "keys.suite");

    let mut txn = device.txn().await;
    let key = device
        .service
        .personal_key(txn.as_mut(), KeyPurpose::Personal, Version::FIRST)
        .await
        .unwrap();
    drop(txn);
    let elsewhere = Origin::parse("https://other.example.com").unwrap();
    let sealed = seal_envelope(
        &key,
        &elsewhere,
        Scope::Personal(device.account),
        &id,
        Version::FIRST,
        "s3cret",
        &json::parse(b"{}").unwrap(),
    )
    .unwrap();
    let replayed: serde_json::Value = serde_json::from_str(&tablepro_keys::body::sealed_json(&sealed)).unwrap();
    let foreign = device
        .service
        .open_personal_envelope(id, replayed, None)
        .await
        .unwrap_err();
    assert_eq!(foreign.code(), "keys.open");
}

#[tokio::test]
async fn an_envelope_counts_only_under_the_version_in_force_at_its_place_and_never_below_the_copy_held() {
    let (_server, device, text) = approved().await;
    let id = connection();
    let first = device
        .service
        .seal_personal_envelope(id.clone(), SecretString::from("one"), json!({}))
        .await
        .unwrap();
    rotate(&device, &text).await;
    let second = device
        .service
        .seal_personal_envelope(id.clone(), SecretString::from("two"), json!({}))
        .await
        .unwrap();
    assert_eq!(second["kv"], 2);

    let after_rotation = device
        .service
        .open_personal_envelope(id.clone(), first.clone(), Some(av(2)))
        .await
        .unwrap_err();
    assert_eq!(after_rotation.code(), "keys.stale");
    let ahead = device
        .service
        .open_personal_envelope(id.clone(), second.clone(), Some(Version::FIRST))
        .await
        .unwrap_err();
    assert_eq!(ahead.code(), "keys.step");
    device
        .service
        .open_personal_envelope(id.clone(), second, Some(av(2)))
        .await
        .unwrap();
    // Below the copy held, even in a snapshot.
    let below = device
        .service
        .open_personal_envelope(id, first, None)
        .await
        .unwrap_err();
    assert_eq!(below.code(), "keys.stale");
}

#[tokio::test]
async fn an_envelope_written_before_the_rotation_that_follows_it_is_taken_at_its_place() {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let c = Device::new(&server, account, "dev_c").await;
    let text = b.genesis().await;
    c.approved_by(&b).await;
    let id = connection();
    let before = b
        .service
        .seal_personal_envelope(id.clone(), SecretString::from("before"), json!({}))
        .await
        .unwrap();
    let c_device = c.service.device_keys().await.unwrap().current.unwrap().key_device;
    b.pull().await;
    let draft = b.service.begin_replace(text).await.unwrap();
    b.service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), vec![c_device])
        .await
        .unwrap();
    c.pull().await;

    // In the order, version 1 was in force where the write sits; slipped in after the rotation it is refused.
    let slipped = c
        .service
        .open_personal_envelope(id.clone(), before.clone(), Some(av(2)))
        .await
        .unwrap_err();
    let taken = c
        .service
        .open_personal_envelope(id, before, Some(Version::FIRST))
        .await
        .unwrap();

    assert_eq!(slipped.code(), "keys.stale");
    assert_eq!(taken.secret.expose_secret(), "before");
}

#[tokio::test]
async fn history_entries_seal_under_the_newest_key_and_open_under_any_held_version() {
    let (_server, device, text) = approved().await;
    let entry = HistoryId(random_uuid().unwrap());
    let plaintext = json!({"query": "select 1", "connection_id": uuid_to_wire(random_uuid().unwrap())});
    let first = device
        .service
        .seal_history_entry(entry, plaintext.clone())
        .await
        .unwrap();
    assert_eq!(first["kv"], 1);
    rotate(&device, &text).await;

    let again = device
        .service
        .seal_history_entry(entry, plaintext.clone())
        .await
        .unwrap();

    assert_eq!(again["kv"], 2);
    assert_eq!(
        device.service.open_history_entry(entry, again).await.unwrap(),
        plaintext
    );
    assert_eq!(
        device.service.open_history_entry(entry, first.clone()).await.unwrap(),
        plaintext
    );
    let moved = device
        .service
        .open_history_entry(HistoryId(random_uuid().unwrap()), first)
        .await
        .unwrap_err();
    assert_eq!(moved.code(), "keys.open");
}

#[tokio::test]
async fn nothing_is_written_under_a_stopped_key_or_without_keys() {
    let (_server, device, _) = approved().await;
    let Some(Row::KeyVersion(row)) = device
        .get(RowKey::KeyVersion(ScopeName::Personal, KeyPurpose::History))
        .await
    else {
        panic!()
    };
    device
        .put(vec![Row::KeyVersion(tablepro_sync::api::state::KeyVersionRow {
            state: KeyVersionState::Stopped,
            stopped_cause: Some(tablepro_sync::api::state::StoppedCause::CatchUp),
            ..row
        })])
        .await;

    let stopped = device
        .service
        .seal_history_entry(HistoryId(random_uuid().unwrap()), json!({}))
        .await
        .unwrap_err();

    assert_eq!(stopped.code(), "sync.locked");
    let keyless = Device::new(&device.server, device.account, "dev_x").await;
    keyless.pull().await;
    let refused = keyless
        .service
        .seal_personal_envelope(connection(), SecretString::from("x"), json!({}))
        .await
        .unwrap_err();
    assert_eq!(refused.code(), "sync.not_allowed");
    let refused = keyless
        .service
        .open_history_entry(
            HistoryId(random_uuid().unwrap()),
            json!({"suite": "tp1", "kv": 1, "nonce": "AAAAAAAAAAAAAAAA", "ct": "AAAA"}),
        )
        .await
        .unwrap_err();
    assert_eq!(refused.code(), "keys.encoding");
}

#[tokio::test]
async fn a_stale_or_unanchored_file_handles_no_secret_until_its_rebuild_or_an_approval() {
    let (server, device, _) = approved().await;
    let id = connection();
    let fields = device
        .service
        .seal_personal_envelope(id.clone(), SecretString::from("s3cret"), json!({}))
        .await
        .unwrap();
    let stale = Device::opened(
        &server,
        device.account,
        "dev_b",
        device.store.clone(),
        tablepro_sync::api::state::Opened {
            sync_tables: tablepro_sync::api::state::SyncTrust::Refill,
            key_tables: tablepro_sync::api::state::KeyTrust::Rebuild {
                checkpoint: Box::default(),
            },
        },
    )
    .await;
    stale.pull().await;

    let refused = stale
        .service
        .open_personal_envelope(id.clone(), fields.clone(), None)
        .await
        .unwrap_err();
    assert_eq!(refused.code(), "sync.not_allowed");
    let written = stale
        .service
        .seal_personal_envelope(connection(), SecretString::from("x"), json!({}))
        .await
        .unwrap_err();
    assert_eq!(written.code(), "sync.not_allowed");

    let unanchored = Device::opened(
        &server,
        device.account,
        "dev_b",
        device.store.clone(),
        tablepro_sync::api::state::Opened {
            sync_tables: tablepro_sync::api::state::SyncTrust::Refill,
            key_tables: tablepro_sync::api::state::KeyTrust::Unanchored,
        },
    )
    .await;
    unanchored.pull().await;
    let locked = unanchored
        .service
        .open_personal_envelope(id, fields, None)
        .await
        .unwrap_err();
    assert_eq!(locked.code(), "sync.locked");
    assert_eq!(
        unanchored.key_state().await,
        tablepro_sync::api::key_flows::KeyState::NeedsApproval { request: None }
    );
}

#[tokio::test]
async fn an_envelope_counts_under_the_version_in_force_at_its_place_in_a_real_pull() {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let c = Device::new(&server, account, "dev_c").await;
    let text = b.genesis().await;
    c.approved_by(&b).await;
    let id = connection();
    let written = b
        .service
        .seal_personal_envelope(id.clone(), SecretString::from("written at v1"), json!({}))
        .await
        .unwrap();
    let change = tablepro_sync::api::transport::Change {
        kind: tablepro_sync::api::ids::KindName::parse("secret_envelope").unwrap(),
        record_id: id.to_wire(),
        base: None,
        op: tablepro_sync::api::transport::ChangeOp::Write {
            fields: written.clone(),
            patch: written.clone(),
        },
    };
    b.service
        .push_change_set(ScopeName::Personal, vec![change.clone()], b.proof().await)
        .await
        .unwrap();
    let c_device = c.service.device_keys().await.unwrap().current.unwrap().key_device;
    b.pull().await;
    let draft = b.service.begin_replace(text).await.unwrap();
    b.service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), vec![c_device])
        .await
        .unwrap();

    // Offline while B wrote under v1 and then rotated, C meets the write before the rotation and takes it.
    let opened = c.pull_with_envelopes().await;

    assert_eq!(opened, [(id.to_wire(), Ok("written at v1".to_owned()))]);
    // The honest server takes no write under v1 once v2 is current.
    let late = b
        .service
        .push_change_set(
            ScopeName::Personal,
            vec![tablepro_sync::api::transport::Change {
                record_id: connection().to_wire(),
                ..change
            }],
            b.proof().await,
        )
        .await
        .unwrap();
    assert_eq!(
        late,
        [tablepro_sync::api::transport::ChangeOutcome::Rejected {
            code: tablepro_sync::api::transport::RejectedCode::KeyVersionStale
        }]
    );
    // Slipped in after the rotation by a server that lies, the same write is refused there.
    let mut rotation: Vec<_> = b
        .served()
        .await
        .into_iter()
        .filter(|record| record.kind.is_key())
        .collect();
    rotation.push(crate::harness::record(
        "secret_envelope",
        &id.to_wire(),
        &written.to_string(),
    ));
    let (_, slipped) = c
        .feed_with_envelopes(
            rotation,
            tablepro_sync::api::key_flows::ArrivalOrder::InOrder,
            Some(Version::FIRST),
        )
        .await;
    assert_eq!(slipped, [(id.to_wire(), Err("keys.stale"))]);
}
