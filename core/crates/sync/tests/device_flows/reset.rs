// Reset (0056, Account flows): the proposal every device sees, the cancel by a certified device or by R, and the
// activation from the proposing device once the wait passed.

use secrecy::SecretString;
use tablepro_keys::body::KeyBody;
use tablepro_keys::encoding::KeyPurpose;
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::scope_key::{KeyRef, Start};
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::key_flows::{
    AccountFlows, CancelWith, KeyNoticeKind, ResetFlows, ResetKind, ResetState, TypedBack,
};
use tablepro_sync::api::transport::{PulledRecord, RejectedCode, StepUpChallenge, TransportError};
use tablepro_sync_testing::FakeServer;
use tablepro_sync_testing::key_flows::HookCall;

use crate::harness::{Device, approve, new_account, propose_reset, stored, typed_back};

const DAY_US: i64 = 24 * 3600 * 1_000_000;

fn tombstone(kind: &str, record_id: &str) -> PulledRecord {
    PulledRecord {
        kind: tablepro_sync::api::ids::KindName::parse(kind).unwrap(),
        record_id: record_id.to_owned(),
        tag: tablepro_sync::api::ids::ChangeTag::Service("tag".to_owned()),
        fields: None,
        fields_json: None,
        deleted: Some(tablepro_sync::api::transport::DeletedReason::User),
        service: None,
    }
}

fn rejected(code: RejectedCode) -> SyncError {
    SyncError::Rejected { code }
}

#[tokio::test]
async fn a_reset_from_an_approved_device_is_held_seven_days_in_view_of_every_device() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;

    let proposed = propose_reset(&a, ResetKind::KeepScopeKeys).await;
    b.pull().await;

    assert_eq!((proposed.state, proposed.mine), (ResetState::Pending, true));
    assert_eq!(proposed.held_until_us - proposed.taken_at_us, 7 * DAY_US);
    let seen = b.service.pending_reset().await.unwrap().unwrap();
    assert_eq!(
        (seen.reset, seen.mine, seen.state),
        (proposed.reset, false, ResetState::Pending)
    );
    assert!(
        b.hooks.calls().contains(&HookCall::Notice(
            b.service
                .held_notices()
                .into_iter()
                .find(|notice| notice.kind == KeyNoticeKind::ResetPending { reset: proposed.reset })
                .unwrap()
        ))
    );
}

#[tokio::test]
async fn a_reset_of_the_wrong_kind_for_its_caller_or_a_second_one_is_bad_statement() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;

    let kind_3_approved = a.service.begin_reset(ResetKind::StartEmpty).await.unwrap_err();
    let kind_2_signed_in = d.service.begin_reset(ResetKind::KeepScopeKeys).await.unwrap_err();
    propose_reset(&a, ResetKind::KeepScopeKeys).await;
    let second = a.service.begin_reset(ResetKind::KeepScopeKeys).await.unwrap_err();

    assert_eq!(kind_3_approved, rejected(RejectedCode::BadStatement));
    assert_eq!(kind_2_signed_in, rejected(RejectedCode::BadStatement));
    assert_eq!(second, rejected(RejectedCode::BadStatement));
}

#[tokio::test]
async fn r_typed_back_wrong_proposes_nothing_and_keeps_the_draft() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let draft = a.service.begin_reset(ResetKind::KeepScopeKeys).await.unwrap();
    let wrong = TypedBack {
        groups: [
            SecretString::from("ZZZZ".to_owned()),
            SecretString::from("ZZZZ".to_owned()),
        ],
    };

    let error = a.service.finish_reset_proposal(draft.draft, wrong).await.unwrap_err();
    let retried = a
        .service
        .finish_reset_proposal(draft.draft, typed_back(&draft))
        .await
        .unwrap();

    assert_eq!(error, SyncError::TypedBackWrong);
    assert_eq!(retried.state, ResetState::Pending);
}

#[tokio::test]
async fn a_kind_3_proposal_the_server_asks_to_step_up_for_goes_up_after_the_step_up() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    let draft = d.service.begin_reset(ResetKind::StartEmpty).await.unwrap();
    d.wire.fail_next_push(TransportError::StepUpRequired(StepUpChallenge {
        acr_values: vec!["urn:tablepro:acr:passkey".to_owned()],
        max_age_secs: 300,
    }));

    let error = d
        .service
        .finish_reset_proposal(draft.draft, typed_back(&draft))
        .await
        .unwrap_err();
    let proposed = d
        .service
        .finish_reset_proposal(draft.draft, typed_back(&draft))
        .await
        .unwrap();

    assert_eq!(error.code(), "sync.step_up_required");
    assert_eq!((proposed.kind, proposed.mine), (ResetKind::StartEmpty, true));
}

