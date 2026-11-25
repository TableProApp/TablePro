use secrecy::{ExposeSecret, SecretString};
use serde_json::json;
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::cert::CertKind;
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose, Version, random_uuid};
use tablepro_keys::envelope::{EnvelopeId, ParentKind, SecretKind};
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::trust::PinHow;
use tablepro_sync::api::device_store::DeviceItem;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::key_flows::{AccountFlows, ArrivalOrder, KeyNoticeKind, KeyState, LockCause, TypedBack};
use tablepro_sync::api::state::{PendingFlow, Row, RowKey};
use tablepro_sync::api::transport::RejectedCode;
use tablepro_sync_testing::FakeServer;
use tablepro_sync_testing::key_flows::HookCall;
use tablepro_sync_testing::service::ScopeOwner;

use crate::harness::{Device, new_account, origin, record, typed_back};

fn envelope() -> EnvelopeId {
    EnvelopeId::new(
        ParentKind::Connection,
        &tablepro_keys::encoding::uuid_to_wire(random_uuid().unwrap()),
        SecretKind::Password,
    )
    .unwrap()
}

fn av(value: u32) -> Version {
    Version::new(value).unwrap()
}

async fn replace(device: &Device, text: &SecretString, keep: Vec<KeyDeviceId>) -> SecretString {
    device.pull().await;
    let draft = device.service.begin_replace(text.clone()).await.unwrap();
    device
        .service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), keep)
        .await
        .unwrap();
    draft.recovery.text
}

async fn key_device(device: &Device) -> KeyDeviceId {
    device.service.device_keys().await.unwrap().current.unwrap().key_device
}

#[tokio::test]
async fn replace_moves_to_a_new_identity_the_old_one_endorses_and_kept_devices_follow_with_a_notice() {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let c = Device::new(&server, account, "dev_c").await;
    let text = b.genesis().await;
    c.approved_by(&b).await;
    let old_ik = b.pin(account).await.unwrap().ik;
    let c_device = key_device(&c).await;

    b.pull().await;
    let draft = b.service.begin_replace(text.clone()).await.unwrap();
    assert!(
        draft
            .devices
            .iter()
            .any(|row| row.device.key_device == c_device && row.keep_by_default)
    );
    assert!(draft.devices.iter().any(|row| row.device.this_device));
    b.service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), vec![c_device])
        .await
        .unwrap();

    let id = format!("{}/2", account.to_wire());
    let stored = server
        .stored(ScopeOwner::Personal(account), "key.account", &id)
        .unwrap();
    let object = KeyObject::parse(
        "key.account",
        &id,
        serde_json::to_string(&stored.fields.unwrap()).unwrap().as_bytes(),
    )
    .unwrap();
    let KeyBody::Account(body) = object.body else { panic!() };
    let certificate = body.certificate(account, av(2));
    assert_eq!(certificate.kind, CertKind::Replace);
    let next = RecoveryKey::parse(draft.recovery.text.expose_secret()).unwrap();
    assert_eq!(
        certificate.ik,
        next.identity_seed(&origin(), account).unwrap().public().unwrap()
    );
    assert_eq!(
        certificate.ik_change(&origin(), &old_ik).unwrap(),
        tablepro_keys::cert::IkChange::Endorsed
    );
    let pin = b.pin(account).await.unwrap();
    assert_eq!(
        (pin.ik, pin.av, pin.replaced.clone()),
        (certificate.ik, av(2), vec![old_ik])
    );
    assert!(
        b.get(RowKey::KeyPending(PendingFlow::AccountRotation { av: av(2) }))
            .await
            .is_some()
    );

    c.pull().await;

    let pin = c.pin(account).await.unwrap();
    assert_eq!(
        (pin.ik, pin.av, pin.how, pin.replaced.clone(), pin.alert),
        (certificate.ik, av(2), PinHow::Replaced, vec![old_ik], false)
    );
    assert_eq!(
        c.key_state().await,
        KeyState::Approved {
            av: av(2),
            key_device: c_device
        }
    );
    assert!(
        c.service
            .notices()
            .await
            .unwrap()
            .iter()
            .any(|notice| notice.kind == KeyNoticeKind::RecoveryKeyReplaced { account })
    );
}

