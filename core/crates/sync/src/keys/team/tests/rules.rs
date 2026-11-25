// The team rules the vectors leave to the flows, each refusal with its exact code: holder chains, alerts, held objects,
// forks, restarts, joining, stops, reading keys, and the checks the service makes before it seals, confirms, rotates
// or decides on a roster: the 5,000-holder limit, envelope versions, `rotation_due`, member standing and recipients.

use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyBody, KeyObject, VersionBody};
use tablepro_keys::encoding::KeyPurpose;
use tablepro_keys::keys::{Ed25519Seed, ScopeKey};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::scope_key::{KeyRef, Start, VersionRecord};
use uuid::Uuid;

use super::{Account, TestFacts, TestKeyring, book, insert_all, origin, row, team, v, version, wrap};
use crate::api::key_flows::{MemberKeyStatus, Roster};
use crate::api::scopes::{Role, TeamMember};
use crate::api::state::{Holder, KeyVersionState, StoppedCause};
use crate::api::transport::RejectedCode;
use crate::keys::team::book::{Progress, TeamEvent};
use crate::keys::team::envelopes::{check_may_seal, check_open_kv};
use crate::keys::team::facts::Certificate;
use crate::keys::team::{roster, secrets};

fn refusal(progress: &Progress, objects: &[KeyObject], kind: &str) -> Option<&'static str> {
    let id = objects
        .iter()
        .find(|object| object.id.kind().name() == kind)?
        .id
        .to_wire();
    progress
        .refused
        .iter()
        .find(|refused| refused.record_id == id)
        .map(|refused| refused.error.code())
}

fn key() -> ScopeKey {
    ScopeKey::generate().unwrap()
}

fn members(entries: &[(&Account, Role)]) -> Roster {
    Roster {
        members: entries
            .iter()
            .map(|(account, role)| TeamMember {
                account: account.id,
                role: *role,
            })
            .collect(),
        role: None,
        rotation_due: false,
        stopped: Vec::new(),
        caught_up: true,
    }
}

struct Team {
    a: Account,
    m: Account,
    me: Account,
    facts: TestFacts,
}

// A holds version 5 with this device's account; both at `av` 1, M at `av` 1 too.
fn five() -> Team {
    let (a, m, me) = (
        Account::generated(1, 1),
        Account::generated(2, 1),
        Account::generated(3, 1),
    );
    let mut facts = TestFacts::default();
    facts.know(&a, 1);
    facts.know(&m, 1);
    facts.know(&me, 1);
    Team { a, m, me, facts }
}

#[tokio::test]
async fn a_holder_that_replaced_its_ik_with_an_endorsement_is_the_same_holder() {
    let mut t = five();
    t.a.change_ik(2, true);
    t.facts.know(&t.a, 2);
    let mut team = book(
        &t.me,
        Some(row(5, &[t.a.holder(1), t.me.holder(1)], KeyVersionState::Ok)),
    );
    let (five, six) = (key(), key());
    insert_all(
        &mut team,
        &version(6, Start::Next, &six, Some(&five), (&t.a, 2), &[(&t.me, 1)]),
    );

    let progress = team.advance(&mut t.facts).await.unwrap();

    assert_eq!(progress.events, [TeamEvent::Advanced { version: v(6) }]);
}

#[tokio::test]
async fn a_holder_after_an_unendorsed_ik_change_is_another_account_holder_and_stops_the_device() {
    let mut t = five();
    t.a.change_ik(2, false);
    t.facts.know(&t.a, 2);
    let mut team = book(
        &t.me,
        Some(row(5, &[t.a.holder(1), t.me.holder(1)], KeyVersionState::Ok)),
    );
    let objects = version(6, Start::Next, &key(), Some(&key()), (&t.a, 2), &[(&t.me, 1)]);
    insert_all(&mut team, &objects);

    let progress = team.advance(&mut t.facts).await.unwrap();

    assert_eq!(refusal(&progress, &objects, "key.version"), Some("keys.not_holder"));
    assert_eq!(team.row().unwrap().state, KeyVersionState::Stopped);
}

