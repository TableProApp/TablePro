use secrecy::{ExposeSecret, SecretString};
use serde_json::json;
use tablepro_keys::KeysError;
use tablepro_keys::encoding::{AccountId, KeyDeviceId, Origin, RequestId, TeamId, Version};
use tablepro_keys::envelope::EnvelopeId;
use tablepro_keys::keys::Ed25519Public;
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::key_flows::Acceptance;
use tablepro_sync::api::key_flows::{
    AccountDevice, AccountFlows, ApprovalFlows, ApprovalRequest, CancelWith, DeviceFlows, GenesisOutcome, KeyState,
    MemberKeyStatus, RecoveryKeyDraft, ResetFlows, ResetKind, ResetState, SessionEnd, SessionPhase, StopAction,
    StopFlows, TeamFlows, TypedBack,
};
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::transport::{RejectedCode, TransportError};
use uuid::Uuid;

use super::{FakeKeyFlows, RESET_HOLD_US, SESSION_US, groups};

fn flows() -> FakeKeyFlows {
    FakeKeyFlows::new(
        Origin::parse("https://api.tablepro.app").unwrap(),
        AccountId(Uuid::from_u128(1)),
    )
}

fn typed(draft: &RecoveryKeyDraft) -> TypedBack {
    let groups = groups(&draft.text);
    TypedBack {
        groups: draft
            .check
            .map(|index| SecretString::from(groups[usize::from(index)].to_lowercase())),
    }
}

async fn with_keys() -> FakeKeyFlows {
    let flows = flows();
    let draft = flows.begin_genesis().await.unwrap();
    flows.finish_genesis(draft.draft, typed(&draft)).await.unwrap();
    flows
}

fn envelope() -> EnvelopeId {
    EnvelopeId::parse("connection/6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44/password").unwrap()
}

#[tokio::test]
async fn genesis_shows_r_and_pushes_only_once_two_groups_are_typed_back() {
    let flows = flows();
    let draft = flows.begin_genesis().await.unwrap();
    let mut wrong = typed(&draft);
    wrong.groups[1] = SecretString::from("ZZZZ".to_owned());

    let refused = flows.finish_genesis(draft.draft, wrong).await;
    let created = flows.finish_genesis(draft.draft, typed(&draft)).await.unwrap();

    assert_eq!(draft.text.expose_secret().split('-').count(), 14);
    assert_ne!(draft.check[0], draft.check[1]);
    assert_eq!(refused.unwrap_err(), SyncError::TypedBackWrong);
    assert_eq!(created, GenesisOutcome::Created);
    assert!(matches!(flows.key_state().await.unwrap(), KeyState::Approved { av, .. } if av.get() == 1));
    assert!(flows.begin_genesis().await.is_err());
}

#[tokio::test]
async fn a_genesis_that_lost_to_another_device_asks_for_approval() {
    let flows = flows();
    flows.another_device_wins_genesis();
    let draft = flows.begin_genesis().await.unwrap();

    let outcome = flows.finish_genesis(draft.draft, typed(&draft)).await.unwrap();

    assert_eq!(outcome, GenesisOutcome::AnotherDeviceWon);
    assert!(matches!(
        flows.key_state().await.unwrap(),
        KeyState::NeedsApproval { .. }
    ));
}

#[tokio::test]
async fn a_new_device_s_session_runs_open_compare_approved() {
    let flows = flows();
    flows.account_has_keys();
    let request = flows.request_approval().await.unwrap();

    let open = flows.approval_session(request).await.unwrap();
    let second = flows.request_approval().await;
    let early = flows.confirm_session(request).await;
    flows.approver_chose(request);
    let compare = flows.approval_session(request).await.unwrap();
    let approved = flows.confirm_session(request).await.unwrap();

    assert_eq!(open.phase, SessionPhase::Open);
    assert_eq!(
        second.unwrap_err(),
        SyncError::Rejected {
            code: RejectedCode::RequestPending
        }
    );
    assert_eq!(early.unwrap_err(), SyncError::Keys(KeysError::Session));
    assert!(matches!(compare.phase, SessionPhase::Compare { ref words } if words.len() == 5));
    assert_eq!(approved.phase, SessionPhase::Approved);
    assert!(matches!(flows.key_state().await.unwrap(), KeyState::Approved { .. }));
}