#[tokio::test]
async fn a_certified_device_cancels_a_reset_and_every_device_sees_it_end() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let proposed = propose_reset(&a, ResetKind::KeepScopeKeys).await;
    b.pull().await;

    b.service
        .cancel_reset(proposed.reset, CancelWith::ThisDevice)
        .await
        .unwrap();
    a.pull().await;

    assert_eq!(b.pending_reset_state().await, Some(ResetState::Cancelled));
    assert_eq!(a.pending_reset_state().await, Some(ResetState::Cancelled));
    assert!(a.service.reset_keys(proposed.reset).await.unwrap().is_none());
}

#[tokio::test]
async fn r_cancels_a_reset_from_any_device_and_another_recovery_key_is_keys_signature() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    let proposed = propose_reset(&d, ResetKind::StartEmpty).await;
    a.pull().await;

    let wrong = a
        .service
        .cancel_reset(
            proposed.reset,
            CancelWith::RecoveryKey(RecoveryKey::generate().unwrap().to_text().unwrap()),
        )
        .await
        .unwrap_err();
    a.service
        .cancel_reset(proposed.reset, CancelWith::RecoveryKey(r))
        .await
        .unwrap();
    d.pull().await;

    assert_eq!(wrong.code(), "keys.signature");
    let cancel = stored(
        &server,
        account,
        "key.cancel",
        &KeyRecordId::Cancel {
            account,
            reset: proposed.reset,
        }
        .to_wire(),
    )
    .unwrap();
    assert!(matches!(cancel.body, KeyBody::Cancel { sig: Some(_) }));
    assert_eq!(d.pending_reset_state().await, Some(ResetState::Cancelled));
}

#[tokio::test]
async fn an_activation_before_held_until_is_reset_held_and_takes_effect_after_the_wait() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let proposed = propose_reset(&a, ResetKind::KeepScopeKeys).await;
    let pushes = a.wire.pushed.lock().unwrap().len();

    let early = a.service.activate_reset(proposed.reset).await.unwrap_err();
    let pushed_early = a.wire.pushed.lock().unwrap().len() - pushes;
    server.advance_clock(7 * DAY_US);
    a.service.activate_reset(proposed.reset).await.unwrap();

    assert_eq!(early, rejected(RejectedCode::ResetHeld));
    assert_eq!(pushed_early, 0);
    assert_eq!(a.pending_reset_state().await, Some(ResetState::Active));
    a.server_approves().await;
    assert_eq!(a.av().await, 2);
    for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
        let key = KeyRef {
            owner: account.0,
            purpose,
            version: tablepro_keys::encoding::Version::new(2).unwrap(),
        };
        let version = stored(&server, account, "key.version", &KeyRecordId::Version(key).to_wire()).unwrap();
        assert_eq!(version.version_record().unwrap().start, Start::Next);
        assert!(stored(&server, account, "key.ring", &KeyRecordId::Ring(key).to_wire()).is_some());
    }
}

// The activation applied and its answer was lost; the proposer learns of it by pull, as the server tombstones the
// proposal, and adopts the keys it proposed. That wins over the lock the unendorsed IK raised meanwhile.
#[tokio::test]
async fn a_proposer_that_learns_of_its_activation_by_pull_adopts_it() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let proposed = propose_reset(&a, ResetKind::KeepScopeKeys).await;
    server.advance_clock(7 * DAY_US);
    a.wire.lose_next_answer();
    let lost = a.service.activate_reset(proposed.reset).await.unwrap_err();
    a.pull().await;
    let id = KeyRecordId::Reset {
        account,
        reset: proposed.reset,
    };

    a.service
        .apply_reset_objects(tablepro_sync::api::key_flows::KeyArrival {
            scope: tablepro_sync::api::ids::ScopeName::Personal,
            records: vec![tombstone("key.reset", &id.to_wire())],
            order: tablepro_sync::api::key_flows::ArrivalOrder::InOrder,
        })
        .await
        .unwrap();
    a.server_approves().await;

    assert!(matches!(lost, SyncError::Transport(TransportError::Network { .. })));
    assert_eq!(a.pending_reset_state().await, Some(ResetState::Active));
    assert_eq!(a.av().await, 2);
}