#[tokio::test]
async fn a_replace_the_team_shows_with_an_av_missing_before_it_matches_no_holder() {
    let mut t = five();
    t.a.keys
        .insert(2, tablepro_keys::keys::AccountKeys::generate().unwrap());
    t.a.sign_rotation(2);
    t.a.change_ik(3, true);
    t.facts.know(&t.a, 3);
    t.facts.certificates.remove(&(t.a.id, v(2)));
    let mut team = book(
        &t.me,
        Some(row(5, &[t.a.holder(1), t.me.holder(1)], KeyVersionState::Ok)),
    );
    let objects = version(6, Start::Next, &key(), Some(&key()), (&t.a, 3), &[]);
    insert_all(&mut team, &objects);

    let progress = team.advance(&mut t.facts).await.unwrap();

    assert_eq!(refusal(&progress, &objects, "key.version"), Some("keys.not_holder"));
}

#[tokio::test]
async fn a_signer_under_an_open_alert_is_held_with_no_effect_until_the_person_re_confirms() {
    let mut t = five();
    t.facts.alert(&t.a, 1);
    let mut team = book(
        &t.me,
        Some(row(5, &[t.a.holder(1), t.me.holder(1)], KeyVersionState::Ok)),
    );
    let objects = version(6, Start::Next, &key(), Some(&key()), (&t.a, 1), &[(&t.me, 1)]);
    insert_all(&mut team, &objects);

    let waiting = team.advance(&mut t.facts).await.unwrap();

    assert!(waiting.refused.is_empty());
    assert!(waiting.held.contains(&objects[0].id.to_wire()));
    assert_eq!(
        (team.row().unwrap().version, team.row().unwrap().state),
        (v(5), KeyVersionState::Ok)
    );

    t.facts.know(&t.a, 1);
    let confirmed = team.advance(&mut t.facts).await.unwrap();

    assert_eq!(confirmed.events, [TeamEvent::Advanced { version: v(6) }]);
}

#[tokio::test]
async fn a_version_whose_signer_certificate_has_not_arrived_is_held_not_refused() {
    let mut t = five();
    t.facts.certificates.remove(&(t.a.id, v(1)));
    let mut team = book(&t.me, Some(row(5, &[t.a.holder(1)], KeyVersionState::Ok)));
    let objects = version(6, Start::Next, &key(), Some(&key()), (&t.a, 1), &[]);
    insert_all(&mut team, &objects);

    let progress = team.advance(&mut t.facts).await.unwrap();

    assert!(progress.refused.is_empty());
    assert!(progress.held.contains(&objects[0].id.to_wire()));
    assert_eq!(team.row().unwrap().state, KeyVersionState::Ok);
}

#[tokio::test]
async fn a_version_record_signed_by_another_key_than_its_signer_names_is_keys_signature() {
    let mut t = five();
    let mut team = book(&t.me, Some(row(5, &[t.a.holder(1)], KeyVersionState::Ok)));
    let forged = VersionRecord::sign(
        &origin(),
        KeyRef {
            owner: team_id().0,
            purpose: KeyPurpose::Team,
            version: v(6),
        },
        Start::Next,
        &key(),
        t.a.id,
        v(1),
        &Ed25519Seed::generate().unwrap(),
    )
    .unwrap();
    let object = KeyObject {
        id: KeyRecordId::Version(forged.key),
        body: KeyBody::Version(VersionBody::of(&forged)),
    };
    team.insert(&object, true).unwrap();

    let progress = team.advance(&mut t.facts).await.unwrap();

    assert_eq!(progress.refused[0].error, KeysError::Signature);
    assert_eq!(team.row().unwrap().state, KeyVersionState::Stopped);
}

fn team_id() -> tablepro_keys::encoding::TeamId {
    team()
}

#[tokio::test]
async fn another_record_at_the_version_held_is_a_fork_that_ends_the_team() {
    let mut t = five();
    let objects = version(5, Start::Next, &key(), Some(&key()), (&t.a, 1), &[]);
    let mut held = row(5, &[t.a.holder(1)], KeyVersionState::Ok);
    held.record = [7; 32];
    let mut team = book(&t.me, Some(held));
    insert_all(&mut team, &objects);

    let progress = team.advance(&mut t.facts).await.unwrap();

    assert_eq!(refusal(&progress, &objects, "key.version"), Some("keys.conflict"));
    assert_eq!(progress.events, [TeamEvent::Ended]);
    assert_eq!(team.row().unwrap().state, KeyVersionState::Ended);

    let later = version(6, Start::Next, &key(), Some(&key()), (&t.a, 1), &[(&t.me, 1)]);
    insert_all(&mut team, &later);
    assert!(team.advance(&mut t.facts).await.unwrap().events.is_empty());
    assert_eq!(team.row().unwrap().version, v(5));
}

