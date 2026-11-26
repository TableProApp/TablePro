// What a server that lies serves the account flows (threat model, A malicious server operator): a made-up reset, an
// IK seen replaced, a version under a removed device's account key, a wrap of a key it knows, another object at a held
// id, a replayed or skipping certificate, a downgraded suite, and an approval wrap a stolen account key signed.

use secrecy::{ExposeSecret, SecretString};
use serde_json::json;
use tablepro_keys::body::{AccountBody, KeyBody, KeyObject, VersionBody, WrapBody};
use tablepro_keys::cert::{AccountCertificate, CertKind};
use tablepro_keys::encoding::{KeyPurpose, Version, WrapPurpose, random_uuid, uuid_to_wire};
use tablepro_keys::envelope::{EnvelopeId, ParentKind, SecretKind};
use tablepro_keys::keys::{AccountKeys, Ed25519Seed, ScopeKey};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::scope_key::{KeyRef, Start, VersionRecord};
use tablepro_keys::wrap::{Wrap, Wrapper, device_target, scope_key_target};
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::key_flows::{AccountFlows, ArrivalOrder, KeyNoticeKind, KeyState, LockCause};
use tablepro_sync::api::state::{KeyVersionState, Row, RowKey, StoppedCause};
use tablepro_sync_testing::FakeServer;
use tablepro_sync_testing::key_flows::HookCall;

use crate::harness::{Device, new_account, origin, record, record_of, refused_codes, stored, typed_back};

fn av(value: u32) -> Version {
    Version::new(value).unwrap()
}

fn account_object(certificate: &AccountCertificate) -> KeyObject {
    KeyObject {
        id: KeyRecordId::Account {
            account: certificate.account,
            av: certificate.av,
        },
        body: KeyBody::Account(AccountBody::of(certificate)),
    }
}

async fn replaced(server: &std::sync::Arc<FakeServer>) -> (Device, SecretString, SecretString) {
    let device = Device::new(server, new_account(), "dev_b").await;
    let text = device.genesis().await;
    device.pull().await;
    let draft = device.service.begin_replace(text.clone()).await.unwrap();
    device
        .service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), Vec::new())
        .await
        .unwrap();
    device.pull().await;
    (device, text, draft.recovery.text)
}

#[tokio::test]
async fn an_identity_nothing_endorsed_on_the_own_account_locks_the_device_and_erases_nothing() {
    let server = FakeServer::new();
    let device = Device::new(&server, new_account(), "dev_b").await;
    device.genesis().await;
    let reset = RecoveryKey::generate().unwrap();
    let keys = AccountKeys::generate().unwrap();
    let certificate = AccountCertificate::sign(
        &origin(),
        device.account,
        av(2),
        CertKind::ResetKeepingKeys,
        &reset.identity_seed(&origin(), device.account).unwrap(),
        keys.public().unwrap(),
        None,
    )
    .unwrap();
    let before = device.store.len();

    let applied = device
        .feed(vec![record_of(&account_object(&certificate))], ArrivalOrder::InOrder)
        .await;

    assert_eq!(refused_codes(&applied), ["keys.unendorsed"]);
    assert_eq!(
        device.key_state().await,
        KeyState::Locked {
            cause: LockCause::OwnAccountReset
        }
    );
    assert!(
        device
            .hooks
            .calls()
            .contains(&HookCall::Lock(LockCause::OwnAccountReset))
    );
    let pin = device.pin(device.account).await.unwrap();
    assert!(pin.alert && pin.av == Version::FIRST);
    assert_eq!(device.store.len(), before);
    let id = EnvelopeId::new(
        ParentKind::Connection,
        &uuid_to_wire(random_uuid().unwrap()),
        SecretKind::Password,
    )
    .unwrap();
    let sealed = device
        .service
        .seal_personal_envelope(id, SecretString::from("x"), json!({}))
        .await
        .unwrap_err();
    assert_eq!(
        sealed,
        tablepro_sync::SyncError::Locked {
            cause: LockCause::OwnAccountReset
        }
    );
    // Its own account's new identity is never accepted by a click: another device approves it again.
    let accept = device
        .service
        .accept_key_change(
            device.account,
            certificate.ik,
            tablepro_sync::api::key_flows::Acceptance::Compared,
        )
        .await
        .unwrap_err();
    assert_eq!(accept.code(), "sync.not_allowed");
}

