// What a push-back answer does on the device: every refusal is final (0051, After a restore). An account set ends
// the account and locks it, a team version or `key.member` ends the team and withdraws its report, and a wrap alone
// ends nothing.

use tablepro_keys::encoding::{KeyPurpose, TeamId};
use tablepro_keys::scope_key::Start;

use super::fakes::{Hook, Rig, dpop, epoch};
use super::world::{World, v};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{KeyChangeSet, KeyNoticeKind, LockCause, PushBackVerdict, RestoreFlows};
use crate::api::state::{KeyVersionRow, KeyVersionState, PendingFlow, Row, RowKey, ScopeRow, StoppedCause};
use crate::api::transport::{AppliedStamp, ChangeOp, ChangeOutcome, RejectedCode};
use crate::keys::restore::plan::{Plan, ServerView, TeamVerdict};
use crate::keys::restore::push_back_change;
use crate::keys::{HeldObject, create_change};

const RESET_LOST: &str = "a completed reset a restore lost";
const GENESIS: &str = "two genesis change sets, and an identical retry";

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

fn serving(rig: &Rig, epoch: crate::api::ids::EpochId) {
    *rig.transport.body.lock().unwrap() = Some(super::fakes::scopes(epoch, Vec::new()));
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
    serving(&rig, epoch(2));
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
    serving(&rig, epoch(5));
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
        (KeyVersionState::Ended, None, Some(epoch(5)))
    );
    assert!(
        rig.get(&RowKey::KeyPending(PendingFlow::StopWithdrawal { team: world.team }))
            .await
            .is_some()
    );
    assert_eq!(rig.hooks.without_notices(), [Hook::End(team, Some(epoch(5)))]);
}

#[tokio::test]
async fn a_refused_key_member_alone_ends_nothing() {
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

    assert_eq!(verdict, PushBackVerdict::Continue);
    assert_eq!(
        version_row(&rig, team, KeyPurpose::Team).await.state,
        KeyVersionState::Ok
    );
}

// 0064: a version naming a recipient whose `key.member` the server lacks can still go back once it is there, so the
// team waits rather than ends, and the versions above it wait with it.
#[tokio::test]
async fn a_version_set_refused_only_for_a_missing_certificate_waits_and_ends_nothing() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("A"));
    rig.put([scope_row(team), row(team, KeyPurpose::Team, 6)]).await;
    serving(&rig, epoch(5));
    let objects = [world.team_version(7, "A", 2, Start::Next), world.team_ring(7)];

    let verdict = rig
        .service
        .push_back_answered(
            set(team, &objects),
            vec![rejected(RejectedCode::KeyDependency), rejected(RejectedCode::ChangeSet)],
        )
        .await
        .unwrap();

    assert_eq!(verdict, PushBackVerdict::Wait { scope: team });
    let waiting = version_row(&rig, team, KeyPurpose::Team).await;
    assert_eq!(
        (waiting.state, waiting.stopped_cause),
        (KeyVersionState::Stopped, Some(StoppedCause::RestoreWait))
    );
}

#[tokio::test]
async fn a_refusal_the_server_cannot_name_an_epoch_for_is_still_recorded() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("A"));
    rig.put([row(team, KeyPurpose::Team, 7)]).await;
    let objects = [world.team_version(7, "A", 2, Start::Next)];

    rig.service
        .push_back_answered(set(team, &objects), vec![rejected(RejectedCode::CreateOnly)])
        .await
        .unwrap();

    let ended = version_row(&rig, team, KeyPurpose::Team).await;
    assert_eq!(
        (ended.state, ended.epoch),
        (KeyVersionState::Ended, None),
        "recorded with no epoch to name"
    );
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