#[tokio::test]
async fn a_session_that_ended_takes_no_step_and_one_expires_after_ten_minutes() {
    let flows = flows();
    flows.account_has_keys();
    let request = flows.request_approval().await.unwrap();
    flows.approver_chose(request);

    flows.words_differ(request).await.unwrap();
    let after = flows.confirm_session(request).await;
    let ended = flows.approval_session(request).await.unwrap();
    let next = flows.request_approval().await.unwrap();
    flows.advance_clock(SESSION_US);

    assert_eq!(after.unwrap_err(), SyncError::Keys(KeysError::Session));
    assert_eq!(
        ended.phase,
        SessionPhase::Cancelled {
            reason: SessionEnd::Mismatch
        }
    );
    assert_eq!(flows.approval_session(next).await.unwrap().phase, SessionPhase::Expired);
}

#[tokio::test]
async fn an_approver_holds_a_session_unless_another_wrote_its_nonce_first() {
    let flows = with_keys().await;
    let now = flows.now_us();
    let mine = RequestId(Uuid::new_v4());
    let theirs = RequestId(Uuid::new_v4());
    for request in [mine, theirs] {
        flows.incoming_request(ApprovalRequest {
            request,
            device: None,
            device_name: Some("iPhone".to_owned()),
            platform: Some("ios".to_owned()),
            requested_at_us: now,
        });
    }
    flows.taken_by_another_approver(theirs);

    let listed = flows.approval_requests().await.unwrap();
    let chosen = flows.choose_request(mine).await.unwrap();
    let taken = flows.choose_request(theirs).await.unwrap();
    let done = flows.confirm_session(mine).await.unwrap();

    assert_eq!(listed.len(), 2);
    assert!(matches!(chosen.phase, SessionPhase::Compare { .. }));
    assert_eq!(taken.phase, SessionPhase::TakenElsewhere);
    assert_eq!(done.phase, SessionPhase::Approved);
    assert!(flows.approval_requests().await.unwrap().is_empty());
}

#[tokio::test]
async fn replace_needs_the_current_recovery_key_and_moves_the_account_on() {
    let flows = with_keys().await;
    let current = flows.recovery_key().unwrap();
    let other = tablepro_keys::recovery::RecoveryKey::generate()
        .unwrap()
        .to_text()
        .unwrap();

    let refused = flows.begin_replace(other).await;
    let draft = flows.begin_replace(current.clone()).await.unwrap().recovery;
    flows
        .finish_replace(draft.draft, typed(&draft), Vec::new())
        .await
        .unwrap();

    assert!(refused.is_err());
    assert_eq!(
        flows.recovery_key().unwrap().expose_secret(),
        draft.text.expose_secret()
    );
    assert!(matches!(flows.key_state().await.unwrap(), KeyState::Approved { av, .. } if av.get() == 2));
}