#[tokio::test]
async fn a_proposer_whose_activation_answer_was_lost_adopts_it_on_resume() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let proposed = propose_reset(&a, ResetKind::KeepScopeKeys).await;
    server.advance_clock(7 * DAY_US);
    a.wire.lose_next_answer();
    a.service.activate_reset(proposed.reset).await.unwrap_err();
    a.pull().await;

    a.service.resume_reset(proposed.reset).await.unwrap();
    a.server_approves().await;

    assert_eq!(a.pending_reset_state().await, Some(ResetState::Active));
    assert_eq!(a.av().await, 2);
}

// The server took the proposal and its answer was lost: the device keeps the keys, the candidate and the row, and
// sends the same proposal again.
#[tokio::test]
async fn a_proposal_whose_answer_was_lost_keeps_its_keys_and_goes_up_again() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let draft = a.service.begin_reset(ResetKind::KeepScopeKeys).await.unwrap();
    a.wire.lose_next_answer();

    let held = a
        .service
        .finish_reset_proposal(draft.draft, typed_back(&draft))
        .await
        .unwrap();
    let first = a.wire.last_push_by_id();
    a.service.resume_reset(held.reset).await.unwrap();
    let second = a.wire.last_push_by_id();
    server.advance_clock(7 * DAY_US);
    a.service.activate_reset(held.reset).await.unwrap();

    assert_eq!(first, second);
    assert_eq!(a.pending_reset_state().await, Some(ResetState::Active));
}

#[tokio::test]
async fn a_kind_3_activation_starts_the_personal_and_history_keys_over_with_no_ring() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    let proposed = propose_reset(&d, ResetKind::StartEmpty).await;
    server.advance_clock(7 * DAY_US);

    d.service.activate_reset(proposed.reset).await.unwrap();
    d.server_approves().await;

    assert_eq!(d.av().await, 2);
    for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
        let key = KeyRef {
            owner: account.0,
            purpose,
            version: tablepro_keys::encoding::Version::new(2).unwrap(),
        };
        let version = stored(&server, account, "key.version", &KeyRecordId::Version(key).to_wire()).unwrap();
        assert_eq!(version.version_record().unwrap().start, Start::Over);
        assert!(stored(&server, account, "key.ring", &KeyRecordId::Ring(key).to_wire()).is_none());
    }
}

#[tokio::test]
async fn only_the_proposing_device_activates() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let proposed = propose_reset(&a, ResetKind::KeepScopeKeys).await;
    b.pull().await;
    server.advance_clock(7 * DAY_US);

    let error = b.service.activate_reset(proposed.reset).await.unwrap_err();

    assert_eq!(error, rejected(RejectedCode::WriterBound));
}

#[tokio::test]
async fn a_pending_reset_seven_days_past_held_until_ends_and_its_keys_go() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let proposed = propose_reset(&a, ResetKind::KeepScopeKeys).await;
    server.advance_clock(14 * DAY_US);

    let state = a.pending_reset_state().await;
    let late = a.service.activate_reset(proposed.reset).await.unwrap_err();

    assert_eq!(state, Some(ResetState::Superseded));
    assert!(a.service.reset_keys(proposed.reset).await.unwrap().is_none());
    assert_eq!(late, rejected(RejectedCode::BadStatement));
}