#[tokio::test]
async fn an_ik_seen_replaced_is_never_the_newest_again() {
    let server = FakeServer::new();
    let (device, old, _) = replaced(&server).await;
    let old = RecoveryKey::parse(old.expose_secret()).unwrap();
    let keys = AccountKeys::generate().unwrap();
    let back = AccountCertificate::sign(
        &origin(),
        device.account,
        av(3),
        CertKind::GenesisOrRotation,
        &old.identity_seed(&origin(), device.account).unwrap(),
        keys.public().unwrap(),
        None,
    )
    .unwrap();

    let applied = device
        .feed(vec![record_of(&account_object(&back))], ArrivalOrder::InOrder)
        .await;

    assert_eq!(refused_codes(&applied), ["keys.retired_ik"]);
    let pin = device.pin(device.account).await.unwrap();
    assert_eq!(pin.av, av(2));
    assert!(!pin.alert);
    assert!(matches!(device.key_state().await, KeyState::Approved { av: at, .. } if at == av(2)));
}

#[tokio::test]
async fn a_certificate_replayed_from_before_or_one_that_skips_moves_nothing() {
    let server = FakeServer::new();
    let (device, _, next) = replaced(&server).await;
    let genesis = stored(
        &server,
        device.account,
        "key.account",
        &format!("{}/1", device.account.to_wire()),
    );
    let next = RecoveryKey::parse(next.expose_secret()).unwrap();
    let skipping = AccountCertificate::sign(
        &origin(),
        device.account,
        av(4),
        CertKind::GenesisOrRotation,
        &next.identity_seed(&origin(), device.account).unwrap(),
        AccountKeys::generate().unwrap().public().unwrap(),
        None,
    )
    .unwrap();

    let applied = device
        .feed(
            vec![record_of(&genesis), record_of(&account_object(&skipping))],
            ArrivalOrder::InOrder,
        )
        .await;

    assert!(applied.refused.is_empty());
    assert_eq!(applied.held, [account_object(&skipping).id.to_wire()]);
    assert!(matches!(device.key_state().await, KeyState::Approved { av: at, .. } if at == av(2)));
    assert_eq!(device.pin(device.account).await.unwrap().av, av(2));
}

#[tokio::test]
async fn a_personal_version_under_a_removed_device_s_account_key_stops_the_key_there() {
    let server = FakeServer::new();
    let (device, _, _) = replaced(&server).await;
    let removed = device.service.account_keys(Version::FIRST).await.unwrap().unwrap();
    let planted = VersionRecord::sign(
        &origin(),
        KeyRef {
            owner: device.account.0,
            purpose: KeyPurpose::Personal,
            version: av(3),
        },
        Start::Next,
        &ScopeKey::generate().unwrap(),
        device.account,
        Version::FIRST,
        &removed.ask,
    )
    .unwrap();
    let object = KeyObject {
        id: KeyRecordId::Version(planted.key),
        body: KeyBody::Version(VersionBody::of(&planted)),
    };

    device.feed(vec![record_of(&object)], ArrivalOrder::InOrder).await;

    let Some(Row::KeyVersion(row)) = device
        .get(RowKey::KeyVersion(ScopeName::Personal, KeyPurpose::Personal))
        .await
    else {
        panic!()
    };
    assert_eq!(
        (row.version, row.state, row.stopped_cause),
        (av(2), KeyVersionState::Stopped, Some(StoppedCause::CatchUp))
    );
    assert_eq!(
        device.key_state().await,
        KeyState::Locked {
            cause: LockCause::PersonalStopped
        }
    );
    let calls = device.hooks.calls();
    assert!(calls.contains(&HookCall::Stop(ScopeName::Personal, StoppedCause::CatchUp)));
    assert!(calls.contains(&HookCall::Lock(LockCause::PersonalStopped)));
    let id = EnvelopeId::new(
        ParentKind::Connection,
        &uuid_to_wire(random_uuid().unwrap()),
        SecretKind::Password,
    )
    .unwrap();
    let refused = device
        .service
        .seal_personal_envelope(id, SecretString::from("x"), json!({}))
        .await
        .unwrap_err();
    assert_eq!(refused.code(), "sync.locked");
}