#[tokio::test]
async fn removing_a_device_needs_a_step_up_then_r_and_keeps_only_compared_devices() {
    let flows = with_keys().await;
    let lost = KeyDeviceId(Uuid::new_v4());
    let kept = KeyDeviceId(Uuid::new_v4());
    let never_compared = KeyDeviceId(Uuid::new_v4());
    for (key_device, compared) in [(lost, true), (kept, true), (never_compared, false)] {
        flows.add_device(AccountDevice {
            key_device,
            device: None,
            name: None,
            platform: None,
            added_at_us: None,
            this_device: false,
            compared,
        });
    }
    let row = tablepro_sync::api::ids::DeviceRowId("dev_lost".to_owned());

    let without = flows.remove_device_row(row.clone()).await;
    flows.set_step_up(true);
    flows.remove_device_row(row).await.unwrap();
    let review = flows
        .begin_removal(flows.recovery_key().unwrap(), vec![lost])
        .await
        .unwrap();
    let by_default: Vec<_> = review
        .devices
        .iter()
        .filter(|device| device.keep_by_default)
        .map(|device| device.device.key_device)
        .collect();
    let refused = flows
        .finish_removal(review.review, vec![never_compared], Vec::new())
        .await;
    let review = flows
        .begin_removal(flows.recovery_key().unwrap(), vec![lost])
        .await
        .unwrap();
    flows
        .finish_removal(review.review, vec![kept], Vec::new())
        .await
        .unwrap();

    assert!(matches!(
        without,
        Err(SyncError::Transport(TransportError::StepUpRequired(_)))
    ));
    assert_eq!(by_default, [kept]);
    assert_eq!(refused.unwrap_err(), SyncError::Keys(KeysError::NotCompared));
    let left: Vec<_> = flows
        .account_devices()
        .await
        .unwrap()
        .iter()
        .map(|device| device.key_device)
        .collect();
    assert_eq!(left, [kept]);
}

#[tokio::test]
async fn a_reset_waits_seven_days_and_can_be_cancelled_meanwhile() {
    let flows = with_keys().await;
    let draft = flows.begin_reset(ResetKind::KeepScopeKeys).await.unwrap();
    let pending = flows.finish_reset_proposal(draft.draft, typed(&draft)).await.unwrap();

    let second = flows.begin_reset(ResetKind::KeepScopeKeys).await;
    let early = flows.activate_reset(pending.reset).await;
    flows.cancel_reset(pending.reset, CancelWith::ThisDevice).await.unwrap();
    let cancelled = flows.pending_reset().await.unwrap().unwrap();

    assert_eq!(pending.held_until_us - pending.taken_at_us, RESET_HOLD_US);
    assert_eq!(
        second.unwrap_err(),
        SyncError::Rejected {
            code: RejectedCode::BadStatement
        }
    );
    assert_eq!(
        early.unwrap_err(),
        SyncError::Rejected {
            code: RejectedCode::ResetHeld
        }
    );
    assert_eq!(cancelled.state, ResetState::Cancelled);
}

#[tokio::test]
async fn a_reset_activates_after_its_hold_and_ends_unactivated_seven_days_later() {
    let flows = with_keys().await;
    let draft = flows.begin_reset(ResetKind::KeepScopeKeys).await.unwrap();
    let pending = flows.finish_reset_proposal(draft.draft, typed(&draft)).await.unwrap();
    flows.advance_clock(RESET_HOLD_US);
    flows.activate_reset(pending.reset).await.unwrap();

    let later = with_keys().await;
    let stale_draft = later.begin_reset(ResetKind::KeepScopeKeys).await.unwrap();
    let stale = later
        .finish_reset_proposal(stale_draft.draft, typed(&stale_draft))
        .await
        .unwrap();
    later.advance_clock(2 * RESET_HOLD_US);

    assert_eq!(flows.pending_reset().await.unwrap().unwrap().state, ResetState::Active);
    assert_eq!(
        flows.recovery_key().unwrap().expose_secret(),
        draft.text.expose_secret()
    );
    assert!(matches!(flows.key_state().await.unwrap(), KeyState::Approved { av, .. } if av.get() == 2));
    assert_eq!(
        later.pending_reset().await.unwrap().unwrap().state,
        ResetState::Superseded
    );
    assert!(later.activate_reset(stale.reset).await.is_err());
}