#[tokio::test]
async fn a_wrap_by_a_non_holder_adds_no_holder_and_one_under_an_older_av_is_stale() {
    let mut t = five();
    t.a.keys
        .insert(2, tablepro_keys::keys::AccountKeys::generate().unwrap());
    t.a.sign_rotation(2);
    t.facts.know(&t.a, 2);
    let outsider = Account::generated(9, 1);
    t.facts.know(&outsider, 1);
    let five_key = key();
    let mut team = book(
        &t.me,
        Some(row(5, &[t.a.holder(2), t.me.holder(1)], KeyVersionState::Ok)),
    );
    let by_outsider = wrap(5, &five_key, (&outsider, 1), (&t.m, 1));
    let other = Account::generated(10, 1);
    t.facts.know(&other, 1);
    let by_old_key = wrap(5, &five_key, (&t.a, 1), (&other, 1));

    team.insert(&by_outsider, true).unwrap();
    let progress = team.advance(&mut t.facts).await.unwrap();
    assert_eq!(progress.refused[0].error.code(), "keys.not_holder");

    team.insert(&by_old_key, true).unwrap();
    let progress = team.advance(&mut t.facts).await.unwrap();
    assert!(
        progress
            .refused
            .iter()
            .any(|refused| refused.error.code() == "keys.stale")
    );
    let holders = &team.row().unwrap().holders;
    assert!(
        !holders
            .iter()
            .any(|holder| holder.account == t.m.id || holder.account == other.id)
    );
}

#[tokio::test]
async fn a_confirmation_by_a_member_the_rotation_made_a_holder_counts_whatever_order_they_came_in() {
    let mut t = five();
    let mut team = book(
        &t.me,
        Some(row(5, &[t.a.holder(1), t.me.holder(1)], KeyVersionState::Ok)),
    );
    let (five_key, six) = (key(), key());
    let rotation = version(
        6,
        Start::Next,
        &six,
        Some(&five_key),
        (&t.a, 1),
        &[(&t.a, 1), (&t.m, 1)],
    );
    let newcomer = Account::generated(4, 1);
    t.facts.know(&newcomer, 1);
    let confirmation = wrap(6, &six, (&t.m, 1), (&newcomer, 1));
    team.insert(&confirmation, true).unwrap();
    insert_all(&mut team, &rotation);

    team.advance(&mut t.facts).await.unwrap();

    let holders = &team.row().unwrap().holders;
    assert!(holders.contains(&t.m.holder(1)) && holders.contains(&newcomer.holder(1)));
    assert!(!holders.contains(&t.me.holder(1)));
}

#[tokio::test]
async fn a_restart_is_taken_by_a_member_that_holds_nothing_and_signed_under_an_older_av_is_stale() {
    let mut t = five();
    let owner = Account::generated(5, 2);
    t.facts.know(&owner, 2);
    let objects = version(6, Start::Over, &key(), None, (&owner, 2), &[(&owner, 2), (&t.me, 1)]);
    let mut taken = book(&t.me, Some(row(5, &[t.a.holder(1)], KeyVersionState::Ok)));
    insert_all(&mut taken, &objects);

    let progress = taken.advance(&mut t.facts).await.unwrap();

    assert_eq!(progress.events, [TeamEvent::Restarted { version: v(6) }]);
    assert!(taken.row().unwrap().holders.contains(&t.me.holder(1)));

    let stale = version(6, Start::Over, &key(), None, (&owner, 1), &[(&t.me, 1)]);
    let mut refused = book(&t.me, Some(row(5, &[t.a.holder(1)], KeyVersionState::Ok)));
    insert_all(&mut refused, &stale);
    let progress = refused.advance(&mut t.facts).await.unwrap();
    assert_eq!(refusal(&progress, &stale, "key.version"), Some("keys.stale"));
}