fn info(scope: ScopeName) -> crate::api::scopes::ScopeInfo {
    crate::api::scopes::ScopeInfo {
        scope,
        role: None,
        horizon: 0,
        epochs: vec![crate::api::scopes::LineageEpoch {
            id: epoch(2),
            kept_revision: 0,
        }],
        writable: true,
        policies: crate::api::scopes::ScopePolicies::default(),
        quota: None,
        rotation_due: false,
        members: Vec::new(),
        stopped: Vec::new(),
        approved: Some(true),
    }
}

fn held_row(scope: ScopeName, held: &HeldObject) -> Row {
    Row::KeyObject(crate::api::state::KeyObjectRow {
        scope,
        kind: crate::api::ids::KindName::parse(held.object.id.kind().name()).unwrap(),
        record_id: held.object.id.to_wire(),
        fields: held.fields.clone(),
        applied: true,
        served: None,
    })
}

fn base_row(scope: ScopeName, held: &HeldObject) -> Row {
    Row::Base(crate::api::state::BaseRow {
        key: crate::api::ids::RecordKey::new(
            scope,
            crate::api::ids::KindName::parse(held.object.id.kind().name()).unwrap(),
            held.object.id.to_wire(),
        ),
        tag: crate::api::ids::ChangeTag::Service("tag".to_owned()),
        version: Some(1),
        revision: Some(1),
        epoch: Some(epoch(2)),
        deleted: None,
        fields: None,
        created_ms: None,
    })
}

#[tokio::test]
async fn push_back_refuses_to_judge_a_personal_scope_the_engine_kept_no_bases_for() {
    let world = World::load();
    let rig = Rig::new(&world.origin, world.account("P"));
    let certificate = world.record(GENESIS, "B's genesis: certificate at av 1");
    rig.put([held_row(ScopeName::Personal, &certificate)]).await;
    let body = super::fakes::scopes(epoch(2), vec![info(ScopeName::Personal)]);
    let mut txn = rig.service.begin().await.unwrap();

    let blind = rig.service.gather(&mut *txn, &body).await;
    txn.put(base_row(ScopeName::Personal, &certificate)).await.unwrap();
    let seen = rig.service.gather(&mut *txn, &body).await;

    assert_eq!(blind.err().map(|error| error.code()), Some("sync.not_allowed"));
    assert!(seen.is_ok());
}

#[tokio::test]
async fn a_team_with_no_bases_still_plans_its_objects_as_lacking() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("A"));
    let member = world.member("A", 2);
    rig.put([held_row(team, &member), row(team, KeyPurpose::Team, 6)]).await;
    let body = super::fakes::scopes(epoch(2), vec![info(team)]);
    let mut txn = rig.service.begin().await.unwrap();

    let gathered = rig.service.gather(&mut *txn, &body).await.unwrap();

    assert_eq!(gathered.teams.len(), 1);
}

fn gathered(team: TeamId, row: KeyVersionRow) -> crate::keys::restore::Gathered {
    crate::keys::restore::Gathered {
        personal: Vec::new(),
        teams: vec![crate::keys::restore::GatheredTeam {
            team,
            objects: Vec::new(),
            row: Some(row),
            roster: None,
        }],
        bases: crate::keys::restore::server::Bases::default(),
    }
}

fn team_version_row(scope: ScopeName, cause: Option<StoppedCause>) -> KeyVersionRow {
    let Row::KeyVersion(mut row) = row(scope, KeyPurpose::Team, 7) else {
        unreachable!()
    };
    if let Some(cause) = cause {
        row.stop(cause);
    }
    row
}

async fn apply(rig: &Rig, team: TeamId, row: KeyVersionRow, verdict: TeamVerdict) -> KeyVersionRow {
    let plan = Plan {
        sets: Vec::new(),
        teams: vec![(team, verdict)],
        blind: false,
    };
    let gathered = gathered(team, row.clone());
    rig.put([Row::KeyVersion(row)]).await;
    let mut txn = rig.service.begin().await.unwrap();
    let effects = rig
        .service
        .apply_verdicts(&mut *txn, &gathered, &plan, epoch(2))
        .await
        .unwrap();
    txn.commit().await.unwrap();
    rig.service.announce(&effects).await.unwrap();
    version_row(rig, ScopeName::Team(team), KeyPurpose::Team).await
}

