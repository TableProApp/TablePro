use secrecy::{ExposeSecret, SecretString};
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::cert::CertKind;
use tablepro_keys::encoding::{KeyPurpose, Version};
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::trust::PinHow;
use tablepro_sync::api::device_store::DeviceItem;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::key_flows::{AccountFlows, GenesisOutcome, KeyState, TypedBack};
use tablepro_sync::api::state::{KeyVersionState, Row, RowKey, RowRange, Table};
use tablepro_sync::api::transport::{RejectedCode, TransportError};
use tablepro_sync_testing::FakeServer;
use tablepro_sync_testing::service::ScopeOwner;

use crate::harness::{Device, new_account, origin, typed_back};

fn stored_object(server: &FakeServer, owner: ScopeOwner, kind: &str, id: &str) -> KeyObject {
    let stored = server.stored(owner, kind, id).unwrap();
    let text = serde_json::to_string(stored.fields.as_ref().unwrap()).unwrap();
    KeyObject::parse(kind, id, text.as_bytes()).unwrap()
}

#[tokio::test]
async fn genesis_makes_the_keys_behind_the_recovery_key_and_approves_this_device() {
    let server = FakeServer::new();
    let account = new_account();
    let device = Device::new(&server, account, "dev_b").await;
    device.pull().await;
    assert_eq!(device.key_state().await, KeyState::NoKeys);

    let text = device.genesis().await;

    let owner = ScopeOwner::Personal(account);
    let id = format!("{}/1", account.to_wire());
    let KeyBody::Account(body) = stored_object(&server, owner, "key.account", &id).body else {
        panic!("not a certificate");
    };
    let certificate = body.certificate(account, Version::FIRST);
    certificate.verify(&origin()).unwrap();
    assert_eq!(certificate.kind, CertKind::GenesisOrRotation);
    let recovery = RecoveryKey::parse(text.expose_secret()).unwrap();
    assert_eq!(
        certificate.ik,
        recovery.identity_seed(&origin(), account).unwrap().public().unwrap()
    );
    let KeyBody::Recovery(blob) = stored_object(&server, owner, "key.recovery", &id).body else {
        panic!("not a blob");
    };
    let keys = recovery.open_blob(&origin(), account, Version::FIRST, &blob).unwrap();
    keys.check_against(&certificate.ask, &certificate.aek).unwrap();
    let key_device = device.service.device_keys().await.unwrap().current.unwrap().key_device;
    assert_eq!(
        device.key_state().await,
        KeyState::Approved {
            av: Version::FIRST,
            key_device
        }
    );
    let pin = device.pin(account).await.unwrap();
    assert_eq!(
        (pin.ik, pin.av, pin.how, pin.alert),
        (certificate.ik, Version::FIRST, PinHow::Compared, false)
    );
    for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
        let Some(Row::KeyVersion(row)) = device.get(RowKey::KeyVersion(ScopeName::Personal, purpose)).await else {
            panic!("no {purpose:?} version");
        };
        assert_eq!((row.version, row.state), (Version::FIRST, KeyVersionState::Ok));
        let record = stored_object(
            &server,
            owner,
            "key.version",
            &format!("{}/{}/1", account.to_wire(), purpose.name()),
        )
        .version_record()
        .unwrap();
        assert_eq!(record.start, tablepro_keys::scope_key::Start::Over);
        assert_eq!(row.record, record.digest(&origin()).unwrap());
    }
    let mut txn = device.txn().await;
    let objects = txn.scan(&RowRange::Table(Table::KeyObjects)).await.unwrap();
    assert_eq!(objects.len(), 7);
    assert!(
        objects
            .iter()
            .all(|row| matches!(row, Row::KeyObject(row) if row.applied))
    );
}

#[tokio::test]
async fn groups_typed_back_wrong_push_nothing_and_keep_the_draft() {
    let server = FakeServer::new();
    let account = new_account();
    let device = Device::new(&server, account, "dev_b").await;
    device.pull().await;
    let draft = device.service.begin_genesis().await.unwrap();
    let wrong = TypedBack {
        groups: [SecretString::from("0000"), SecretString::from("0000")],
    };

    let refused = device.service.finish_genesis(draft.draft, wrong).await.unwrap_err();

    assert_eq!(refused.code(), "sync.typed_back_wrong");
    assert_eq!(server.horizon(ScopeOwner::Personal(account)), 0);
    let outcome = device
        .service
        .finish_genesis(draft.draft, typed_back(&draft))
        .await
        .unwrap();
    assert_eq!(outcome, GenesisOutcome::Created);
    let again = device
        .service
        .finish_genesis(draft.draft, typed_back(&draft))
        .await
        .unwrap_err();
    assert_eq!(again.code(), "sync.unknown");
}

#[tokio::test]
async fn genesis_is_offered_only_while_the_account_has_no_keys() {
    let server = FakeServer::new();
    let account = new_account();
    let first = Device::new(&server, account, "dev_b").await;
    let unread = Device::new(&server, account, "dev_c").await;
    assert_eq!(unread.key_state().await, KeyState::Unknown);
    assert_eq!(
        unread.service.begin_genesis().await.unwrap_err().code(),
        "sync.not_allowed"
    );
    first.genesis().await;

    unread.pull().await;

    assert_eq!(unread.key_state().await, KeyState::NeedsApproval { request: None });
    assert_eq!(
        first.service.begin_genesis().await.unwrap_err().code(),
        "sync.not_allowed"
    );
    assert_eq!(
        unread.service.begin_genesis().await.unwrap_err().code(),
        "sync.not_allowed"
    );
}