// The proposal's answer was lost, so this device holds it as a candidate. The server serves a proposal of its own at
// that id, which the candidate gives way to, and a certificate to match: this device's reset keys decide what its own
// activation is, so nothing of the server's is adopted.
#[tokio::test]
async fn a_served_proposal_and_certificate_are_never_adopted_as_this_device_s_activation() {
    use tablepro_keys::body::{AccountBody, DeviceBody, KeyObject, ResetBody};
    use tablepro_keys::cert::{AccountCertificate, CertKind, DeviceCertificate};
    use tablepro_keys::keys::{AccountKeys, DeviceKeys, Ed25519Seed};

    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let ik = a.pin(account).await.unwrap().ik;
    let draft = a.service.begin_reset(ResetKind::KeepScopeKeys).await.unwrap();
    a.wire.fail_next_push(TransportError::Network {
        detail: "offline".to_owned(),
    });
    let proposed = a
        .service
        .finish_reset_proposal(draft.draft, typed_back(&draft))
        .await
        .unwrap();
    let av = tablepro_keys::encoding::Version::new(2).unwrap();
    let (server_ik, keys, device) = (
        Ed25519Seed::generate().unwrap(),
        AccountKeys::generate().unwrap(),
        DeviceKeys::generate().unwrap(),
    );
    let certificate = AccountCertificate::sign(
        &crate::harness::origin(),
        account,
        av,
        CertKind::ResetKeepingKeys,
        &server_ik,
        keys.public().unwrap(),
        None,
    )
    .unwrap();
    let device_certificate = DeviceCertificate::sign(
        &crate::harness::origin(),
        account,
        av,
        device.key_device,
        device.dek.public().unwrap(),
        device.dsk.public().unwrap(),
        &keys.ask,
    )
    .unwrap();
    let body = ResetBody {
        av,
        key_device: device.key_device,
        account: AccountBody::of(&certificate),
        device: DeviceBody::of(&device_certificate),
        recovery: RecoveryKey::generate()
            .unwrap()
            .seal_blob(&crate::harness::origin(), account, av, &keys)
            .unwrap(),
    };
    let id = KeyRecordId::Reset {
        account,
        reset: proposed.reset,
    };
    let served_proposal = KeyObject {
        id,
        body: KeyBody::Reset(Box::new(body)),
    };
    let served_certificate = KeyObject {
        id: KeyRecordId::Account { account, av },
        body: KeyBody::Account(AccountBody::of(&certificate)),
    };
    let served_device = KeyObject {
        id: KeyRecordId::Device {
            account,
            key_device: device.key_device,
            av,
        },
        body: KeyBody::Device(DeviceBody::of(&device_certificate)),
    };

    a.service
        .apply_reset_objects(crate::harness::arrival(vec![crate::harness::served(&served_proposal)]))
        .await
        .unwrap();
    a.service
        .apply_account_objects(crate::harness::arrival(vec![
            crate::harness::served(&served_certificate),
            crate::harness::served(&served_device),
        ]))
        .await
        .unwrap();
    a.service
        .apply_reset_objects(crate::harness::arrival(vec![tombstone("key.reset", &id.to_wire())]))
        .await
        .unwrap();
    a.service.resume_reset(proposed.reset).await.ok();

    assert_eq!(a.pin(account).await.unwrap().ik, ik);
    assert_ne!(a.pending_reset_state().await, Some(ResetState::Active));
}

// The adoption after a pull failed half way: the activation is still this device's, so resume adopts it, however long
// after `held_until`.
#[tokio::test]
async fn an_own_activation_whose_adoption_failed_is_adopted_on_resume_even_late() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let proposed = propose_reset(&a, ResetKind::KeepScopeKeys).await;
    server.advance_clock(7 * DAY_US);
    a.wire.lose_next_answer();
    a.service.activate_reset(proposed.reset).await.unwrap_err();
    a.pull().await;
    let id = KeyRecordId::Reset {
        account,
        reset: proposed.reset,
    };
    a.fail_next_device_keys_write();
    let failed = a
        .service
        .apply_reset_objects(crate::harness::arrival(vec![tombstone("key.reset", &id.to_wire())]))
        .await;
    server.advance_clock(14 * DAY_US);

    a.service.resume_reset(proposed.reset).await.unwrap();
    a.server_approves().await;

    assert!(failed.is_err());
    assert_eq!(a.pending_reset_state().await, Some(ResetState::Active));
    assert_eq!(a.av().await, 2);
}

// A proposal sent again and refused ends: its keys, candidate and row go, and a new reset can start.
#[tokio::test]
async fn a_proposal_refused_when_sent_again_ends() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let draft = a.service.begin_reset(ResetKind::KeepScopeKeys).await.unwrap();
    a.wire.fail_next_push(TransportError::Network {
        detail: "offline".to_owned(),
    });
    let held = a
        .service
        .finish_reset_proposal(draft.draft, typed_back(&draft))
        .await
        .unwrap();
    a.wire.refuse_next_push(RejectedCode::BadStatement);

    let refused = a.service.resume_reset(held.reset).await.unwrap_err();

    assert_eq!(refused, rejected(RejectedCode::BadStatement));
    assert!(a.service.reset_keys(held.reset).await.unwrap().is_none());
    assert!(a.service.begin_reset(ResetKind::KeepScopeKeys).await.is_ok());
}

// The server answers `reset_held` to a device whose clock runs ahead: the built activation stays and goes up again
// unchanged after the wait.
#[tokio::test]
async fn a_server_reset_held_answer_keeps_the_activation_as_built() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let proposed = propose_reset(&a, ResetKind::KeepScopeKeys).await;
    a.advance(7 * DAY_US);
    a.wire.refuse_next_push(RejectedCode::ResetHeld);

    let early = a.service.activate_reset(proposed.reset).await.unwrap_err();
    let first = a.wire.last_push_by_id();
    a.advance(-7 * DAY_US);
    server.advance_clock(7 * DAY_US);
    a.service.activate_reset(proposed.reset).await.unwrap();
    let second = a.wire.last_push_by_id();

    assert_eq!(early, rejected(RejectedCode::ResetHeld));
    assert_eq!(first, second);
}