fn waits() -> TeamVerdict {
    TeamVerdict::Waits {
        version: v(7),
        awaiting: Vec::new(),
    }
}

#[tokio::test]
async fn a_wait_stops_an_ok_team_as_restore_wait_and_its_end_clears_only_that() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("P"));

    let stopped = apply(&rig, world.team, team_version_row(team, None), waits()).await;
    let resumed = apply(&rig, world.team, stopped.clone(), TeamVerdict::Done).await;
    let caught = apply(
        &rig,
        world.team,
        team_version_row(team, Some(StoppedCause::CatchUp)),
        TeamVerdict::Done,
    )
    .await;
    let still = apply(
        &rig,
        world.team,
        team_version_row(team, Some(StoppedCause::CatchUp)),
        waits(),
    )
    .await;

    assert_eq!(
        (stopped.state, stopped.stopped_cause),
        (KeyVersionState::Stopped, Some(StoppedCause::RestoreWait))
    );
    assert_eq!((resumed.state, resumed.stopped_cause), (KeyVersionState::Ok, None));
    assert_eq!(
        caught.stopped_cause,
        Some(StoppedCause::CatchUp),
        "a catch-up stop clears only by re-confirmation"
    );
    assert_eq!(still.stopped_cause, Some(StoppedCause::CatchUp));
    assert_eq!(
        rig.hooks.without_notices(),
        [Hook::Stop(team, StoppedCause::RestoreWait), Hook::Resume(team)]
    );
}

// M's restart of version 8 passed its checks while P's team waited at 7 for a version the restore lost. Once the wait
// clears, the restart is judged as a pull would judge it and held for the person's words (0064), so P never seals
// under the older key with a restart pending.
#[tokio::test]
async fn a_restart_that_passed_during_a_restore_wait_is_held_once_the_wait_clears() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("P"));
    rig.put([
        Row::KeyPin(crate::api::state::KeyPinRow {
            account: world.account("M"),
            ik: world.ik("M").public().unwrap(),
            av: v(2),
            how: tablepro_keys::trust::PinHow::FirstUse,
            alert: false,
            replaced: Vec::new(),
        }),
        held_row(team, &world.member("M", 2)),
        held_row(team, &world.team_version(8, "M", 2, Start::Over)),
        held_row(team, &world.team_wrap(8, ("M", 2), ("P", 2))),
    ])
    .await;

    let after = apply(
        &rig,
        world.team,
        team_version_row(team, Some(StoppedCause::RestoreWait)),
        TeamVerdict::Done,
    )
    .await;

    assert_eq!(
        (after.version, after.state, after.stopped_cause),
        (v(7), KeyVersionState::Stopped, Some(StoppedCause::RestartHeld))
    );
    assert_eq!(
        rig.hooks.without_notices(),
        [Hook::Resume(team), Hook::Stop(team, StoppedCause::RestartHeld)]
    );
}

// The same restart, with P's key tables still rebuilding: the wait clears, and the team takes nothing until the
// commit that ends the rebuild judges it (0054, A stale file).
#[tokio::test]
async fn a_wait_that_clears_while_the_key_tables_rebuild_judges_nothing() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("P"));
    rig.service.rebuilding.store(true, std::sync::atomic::Ordering::SeqCst);
    rig.put([
        Row::KeyPin(crate::api::state::KeyPinRow {
            account: world.account("M"),
            ik: world.ik("M").public().unwrap(),
            av: v(2),
            how: tablepro_keys::trust::PinHow::FirstUse,
            alert: false,
            replaced: Vec::new(),
        }),
        held_row(team, &world.member("M", 2)),
        held_row(team, &world.team_version(8, "M", 2, Start::Over)),
        held_row(team, &world.team_wrap(8, ("M", 2), ("P", 2))),
    ])
    .await;

    let after = apply(
        &rig,
        world.team,
        team_version_row(team, Some(StoppedCause::RestoreWait)),
        TeamVerdict::Done,
    )
    .await;

    assert_eq!(
        (after.version, after.state, after.stopped_cause),
        (v(7), KeyVersionState::Ok, None)
    );
    assert_eq!(rig.hooks.without_notices(), [Hook::Resume(team)]);
}