#[tokio::test]
async fn a_reset_that_starts_empty_comes_from_an_unapproved_sign_in_with_a_step_up() {
    let approved = with_keys().await;
    let unapproved = flows();
    unapproved.account_has_keys();

    let from_approved = approved.begin_reset(ResetKind::StartEmpty).await;
    let without_step_up = unapproved.begin_reset(ResetKind::StartEmpty).await;
    unapproved.set_step_up(true);
    let stepped_up = unapproved.begin_reset(ResetKind::StartEmpty).await;
    let keep_from_sign_in = unapproved.begin_reset(ResetKind::KeepScopeKeys).await;

    assert_eq!(
        from_approved.unwrap_err(),
        SyncError::Rejected {
            code: RejectedCode::BadStatement
        }
    );
    assert!(matches!(
        without_step_up,
        Err(SyncError::Transport(TransportError::StepUpRequired(_)))
    ));
    assert!(stepped_up.is_ok());
    assert_eq!(
        keep_from_sign_in.unwrap_err(),
        SyncError::Rejected {
            code: RejectedCode::BadStatement
        }
    );
}

#[tokio::test]
async fn only_an_owner_or_admin_confirms_and_nothing_goes_to_a_member_under_an_alert() {
    let flows = with_keys().await;
    let team = TeamId(Uuid::new_v4());
    let ana = AccountId(Uuid::from_u128(2));
    let bo = AccountId(Uuid::from_u128(3));
    flows.add_team(
        team,
        Role::Owner,
        &[
            (ana, Role::Editor, MemberKeyStatus::AwaitingConfirmation),
            (bo, Role::Member, MemberKeyStatus::NoKeys),
        ],
    );
    flows.create_team_keys(team).await.unwrap();

    flows.confirm_member(team, ana).await.unwrap();
    let no_keys = flows.confirm_member(team, bo).await;
    flows.raise_alert(ana);
    let under_alert = flows.confirm_member(team, ana).await;
    let change = flows.key_change(ana).await.unwrap().unwrap();
    let stale = Ed25519Public([9; 32]);
    let wrong = flows.accept_key_change(ana, stale, Acceptance::Compared).await;
    flows
        .accept_key_change(ana, change.offered_ik, Acceptance::Compared)
        .await
        .unwrap();
    flows.confirm_member(team, ana).await.unwrap();

    assert!(no_keys.is_err());
    assert!(under_alert.is_err());
    assert!(wrong.is_err());
    assert_ne!(change.pinned.words, change.offered.words);
    assert!(flows.key_change(ana).await.unwrap().is_none());
    let keys = flows.team_keys(team).await.unwrap();
    assert_eq!(keys.version, Some(Version::new(1).unwrap()));
    assert!(
        keys.members
            .iter()
            .any(|member| member.account == ana && member.status == MemberKeyStatus::Holder)
    );
}

#[tokio::test]
async fn a_member_rotates_only_while_due_and_an_owner_restarts_only_with_no_holder() {
    let flows = with_keys().await;
    let team = TeamId(Uuid::new_v4());
    let ana = AccountId(Uuid::from_u128(2));
    flows.add_team(
        team,
        Role::Owner,
        &[(ana, Role::Editor, MemberKeyStatus::AwaitingConfirmation)],
    );
    flows.create_team_keys(team).await.unwrap();
    flows.confirm_member(team, ana).await.unwrap();

    let restart = flows.restart_team(team, vec![ana]).await;
    flows.rotate_team(team, vec![ana]).await.unwrap();

    assert_eq!(
        restart.unwrap_err(),
        SyncError::Rejected {
            code: RejectedCode::Role
        }
    );
    let keys = flows.team_keys(team).await.unwrap();
    assert_eq!(keys.version, Some(Version::new(2).unwrap()));
    assert!(
        keys.members
            .iter()
            .all(|member| member.status == MemberKeyStatus::AwaitingConfirmation)
    );
}

