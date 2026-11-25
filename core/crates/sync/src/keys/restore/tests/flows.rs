// What a push-back answer does on the device: every refusal is final (0051, After a restore). An account set ends
// the account and locks it, a team version or `key.member` ends the team and withdraws its report, and a wrap alone
// ends nothing.

use tablepro_keys::encoding::KeyPurpose;
use tablepro_keys::scope_key::Start;

use super::fakes::{Hook, Rig, dpop, epoch};
use super::world::{World, v};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{KeyChangeSet, KeyNoticeKind, LockCause, PushBackVerdict, RestoreFlows};
use crate::api::state::{KeyVersionRow, KeyVersionState, PendingFlow, Row, RowKey, ScopeRow, StoppedCause};
use crate::api::transport::{AppliedStamp, ChangeOp, ChangeOutcome, RejectedCode};
use crate::keys::restore::push_back_change;
use crate::keys::{HeldObject, create_change};

const RESET_LOST: &str = "a completed reset a restore lost";

fn set(scope: ScopeName, objects: &[HeldObject]) -> KeyChangeSet {
    KeyChangeSet {
        scope,
        changes: objects.iter().map(|held| push_back_change(held).unwrap()).collect(),
        proof: dpop(),
    }
}

fn applied() -> ChangeOutcome {
    ChangeOutcome::Applied {
        tag: None,
        service: Some(AppliedStamp {
            version: 1,
            revision: 1,
        }),
    }
}

fn rejected(code: RejectedCode) -> ChangeOutcome {
    ChangeOutcome::Rejected { code }
}

fn row(scope: ScopeName, purpose: KeyPurpose, version: u32) -> Row {
    Row::KeyVersion(KeyVersionRow {
        scope,
        purpose,
        version: v(version),
        record: [1; 32],
        holders: Vec::new(),
        state: KeyVersionState::Ok,
        stopped_cause: None,
        epoch: None,
    })
}

fn scope_row(scope: ScopeName) -> Row {
    Row::Scope(ScopeRow {
        epoch: Some(epoch(2)),
        ..ScopeRow::new(scope)
    })
}

async fn version_row(rig: &Rig, scope: ScopeName, purpose: KeyPurpose) -> KeyVersionRow {
    match rig.get(&RowKey::KeyVersion(scope, purpose)).await {
        Some(Row::KeyVersion(row)) => row,
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_push_back_change_is_the_held_fields_as_a_create() {
    let world = World::load();
    let held = world.record(
        "a team version pushed back after a restore by its signer's device",
        "version 7 by A",
    );

    let change = push_back_change(&held).unwrap();

    assert_eq!(change.base, None);
    let ChangeOp::Write { fields, patch } = &change.op else {
        panic!()
    };
    let served: serde_json::Value = serde_json::from_str(&held.fields).unwrap();
    assert_eq!(fields, &served);
    assert_eq!(patch, &served);
    assert_eq!(change, create_change(&held.object).unwrap());
}

#[tokio::test]
async fn a_completed_reset_the_restore_lost_cannot_go_back_and_the_account_s_devices_lock() {
    let world = World::load();
    let rig = Rig::new(&world.origin, world.account("P"));
    rig.put([
        scope_row(ScopeName::Personal),
        row(ScopeName::Personal, KeyPurpose::Personal, 2),
        row(ScopeName::Personal, KeyPurpose::History, 2),
    ])
    .await;
    let reset = world.records_labelled(RESET_LOST, "P's reset proposal");
    let mut outcomes = vec![rejected(RejectedCode::ChangeSet); reset.len()];
    outcomes[0] = rejected(RejectedCode::BadStatement);

    let verdict = rig
        .service
        .push_back_answered(set(ScopeName::Personal, &reset), outcomes)
        .await
        .unwrap();

    assert_eq!(verdict, PushBackVerdict::AccountEnded);
    for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
        let ended = version_row(&rig, ScopeName::Personal, purpose).await;
        assert_eq!((ended.state, ended.epoch), (KeyVersionState::Ended, Some(epoch(2))));
    }
    assert_eq!(
        rig.hooks.without_notices(),
        [
            Hook::End(ScopeName::Personal, Some(epoch(2))),
            Hook::Lock(LockCause::AccountEnded)
        ]
    );
    assert!(rig.service.held_notices().iter().any(|notice| notice.kind
        == KeyNoticeKind::Locked {
            cause: LockCause::AccountEnded
        }));
}

#[tokio::test]
async fn a_refused_version_of_its_own_ends_the_team_for_good_and_withdraws_its_report() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("A"));
    rig.put([scope_row(team), row(team, KeyPurpose::Team, 7)]).await;
    let objects = [world.team_version(7, "A", 2, Start::Next), world.team_ring(7)];

    let verdict = rig
        .service
        .push_back_answered(
            set(team, &objects),
            vec![rejected(RejectedCode::CreateOnly), rejected(RejectedCode::ChangeSet)],
        )
        .await
        .unwrap();

    assert_eq!(verdict, PushBackVerdict::Ended { scope: team });
    let ended = version_row(&rig, team, KeyPurpose::Team).await;
    assert_eq!(
        (ended.state, ended.stopped_cause, ended.epoch),
        (KeyVersionState::Ended, None, Some(epoch(2)))
    );
    assert!(
        rig.get(&RowKey::KeyPending(PendingFlow::StopWithdrawal { team: world.team }))
            .await
            .is_some()
    );
    assert_eq!(rig.hooks.without_notices(), [Hook::End(team, Some(epoch(2)))]);
}

