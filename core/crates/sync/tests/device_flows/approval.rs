// Approving a device (0056): the session as both people run it, and each refusal with its code.

use tablepro_keys::body::{KeyBody, KeyObject, WrapBody};
use tablepro_keys::encoding::WrapPurpose;
use tablepro_keys::keys::DeviceKeys;
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::trust::TrustPlaintext;
use tablepro_keys::wrap::{Wrap, Wrapper, device_target};
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::ids::{ChangeTag, KindName, ScopeName};
use tablepro_sync::api::key_flows::{
    AccountFlows, ApprovalFlows, ArrivalOrder, KeyArrival, KeyState, SessionEnd, SessionPhase,
};
use tablepro_sync::api::transport::{PulledRecord, RejectedCode};
use tablepro_sync_testing::FakeServer;

use crate::harness::{Device, approve, new_account, stored};

fn pulled(object: &KeyObject) -> PulledRecord {
    let fields = object.fields_json();
    PulledRecord {
        kind: KindName::parse(object.id.kind().name()).unwrap(),
        record_id: object.id.to_wire(),
        tag: ChangeTag::Service("tag".to_owned()),
        fields: Some(serde_json::from_str(&fields).unwrap()),
        fields_json: Some(fields),
        deleted: None,
        service: None,
    }
}

fn arrival(records: Vec<PulledRecord>) -> KeyArrival {
    KeyArrival {
        scope: ScopeName::Personal,
        records,
        order: ArrivalOrder::InOrder,
    }
}

#[tokio::test]
async fn an_approved_device_approves_a_new_one_after_both_see_the_same_words() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;

    let request = approve(&n, &a).await;

    assert_eq!(n.av().await, 1);
    let n_device = n.service.device_keys().await.unwrap().current.unwrap();
    let a_device = a.service.device_keys().await.unwrap().current.unwrap();
    assert_eq!(
        n.device_pins()
            .await
            .iter()
            .map(|pin| pin.key_device)
            .collect::<Vec<_>>(),
        vec![a_device.key_device]
    );
    assert!(
        a.device_pins()
            .await
            .iter()
            .any(|pin| pin.key_device == n_device.key_device)
    );
    assert_eq!(n.pin(account).await.unwrap().ik, a.pin(account).await.unwrap().ik);
    let id = KeyRecordId::Device {
        account,
        key_device: n_device.key_device,
        av: tablepro_keys::encoding::Version::FIRST,
    };
    assert!(stored(&server, account, "key.device", &id.to_wire()).is_some());
    assert_eq!(
        a.service.approval_session(request).await.unwrap().phase,
        SessionPhase::Approved
    );
}

#[tokio::test]
async fn a_second_open_request_from_one_row_is_request_pending() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    n.service.request_approval().await.unwrap();

    let second = n.service.request_approval().await.unwrap_err();

    assert_eq!(
        second,
        SyncError::Rejected {
            code: RejectedCode::RequestPending
        }
    );
}

#[tokio::test]
async fn an_approver_that_answers_second_finds_the_session_taken() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    b.pull().await;
    a.service.choose_request(request).await.unwrap();

    let second = b.service.choose_request(request).await.unwrap();
    b.pull().await;

    assert_eq!(second.phase, SessionPhase::TakenElsewhere);
    assert!(b.service.approval_requests().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_reveal_that_does_not_open_the_commitment_ends_the_session_with_a_commitment_cancel() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    a.service.choose_request(request).await.unwrap();
    let forged = KeyObject {
        id: KeyRecordId::Sas {
            request,
            step: tablepro_keys::record_id::SasStep::Reveal,
        },
        body: KeyBody::Sas(tablepro_keys::body::SasBody::Reveal { r: [0x5a; 32] }),
    };

    let applied = a
        .service
        .apply_session_objects(arrival(vec![pulled(&forged)]))
        .await
        .unwrap();
    a.service.resume_approval(request).await.unwrap();

    assert_eq!(
        applied
            .refused
            .iter()
            .map(|refused| refused.error.code())
            .collect::<Vec<_>>(),
        vec!["keys.commitment"]
    );
    assert_eq!(
        a.service.approval_session(request).await.unwrap().phase,
        SessionPhase::Cancelled {
            reason: SessionEnd::Commitment
        }
    );
    let cancel = stored(&server, account, "key.sas", &format!("{}/cancel", request.to_wire())).unwrap();
    assert!(cancel.fields_json().contains("\"commitment\""));
}