#[tokio::test]
async fn a_version_two_above_waits_for_the_one_between_and_stops_nothing() {
    let mut t = five();
    let mut team = book(&t.me, Some(row(5, &[t.a.holder(1)], KeyVersionState::Ok)));
    let objects = version(7, Start::Next, &key(), Some(&key()), (&t.a, 1), &[]);
    insert_all(&mut team, &objects);

    let progress = team.advance(&mut t.facts).await.unwrap();

    assert!(progress.refused.is_empty());
    assert!(progress.held.contains(&objects[0].id.to_wire()));
    assert_eq!(team.row().unwrap().state, KeyVersionState::Ok);
}

#[tokio::test]
async fn objects_of_another_team_or_purpose_are_keys_encoding() {
    let t = five();
    let mut team = book(&t.me, None);
    let personal = VersionRecord::sign(
        &origin(),
        KeyRef {
            owner: t.me.id.0,
            purpose: KeyPurpose::Personal,
            version: v(1),
        },
        Start::Over,
        &key(),
        t.me.id,
        v(1),
        &t.me.keys[&1].ask,
    )
    .unwrap();
    let personal = KeyObject {
        id: KeyRecordId::Version(personal.key),
        body: KeyBody::Version(VersionBody::of(&personal)),
    };
    let mut other = wrap(1, &key(), (&t.a, 1), (&t.me, 1));
    if let KeyRecordId::Wrap(target) = &mut other.id {
        target.owner = Uuid::from_u128(77);
    }

    assert_eq!(team.insert(&personal, true).unwrap_err().code(), "keys.encoding");
    assert_eq!(team.insert(&other, true).unwrap_err().code(), "keys.encoding");
}

#[tokio::test]
async fn a_new_member_joins_at_the_version_it_was_confirmed_with_then_follows_the_rule() {
    let mut t = five();
    let (three, four) = (key(), key());
    let mut team = book(&t.me, None);
    insert_all(
        &mut team,
        &version(3, Start::Next, &three, Some(&key()), (&t.a, 1), &[(&t.a, 1)]),
    );
    team.insert(&wrap(3, &three, (&t.a, 1), (&t.me, 1)), true).unwrap();
    insert_all(
        &mut team,
        &version(4, Start::Next, &four, Some(&three), (&t.a, 1), &[(&t.a, 1), (&t.me, 1)]),
    );

    let progress = team.advance(&mut t.facts).await.unwrap();

    assert_eq!(
        progress.events,
        [
            TeamEvent::Joined { version: v(3) },
            TeamEvent::Advanced { version: v(4) }
        ]
    );
    assert!(team.row().unwrap().holders.contains(&t.me.holder(1)));
    let keyring = TestKeyring { account: t.me.clone() };
    let read = secrets::team_key(&keyring, super::team(), &team, &mut t.facts, v(3), v(4))
        .await
        .unwrap();
    assert_eq!(read.expose(), three.expose());
}

#[tokio::test]
async fn a_stopped_device_counts_no_new_wrap_and_needs_its_own_wrap_from_a_counted_holder_to_clear() {
    let mut t = five();
    let held = [t.a.holder(1), t.me.holder(1)];
    let mut team = book(&t.me, Some(row(5, &held, KeyVersionState::Stopped)));
    let (five_key, six) = (key(), key());
    team.insert(&wrap(5, &five_key, (&t.a, 1), (&t.m, 1)), true).unwrap();
    insert_all(
        &mut team,
        &version(6, Start::Next, &six, Some(&five_key), (&t.a, 1), &[(&t.a, 1)]),
    );

    let without_own = team.advance(&mut t.facts).await.unwrap();

    assert!(without_own.events.is_empty());
    assert_eq!(team.row().unwrap().holders, row(5, &held, KeyVersionState::Ok).holders);

    team.insert(&wrap(6, &six, (&t.m, 1), (&t.me, 1)), true).unwrap();
    let by_uncounted = team.advance(&mut t.facts).await.unwrap();
    assert!(
        by_uncounted
            .refused
            .iter()
            .any(|refused| refused.error.code() == "keys.not_holder")
    );
    assert_eq!(team.row().unwrap().state, KeyVersionState::Stopped);

    // A wrap id is one per recipient, so the counted holder's wrap comes in a team that never saw M's.
    let mut team = book(&t.me, Some(row(5, &held, KeyVersionState::Stopped)));
    insert_all(
        &mut team,
        &version(6, Start::Next, &six, Some(&five_key), (&t.a, 1), &[(&t.a, 1)]),
    );
    team.insert(&wrap(6, &six, (&t.a, 1), (&t.me, 1)), true).unwrap();
    let cleared = team.advance(&mut t.facts).await.unwrap();
    assert_eq!(cleared.events, [TeamEvent::Cleared { version: v(6) }]);
    assert_eq!(team.row().unwrap().stopped_cause, None);
}