#[tokio::test]
async fn an_envelope_is_sealed_under_the_newest_version_and_never_taken_below_one_held() {
    let flows = with_keys().await;
    let old = flows
        .seal_personal_envelope(envelope(), SecretString::from("old".to_owned()), json!({"host": "db"}))
        .await
        .unwrap();
    for _ in 0..2 {
        let draft = flows
            .begin_replace(flows.recovery_key().unwrap())
            .await
            .unwrap()
            .recovery;
        flows
            .finish_replace(draft.draft, typed(&draft), Vec::new())
            .await
            .unwrap();
    }
    let newest = flows
        .seal_personal_envelope(
            envelope(),
            SecretString::from("hunter2".to_owned()),
            json!({"host": "db"}),
        )
        .await
        .unwrap();

    let opened = flows
        .open_personal_envelope(envelope(), newest.clone(), None)
        .await
        .unwrap();
    let older = flows.open_personal_envelope(envelope(), old.clone(), None).await;
    let in_force = Some(Version::new(2).unwrap());
    let below_in_force = flows.open_personal_envelope(envelope(), old, in_force).await;
    let above_in_force = flows.open_personal_envelope(envelope(), newest, in_force).await;

    assert_eq!(opened.kv.get(), 3);
    assert_eq!(opened.secret.expose_secret(), "hunter2");
    assert_eq!(opened.dest, json!({"host": "db"}));
    assert!(matches!(
        older,
        Err(SyncError::Keys(KeysError::Stale { held: 3, offered: 1 }))
    ));
    assert!(matches!(below_in_force, Err(SyncError::Keys(KeysError::Stale { .. }))));
    assert!(matches!(above_in_force, Err(SyncError::Keys(KeysError::Step { .. }))));
}

#[tokio::test]
async fn a_team_envelope_waits_while_the_team_is_due_a_rotation() {
    let flows = with_keys().await;
    let team = TeamId(Uuid::new_v4());
    flows.add_team(team, Role::Owner, &[]);
    flows.create_team_keys(team).await.unwrap();
    let id = EnvelopeId::parse("library_connection/6f1c2a9e-0b4d-4c8e-9a51-3d7e2b1f0c44/password").unwrap();
    flows
        .roster_read(
            team,
            tablepro_sync::api::key_flows::Roster {
                members: Vec::new(),
                role: Some(Role::Owner),
                rotation_due: true,
                caught_up: true,
            },
        )
        .await
        .unwrap();

    let held = flows
        .seal_team_envelope(team, id.clone(), SecretString::from("x".to_owned()), json!({}))
        .await;
    flows.rotate_team(team, Vec::new()).await.unwrap();
    let sealed = flows
        .seal_team_envelope(team, id, SecretString::from("x".to_owned()), json!({}))
        .await
        .unwrap();

    assert_eq!(
        held.unwrap_err(),
        SyncError::Rejected {
            code: RejectedCode::RotationDue
        }
    );
    assert_eq!(sealed["kv"], json!(2));
}

#[tokio::test]
async fn a_withdrawal_settles_before_a_new_report_for_its_team() {
    let flows = with_keys().await;
    let team = TeamId(Uuid::new_v4());
    let report = StopAction::Report {
        team,
        version: Version::new(5).unwrap(),
    };
    let withdraw = StopAction::Withdraw { team };
    flows.queue_stop_action(report);
    flows.queue_stop_action(withdraw);

    let actions = flows.stop_actions().await.unwrap();
    flows.stop_action_sent(withdraw).await.unwrap();

    assert_eq!(actions, [withdraw, report]);
    assert_eq!(flows.stop_actions().await.unwrap(), [report]);
}

#[tokio::test]
async fn a_signed_out_device_is_a_new_device_and_offline_still_erases() {
    let flows = with_keys().await;
    flows.set_offline(true);

    let outcome = flows.sign_out().await.unwrap();

    assert_eq!(outcome, tablepro_sync::api::key_flows::SignOutOutcome::ErasedOffline);
    assert!(matches!(
        flows.key_state().await.unwrap(),
        KeyState::NeedsApproval { request: None }
    ));
}

#[tokio::test]
async fn fingerprints_are_six_words_and_their_qr_compares() {
    let flows = with_keys().await;
    let ana = AccountId(Uuid::from_u128(2));

    let own = flows.own_fingerprint().await.unwrap();
    let theirs = flows.fingerprint(ana).await.unwrap();

    assert_eq!(own.words.len(), 6);
    assert!(theirs.qr.starts_with("TPF1:"));
    assert!(flows.compare_qr(ana, theirs.qr.clone()).await.unwrap());
    assert!(!flows.compare_qr(ana, own.qr).await.unwrap());
}