#[tokio::test]
async fn words_that_differ_end_the_session_with_a_mismatch_on_both_sides() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    a.service.choose_request(request).await.unwrap();
    n.pull().await;
    n.words(request).await;

    n.service.words_differ(request).await.unwrap();
    a.pull().await;

    let mismatch = SessionPhase::Cancelled {
        reason: SessionEnd::Mismatch,
    };
    assert_eq!(n.service.approval_session(request).await.unwrap().phase, mismatch);
    assert_eq!(a.service.approval_session(request).await.unwrap().phase, mismatch);
    assert_eq!(
        n.service.confirm_session(request).await.unwrap_err().code(),
        "keys.session"
    );
}

#[tokio::test]
async fn words_differ_before_any_words_is_keys_session() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();

    let error = n.service.words_differ(request).await.unwrap_err();

    assert_eq!(error.code(), "keys.session");
}

#[tokio::test]
async fn a_session_past_expires_at_takes_no_step() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    a.advance(600 * 1_000_000);

    let error = a.service.choose_request(request).await.unwrap_err();

    assert_eq!(error.code(), "keys.session");
    assert_eq!(
        a.service.approval_session(request).await.unwrap().phase,
        SessionPhase::Expired
    );
    assert!(a.service.approval_requests().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_cancel_from_either_side_ends_the_session_for_both() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    a.service.choose_request(request).await.unwrap();

    a.service.cancel_session(request).await.unwrap();
    n.pull().await;

    let user = SessionPhase::Cancelled {
        reason: SessionEnd::User,
    };
    assert_eq!(n.service.approval_session(request).await.unwrap().phase, user);
    assert_eq!(a.service.approval_session(request).await.unwrap().phase, user);
}

// A server-made approval: a device certificate the server replays at the new key device's id, with wraps signed by a
// key the new device never compared. N refuses it and keeps the keys it had.
#[tokio::test]
async fn an_approval_wrapped_under_a_dsk_the_new_device_did_not_compare_is_keys_not_compared() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    a.service.choose_request(request).await.unwrap();
    n.pull().await;
    n.words(request).await;
    a.pull().await;
    a.words(request).await;
    assert_eq!(
        n.service.confirm_session(request).await.unwrap().phase,
        SessionPhase::Confirmed
    );
    let pending = n.service.device_keys().await.unwrap().pending.unwrap();
    let mut txn = a.txn().await;
    let own = a.service.own_account(txn.as_mut()).await.unwrap().unwrap();
    drop(txn);
    let certificate = tablepro_keys::cert::DeviceCertificate::sign(
        &crate::harness::origin(),
        account,
        own.av,
        pending.key_device,
        pending.dek.public().unwrap(),
        pending.dsk.public().unwrap(),
        &own.keys.ask,
    )
    .unwrap();
    let server_key = DeviceKeys::generate().unwrap();
    let wrapper = Wrapper {
        account,
        av: own.av,
        key_device: own.device.key_device,
    };
    let account_wrap = Wrap::seal_account(
        &crate::harness::origin(),
        device_target(account, WrapPurpose::Account, own.av, pending.key_device),
        &pending.dek.public().unwrap(),
        &own.keys,
        wrapper,
        &server_key.dsk,
    )
    .unwrap();
    let trust_wrap = Wrap::seal_trust(
        &crate::harness::origin(),
        device_target(account, WrapPurpose::Trust, own.av, pending.key_device),
        &pending.dek.public().unwrap(),
        &TrustPlaintext::default(),
        wrapper,
        &server_key.dsk,
    )
    .unwrap();
    let objects = [
        KeyObject {
            id: KeyRecordId::Device {
                account,
                key_device: pending.key_device,
                av: own.av,
            },
            body: KeyBody::Device(tablepro_keys::body::DeviceBody::of(&certificate)),
        },
        KeyObject {
            id: KeyRecordId::Wrap(account_wrap.target),
            body: KeyBody::Wrap(WrapBody::of(&account_wrap)),
        },
        KeyObject {
            id: KeyRecordId::Wrap(trust_wrap.target),
            body: KeyBody::Wrap(WrapBody::of(&trust_wrap)),
        },
    ];
    n.service
        .apply_account_objects(arrival(objects.iter().map(pulled).collect()))
        .await
        .unwrap();

    let error = n.service.resume_approval(request).await.unwrap_err();

    assert_eq!(error.code(), "keys.not_compared");
    assert!(n.service.device_keys().await.unwrap().pending.is_none());
    assert!(!matches!(n.key_state().await, KeyState::Approved { .. }));
}