#[tokio::test]
async fn a_refused_key_member_ends_the_team() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("A"));
    rig.put([scope_row(team), row(team, KeyPurpose::Team, 6)]).await;

    let verdict = rig
        .service
        .push_back_answered(
            set(team, &[world.member("A", 2)]),
            vec![rejected(RejectedCode::BadStatement)],
        )
        .await
        .unwrap();

    assert_eq!(verdict, PushBackVerdict::Ended { scope: team });
}

#[tokio::test]
async fn a_lost_confirmation_a_plain_member_pushes_back_is_refused_with_role_and_ends_nothing() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("M"));
    rig.put([scope_row(team), row(team, KeyPurpose::Team, 6)]).await;
    let confirmation = world.record(
        "a lost confirmation pushed back by a plain member",
        "M's copy of the confirmation of P at version 6",
    );

    let verdict = rig
        .service
        .push_back_answered(set(team, &[confirmation]), vec![rejected(RejectedCode::Role)])
        .await
        .unwrap();

    assert_eq!(verdict, PushBackVerdict::Continue);
    assert_eq!(
        version_row(&rig, team, KeyPurpose::Team).await.state,
        KeyVersionState::Ok
    );
    assert!(rig.hooks.calls().is_empty());
}

#[tokio::test]
async fn an_applied_set_continues_and_an_answer_of_another_length_is_malformed() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("A"));
    let objects = [world.team_version(7, "A", 2, Start::Next), world.team_ring(7)];

    let continued = rig
        .service
        .push_back_answered(set(team, &objects), vec![applied(), applied()])
        .await
        .unwrap();
    let short = rig
        .service
        .push_back_answered(set(team, &objects), vec![applied()])
        .await;

    assert_eq!(continued, PushBackVerdict::Continue);
    assert_eq!(
        short.unwrap_err(),
        SyncError::Malformed {
            what: "push-back answer"
        }
    );
}

#[tokio::test]
async fn an_ended_scope_stays_ended_when_a_wait_would_stop_it() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("A"));
    rig.put([scope_row(team), row(team, KeyPurpose::Team, 7)]).await;
    rig.service
        .push_back_answered(
            set(team, &[world.team_version(7, "A", 2, Start::Next)]),
            vec![rejected(RejectedCode::CreateOnly)],
        )
        .await
        .unwrap();
    let mut txn = rig.service.begin().await.unwrap();

    let newly = rig
        .service
        .mark_stopped(&mut *txn, team, KeyPurpose::Team, StoppedCause::RestoreWait)
        .await
        .unwrap();
    txn.commit().await.unwrap();

    assert!(!newly);
    assert_eq!(
        version_row(&rig, team, KeyPurpose::Team).await.state,
        KeyVersionState::Ended
    );
}