#[tokio::test]
async fn an_awaited_confirmation_that_cannot_go_back_ends_the_team_with_its_withdrawal() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("P"));

    let ended = apply(&rig, world.team, team_version_row(team, None), TeamVerdict::Ends).await;

    assert_eq!((ended.state, ended.epoch), (KeyVersionState::Ended, Some(epoch(2))));
    assert!(
        rig.get(&RowKey::KeyPending(PendingFlow::StopWithdrawal { team: world.team }))
            .await
            .is_some()
    );
    assert_eq!(rig.hooks.without_notices(), [Hook::End(team, Some(epoch(2)))]);
}

#[tokio::test]
async fn the_roster_counts_only_once_the_team_s_pull_is_caught_up() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("A"));
    let member = world.member("A", 2);
    rig.put([
        held_row(team, &member),
        base_row(team, &member),
        row(team, KeyPurpose::Team, 6),
    ])
    .await;
    let mut listed = info(team);
    listed.members = vec![crate::api::scopes::TeamMember {
        account: world.account("A"),
        role: crate::api::scopes::Role::Admin,
    }];
    let body = super::fakes::scopes(epoch(2), vec![listed]);

    let mut txn = rig.service.begin().await.unwrap();
    txn.put(Row::Scope(ScopeRow {
        caught_up: true,
        ..ScopeRow::new(team)
    }))
    .await
    .unwrap();
    let flag_only = rig.service.gather(&mut *txn, &body).await.unwrap();
    let members = body.scopes[0].members.clone();
    rig.service.rosters().put(
        world.team,
        crate::keys::test_roster(world.team, members.clone(), None, false, false, epoch(2)),
    );
    let read_behind = rig.service.gather(&mut *txn, &body).await.unwrap();
    rig.service.rosters().put(
        world.team,
        crate::keys::test_roster(world.team, members.clone(), None, false, true, epoch(1)),
    );
    let earlier_epoch = rig.service.gather(&mut *txn, &body).await.unwrap();
    rig.service.rosters().put(
        world.team,
        crate::keys::test_roster(world.team, members, None, false, true, epoch(2)),
    );
    let caught_up = rig.service.gather(&mut *txn, &body).await.unwrap();

    assert_eq!(flag_only.teams[0].roster, None);
    assert_eq!(read_behind.teams[0].roster, None);
    assert_eq!(
        earlier_epoch.teams[0].roster, None,
        "a roster of the epoch before the restore"
    );
    assert_eq!(caught_up.teams[0].roster.as_ref().map(Vec::len), Some(1));
}