#[tokio::test]
async fn a_rotation_ends_a_pending_reset_and_moves_history_to_the_new_version() {
    let flows = with_keys().await;
    let draft = flows.begin_reset(ResetKind::KeepScopeKeys).await.unwrap();
    let pending = flows.finish_reset_proposal(draft.draft, typed(&draft)).await.unwrap();
    let again = flows.finish_reset_proposal(draft.draft, typed(&draft)).await;

    let replace = flows
        .begin_replace(flows.recovery_key().unwrap())
        .await
        .unwrap()
        .recovery;
    flows
        .finish_replace(replace.draft, typed(&replace), Vec::new())
        .await
        .unwrap();
    flows.advance_clock(RESET_HOLD_US);
    let entry = tablepro_keys::encoding::HistoryId(Uuid::new_v4());
    let sealed = flows
        .seal_history_entry(entry, json!({"query": "select 1"}))
        .await
        .unwrap();

    assert!(again.is_err());
    assert_eq!(
        flows.pending_reset().await.unwrap().unwrap().state,
        ResetState::Superseded
    );
    assert!(flows.activate_reset(pending.reset).await.is_err());
    assert_eq!(sealed["kv"], json!(2));
}

#[tokio::test]
async fn a_refused_push_back_of_a_version_ends_the_team_and_a_refused_confirmation_does_not() {
    use tablepro_sync::api::ids::{KindName, ScopeName};
    use tablepro_sync::api::key_flows::{KeyChangeSet, PushBackVerdict, RestoreFlows};
    use tablepro_sync::api::transport::{Change, ChangeOp, ChangeOutcome, DpopKey};

    let flows = with_keys().await;
    let team = TeamId(Uuid::new_v4());
    flows.add_team(team, Role::Owner, &[]);
    flows.create_team_keys(team).await.unwrap();
    let set = |kind: &str| KeyChangeSet {
        scope: ScopeName::Team(team),
        changes: vec![Change {
            kind: KindName::parse(kind).unwrap(),
            record_id: "x".to_owned(),
            base: None,
            op: ChangeOp::Delete,
        }],
        proof: DpopKey(std::sync::Arc::new(
            tablepro_keys::keys::Ed25519Seed::generate().unwrap(),
        )),
    };
    let refused = || {
        vec![ChangeOutcome::Rejected {
            code: RejectedCode::Role,
        }]
    };

    let confirmation = flows.push_back_answered(set("key.wrap"), refused()).await.unwrap();
    let version = flows.push_back_answered(set("key.version"), refused()).await.unwrap();

    assert_eq!(confirmation, PushBackVerdict::Continue);
    assert_eq!(
        version,
        PushBackVerdict::Ended {
            scope: ScopeName::Team(team)
        }
    );
    assert_eq!(
        flows.team_keys(team).await.unwrap().state,
        tablepro_sync::api::state::KeyVersionState::Ended
    );
    assert!(flows.rotate_team(team, Vec::new()).await.is_err());
}

#[tokio::test]
async fn a_restart_wraps_to_no_member_under_an_alert() {
    let flows = with_keys().await;
    let team = TeamId(Uuid::new_v4());
    let ana = AccountId(Uuid::from_u128(2));
    flows.add_team(
        team,
        Role::Owner,
        &[(ana, Role::Editor, MemberKeyStatus::AwaitingConfirmation)],
    );
    flows.raise_alert(ana);

    flows.restart_team(team, vec![ana]).await.unwrap();

    let keys = flows.team_keys(team).await.unwrap();
    assert!(keys.holder);
    assert_eq!(keys.members[0].status, MemberKeyStatus::Alert);
}

#[tokio::test]
async fn a_new_approval_after_sign_out_takes_a_new_key_device() {
    let flows = with_keys().await;
    let before = flows.key_device();

    flows.sign_out().await.unwrap();

    assert_ne!(flows.key_device(), before);
}
