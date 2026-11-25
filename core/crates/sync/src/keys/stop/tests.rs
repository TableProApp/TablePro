// A stopped device (0056, Teams; 0051, A stopped device; 0062): the vectors' stopped rows, the re-confirmation only a
// holder it counted can give, the reports and their withdrawals across a crash, and the team that ends when no owner
// or admin held its version.

use tablepro_keys::cert::CertKind;
use tablepro_keys::encoding::{KeyPurpose, TeamId};
use tablepro_keys::keys::Ed25519Public;
use tablepro_keys::wrap::Wrapper;

use super::{Chain, Reconfirmation, ended, resumed, same_holder};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{Roster, StopAction, StopFlows};
use crate::api::scopes::{Role, TeamMember};
use crate::api::state::{
    Holder, KeyPendingRow, KeyPinRow, KeyVersionRow, KeyVersionState, PendingFlow, Row, RowKey, ScopeRow, StoppedCause,
};
use crate::keys::restore::tests::fakes::{Hook, Rig, Sent, epoch};
use crate::keys::restore::tests::world::{World, v};
use std::collections::BTreeMap;
use tablepro_keys::trust::PinHow;

fn team_row(world: &World, version: u32, holders: &[(&str, u32)], cause: Option<StoppedCause>) -> KeyVersionRow {
    let mut holders: Vec<Holder> = holders
        .iter()
        .map(|(name, av)| Holder {
            account: world.account(name),
            ik: world.certificate(name, *av, CertKind::GenesisOrRotation).ik,
        })
        .collect();
    holders.sort();
    KeyVersionRow {
        scope: ScopeName::Team(world.team),
        purpose: KeyPurpose::Team,
        version: v(version),
        record: [6; 32],
        holders,
        state: if cause.is_some() {
            KeyVersionState::Stopped
        } else {
            KeyVersionState::Ok
        },
        stopped_cause: cause,
        epoch: None,
    }
}

fn wrapper(world: &World, name: &str, av: u32) -> Wrapper {
    Wrapper {
        account: world.account(name),
        av: v(av),
        key_device: world.device(name),
    }
}

fn pin(world: &World, name: &str, av: u32) -> Row {
    Row::KeyPin(KeyPinRow {
        account: world.account(name),
        ik: world.ik(name).public().unwrap(),
        av: v(av),
        how: PinHow::FirstUse,
        alert: false,
        replaced: Vec::new(),
    })
}

fn scope_row(world: &World) -> Row {
    Row::Scope(ScopeRow {
        epoch: Some(epoch(3)),
        caught_up: true,
        ..ScopeRow::new(ScopeName::Team(world.team))
    })
}

// P's device, stopped at team version 6, which it verified with A and P as holders (the vectors' given).
async fn stopped_at_6(world: &World) -> Rig {
    let rig = Rig::new(&world.origin, world.account("P"));
    rig.put([
        scope_row(world),
        Row::KeyVersion(team_row(world, 6, &[("A", 2), ("P", 2)], Some(StoppedCause::CatchUp))),
        Row::KeyObject(member_row(world, "A", 2)),
        Row::KeyObject(member_row(world, "O", 2)),
        Row::KeyObject(member_row(world, "M", 2)),
        pin(world, "A", 2),
    ])
    .await;
    rig
}

fn member_row(world: &World, name: &str, av: u32) -> crate::api::state::KeyObjectRow {
    let held = world.member(name, av);
    crate::api::state::KeyObjectRow {
        scope: ScopeName::Team(world.team),
        kind: crate::api::ids::KindName::parse("key.member").unwrap(),
        record_id: held.object.id.to_wire(),
        fields: held.fields,
        applied: true,
    }
}

async fn reconfirm(rig: &Rig, world: &World, version: u32, by: Wrapper) -> Result<Reconfirmation, SyncError> {
    let mut txn = rig.service.begin().await.unwrap();
    rig.service.reconfirmation(&mut *txn, world.team, v(version), &by).await
}

#[test]
fn a_restore_wait_resumes_a_catch_up_stop_does_not_and_an_ended_row_keeps_its_epoch() {
    let world = World::load();
    let mut waiting = team_row(&world, 6, &[], None);
    waiting.stop(StoppedCause::RestoreWait);
    let mut both = waiting.clone();
    both.stop(StoppedCause::CatchUp);
    let over = ended(both.clone(), epoch(9));

    assert_eq!(resumed(waiting).state, KeyVersionState::Ok);
    assert_eq!(
        resumed(both.clone()),
        both,
        "only re-confirmation clears a catch-up stop"
    );
    assert_eq!(
        (over.state, over.stopped_cause, over.epoch),
        (KeyVersionState::Ended, None, Some(epoch(9)))
    );
}