#[tokio::test]
async fn after_a_replace_old_envelopes_open_through_the_rings_and_only_the_new_recovery_key_opens_the_blob() {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let c = Device::new(&server, account, "dev_c").await;
    let text = b.genesis().await;
    c.approved_by(&b).await;
    let secret = envelope();
    let sealed = c
        .service
        .seal_personal_envelope(secret.clone(), SecretString::from("hunter2"), json!({"host": "db"}))
        .await
        .unwrap();
    let c_device = key_device(&c).await;

    let next = replace(&b, &text, vec![c_device]).await;
    c.pull().await;

    // The old envelope opens through the new version's ring; a new one goes under the version signed under av 2.
    for device in [&b, &c] {
        let opened = device
            .service
            .open_personal_envelope(secret.clone(), sealed.clone(), None)
            .await
            .unwrap();
        assert_eq!(opened.secret.expose_secret(), "hunter2");
        assert_eq!(opened.kv, Version::FIRST);
    }
    let resealed = b
        .service
        .seal_personal_envelope(envelope(), SecretString::from("next"), json!({}))
        .await
        .unwrap();
    assert_eq!(resealed["kv"], 2);
    // The old recovery key no longer opens anything at av 2; the new one does.
    let id = format!("{}/2", account.to_wire());
    let KeyBody::Recovery(blob) = KeyObject::parse(
        "key.recovery",
        &id,
        serde_json::to_string(
            &server
                .stored(ScopeOwner::Personal(account), "key.recovery", &id)
                .unwrap()
                .fields
                .unwrap(),
        )
        .unwrap()
        .as_bytes(),
    )
    .unwrap()
    .body
    else {
        panic!()
    };
    let old = RecoveryKey::parse(text.expose_secret()).unwrap();
    assert_eq!(
        old.open_blob(&origin(), account, av(2), &blob).unwrap_err().code(),
        "keys.open"
    );
    let next = RecoveryKey::parse(next.expose_secret()).unwrap();
    next.open_blob(&origin(), account, av(2), &blob).unwrap();
}

#[tokio::test]
async fn a_device_left_out_waits_for_the_whole_change_set_then_locks_and_erases_nothing() {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let d = Device::new(&server, account, "dev_d").await;
    let text = b.genesis().await;
    d.approved_by(&b).await;
    let d_device = key_device(&d).await;
    replace(&b, &text, Vec::new()).await;
    let id = format!("{}/2", account.to_wire());
    let certificate = server
        .stored(ScopeOwner::Personal(account), "key.account", &id)
        .unwrap();
    let alone = record(
        "key.account",
        &id,
        &serde_json::to_string(&certificate.fields.unwrap()).unwrap(),
    );

    d.feed(vec![alone], ArrivalOrder::InOrder).await;
    let waiting = d
        .service
        .seal_personal_envelope(envelope(), SecretString::from("x"), json!({}))
        .await
        .unwrap_err();
    assert_eq!(
        waiting,
        tablepro_sync::SyncError::NotAllowed {
            what: "write while a newer account version waits"
        }
    );

    assert_eq!(
        d.key_state().await,
        KeyState::Approved {
            av: Version::FIRST,
            key_device: d_device
        }
    );
    d.pull().await;
    assert_eq!(
        d.key_state().await,
        KeyState::Locked {
            cause: LockCause::LeftOutOfRotation
        }
    );
    assert!(d.hooks.calls().contains(&HookCall::Lock(LockCause::LeftOutOfRotation)));
    assert!(d.store.holds(&DeviceItem::AccountKeys {
        origin: origin(),
        account,
        av: Version::FIRST,
    }));
    assert_eq!(key_device(&d).await, d_device);
    let refused = d
        .service
        .seal_personal_envelope(envelope(), SecretString::from("x"), json!({}))
        .await
        .unwrap_err();
    assert_eq!(refused.code(), "sync.not_allowed");
}