#[tokio::test]
async fn the_second_genesis_loses_on_create_only_and_discards_its_keys() {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let c = Device::new(&server, account, "dev_c").await;
    b.pull().await;
    c.pull().await;
    let b_draft = b.service.begin_genesis().await.unwrap();
    let c_draft = c.service.begin_genesis().await.unwrap();
    b.service
        .finish_genesis(b_draft.draft, typed_back(&b_draft))
        .await
        .unwrap();

    let outcome = c
        .service
        .finish_genesis(c_draft.draft, typed_back(&c_draft))
        .await
        .unwrap();

    assert_eq!(outcome, GenesisOutcome::AnotherDeviceWon);
    assert!(!c.store.holds(&DeviceItem::AccountKeys {
        origin: origin(),
        account,
        av: Version::FIRST,
    }));
    let mut txn = c.txn().await;
    assert!(txn.scan(&RowRange::Table(Table::KeyObjects)).await.unwrap().is_empty());
    drop(txn);
    c.pull().await;
    assert_eq!(c.key_state().await, KeyState::NeedsApproval { request: None });
    let c_ik = RecoveryKey::parse(c_draft.text.expose_secret())
        .unwrap()
        .identity_seed(&origin(), account)
        .unwrap()
        .public()
        .unwrap();
    assert!(c.pin(account).await.is_none());
    let held = stored_object(
        &server,
        ScopeOwner::Personal(account),
        "key.account",
        &format!("{}/1", account.to_wire()),
    );
    let KeyBody::Account(body) = held.body else { panic!() };
    assert_ne!(body.ik, c_ik);
}

#[tokio::test]
async fn a_retry_after_a_lost_answer_sends_the_same_objects_and_is_applied() {
    let server = FakeServer::new();
    let account = new_account();
    let device = Device::new(&server, account, "dev_b").await;
    device.pull().await;
    let draft = device.service.begin_genesis().await.unwrap();
    server.fail_next(TransportError::Network {
        detail: "timeout".to_owned(),
    });

    let lost = device
        .service
        .finish_genesis(draft.draft, typed_back(&draft))
        .await
        .unwrap_err();

    assert_eq!(lost.code(), "sync.network");
    let mut txn = device.txn().await;
    let candidates: Vec<_> = txn
        .scan(&RowRange::Table(Table::KeyObjects))
        .await
        .unwrap()
        .into_iter()
        .filter_map(|row| match row {
            Row::KeyObject(row) => Some(row),
            _ => None,
        })
        .collect();
    drop(txn);
    assert_eq!(candidates.len(), 7);
    assert!(candidates.iter().all(|row| !row.applied));
    // The first push landed and only its answer was lost: the server holds these very objects.
    let changes = candidates
        .iter()
        .map(|row| {
            let object = KeyObject::parse(row.kind.as_str(), &row.record_id, row.fields.as_bytes()).unwrap();
            tablepro_sync::keys::create_change(&object).unwrap()
        })
        .collect();
    device
        .service
        .push_change_set(ScopeName::Personal, changes, device.proof().await)
        .await
        .unwrap();

    let outcome = device
        .service
        .finish_genesis(draft.draft, typed_back(&draft))
        .await
        .unwrap();

    assert_eq!(outcome, GenesisOutcome::Created);
    for row in candidates {
        let stored = server
            .stored(ScopeOwner::Personal(account), row.kind.as_str(), &row.record_id)
            .unwrap();
        let held: serde_json::Value = serde_json::from_str(&row.fields).unwrap();
        assert_eq!(stored.fields.unwrap(), held);
    }
}

#[tokio::test]
async fn a_genesis_the_server_refuses_whole_keeps_no_candidate_and_can_be_built_again() {
    let server = FakeServer::new();
    let account = new_account();
    let device = Device::new(&server, account, "dev_b").await;
    device.pull().await;
    let draft = device.service.begin_genesis().await.unwrap();
    device.transport.refuse_next_push(RejectedCode::BadStatement);

    let refused = device
        .service
        .finish_genesis(draft.draft, typed_back(&draft))
        .await
        .unwrap_err();

    assert_eq!(
        refused,
        tablepro_sync::SyncError::Rejected {
            code: RejectedCode::BadStatement
        }
    );
    let mut txn = device.txn().await;
    assert!(txn.scan(&RowRange::Table(Table::KeyObjects)).await.unwrap().is_empty());
    drop(txn);
    assert!(!device.store.holds(&DeviceItem::AccountKeys {
        origin: origin(),
        account,
        av: Version::FIRST,
    }));
    assert_eq!(device.key_state().await, KeyState::NoKeys);
    let outcome = device
        .service
        .finish_genesis(draft.draft, typed_back(&draft))
        .await
        .unwrap();
    assert_eq!(outcome, GenesisOutcome::Created);
}