#[test]
fn a_holder_rotating_its_account_keys_stays_the_holder_and_a_reset_makes_another() {
    let world = World::load();
    let accepted = world.ik("A").public().unwrap();
    let mut certificates = BTreeMap::new();
    for av in 1..=3 {
        certificates.insert(v(av), world.certificate("A", av, CertKind::GenesisOrRotation));
    }

    assert_eq!(
        same_holder(&world.origin, &accepted, &certificates, v(3)),
        Chain::Matches
    );
    assert_eq!(
        same_holder(&world.origin, &Ed25519Public([9; 32]), &certificates, v(3)),
        Chain::Missing
    );
    let mut forged = certificates.clone();
    let under_another_ik = tablepro_keys::cert::AccountCertificate::sign(
        &world.origin,
        world.account("A"),
        v(4),
        CertKind::GenesisOrRotation,
        &world.ik("M"),
        world.public("A", 3),
        None,
    )
    .unwrap();
    forged.insert(v(4), under_another_ik);
    assert_eq!(
        same_holder(&world.origin, &accepted, &forged, v(4)),
        Chain::Breaks,
        "an IK change with no endorsement"
    );

    let mut reset = certificates.clone();
    reset.insert(v(3), world.certificate("A", 3, CertKind::ResetEmpty));
    assert_eq!(same_holder(&world.origin, &accepted, &reset, v(3)), Chain::Breaks);

    let mut gap = certificates.clone();
    gap.remove(&v(2));
    let mut from_one = BTreeMap::new();
    from_one.insert(v(1), world.certificate("A", 1, CertKind::GenesisOrRotation));
    from_one.insert(v(3), world.certificate("A", 3, CertKind::GenesisOrRotation));
    assert_eq!(
        same_holder(&world.origin, &accepted, &from_one, v(3)),
        Chain::Missing,
        "av 2 may hold a reset"
    );
    gap.retain(|av, _| *av != v(3));
    assert_eq!(same_holder(&world.origin, &accepted, &gap, v(3)), Chain::Missing);
}

#[tokio::test]
async fn a_stopped_device_takes_a_rotation_by_a_holder_it_counted_and_refuses_one_by_another_account() {
    let world = World::load();
    let rig = stopped_at_6(&world).await;

    let holder = reconfirm(&rig, &world, 7, wrapper(&world, "A", 2)).await;
    let other = reconfirm(&rig, &world, 7, wrapper(&world, "O", 2)).await;

    assert_eq!(holder.unwrap(), Reconfirmation::Taken);
    assert_eq!(other.unwrap_err().code(), "keys.not_holder");
}

#[tokio::test]
async fn a_stopped_device_takes_a_qualifying_admin_s_wrap_under_the_av_it_rotated_to_since() {
    let world = World::load();
    let rig = stopped_at_6(&world).await;
    let at_3 = world.record(
        "a stopped device whose qualifying admin rotated its account keys since",
        "A's certificate in the team at av 3",
    );
    rig.put([Row::KeyObject(crate::api::state::KeyObjectRow {
        scope: ScopeName::Team(world.team),
        kind: crate::api::ids::KindName::parse("key.member").unwrap(),
        record_id: at_3.object.id.to_wire(),
        fields: at_3.fields,
        applied: true,
    })])
    .await;

    let under_3 = reconfirm(&rig, &world, 7, wrapper(&world, "A", 3)).await;
    let under_2 = reconfirm(&rig, &world, 7, wrapper(&world, "A", 2)).await;

    assert_eq!(under_3.unwrap(), Reconfirmation::Taken);
    assert_eq!(
        under_2.unwrap_err().code(),
        "keys.stale",
        "signed under an older av than the newest it knows"
    );
}

#[tokio::test]
async fn while_stopped_a_new_holder_never_counts_and_an_old_key_s_wrap_is_stale() {
    // While stopped at 6: a wrap of 6 to M under A's old account key, then M's rotation wrapping to the device.
    let world = World::load();
    let rig = stopped_at_6(&world).await;

    let old_key = reconfirm(&rig, &world, 7, wrapper(&world, "A", 1)).await;
    let by_m = reconfirm(&rig, &world, 7, wrapper(&world, "M", 2)).await;

    assert_eq!(old_key.unwrap_err().code(), "keys.stale");
    assert_eq!(by_m.unwrap_err().code(), "keys.not_holder");
}