#[tokio::test]
async fn a_restart_by_a_counted_holder_never_clears_the_stop_of_a_device_whose_account_held_the_version() {
    let mut t = five();
    let held = [t.a.holder(1), t.me.holder(1)];
    let mut team = book(&t.me, Some(row(5, &held, KeyVersionState::Stopped)));
    let objects = version(6, Start::Over, &key(), None, (&t.a, 1), &[(&t.a, 1), (&t.me, 1)]);
    insert_all(&mut team, &objects);

    let progress = team.advance(&mut t.facts).await.unwrap();

    assert_eq!(refusal(&progress, &objects, "key.version"), Some("keys.not_holder"));
    assert_eq!(team.row().unwrap().state, KeyVersionState::Stopped);
}

#[tokio::test]
async fn a_wrap_whose_wrapper_waits_on_a_missing_certificate_is_held_not_refused() {
    let mut t = five();
    let newcomer = Account::generated(12, 1);
    let late = Account::generated(13, 1);
    t.facts.know(&newcomer, 1);
    t.facts.know(&late, 1);
    t.facts.certificates.remove(&(late.id, v(1)));
    let five_key = key();
    let mut team = book(
        &t.me,
        Some(row(5, &[t.a.holder(1), t.me.holder(1)], KeyVersionState::Ok)),
    );
    let to_late = wrap(5, &five_key, (&t.a, 1), (&late, 1));
    let by_late = wrap(5, &five_key, (&late, 1), (&newcomer, 1));
    team.insert(&by_late, true).unwrap();
    team.insert(&to_late, true).unwrap();

    let waiting = team.advance(&mut t.facts).await.unwrap();

    assert!(waiting.refused.is_empty(), "{:?}", waiting.refused);
    assert!(waiting.held.contains(&to_late.id.to_wire()) && waiting.held.contains(&by_late.id.to_wire()));

    t.facts.know(&late, 1);
    let arrived = team.advance(&mut t.facts).await.unwrap();

    assert!(arrived.refused.is_empty());
    let holders = &team.row().unwrap().holders;
    assert!(holders.contains(&late.holder(1)) && holders.contains(&newcomer.holder(1)));
}

#[tokio::test]
async fn a_restore_stop_is_left_to_the_restore_flow_and_a_catch_up_failure_met_meanwhile_makes_it_a_catch_up() {
    let mut t = five();
    let held = [t.a.holder(1), t.me.holder(1)];
    let mut waiting = row(5, &held, KeyVersionState::Stopped);
    waiting.stopped_cause = Some(StoppedCause::RestoreWait);
    let (five_key, six) = (key(), key());

    let mut passing = book(&t.me, Some(waiting.clone()));
    insert_all(
        &mut passing,
        &version(6, Start::Next, &six, Some(&five_key), (&t.a, 1), &[(&t.me, 1)]),
    );
    let progress = passing.advance(&mut t.facts).await.unwrap();
    assert!(progress.events.is_empty());
    assert_eq!(passing.row().unwrap().stopped_cause, Some(StoppedCause::RestoreWait));
    assert_eq!(passing.row().unwrap().version, v(5));

    let mut failing = book(&t.me, Some(waiting));
    let by_outsider = Account::generated(11, 1);
    t.facts.know(&by_outsider, 1);
    let objects = version(6, Start::Next, &six, Some(&five_key), (&by_outsider, 1), &[(&t.me, 1)]);
    insert_all(&mut failing, &objects);
    let progress = failing.advance(&mut t.facts).await.unwrap();
    assert_eq!(refusal(&progress, &objects, "key.version"), Some("keys.not_holder"));
    assert_eq!(failing.row().unwrap().stopped_cause, Some(StoppedCause::CatchUp));
}