// A rotation that keeps A passes the `av` A built the approval at: the server refuses it, and A builds it again at
// the new `av` after its pull, which N then takes.
#[tokio::test]
async fn an_approval_built_at_an_av_a_rotation_passed_is_built_again_at_the_new_av() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    a.service.choose_request(request).await.unwrap();
    n.pull().await;
    n.words(request).await;
    a.pull().await;
    a.words(request).await;
    a.wire.refuse_next_push(RejectedCode::BadStatement);

    let confirmed = a.service.confirm_session(request).await.unwrap();
    crate::rotation::rotate_keeping_only_self(&a, &r).await;
    a.server_approves().await;
    a.pull().await;
    a.service.resume_approval(request).await.unwrap();
    n.pull().await;
    let merged = n.service.confirm_session(request).await.unwrap();

    assert_eq!(confirmed.phase, SessionPhase::Confirmed);
    assert_eq!(merged.phase, SessionPhase::Approved);
    n.server_approves().await;
    assert_eq!(n.av().await, 2);
}

#[tokio::test]
async fn a_device_that_already_holds_the_account_s_keys_does_not_ask() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;

    let error = a.service.request_approval().await.unwrap_err();

    assert_eq!(error.code(), "sync.not_allowed");
}

// A replace changes IK, which the words covered: the session ends, and N asks again.
#[tokio::test]
async fn a_replace_during_a_session_ends_it_with_keys_session() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    a.service.choose_request(request).await.unwrap();
    n.pull().await;
    n.words(request).await;
    a.pull().await;
    a.words(request).await;
    let draft = a.service.begin_replace(r).await.unwrap();
    a.service
        .finish_replace(
            draft.recovery.draft,
            crate::harness::typed_back(&draft.recovery),
            Vec::new(),
        )
        .await
        .unwrap();
    a.server_approves().await;
    a.pull().await;

    let error = a.service.confirm_session(request).await.unwrap_err();

    assert_eq!(error.code(), "keys.session");
}

// The approval applied before `expires_at`; N, offline until after it, still takes it once it pulls.
#[tokio::test]
async fn n_takes_an_approval_that_applied_in_time_however_late_it_pulls() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    a.service.choose_request(request).await.unwrap();
    n.pull().await;
    n.words(request).await;
    a.pull().await;
    a.words(request).await;
    n.service.confirm_session(request).await.unwrap();
    a.service.confirm_session(request).await.unwrap();
    n.advance(700 * 1_000_000);

    n.pull().await;
    let session = n.service.approval_session(request).await.unwrap();

    assert_eq!(session.phase, SessionPhase::Approved);
}

// A device a rotation left out asks again: a new key device id, its old keys kept until the approval applies, and
// the approver as its only own-device pin.
#[tokio::test]
async fn a_device_left_out_of_a_rotation_is_approved_again_under_a_new_key_device() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let before = b.service.device_keys().await.unwrap().current.unwrap().key_device;
    crate::rotation::rotate_keeping_only_self(&a, &r).await;
    a.server_approves().await;
    b.pull().await;

    approve(&b, &a).await;

    let after = b.service.device_keys().await.unwrap().current.unwrap().key_device;
    let a_device = a.service.device_keys().await.unwrap().current.unwrap().key_device;
    assert_ne!(after, before);
    assert_eq!(b.av().await, 2);
    assert_eq!(
        b.device_pins()
            .await
            .iter()
            .map(|pin| pin.key_device)
            .collect::<Vec<_>>(),
        vec![a_device]
    );
}

// A reset elsewhere leaves this device's own account under an IK it never saw endorsed, so it locks. Approved by the
// resetting device, it takes that device's pin and the lock clears.
#[tokio::test]
async fn a_device_locked_by_its_own_account_s_reset_is_approved_by_the_resetting_device() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let reset = crate::harness::propose_reset(&a, tablepro_sync::api::key_flows::ResetKind::KeepScopeKeys).await;
    server.advance_clock(7 * 24 * 3600 * 1_000_000);
    tablepro_sync::api::key_flows::ResetFlows::activate_reset(&a.service, reset.reset)
        .await
        .unwrap();
    a.server_approves().await;
    a.pull().await;
    b.pull().await;
    let locked = b.key_state().await;

    approve(&b, &a).await;

    assert!(matches!(locked, KeyState::Locked { .. }), "{locked:?}");
    assert_eq!(b.av().await, 2);
    assert_eq!(b.pin(account).await.unwrap().ik, a.pin(account).await.unwrap().ik);
}