#[tokio::test]
async fn a_wrap_of_a_key_the_server_knows_is_refused_and_never_read() {
    let server = FakeServer::new();
    let (device, _, _) = replaced(&server).await;
    let aek = device
        .service
        .account_keys(av(2))
        .await
        .unwrap()
        .unwrap()
        .aek
        .public()
        .unwrap();
    let known = ScopeKey::generate().unwrap();
    let key = KeyRef {
        owner: device.account.0,
        purpose: KeyPurpose::Personal,
        version: Version::FIRST,
    };
    let target = scope_key_target(key, device.account, av(2));
    let forged = Wrap::seal_scope_key(
        &origin(),
        target,
        &aek,
        &known,
        Wrapper {
            account: device.account,
            av: av(2),
            key_device: device.service.device_keys().await.unwrap().current.unwrap().key_device,
        },
        &Ed25519Seed::generate().unwrap(),
    )
    .unwrap();
    let object = KeyObject {
        id: KeyRecordId::Wrap(target),
        body: KeyBody::Wrap(WrapBody::of(&forged)),
    };

    let applied = device.feed(vec![record_of(&object)], ArrivalOrder::InOrder).await;

    assert_eq!(refused_codes(&applied), ["keys.signature"]);
    let mut txn = device.txn().await;
    let read = device
        .service
        .personal_key(txn.as_mut(), KeyPurpose::Personal, Version::FIRST)
        .await
        .unwrap();
    assert_ne!(read.expose(), known.expose());
}

#[tokio::test]
async fn another_object_at_a_held_id_is_an_alarm_and_changes_nothing() {
    let server = FakeServer::new();
    let device = Device::new(&server, new_account(), "dev_b").await;
    device.genesis().await;
    let keys = device.service.account_keys(Version::FIRST).await.unwrap().unwrap();
    let other = VersionRecord::sign(
        &origin(),
        KeyRef {
            owner: device.account.0,
            purpose: KeyPurpose::Personal,
            version: Version::FIRST,
        },
        Start::Over,
        &ScopeKey::generate().unwrap(),
        device.account,
        Version::FIRST,
        &keys.ask,
    )
    .unwrap();
    let Some(Row::KeyVersion(before)) = device
        .get(RowKey::KeyVersion(ScopeName::Personal, KeyPurpose::Personal))
        .await
    else {
        panic!()
    };

    let applied = device
        .feed(
            vec![record_of(&KeyObject {
                id: KeyRecordId::Version(other.key),
                body: KeyBody::Version(VersionBody::of(&other)),
            })],
            ArrivalOrder::InOrder,
        )
        .await;

    assert_eq!(refused_codes(&applied), ["keys.conflict"]);
    assert!(device.service.notices().await.unwrap().iter().any(|notice| notice.kind
        == KeyNoticeKind::Conflict {
            scope: ScopeName::Personal
        }));
    assert_eq!(
        device
            .get(RowKey::KeyVersion(ScopeName::Personal, KeyPurpose::Personal))
            .await,
        Some(Row::KeyVersion(before))
    );
}

#[tokio::test]
async fn a_downgraded_suite_or_another_account_s_object_is_refused() {
    let server = FakeServer::new();
    let device = Device::new(&server, new_account(), "dev_b").await;
    device.genesis().await;
    let genesis = stored(
        &server,
        device.account,
        "key.account",
        &format!("{}/1", device.account.to_wire()),
    );
    let downgraded = genesis.fields_json().replace("\"tp1\"", "\"tp0\"");
    let stranger = new_account();

    let applied = device
        .feed(
            vec![
                record("key.account", &format!("{}/2", device.account.to_wire()), &downgraded),
                record(
                    "key.account",
                    &format!("{}/1", stranger.to_wire()),
                    &genesis.fields_json(),
                ),
            ],
            ArrivalOrder::InOrder,
        )
        .await;

    assert_eq!(refused_codes(&applied), ["keys.suite", "keys.encoding"]);
}