#[tokio::test]
async fn a_stopped_device_refuses_a_counted_holder_signing_under_an_older_av() {
    let mut t = five();
    t.a.keys
        .insert(2, tablepro_keys::keys::AccountKeys::generate().unwrap());
    t.a.sign_rotation(2);
    t.facts.know(&t.a, 2);
    let held = [t.a.holder(1), t.me.holder(1)];
    let mut team = book(&t.me, Some(row(5, &held, KeyVersionState::Stopped)));
    let objects = version(6, Start::Next, &key(), Some(&key()), (&t.a, 1), &[(&t.me, 1)]);
    insert_all(&mut team, &objects);

    let progress = team.advance(&mut t.facts).await.unwrap();

    assert_eq!(refusal(&progress, &objects, "key.version"), Some("keys.stale"));
    assert_eq!(team.row().unwrap().state, KeyVersionState::Stopped);
}

#[tokio::test]
async fn reading_walks_the_rings_down_and_a_key_that_misses_its_kid_opens_nothing() {
    let mut t = five();
    let (four, five_key, six) = (key(), key(), key());
    let mut team = book(
        &t.me,
        Some(row(6, &[t.a.holder(1), t.me.holder(1)], KeyVersionState::Ok)),
    );
    insert_all(&mut team, &version(4, Start::Next, &four, Some(&key()), (&t.a, 1), &[]));
    insert_all(
        &mut team,
        &version(5, Start::Next, &five_key, Some(&four), (&t.a, 1), &[]),
    );
    insert_all(
        &mut team,
        &version(6, Start::Next, &six, Some(&five_key), (&t.a, 1), &[(&t.me, 1)]),
    );
    let keyring = TestKeyring { account: t.me.clone() };

    let read = secrets::team_key(&keyring, super::team(), &team, &mut t.facts, v(4), v(6))
        .await
        .unwrap();
    assert_eq!(read.expose(), four.expose());

    let mut wrong = book(
        &t.me,
        Some(row(7, &[t.a.holder(1), t.me.holder(1)], KeyVersionState::Ok)),
    );
    let record = version(7, Start::Over, &key(), None, (&t.a, 1), &[]);
    insert_all(&mut wrong, &record);
    wrong.insert(&wrap(7, &key(), (&t.a, 1), (&t.me, 1)), true).unwrap();
    let missed = secrets::team_key(&keyring, super::team(), &wrong, &mut t.facts, v(7), v(7)).await;
    assert_eq!(missed.unwrap_err().code(), "sync.not_allowed");
}

#[tokio::test]
async fn a_restart_without_a_ring_ends_the_walk_down() {
    let mut t = five();
    let (five_key, six) = (key(), key());
    let mut team = book(&t.me, Some(row(6, &[t.me.holder(1)], KeyVersionState::Ok)));
    insert_all(
        &mut team,
        &version(5, Start::Next, &five_key, Some(&key()), (&t.a, 1), &[]),
    );
    insert_all(
        &mut team,
        &version(6, Start::Over, &six, None, (&t.me, 1), &[(&t.me, 1)]),
    );
    let keyring = TestKeyring { account: t.me.clone() };

    assert!(
        secrets::team_key(&keyring, super::team(), &team, &mut t.facts, v(6), v(6))
            .await
            .is_ok()
    );
    let five_read = secrets::team_key(&keyring, super::team(), &team, &mut t.facts, v(5), v(6)).await;
    assert_eq!(five_read.unwrap_err().code(), "sync.not_allowed");
}

#[test]
fn a_confirmation_past_five_thousand_members_holding_the_key_is_team_full() {
    let account = |index: u128| tablepro_keys::encoding::AccountId(Uuid::from_u128(index + 1));
    let holders: Vec<Holder> = (0..5_000_u128)
        .map(|index| Holder {
            account: account(index),
            ik: tablepro_keys::keys::Ed25519Public([0; 32]),
        })
        .collect();
    let on_roster = |count: u128| Roster {
        members: (0..count)
            .map(|index| TeamMember {
                account: account(index),
                role: Role::Member,
            })
            .chain(std::iter::once(TeamMember {
                account: account(9_999),
                role: Role::Member,
            }))
            .collect(),
        role: Some(Role::Admin),
        rotation_due: false,
        stopped: Vec::new(),
        caught_up: true,
    };
    let newcomer = account(9_999);
    let team_full = crate::api::error::SyncError::Rejected {
        code: RejectedCode::TeamFull,
    };

    assert_eq!(
        roster::check_room(&on_roster(5_000), &holders, newcomer),
        Err(team_full.clone())
    );
    assert_eq!(RejectedCode::TeamFull.as_str(), "team_full");
    assert!(roster::check_room(&on_roster(5_000), &holders, holders[0].account).is_ok());
    assert!(roster::check_room(&on_roster(5_000), &holders[..4_999], newcomer).is_ok());
    // A holder that left the roster no longer counts against the limit.
    assert!(roster::check_room(&on_roster(4_999), &holders, newcomer).is_ok());
    assert!(roster::check_fits(5_000).is_ok());
    assert_eq!(roster::check_fits(5_001), Err(team_full));
}