#[tokio::test]
async fn replace_takes_only_this_account_s_recovery_key_and_keeps_only_compared_devices() {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let text = b.genesis().await;
    let other = RecoveryKey::generate().unwrap().to_text().unwrap();

    assert_eq!(
        b.service.begin_replace(other).await.unwrap_err().code(),
        "keys.signature"
    );
    assert_eq!(
        b.service
            .begin_replace(SecretString::from("not a key"))
            .await
            .unwrap_err()
            .code(),
        "keys.recovery_key"
    );
    let draft = b.service.begin_replace(text).await.unwrap();
    let wrong = TypedBack {
        groups: [SecretString::from("0000"), SecretString::from("1111")],
    };
    assert_eq!(
        b.service
            .finish_replace(draft.recovery.draft, wrong, Vec::new())
            .await
            .unwrap_err()
            .code(),
        "sync.typed_back_wrong"
    );
    let stranger = KeyDeviceId(random_uuid().unwrap());
    assert_eq!(
        b.service
            .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), vec![stranger])
            .await
            .unwrap_err()
            .code(),
        "keys.not_compared"
    );
    assert!(
        server
            .stored(
                ScopeOwner::Personal(account),
                "key.account",
                &format!("{}/2", account.to_wire())
            )
            .is_none()
    );
}

#[tokio::test]
async fn a_replace_that_loses_to_another_rotation_discards_its_keys() {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let c = Device::new(&server, account, "dev_c").await;
    let text = b.genesis().await;
    c.approved_by(&b).await;
    b.pull().await;
    let b_draft = b.service.begin_replace(text.clone()).await.unwrap();
    replace(&c, &text, Vec::new()).await;

    let lost = b
        .service
        .finish_replace(b_draft.recovery.draft, typed_back(&b_draft.recovery), Vec::new())
        .await
        .unwrap_err();

    assert_eq!(
        lost,
        tablepro_sync::SyncError::Rejected {
            code: RejectedCode::CreateOnly
        }
    );
    assert!(!b.store.holds(&DeviceItem::AccountKeys {
        origin: origin(),
        account,
        av: av(2),
    }));
    b.pull().await;
    assert_eq!(
        b.key_state().await,
        KeyState::Locked {
            cause: LockCause::LeftOutOfRotation
        }
    );
}

#[tokio::test]
async fn the_new_personal_and_history_versions_are_signed_under_the_new_av_and_carry_the_old_in_rings() {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let text = b.genesis().await;
    replace(&b, &text, Vec::new()).await;

    let mut txn = b.txn().await;
    for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
        let current = b
            .service
            .current_personal(txn.as_mut(), purpose)
            .await
            .unwrap()
            .unwrap();
        assert_eq!((current.record.key.version, current.record.signer_av), (av(2), av(2)));
        let older = b
            .service
            .personal_key(txn.as_mut(), purpose, Version::FIRST)
            .await
            .unwrap();
        let record = KeyObject::parse(
            "key.version",
            &format!("{}/{}/1", account.to_wire(), purpose.name()),
            serde_json::to_string(
                &server
                    .stored(
                        ScopeOwner::Personal(account),
                        "key.version",
                        &format!("{}/{}/1", account.to_wire(), purpose.name()),
                    )
                    .unwrap()
                    .fields
                    .unwrap(),
            )
            .unwrap()
            .as_bytes(),
        )
        .unwrap()
        .version_record()
        .unwrap();
        record.check_key(&older).unwrap();
    }
    let Some(Row::KeyVersion(row)) = b
        .get(RowKey::KeyVersion(ScopeName::Personal, KeyPurpose::Personal))
        .await
    else {
        panic!()
    };
    assert_eq!(row.version, av(2));
}