#[tokio::test]
async fn a_rotation_wrap_signed_by_the_account_key_instead_of_a_compared_device_is_refused() {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let c = Device::new(&server, account, "dev_c").await;
    let text = b.genesis().await;
    c.approved_by(&b).await;
    let c_device = c.service.device_keys().await.unwrap().current.unwrap();
    b.pull().await;
    let draft = b.service.begin_replace(text).await.unwrap();
    b.service
        .finish_replace(
            draft.recovery.draft,
            typed_back(&draft.recovery),
            vec![c_device.key_device],
        )
        .await
        .unwrap();
    let new_keys = b.service.account_keys(av(2)).await.unwrap().unwrap();
    let target = device_target(account, WrapPurpose::Account, av(2), c_device.key_device);
    let forged = Wrap::seal_account(
        &origin(),
        target,
        &c_device.dek.public().unwrap(),
        &new_keys,
        Wrapper {
            account,
            av: av(2),
            key_device: b.service.device_keys().await.unwrap().current.unwrap().key_device,
        },
        &new_keys.ask,
    )
    .unwrap();
    let forged = record_of(&KeyObject {
        id: KeyRecordId::Wrap(target),
        body: KeyBody::Wrap(WrapBody::of(&forged)),
    });
    let served: Vec<_> = c
        .served()
        .await
        .into_iter()
        .map(|served| {
            if served.record_id == forged.record_id {
                forged.clone()
            } else {
                served
            }
        })
        .collect();

    let applied = c.feed(served, ArrivalOrder::Snapshot).await;

    assert!(refused_codes(&applied).contains(&"keys.not_compared"));
    assert_eq!(
        c.key_state().await,
        KeyState::Locked {
            cause: LockCause::LeftOutOfRotation
        }
    );
    assert!(c.service.account_keys(av(2)).await.unwrap().is_none());
}

#[tokio::test]
async fn a_planted_wrap_does_not_hide_the_ring_a_device_reads_an_older_version_through() {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let text = b.genesis().await;
    let id = EnvelopeId::new(
        ParentKind::Connection,
        &uuid_to_wire(random_uuid().unwrap()),
        SecretKind::Password,
    )
    .unwrap();
    let sealed = b
        .service
        .seal_personal_envelope(id.clone(), SecretString::from("older"), json!({}))
        .await
        .unwrap();
    b.pull().await;
    let draft = b.service.begin_replace(text).await.unwrap();
    b.service
        .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), Vec::new())
        .await
        .unwrap();
    let c = Device::new(&server, account, "dev_c").await;
    c.approved_by(&b).await;
    assert!(c.service.account_keys(Version::FIRST).await.unwrap().is_none());
    let aek = c
        .service
        .account_keys(av(2))
        .await
        .unwrap()
        .unwrap()
        .aek
        .public()
        .unwrap();
    let target = scope_key_target(
        KeyRef {
            owner: account.0,
            purpose: KeyPurpose::Personal,
            version: Version::FIRST,
        },
        account,
        av(2),
    );
    let forged = Wrap::seal_scope_key(
        &origin(),
        target,
        &aek,
        &ScopeKey::generate().unwrap(),
        Wrapper {
            account,
            av: av(2),
            key_device: c.service.device_keys().await.unwrap().current.unwrap().key_device,
        },
        &Ed25519Seed::generate().unwrap(),
    )
    .unwrap();
    let planted = c
        .feed(
            vec![record_of(&KeyObject {
                id: KeyRecordId::Wrap(target),
                body: KeyBody::Wrap(WrapBody::of(&forged)),
            })],
            ArrivalOrder::InOrder,
        )
        .await;
    assert_eq!(refused_codes(&planted), ["keys.signature"]);

    let opened = c.service.open_personal_envelope(id, sealed, None).await.unwrap();

    assert_eq!(opened.secret.expose_secret(), "older");
}

