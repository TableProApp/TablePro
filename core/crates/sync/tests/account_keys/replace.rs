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
    assert_eq!(
        refused,
        tablepro_sync::SyncError::Locked {
            cause: LockCause::LeftOutOfRotation
        }
    );
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
    assert!(
        b.get(RowKey::KeyPending(PendingFlow::AccountRotation { av: av(2) }))
            .await
            .is_none()
    );
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

async fn approved_pair() -> (std::sync::Arc<FakeServer>, Device, Device, SecretString) {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let c = Device::new(&server, account, "dev_c").await;
    let text = b.genesis().await;
    c.approved_by(&b).await;
    (server, b, c, text)
}

#[tokio::test]
async fn a_replace_whose_push_fails_is_never_followed_until_it_applies() {
    let (server, b, _c, text) = approved_pair().await;
    let account = b.account;
    b.pull().await;
    let draft = b.service.begin_replace(text).await.unwrap();
    server.fail_next(tablepro_sync::api::transport::TransportError::Network {
        detail: "503".to_owned(),
    });

    let failed = b
        .service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), Vec::new())
        .await
        .unwrap_err();
    b.pull().await;

    assert_eq!(failed.code(), "sync.network");
    let pin = b.pin(account).await.unwrap();
    assert_eq!((pin.av, pin.replaced.len()), (Version::FIRST, 0));
    assert!(matches!(b.key_state().await, KeyState::Approved { av, .. } if av == Version::FIRST));
    let sealed = b
        .service
        .seal_personal_envelope(envelope(), SecretString::from("x"), json!({}))
        .await
        .unwrap();
    assert_eq!(sealed["kv"], 1);
    b.service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), Vec::new())
        .await
        .unwrap();
    assert_eq!(b.pin(account).await.unwrap().av, av(2));
}

#[tokio::test]
async fn a_replace_keeps_only_devices_the_account_still_certifies() {
    let (_server, b, c, text) = approved_pair().await;
    let d = Device::new(&b.server, b.account, "dev_d").await;
    d.approved_by(&b).await;
    let b_device = key_device(&b).await;
    let d_device = key_device(&d).await;
    // C rotates keeping B alone, so D, which B compared with, is no longer certified at av 2.
    let next = replace(&c, &text, vec![b_device]).await;
    b.pull().await;
    assert!(matches!(b.key_state().await, KeyState::Approved { av: at, .. } if at == av(2)));

    let draft = b.service.begin_replace(next).await.unwrap();

    assert!(draft.devices.iter().all(|row| row.device.key_device != d_device));
    let refused = b
        .service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), vec![d_device])
        .await
        .unwrap_err();
    assert_eq!(refused.code(), "sync.not_allowed");
    assert!(b.get(RowKey::KeyDevicePin(d_device)).await.is_some());
}

#[tokio::test]
async fn a_replace_forgets_the_own_device_pins_it_left_out() {
    let (_server, b, c, text) = approved_pair().await;
    let c_device = key_device(&c).await;

    replace(&b, &text, Vec::new()).await;

    assert!(b.get(RowKey::KeyDevicePin(c_device)).await.is_none());
}

#[tokio::test]
async fn a_replace_runs_only_on_an_approved_device_it_can_trust() {
    let (_server, b, _c, text) = approved_pair().await;
    let Some(Row::KeyVersion(row)) = b
        .get(RowKey::KeyVersion(ScopeName::Personal, KeyPurpose::Personal))
        .await
    else {
        panic!()
    };
    b.put(vec![Row::KeyVersion(tablepro_sync::api::state::KeyVersionRow {
        state: tablepro_sync::api::state::KeyVersionState::Stopped,
        stopped_cause: Some(tablepro_sync::api::state::StoppedCause::CatchUp),
        ..row
    })])
    .await;

    let refused = b.service.begin_replace(text).await.unwrap_err();

    assert_eq!(
        refused,
        tablepro_sync::SyncError::Locked {
            cause: LockCause::PersonalStopped
        }
    );
}