#[tokio::test]
async fn a_reconfirmation_must_move_past_the_stopped_version_of_a_catch_up_stop() {
    let world = World::load();
    let rig = stopped_at_6(&world).await;
    let same = reconfirm(&rig, &world, 6, wrapper(&world, "A", 2)).await;
    assert_eq!(same.unwrap_err().code(), "keys.stale");

    rig.put([Row::KeyVersion(team_row(
        &world,
        6,
        &[("A", 2)],
        Some(StoppedCause::RestoreWait),
    ))])
    .await;
    let waiting = reconfirm(&rig, &world, 7, wrapper(&world, "A", 2)).await;
    assert_eq!(
        waiting.unwrap_err().code(),
        "sync.not_allowed",
        "a restore wait clears only by push-back"
    );
}

#[tokio::test]
async fn a_wrapper_whose_certificate_has_not_arrived_is_held() {
    let world = World::load();
    let rig = stopped_at_6(&world).await;

    let pending = reconfirm(&rig, &world, 7, wrapper(&world, "A", 3)).await;

    assert_eq!(pending.unwrap(), Reconfirmation::Held);
}

#[tokio::test]
async fn a_catch_up_stop_reports_its_version_and_a_restore_wait_reports_nothing() {
    let world = World::load();
    let rig = stopped_at_6(&world).await;
    assert_eq!(
        rig.service.stop_actions().await.unwrap(),
        [StopAction::Report {
            team: world.team,
            version: v(6)
        }]
    );

    rig.put([Row::KeyVersion(team_row(
        &world,
        6,
        &[("A", 2)],
        Some(StoppedCause::RestoreWait),
    ))])
    .await;
    assert!(rig.service.stop_actions().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_report_of_a_version_the_server_lost_is_still_sent() {
    // A report is a hint: version 8 after a restore to version 5.
    let world = World::load();
    let rig = stopped_at_6(&world).await;
    rig.put([Row::KeyVersion(team_row(
        &world,
        8,
        &[("A", 2)],
        Some(StoppedCause::CatchUp),
    ))])
    .await;

    assert_eq!(
        rig.service.stop_actions().await.unwrap(),
        [StopAction::Report {
            team: world.team,
            version: v(8)
        }]
    );
}

#[tokio::test]
async fn a_cleared_stop_withdraws_in_the_same_commit_and_the_withdrawal_survives_until_answered() {
    let world = World::load();
    let rig = stopped_at_6(&world).await;
    let mut txn = rig.service.begin().await.unwrap();
    rig.service
        .clear_catch_up_stop(&mut *txn, team_row(&world, 7, &[("A", 2), ("P", 2)], None))
        .await
        .unwrap();
    txn.commit().await.unwrap();

    let withdraw = StopAction::Withdraw { team: world.team };
    assert_eq!(rig.service.stop_actions().await.unwrap(), [withdraw]);
    assert_eq!(
        rig.service.stop_actions().await.unwrap(),
        [withdraw],
        "a crash before it is sent keeps it"
    );
    rig.service.stop_action_sent(withdraw).await.unwrap();
    assert!(rig.service.stop_actions().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_cleared_stop_must_move_to_a_higher_version() {
    let world = World::load();
    let rig = stopped_at_6(&world).await;
    let mut txn = rig.service.begin().await.unwrap();

    let same = rig
        .service
        .clear_catch_up_stop(&mut *txn, team_row(&world, 6, &[("A", 2)], None))
        .await;

    assert_eq!(same.unwrap_err().code(), "keys.stale");
}

#[tokio::test]
#[ignore = "resume_withdrawal proves with KeyService::dpop_key, which K7-1 fills"]
async fn a_withdrawal_whose_answer_was_lost_settles_before_the_report_of_a_second_stop() {
    let world = World::load();
    let rig = stopped_at_6(&world).await;
    rig.put([Row::KeyPending(KeyPendingRow {
        flow: PendingFlow::StopWithdrawal { team: world.team },
        state: Vec::new(),
    })])
    .await;
    *rig.transport.lose_next_answer.lock().unwrap() = true;

    let lost = rig.service.resume_withdrawal(world.team).await;
    assert_eq!(lost.unwrap_err().code(), "sync.network");
    assert_eq!(
        rig.service.stop_actions().await.unwrap(),
        [StopAction::Withdraw { team: world.team }],
        "no report while the withdrawal is pending"
    );

    rig.service.resume_withdrawal(world.team).await.unwrap();
    assert_eq!(
        *rig.transport.sent.lock().unwrap(),
        [Sent::Withdraw(world.team), Sent::Withdraw(world.team)]
    );
    assert_eq!(
        rig.service.stop_actions().await.unwrap(),
        [StopAction::Report {
            team: world.team,
            version: v(6)
        }]
    );
}

#[tokio::test]
async fn a_resumed_withdrawal_that_is_no_longer_pending_sends_nothing() {
    let world = World::load();
    let rig = stopped_at_6(&world).await;

    rig.service.resume_withdrawal(world.team).await.unwrap();

    assert!(rig.transport.sent.lock().unwrap().is_empty());
}

fn roster(world: &World, members: &[(&str, Role)], caught_up: bool) -> Roster {
    Roster {
        members: members
            .iter()
            .map(|(name, role)| TeamMember {
                account: world.account(name),
                role: *role,
            })
            .collect(),
        role: Some(Role::Member),
        rotation_due: false,
        stopped: Vec::new(),
        caught_up,
    }
}

#[tokio::test]
async fn with_no_owner_or_admin_on_the_roster_that_held_its_version_the_team_ends_and_withdraws() {
    let world = World::load();
    let rig = stopped_at_6(&world).await;
    let team: TeamId = world.team;
    rig.service.rosters().put(
        team,
        roster(
            &world,
            &[("O", Role::Owner), ("M", Role::Member), ("P", Role::Member)],
            true,
        ),
    );

    let actions = rig.service.stop_actions().await.unwrap();

    assert_eq!(actions, [StopAction::Withdraw { team }]);
    let Some(Row::KeyVersion(row)) = rig
        .get(&RowKey::KeyVersion(ScopeName::Team(team), KeyPurpose::Team))
        .await
    else {
        panic!()
    };
    assert_eq!((row.state, row.epoch), (KeyVersionState::Ended, Some(epoch(3))));
    assert!(
        rig.hooks
            .calls()
            .contains(&Hook::End(ScopeName::Team(team), Some(epoch(3))))
    );
}

#[tokio::test]
async fn a_roster_not_read_after_catch_up_or_with_a_holding_admin_ends_nothing() {
    let world = World::load();
    let rig = stopped_at_6(&world).await;
    let report = StopAction::Report {
        team: world.team,
        version: v(6),
    };
    rig.service.rosters().put(
        world.team,
        roster(&world, &[("O", Role::Owner), ("P", Role::Member)], false),
    );
    assert_eq!(rig.service.stop_actions().await.unwrap(), [report]);

    rig.service.rosters().put(
        world.team,
        roster(&world, &[("A", Role::Admin), ("P", Role::Member)], true),
    );
    assert_eq!(rig.service.stop_actions().await.unwrap(), [report]);
}

#[tokio::test]
async fn an_admin_who_reset_since_holding_the_version_is_no_holder_and_the_team_ends() {
    let world = World::load();
    let rig = stopped_at_6(&world).await;
    let reset = world.certificate("A", 3, CertKind::ResetEmpty);
    let body = tablepro_keys::body::AccountBody::of(&reset);
    let object = tablepro_keys::body::KeyObject {
        id: tablepro_keys::record_id::KeyRecordId::Member {
            account: world.account("A"),
            av: v(3),
        },
        body: tablepro_keys::body::KeyBody::Member(body),
    };
    rig.put([Row::KeyObject(crate::api::state::KeyObjectRow {
        scope: ScopeName::Team(world.team),
        kind: crate::api::ids::KindName::parse("key.member").unwrap(),
        record_id: object.id.to_wire(),
        fields: object.fields_json(),
        applied: true,
    })])
    .await;
    rig.service.rosters().put(
        world.team,
        roster(&world, &[("A", Role::Admin), ("P", Role::Member)], true),
    );

    assert_eq!(
        rig.service.stop_actions().await.unwrap(),
        [StopAction::Withdraw { team: world.team }]
    );
}

#[tokio::test]
async fn a_report_already_sent_needs_nothing_recorded() {
    let world = World::load();
    let rig = stopped_at_6(&world).await;
    let report = StopAction::Report {
        team: world.team,
        version: v(6),
    };

    rig.service.stop_action_sent(report).await.unwrap();

    assert_eq!(
        rig.service.stop_actions().await.unwrap(),
        [report],
        "a report repeats safely"
    );
}