#[tokio::test]
async fn a_rotation_wrap_whose_keys_are_not_the_certificate_s_is_a_mismatch_and_keeps_the_device_out() {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let c = Device::new(&server, account, "dev_c").await;
    let text = b.genesis().await;
    c.approved_by(&b).await;
    let c_device = c.service.device_keys().await.unwrap().current.unwrap();
    b.pull().await;
    let draft = b.service.begin_replace(text).await.unwrap();
    b.service
        .finish_replace(
            draft.recovery.draft,
            typed_back(&draft.recovery),
            vec![c_device.key_device],
        )
        .await
        .unwrap();
    let b_device = b.service.device_keys().await.unwrap().current.unwrap();
    let target = device_target(account, WrapPurpose::Account, av(2), c_device.key_device);
    let other = Wrap::seal_account(
        &origin(),
        target,
        &c_device.dek.public().unwrap(),
        &AccountKeys::generate().unwrap(),
        Wrapper {
            account,
            av: av(2),
            key_device: b_device.key_device,
        },
        &b_device.dsk,
    )
    .unwrap();
    let other = record_of(&KeyObject {
        id: KeyRecordId::Wrap(target),
        body: KeyBody::Wrap(WrapBody::of(&other)),
    });
    let served: Vec<_> = c
        .served()
        .await
        .into_iter()
        .map(|served| {
            if served.record_id == other.record_id {
                other.clone()
            } else {
                served
            }
        })
        .collect();

    let applied = c.feed(served, ArrivalOrder::Snapshot).await;

    assert!(refused_codes(&applied).contains(&"keys.mismatch"), "{applied:?}");
    assert_eq!(
        c.key_state().await,
        KeyState::Locked {
            cause: LockCause::LeftOutOfRotation
        }
    );
}

#[tokio::test]
async fn a_planted_wrap_naming_a_certificate_that_does_not_verify_does_not_hide_the_genuine_one() {
    let server = FakeServer::new();
    let (device, _, _) = replaced(&server).await;
    let account = device.account;
    let fake = AccountCertificate::sign(
        &origin(),
        account,
        av(4),
        CertKind::GenesisOrRotation,
        &Ed25519Seed::generate().unwrap(),
        AccountKeys::generate().unwrap().public().unwrap(),
        None,
    )
    .unwrap();
    let aek = device
        .service
        .account_keys(Version::FIRST)
        .await
        .unwrap()
        .unwrap()
        .aek
        .public()
        .unwrap();
    let target = scope_key_target(
        KeyRef {
            owner: account.0,
            purpose: KeyPurpose::Personal,
            version: av(2),
        },
        account,
        Version::FIRST,
    );
    let planted = Wrap::seal_scope_key(
        &origin(),
        target,
        &aek,
        &ScopeKey::generate().unwrap(),
        Wrapper {
            account,
            av: av(4),
            key_device: device.service.device_keys().await.unwrap().current.unwrap().key_device,
        },
        &Ed25519Seed::generate().unwrap(),
    )
    .unwrap();
    device
        .feed(
            vec![
                record_of(&account_object(&fake)),
                record_of(&KeyObject {
                    id: KeyRecordId::Wrap(target),
                    body: KeyBody::Wrap(WrapBody::of(&planted)),
                }),
            ],
            ArrivalOrder::InOrder,
        )
        .await;
    let id = EnvelopeId::new(
        ParentKind::Connection,
        &uuid_to_wire(random_uuid().unwrap()),
        SecretKind::Password,
    )
    .unwrap();

    let sealed = device
        .service
        .seal_personal_envelope(id.clone(), SecretString::from("current"), json!({}))
        .await
        .unwrap();

    assert_eq!(sealed["kv"], 2);
    let opened = device.service.open_personal_envelope(id, sealed, None).await.unwrap();
    assert_eq!(opened.secret.expose_secret(), "current");
}