#[test]
fn an_envelope_counts_only_under_the_version_in_force_and_never_below_the_copy_held() {
    let stale = check_open_kv(v(2), Some(v(3)), v(3), None).unwrap_err();
    assert_eq!(stale.code(), "keys.stale");
    assert_eq!(
        check_open_kv(v(4), Some(v(3)), v(4), None).unwrap_err().code(),
        "sync.not_allowed"
    );
    assert!(check_open_kv(v(3), Some(v(3)), v(4), None).is_ok());
    assert!(check_open_kv(v(1), None, v(4), None).is_ok());
    assert_eq!(
        check_open_kv(v(5), None, v(4), None).unwrap_err().code(),
        "sync.not_allowed"
    );
    assert_eq!(
        check_open_kv(v(2), None, v(4), Some(v(3))).unwrap_err().code(),
        "keys.stale"
    );
}

#[test]
fn a_team_due_a_rotation_holds_new_envelopes_and_a_plain_member_writes_none() {
    let due = Roster {
        members: Vec::new(),
        role: Some(Role::Editor),
        rotation_due: true,
        stopped: Vec::new(),
        caught_up: true,
    };
    let member = Roster {
        rotation_due: false,
        role: Some(Role::Member),
        ..due.clone()
    };
    let editor = Roster {
        rotation_due: false,
        ..due.clone()
    };
    let code = |result: Result<(), crate::api::error::SyncError>| match result {
        Err(crate::api::error::SyncError::Rejected { code }) => code.as_str().to_owned(),
        other => format!("{other:?}"),
    };

    assert_eq!(code(check_may_seal(Some(&due), false)), "rotation_due");
    assert_eq!(code(check_may_seal(Some(&editor), true)), "rotation_due");
    assert_eq!(code(check_may_seal(Some(&member), false)), "role");
    assert!(check_may_seal(Some(&editor), false).is_ok());
}

#[tokio::test]
async fn the_roster_never_makes_a_holder_and_an_alert_keeps_a_stopped_team_from_ending() {
    let mut t = five();
    let held = [t.a.holder(1), t.me.holder(1)];
    let admin_m = members(&[(&t.m, Role::Admin), (&t.me, Role::Member)]);
    let admin_a = members(&[(&t.a, Role::Admin), (&t.me, Role::Member)]);

    assert!(
        !roster::someone_can_reconfirm(&origin(), &mut t.facts, &admin_m, &held)
            .await
            .unwrap()
    );
    assert!(
        roster::someone_can_reconfirm(&origin(), &mut t.facts, &admin_a, &held)
            .await
            .unwrap()
    );

    t.a.change_ik(2, false);
    t.facts.know(&t.a, 2);
    assert!(
        !roster::someone_can_reconfirm(&origin(), &mut t.facts, &admin_a, &held)
            .await
            .unwrap()
    );

    t.facts.alert(&t.a, 2);
    assert!(
        roster::someone_can_reconfirm(&origin(), &mut t.facts, &admin_a, &held)
            .await
            .unwrap()
    );
}

async fn status(
    facts: &mut TestFacts,
    held: &[Holder],
    account: tablepro_keys::encoding::AccountId,
) -> MemberKeyStatus {
    roster::member_status(&origin(), facts, held, account).await.unwrap()
}