#[tokio::test]
async fn a_replace_draft_whose_recovery_key_the_account_moved_past_is_refused() {
    let (_server, b, c, text) = approved_pair().await;
    let b_device = key_device(&b).await;
    b.pull().await;
    let draft = b.service.begin_replace(text.clone()).await.unwrap();
    replace(&c, &text, vec![b_device]).await;
    b.pull().await;

    let refused = b
        .service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), Vec::new())
        .await
        .unwrap_err();

    assert_eq!(refused.code(), "keys.signature");
    assert_eq!(b.pin(b.account).await.unwrap().av, av(2));
    let again = b
        .service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), Vec::new())
        .await
        .unwrap_err();
    assert_eq!(again.code(), "sync.unknown");
}

// K7-2's recovery stood in for: a device on a fresh row with only R reads the key kinds before approval, opens the
// blob at `at` and rotates to the next `av`, keeping itself alone (0056, Recovery).
async fn recovered(
    server: &std::sync::Arc<FakeServer>,
    account: tablepro_keys::encoding::AccountId,
    text: &SecretString,
    at: Version,
) -> Device {
    let x = Device::new(server, account, "dev_x").await;
    recover_on(&x, server, account, text, at).await;
    x
}

// The same on a device a test may have shown other objects first.
async fn recover_on(
    x: &Device,
    server: &std::sync::Arc<FakeServer>,
    account: tablepro_keys::encoding::AccountId,
    text: &SecretString,
    at: Version,
) {
    use tablepro_sync::keys::{AccountObjectsPlan, KeptDevice};

    let recovery = RecoveryKey::parse(text.expose_secret()).unwrap();
    let next = at.next().unwrap();
    x.pull().await;
    let certificate = crate::harness::stored_certificate(server, account, at);
    let keys = recovery
        .open_blob(
            &origin(),
            account,
            at,
            &crate::harness::stored_blob(server, account, at),
        )
        .unwrap();
    keys.check_against(&certificate.ask, &certificate.aek).unwrap();
    x.service.store_account_keys(at, &keys).await.unwrap();
    let device = x.service.ensure_device_keys().await.unwrap();
    let new_keys = tablepro_keys::keys::AccountKeys::generate().unwrap();
    let mut objects = x
        .service
        .account_objects(&AccountObjectsPlan {
            av: next,
            kind: CertKind::GenesisOrRotation,
            ik: &recovery.identity_seed(&origin(), account).unwrap(),
            endorsing_ik: None,
            recovery: &recovery,
            keys: &new_keys,
            devices: &[KeptDevice::of(&device).unwrap()],
            wrapper: Some(&device),
        })
        .unwrap();
    for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
        let current = carried(server, account, purpose, at, &keys, &certificate);
        objects.extend(next_version(x, purpose, next, &current, &new_keys, device.key_device));
    }
    x.service.store_account_keys(next, &new_keys).await.unwrap();
    let changes = objects
        .iter()
        .map(|object| tablepro_sync::keys::create_change(object).unwrap())
        .collect();
    x.service
        .push_change_set(ScopeName::Personal, changes, x.proof().await)
        .await
        .unwrap();
    let mut txn = x.txn().await;
    x.service
        .adopt_account_change_set(txn.as_mut(), &objects)
        .await
        .unwrap();
    txn.commit().await.unwrap();
    x.server_approves().await;
    x.pull().await;
}

// The scope key of `purpose` at `at`, opened from its wrap to the account's AEK there, as a recovery carries it.
fn carried(
    server: &FakeServer,
    account: tablepro_keys::encoding::AccountId,
    purpose: KeyPurpose,
    at: Version,
    keys: &tablepro_keys::keys::AccountKeys,
    certificate: &tablepro_keys::cert::AccountCertificate,
) -> tablepro_keys::keys::ScopeKey {
    let key = tablepro_keys::scope_key::KeyRef {
        owner: account.0,
        purpose,
        version: at,
    };
    let record = crate::harness::stored(
        server,
        account,
        "key.version",
        &tablepro_keys::record_id::KeyRecordId::Version(key).to_wire(),
    )
    .version_record()
    .unwrap();
    let target = tablepro_keys::wrap::scope_key_target(key, account, at);
    let wrap = crate::harness::stored(
        server,
        account,
        "key.wrap",
        &tablepro_keys::record_id::KeyRecordId::Wrap(target).to_wire(),
    )
    .wrap()
    .unwrap();
    wrap.open_scope_key(&origin(), &keys.aek, &certificate.aek, &certificate.ask, &record)
        .unwrap()
}