// A different record at an id is no copy of this device's: the push-back does not count it as held, and a version the
// server holds as another record ends the team once the device checked it under its signer's certificate in the team
// (0051, What cannot go back).
#[tokio::test]
async fn another_record_at_an_id_is_not_this_device_s_copy() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("A"));
    let ours = world.team_version(7, "O", 2, Start::Next);
    let theirs = world.team_version(7, "M", 2, Start::Next);
    let base = |held: &HeldObject| {
        Row::Base(crate::api::state::BaseRow {
            key: crate::api::ids::RecordKey::new(
                team,
                crate::api::ids::KindName::parse(held.object.id.kind().name()).unwrap(),
                held.object.id.to_wire(),
            ),
            tag: crate::api::ids::ChangeTag::Service("tag".to_owned()),
            version: Some(1),
            revision: Some(1),
            epoch: Some(epoch(2)),
            deleted: None,
            fields: serde_json::from_str(&held.fields).ok(),
            created_ms: None,
        })
    };
    let body = super::fakes::scopes(epoch(2), vec![info(team)]);
    let view = |rows: Row| {
        let rig = &rig;
        async move {
            rig.put([rows]).await;
            let mut bases = crate::keys::restore::server::Bases::default();
            let mut txn = rig.service.begin().await.unwrap();
            bases.load(&mut *txn, team).await.unwrap();
            bases
        }
    };
    let id = ours.object.id;

    let same = view(base(&ours)).await;
    let same_view = crate::keys::restore::server::BaseView::new(&body, &same, &[(team, &ours)]);
    let held_same = (same_view.holds(team, &id), same_view.holds_another(team, &id));
    let other = view(base(&theirs)).await;
    let mut other_view = crate::keys::restore::server::BaseView::new(&body, &other, &[(team, &ours)]);
    let unchecked = other_view.holds_another(team, &id);
    rig.put([
        Row::KeyPin(crate::api::state::KeyPinRow {
            account: world.account("M"),
            ik: world.ik("M").public().unwrap(),
            av: v(2),
            how: tablepro_keys::trust::PinHow::FirstUse,
            alert: false,
            replaced: Vec::new(),
        }),
        held_row(team, &world.member("M", 2)),
    ])
    .await;
    let mut txn = rig.service.begin().await.unwrap();
    rig.service
        .check_other_versions(&mut *txn, &[(team, &ours)], &mut other_view)
        .await
        .unwrap();

    assert_eq!(held_same, (true, false));
    assert!(!other_view.holds(team, &id));
    assert!(!unchecked);
    assert!(other_view.holds_another(team, &id));
}

// The server's base for `at` as it serves `served`.
fn served_base(scope: ScopeName, at: &HeldObject, served: &HeldObject) -> Row {
    let Row::Base(base) = base_row(scope, at) else {
        unreachable!()
    };
    Row::Base(crate::api::state::BaseRow {
        fields: serde_json::from_str(&served.fields).ok(),
        ..base
    })
}

// O's own restart at 7 went missing in the restore, and the server's copy there is a record of M, whose certificate the
// team does not hold: bytes the device cannot check prove no fork, so O's version goes back and the server's answer
// decides, rather than the team ending on them (0051, What cannot go back).
#[tokio::test]
async fn a_version_the_server_holds_as_bytes_the_device_cannot_check_goes_back_and_ends_nothing() {
    let world = World::load();
    let team = ScopeName::Team(world.team);
    let rig = Rig::new(&world.origin, world.account("O"));
    let six = world.team_version(6, "A", 2, Start::Next);
    let ours = world.team_version(7, "O", 2, Start::Over);
    let theirs = world.team_version(7, "M", 2, Start::Over);
    rig.put([
        held_row(team, &six),
        served_base(team, &six, &six),
        held_row(team, &ours),
        served_base(team, &ours, &theirs),
        row(team, KeyPurpose::Team, 7),
    ])
    .await;
    let body = super::fakes::scopes(epoch(2), vec![info(team)]);
    let mut txn = rig.service.begin().await.unwrap();
    let gathered = rig.service.gather(&mut *txn, &body).await.unwrap();
    let held: Vec<(ScopeName, &HeldObject)> = gathered.teams[0].objects.iter().map(|held| (team, held)).collect();
    let view = crate::keys::restore::server::BaseView::new(&body, &gathered.bases, &held);

    let plan = crate::keys::restore::plan::plan(&crate::keys::restore::plan::Inputs {
        account: world.account("O"),
        key_device: world.device("O"),
        newest_av: v(2),
        approved: true,
        personal: &gathered.personal,
        teams: vec![crate::keys::restore::plan::TeamInputs {
            team: world.team,
            objects: &gathered.teams[0].objects,
            row: gathered.teams[0].row.as_ref(),
            roster: None,
        }],
        server: &view,
    });

    assert_eq!(plan.teams, [(world.team, TeamVerdict::Done)]);
}