#[tokio::test]
async fn members_show_with_no_keys_under_an_alert_as_holders_or_waiting_for_confirmation() {
    let mut t = five();
    let stranger = Account::generated(8, 1);
    let held = [t.a.holder(1)];

    assert_eq!(status(&mut t.facts, &held, stranger.id).await, MemberKeyStatus::NoKeys);
    assert_eq!(status(&mut t.facts, &held, t.a.id).await, MemberKeyStatus::Holder);
    assert_eq!(
        status(&mut t.facts, &held, t.m.id).await,
        MemberKeyStatus::AwaitingConfirmation
    );
    t.facts.alert(&t.m, 1);
    assert_eq!(status(&mut t.facts, &held, t.m.id).await, MemberKeyStatus::Alert);
}

#[tokio::test]
async fn a_rotation_wraps_to_holders_on_the_roster_less_alerts_and_removals_and_always_to_itself() {
    let mut t = five();
    let gone = Account::generated(6, 1);
    let alerted = Account::generated(7, 1);
    t.facts.know(&gone, 1);
    t.facts.know(&alerted, 1);
    t.facts.alert(&alerted, 1);
    let held = [
        t.a.holder(1),
        t.m.holder(1),
        t.me.holder(1),
        gone.holder(1),
        alerted.holder(1),
    ];
    let on_roster = members(&[
        (&t.a, Role::Admin),
        (&t.m, Role::Member),
        (&t.me, Role::Editor),
        (&alerted, Role::Member),
    ]);

    let recipients = roster::rotation_recipients(&origin(), &mut t.facts, &on_roster, &held, t.me.id, &[t.m.id])
        .await
        .unwrap();

    let mut accounts: Vec<_> = recipients.iter().map(|certificate| certificate.account).collect();
    accounts.sort();
    let mut expected = vec![t.a.id, t.me.id];
    expected.sort();
    assert_eq!(accounts, expected);

    t.facts
        .certificates
        .insert((t.a.id, v(1)), Certificate::Invalid(KeysError::Signature));
    let missing = roster::rotation_recipients(&origin(), &mut t.facts, &on_roster, &held, t.me.id, &[]).await;
    assert_eq!(missing.unwrap_err().code(), "sync.not_allowed");
}

#[tokio::test]
async fn a_team_due_after_a_members_own_account_rotation_is_left_to_that_member_and_any_other_cause_to_anyone() {
    let mut t = five();
    let six = key();
    let mut team = book(
        &t.me,
        Some(row(
            6,
            &[t.a.holder(1), t.m.holder(1), t.me.holder(1)],
            KeyVersionState::Ok,
        )),
    );
    insert_all(
        &mut team,
        &version(
            6,
            Start::Next,
            &six,
            Some(&key()),
            (&t.a, 1),
            &[(&t.a, 1), (&t.m, 1), (&t.me, 1)],
        ),
    );
    let on_roster = members(&[(&t.a, Role::Admin), (&t.m, Role::Member), (&t.me, Role::Editor)]);

    assert!(
        !roster::rotation_left_to_a_member(&team, &mut t.facts, &on_roster, t.me.id)
            .await
            .unwrap()
    );

    // M removed a lost device: a rotation at `av` 2 under the same IK, which M's review rotates the team after.
    t.m.keys
        .insert(2, tablepro_keys::keys::AccountKeys::generate().unwrap());
    t.m.sign_rotation(2);
    t.facts.know(&t.m, 2);
    assert!(
        roster::rotation_left_to_a_member(&team, &mut t.facts, &on_roster, t.me.id)
            .await
            .unwrap()
    );
    // This device's own rotation is its own pending flow's, never a reason to wait on itself.
    assert!(
        !roster::rotation_left_to_a_member(&team, &mut t.facts, &on_roster, t.m.id)
            .await
            .unwrap()
    );

    // A replaced the recovery key instead: any holder rotates.
    let mut replaced = five();
    replaced.a.change_ik(2, true);
    replaced.facts.know(&replaced.a, 2);
    let mut team = book(&replaced.me, Some(row(6, &[replaced.a.holder(1)], KeyVersionState::Ok)));
    insert_all(
        &mut team,
        &version(
            6,
            Start::Next,
            &six,
            Some(&key()),
            (&replaced.a, 1),
            &[(&replaced.a, 1)],
        ),
    );
    let on_roster = members(&[(&replaced.a, Role::Admin), (&replaced.me, Role::Editor)]);
    assert!(
        !roster::rotation_left_to_a_member(&team, &mut replaced.facts, &on_roster, replaced.me.id)
            .await
            .unwrap()
    );
}