fn next_version(
    device: &Device,
    purpose: KeyPurpose,
    next: Version,
    current: &tablepro_keys::keys::ScopeKey,
    keys: &tablepro_keys::keys::AccountKeys,
    key_device: KeyDeviceId,
) -> Vec<KeyObject> {
    let fresh = tablepro_keys::keys::ScopeKey::generate().unwrap();
    device
        .service
        .personal_version_objects(
            purpose,
            &tablepro_sync::keys::ScopeKeyPlan {
                version: next,
                key: &fresh,
                start: tablepro_keys::scope_key::Start::Next,
                previous: Some(current),
            },
            next,
            keys,
            key_device,
        )
        .unwrap()
}

#[tokio::test]
async fn a_recovery_from_zero_devices_reads_the_old_versions_through_their_rings_under_a_replaced_identity() {
    let (server, b, _c, text) = approved_pair().await;
    let account = b.account;
    let old = envelope();
    let sealed = b
        .service
        .seal_personal_envelope(old.clone(), SecretString::from("from av 1"), json!({}))
        .await
        .unwrap();
    let next = replace(&b, &text, Vec::new()).await;

    let x = recovered(&server, account, &next, av(2)).await;

    let pin = x.pin(account).await.unwrap();
    let opened = x.service.open_personal_envelope(old, sealed, None).await.unwrap();

    assert_eq!(opened.secret.expose_secret(), "from av 1");
    assert_eq!(pin.av, av(3));
    assert_eq!(pin.replaced.len(), 1);
}

#[tokio::test]
async fn a_recovered_device_never_takes_an_older_certificate_the_server_made_up_as_its_own_history() {
    let (server, b, _c, text) = approved_pair().await;
    let account = b.account;
    let next = replace(&b, &text, Vec::new()).await;
    let forged = tablepro_keys::cert::AccountCertificate::sign(
        &origin(),
        account,
        Version::FIRST,
        CertKind::GenesisOrRotation,
        &tablepro_keys::keys::Ed25519Seed::generate().unwrap(),
        tablepro_keys::keys::AccountKeys::generate().unwrap().public().unwrap(),
        None,
    )
    .unwrap();
    // The server shows the recovering device its own certificate at av 1 in place of the account's.
    let x = Device::new(&server, account, "dev_x").await;
    x.feed(
        vec![crate::harness::record_of(&KeyObject {
            id: tablepro_keys::record_id::KeyRecordId::Account {
                account,
                av: Version::FIRST,
            },
            body: KeyBody::Account(tablepro_keys::body::AccountBody::of(&forged)),
        })],
        ArrivalOrder::InOrder,
    )
    .await;

    recover_on(&x, &server, account, &next, av(2)).await;

    let pin = x.pin(account).await.unwrap();
    assert!(!pin.replaced.contains(&forged.ik));
    let mut txn = x.txn().await;
    let verified = x
        .service
        .verify_certificate(txn.as_mut(), ScopeName::Personal, &forged)
        .await;
    assert!(verified.is_err());
}

#[tokio::test]
async fn a_replace_whose_answer_was_lost_goes_up_again_before_any_new_one() {
    let (server, b, c, text) = approved_pair().await;
    let account = b.account;
    let c_device = key_device(&c).await;
    b.pull().await;
    let first = b.service.begin_replace(text.clone()).await.unwrap();
    b.transport.lose_next_answer();
    let lost = b
        .service
        .finish_replace(first.recovery.draft, typed_back(&first.recovery), vec![c_device])
        .await
        .unwrap_err();
    assert_eq!(lost.code(), "sync.network");

    let second = b.service.begin_replace(text).await.unwrap_err();

    assert_eq!(second.code(), "sync.not_allowed");
    let pin = b.pin(account).await.unwrap();
    let applied = RecoveryKey::parse(first.recovery.text.expose_secret()).unwrap();
    assert_eq!(
        pin.ik,
        applied.identity_seed(&origin(), account).unwrap().public().unwrap()
    );
    applied
        .open_blob(
            &origin(),
            account,
            av(2),
            &crate::harness::stored_blob(&server, account, av(2)),
        )
        .unwrap();
    assert!(
        b.get(RowKey::KeyPending(PendingFlow::AccountRotation { av: av(2) }))
            .await
            .is_some()
    );
    assert!(b.get(RowKey::KeyDevicePin(c_device)).await.is_some());
}