async fn stop_personal(device: &Device) {
    let key = tablepro_sync::api::state::RowKey::KeyVersion(
        ScopeName::Personal,
        tablepro_keys::encoding::KeyPurpose::Personal,
    );
    let Some(tablepro_sync::api::state::Row::KeyVersion(mut row)) = device.get(key).await else {
        unreachable!("no personal key row")
    };
    row.stop(tablepro_sync::api::state::StoppedCause::CatchUp);
    let mut txn = device.txn().await;
    txn.put(tablepro_sync::api::state::Row::KeyVersion(row)).await.unwrap();
    txn.commit().await.unwrap();
}

// A personal stop clears only through an approval that brings the version signed under the current `av` (0056,
// Approving a device, step 7), so a stopped device must be able to ask.
#[tokio::test]
async fn a_device_stopped_on_its_personal_key_asks_again_and_the_approval_clears_the_stop() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    stop_personal(&b).await;
    let stopped = b.key_state().await;

    approve(&b, &a).await;

    assert_eq!(
        stopped,
        KeyState::Locked {
            cause: tablepro_sync::api::key_flows::LockCause::PersonalStopped
        }
    );
    assert_eq!(b.av().await, 1);
}

// A file with no anchor handles no secret until another device approves it again (0054, A stale file).
#[tokio::test]
async fn an_unanchored_device_asks_again_and_the_approval_clears_the_lock() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let b = b
        .reopen(crate::harness::opened_with(
            tablepro_sync::api::state::KeyTrust::Unanchored,
        ))
        .await;
    let unanchored = b.key_state().await;

    approve(&b, &a).await;

    assert_eq!(
        unanchored,
        KeyState::Locked {
            cause: tablepro_sync::api::key_flows::LockCause::Unanchored
        }
    );
    assert_eq!(b.av().await, 1);
}

#[tokio::test]
async fn an_approver_with_no_anchor_or_still_rebuilding_does_not_approve() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    let a = a
        .reopen(crate::harness::opened_with(
            tablepro_sync::api::state::KeyTrust::Unanchored,
        ))
        .await;
    a.pull().await;

    let unanchored = a.service.choose_request(request).await.unwrap_err();
    let listed = a.service.approval_requests().await.unwrap_err();
    let a = a
        .reopen(crate::harness::opened_with(
            tablepro_sync::api::state::KeyTrust::Rebuild {
                checkpoint: Box::default(),
            },
        ))
        .await;
    let rebuilding = a.service.choose_request(request).await.unwrap_err();

    assert_eq!(unanchored.code(), "sync.locked");
    assert_eq!(listed.code(), "sync.locked");
    assert_eq!(rebuilding.code(), "sync.not_allowed");
}

// The server applied the approval and its answer was lost: the retry sends the same objects, sealed once, and A
// keeps N as an own-device pin.
#[tokio::test]
async fn an_approval_whose_answer_was_lost_goes_up_again_unchanged_and_pins_the_new_device() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    a.service.choose_request(request).await.unwrap();
    n.pull().await;
    n.words(request).await;
    a.pull().await;
    a.words(request).await;
    a.wire.lose_next_answer();

    let lost = a.service.confirm_session(request).await.unwrap();
    let first = a.wire.last_push_by_id();
    a.service.resume_approval(request).await.unwrap();
    let second = a.wire.last_push_by_id();
    n.pull().await;
    let merged = n.service.confirm_session(request).await.unwrap();

    assert_eq!(lost.phase, SessionPhase::Confirmed);
    assert_eq!(first, second);
    assert_eq!(
        a.service.approval_session(request).await.unwrap().phase,
        SessionPhase::Approved
    );
    let pending = n.service.device_keys().await.unwrap().current.unwrap();
    assert!(
        a.device_pins()
            .await
            .iter()
            .any(|pin| pin.key_device == pending.key_device)
    );
    assert_eq!(merged.phase, SessionPhase::Approved);
}

