// Reset (0056, Account flows): the proposal every device sees, the cancel by a certified device or by R, and the
// activation from the proposing device once the wait passed.

use secrecy::SecretString;
use tablepro_keys::body::KeyBody;
use tablepro_keys::encoding::KeyPurpose;
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::scope_key::{KeyRef, Start};
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::key_flows::{CancelWith, KeyNoticeKind, ResetFlows, ResetKind, ResetState, TypedBack};
use tablepro_sync::api::transport::{RejectedCode, StepUpChallenge, TransportError};
use tablepro_sync_testing::FakeServer;
use tablepro_sync_testing::key_flows::HookCall;

use crate::harness::{Device, approve, new_account, propose_reset, stored, typed_back};

const DAY_US: i64 = 24 * 3600 * 1_000_000;

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
async fn an_activation_before_held_until_is_reset_held_and_goes_up_unchanged_after_the_wait() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let proposed = propose_reset(&a, ResetKind::KeepScopeKeys).await;
    a.wire.refuse_next_push(RejectedCode::ResetHeld);

    let early = a.service.activate_reset(proposed.reset).await.unwrap_err();
    let first = a.wire.last_push_by_id();
    a.advance(7 * DAY_US);
    a.service.activate_reset(proposed.reset).await.unwrap();
    let second = a.wire.last_push_by_id();

    assert_eq!(early, rejected(RejectedCode::ResetHeld));
    assert_eq!(first, second, "the same objects, sealed once");
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

#[tokio::test]
async fn a_kind_3_activation_starts_the_personal_and_history_keys_over_with_no_ring() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    let proposed = propose_reset(&d, ResetKind::StartEmpty).await;
    d.advance(7 * DAY_US);

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
    b.advance(7 * DAY_US);

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
    a.advance(14 * DAY_US);

    let state = a.pending_reset_state().await;
    let late = a.service.activate_reset(proposed.reset).await.unwrap_err();

    assert_eq!(state, Some(ResetState::Superseded));
    assert!(a.service.reset_keys(proposed.reset).await.unwrap().is_none());
    assert_eq!(late, rejected(RejectedCode::BadStatement));
}