#[tokio::test]
async fn a_retry_names_the_kept_devices_in_any_order() {
    let (_server, b, c, text) = approved_pair().await;
    let d = Device::new(&b.server, b.account, "dev_d").await;
    d.approved_by(&b).await;
    let (c_device, d_device) = (key_device(&c).await, key_device(&d).await);
    b.pull().await;
    let draft = b.service.begin_replace(text).await.unwrap();
    b.transport.lose_next_answer();
    b.service
        .finish_replace(
            draft.recovery.draft,
            typed_back(&draft.recovery),
            vec![c_device, d_device],
        )
        .await
        .unwrap_err();

    b.service
        .finish_replace(
            draft.recovery.draft,
            typed_back(&draft.recovery),
            vec![d_device, c_device],
        )
        .await
        .unwrap();

    assert_eq!(b.pin(b.account).await.unwrap().av, av(2));
}

#[tokio::test]
async fn a_lost_replace_whose_av_another_rotation_took_leaves_no_rotation_row_behind() {
    let (server, b, c, text) = approved_pair().await;
    let b_device = key_device(&b).await;
    b.pull().await;
    let draft = b.service.begin_replace(text.clone()).await.unwrap();
    server.fail_next(tablepro_sync::api::transport::TransportError::Network {
        detail: "offline".to_owned(),
    });
    b.service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), Vec::new())
        .await
        .unwrap_err();
    let next = replace(&c, &text, vec![b_device]).await;

    b.pull().await;

    assert!(
        b.get(RowKey::KeyPending(PendingFlow::AccountRotation { av: av(2) }))
            .await
            .is_none()
    );
    let pin = b.pin(b.account).await.unwrap();
    let won = RecoveryKey::parse(next.expose_secret()).unwrap();
    assert_eq!(
        pin.ik,
        won.identity_seed(&origin(), b.account).unwrap().public().unwrap()
    );
    assert!(matches!(b.key_state().await, KeyState::Approved { av: at, .. } if at == av(2)));
}

#[tokio::test]
async fn a_push_again_the_server_refuses_waits_for_a_pull_and_keeps_the_rotation_row() {
    let (_server, b, _c, text) = approved_pair().await;
    b.pull().await;
    let draft = b.service.begin_replace(text.clone()).await.unwrap();
    b.transport.lose_next_answer();
    b.service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), Vec::new())
        .await
        .unwrap_err();
    b.transport.refuse_next_push(RejectedCode::BadStatement);

    let refused = b.service.begin_replace(text).await.unwrap_err();

    assert_eq!(refused.code(), "sync.rejected");
    assert!(
        b.get(RowKey::KeyPending(PendingFlow::AccountRotation { av: av(2) }))
            .await
            .is_some()
    );
    b.pull().await;
    assert!(matches!(b.key_state().await, KeyState::Approved { av: at, .. } if at == av(2)));
    assert!(
        b.get(RowKey::KeyPending(PendingFlow::AccountRotation { av: av(2) }))
            .await
            .is_some()
    );
}

#[tokio::test]
async fn a_replace_that_applied_unseen_is_finished_even_after_the_account_moved_past_it() {
    let (_server, b, c, text) = approved_pair().await;
    let d = Device::new(&b.server, b.account, "dev_d").await;
    d.approved_by(&b).await;
    let (c_device, d_device) = (key_device(&c).await, key_device(&d).await);
    b.pull().await;
    let draft = b.service.begin_replace(text).await.unwrap();
    b.transport.lose_next_answer();
    b.service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), vec![d_device])
        .await
        .unwrap_err();
    b.pull().await;
    // The pull that showed the replace applied already forgot the device it left out.
    assert!(b.get(RowKey::KeyDevicePin(c_device)).await.is_none());
    d.pull().await;
    replace(&d, &draft.recovery.text, vec![key_device(&b).await]).await;
    b.pull().await;

    b.service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), vec![d_device])
        .await
        .unwrap();

    assert!(matches!(b.key_state().await, KeyState::Approved { av: at, .. } if at == av(3)));
}