async fn compared_session(n: &Device, a: &Device) -> tablepro_keys::encoding::RequestId {
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    a.service.choose_request(request).await.unwrap();
    n.pull().await;
    n.words(request).await;
    a.pull().await;
    a.words(request).await;
    a.service.confirm_session(request).await.unwrap();
    n.pull().await;
    request
}

// N's tables and its device keys cannot change in one write: whichever lands first, the merge finishes on resume.
#[tokio::test]
async fn a_merge_whose_commit_did_not_land_resumes() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    a.service.choose_request(request).await.unwrap();
    n.pull().await;
    n.words(request).await;
    a.pull().await;
    a.words(request).await;
    n.service.confirm_session(request).await.unwrap();
    a.service.confirm_session(request).await.unwrap();
    n.pull().await;
    n.fail_next_commit();

    let failed = n.service.resume_approval(request).await;
    n.service.resume_approval(request).await.unwrap();
    n.server_approves().await;

    assert!(failed.is_err());
    assert_eq!(
        n.service.approval_session(request).await.unwrap().phase,
        SessionPhase::Approved
    );
    assert_eq!(n.av().await, 1);
}

#[tokio::test]
async fn a_merge_whose_device_key_switch_did_not_land_resumes() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    let request = compared_session(&n, &a).await;
    n.fail_next_device_keys_write();

    let failed = n.service.confirm_session(request).await;
    n.service.resume_approval(request).await.unwrap();
    n.server_approves().await;

    assert!(failed.is_err());
    assert_eq!(n.av().await, 1);
}

// An approval replaces the device keys and the account keys a device held (0056, Keys, Erasing).
#[tokio::test]
async fn an_approval_erases_the_account_keys_the_device_held_before() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    crate::rotation::rotate_keeping_only_self(&a, &r).await;
    a.server_approves().await;
    b.pull().await;
    let old = tablepro_sync::api::device_store::DeviceItem::AccountKeys {
        origin: crate::harness::origin(),
        account,
        av: tablepro_keys::encoding::Version::FIRST,
    };
    let held_before = b.store.inner.holds(&old);

    approve(&b, &a).await;

    assert!(held_before);
    assert!(!b.store.inner.holds(&old));
    assert_eq!(b.av().await, 2);
}

// The server purges the request once the session ended; N, its device key switch still owed, keeps what it needs.
#[tokio::test]
async fn a_purge_after_the_merge_keeps_the_owed_device_key_switch() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    let request = compared_session(&n, &a).await;
    n.fail_next_device_keys_write();
    n.service.confirm_session(request).await.unwrap_err();
    let id = KeyRecordId::Request { request };

    n.service
        .apply_session_objects(crate::harness::arrival(vec![crate::harness::tombstone_of(
            "key.request",
            &id.to_wire(),
        )]))
        .await
        .unwrap();
    n.service.resume_approval(request).await.unwrap();
    n.server_approves().await;

    assert_eq!(n.av().await, 1);
}

// The approver's push met another copy at its ids: it waits for the pull instead of sealing again, and sends the same
// objects when it goes up again.
#[tokio::test]
async fn an_approval_refused_create_only_is_not_sealed_again() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    let request = n.service.request_approval().await.unwrap();
    a.pull().await;
    a.service.choose_request(request).await.unwrap();
    n.pull().await;
    n.words(request).await;
    a.pull().await;
    a.words(request).await;
    a.wire.refuse_next_push(RejectedCode::CreateOnly);

    let refused = a.service.confirm_session(request).await.unwrap();
    let first = a.wire.last_push_by_id();
    a.service.resume_approval(request).await.unwrap();
    let second = a.wire.last_push_by_id();

    assert_eq!(refused.phase, SessionPhase::Confirmed);
    assert_eq!(first, second);
    assert_eq!(
        a.service.approval_session(request).await.unwrap().phase,
        SessionPhase::Approved
    );
}

#[tokio::test]
async fn a_device_whose_rotation_still_settles_does_not_ask_for_approval() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    crate::harness::put_rows(
        &n,
        vec![tablepro_sync::api::state::Row::KeyPending(
            tablepro_sync::api::state::KeyPendingRow {
                flow: tablepro_sync::api::state::PendingFlow::AccountRotation {
                    av: tablepro_keys::encoding::Version::new(2).unwrap(),
                },
                state: Vec::new(),
            },
        )],
    )
    .await;

    let error = n.service.request_approval().await.unwrap_err();

    assert_eq!(error.code(), "sync.not_allowed");
}
