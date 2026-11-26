// 0056's Vectors rows for teams, from `tablepro-keys`'s flows vectors: each scenario's signed objects, run through the
// team rules from the state its `given` describes. S3-C1 and S5-M2, the attacks of gate G0, must fail closed.

use std::collections::BTreeMap;

use serde_json::Value;
use tablepro_keys::KeysError;
use tablepro_keys::body::KeyObject;
use tablepro_keys::encoding::AccountId;
use tablepro_keys::keys::{AccountKeys, Ed25519Seed};
use tablepro_keys::recovery::RecoveryKey;

use super::{Account, TestFacts, TestKeyring, book, hex_bytes, origin, row, v, x25519};
use crate::api::key_flows::{RefusedObject, Roster};
use crate::api::scopes::{Role, TeamMember};
use crate::api::state::{Holder, KeyVersionState};
use crate::keys::team::book::{Progress, TeamBook, TeamEvent};
use crate::keys::team::roster;
use crate::keys::team::secrets;

const FLOWS: &str = include_str!("../../../../../keys/vectors/flows.json");

struct World {
    accounts: BTreeMap<String, Account>,
    document: Value,
}

fn text(value: &Value) -> &str {
    value.as_str().unwrap()
}

fn world() -> World {
    let document: Value = serde_json::from_str(FLOWS).unwrap();
    assert_eq!(text(&document["origin"]), origin().as_str());
    let mut accounts = BTreeMap::new();
    for entry in document["world"]["accounts"].as_array().unwrap() {
        let name = text(&entry["name"]).to_owned();
        if name.contains(' ') {
            continue;
        }
        let id = AccountId::from_wire(text(&entry["account"])).unwrap();
        let recovery = RecoveryKey::from_bytes(hex_bytes(text(&entry["r_hex"])).try_into().unwrap());
        let ik = recovery.identity_seed(&origin(), id).unwrap();
        assert_eq!(ik.public().unwrap().0.to_vec(), hex_bytes(text(&entry["ik_hex"])));
        let mut account = Account {
            id,
            ik,
            keys: BTreeMap::new(),
            certificates: BTreeMap::new(),
        };
        for keys in entry["account_keys"].as_array().unwrap() {
            let av = u32::try_from(keys["av"].as_u64().unwrap()).unwrap();
            account.keys.insert(
                av,
                AccountKeys {
                    ask: Ed25519Seed::from_slice(&hex_bytes(text(&keys["ask_seed_hex"]))).unwrap(),
                    aek: x25519(text(&keys["aek_secret_hex"])),
                },
            );
            account.sign_rotation(av);
        }
        accounts.insert(name, account);
    }
    World { accounts, document }
}

impl World {
    fn account(&self, name: &str) -> Account {
        self.accounts[name].clone()
    }

    fn scenario(&self, name: &str) -> &Value {
        self.document["scenarios"]
            .as_array()
            .unwrap()
            .iter()
            .find(|scenario| text(&scenario["name"]) == name)
            .unwrap()
    }

    // The objects of one step, in the order the step lists them.
    fn step(&self, scenario: &str, index: usize) -> Vec<KeyObject> {
        self.scenario(scenario)["steps"][index]["records"]
            .as_array()
            .unwrap()
            .iter()
            .map(object)
            .collect()
    }

    fn team_record(&self, label: &str) -> KeyObject {
        self.document["world"]["version_records"]
            .as_array()
            .unwrap()
            .iter()
            .find(|record| text(&record["label"]) == label)
            .map(object)
            .unwrap()
    }

    fn team_key(&self, version: u64) -> Vec<u8> {
        self.document["world"]["team_keys"]
            .as_array()
            .unwrap()
            .iter()
            .find(|key| key["version"].as_u64() == Some(version))
            .map(|key| hex_bytes(text(&key["key_hex"])))
            .unwrap()
    }
}

fn object(record: &Value) -> KeyObject {
    let fields = serde_json::to_string(&record["fields"]).unwrap();
    KeyObject::parse(text(&record["kind"]), text(&record["id"]), fields.as_bytes()).unwrap()
}

// Certificates go to the pins, as the service offers them; versions, rings and wraps go to the team.
fn take(book: &mut TeamBook, objects: &[KeyObject]) {
    for object in objects {
        if object.id.kind() != tablepro_keys::record_id::KeyKind::Member {
            book.insert(object, true).unwrap();
        }
    }
}

fn refused(progress: &Progress, object: &KeyObject) -> Option<KeysError> {
    let id = object.id.to_wire();
    progress
        .refused
        .iter()
        .find(|refused| refused.record_id == id)
        .map(|RefusedObject { error, .. }| error.clone())
}

fn holders(names: &[(&Account, u32)]) -> Vec<Holder> {
    names.iter().map(|(account, av)| account.holder(*av)).collect()
}

fn roster(members: &[(&Account, Role)]) -> Roster {
    let members = members
        .iter()
        .map(|(account, role)| TeamMember {
            account: account.id,
            role: *role,
        })
        .collect();
    crate::keys::test_roster(super::team(), members, None, false, true, crate::api::ids::EpochId(uuid::Uuid::nil()))
}

#[test]
fn the_vector_record_digests_are_the_ones_the_rules_anchor() {
    let world = world();
    let record = world.team_record("team 6").version_record().unwrap();
    let expected = world.document["world"]["version_records"]
        .as_array()
        .unwrap()
        .iter()
        .find(|record| text(&record["label"]) == "team 6")
        .map(|record| hex_bytes(text(&record["verify"]["digest_hex"])))
        .unwrap();

    assert_eq!(record.digest(&origin()).unwrap().to_vec(), expected);
}

#[tokio::test]
async fn a_version_from_a_non_holder_is_not_holder_and_one_under_an_older_av_is_stale() {
    let world = world();
    let name = "team version from a non-holder, and from a holder under an older av";
    let (a, m, e, p) = (
        world.account("A"),
        world.account("M"),
        world.account("E"),
        world.account("P"),
    );
    for (index, expected) in [(0, KeysError::NotHolder), (1, KeysError::Stale { held: 2, offered: 1 })] {
        let mut facts = TestFacts::default();
        facts.know(&a, 2);
        facts.know(&m, 1);
        facts.know(&e, 1);
        facts.know(&p, 2);
        let mut team = book(&p, Some(row(5, &holders(&[(&a, 2), (&m, 1)]), KeyVersionState::Ok)));
        let objects = world.step(name, index);
        take(&mut team, &objects);

        let progress = team.advance(&mut facts).await.unwrap();

        let version = objects
            .iter()
            .find(|object| object.id.kind().name() == "key.version")
            .unwrap();
        assert_eq!(
            refused(&progress, version),
            Some(expected.clone()),
            "{}",
            expected.code()
        );
        assert_eq!(team.row().unwrap().version, v(5));
        assert_eq!(team.row().unwrap().state, KeyVersionState::Stopped);
        assert_eq!(progress.events, [TeamEvent::Stopped { at: v(5) }]);
    }
}

#[tokio::test]
async fn an_older_av_signature_on_the_way_stops_at_the_version_before_it() {
    let world = world();
    let (a, p) = (world.account("A"), world.account("P"));
    let mut facts = TestFacts::default();
    facts.know(&a, 2);
    facts.know(&p, 2);
    let mut team = book(&p, Some(row(5, &holders(&[(&a, 2)]), KeyVersionState::Ok)));
    let objects = world.step("an older-av signature on the way to a newer version", 0);
    take(&mut team, &objects);

    let progress = team.advance(&mut facts).await.unwrap();

    assert_eq!(refused(&progress, &objects[0]).unwrap().code(), "keys.stale");
    assert_eq!(team.row().unwrap().version, v(5));
    assert_eq!(team.row().unwrap().state, KeyVersionState::Stopped);
}

// S3-C1: a removed device's old ASK of A, with the server, signs version 7 and wraps it to M, whose own current key
// then signs version 8. The device saw A's rotation, so it must stop at 6 and never count M.
#[tokio::test]
async fn s3_c1_an_old_key_version_and_its_recipients_next_version_stop_the_device_at_six() {
    let world = world();
    let (a, m, p) = (world.account("A"), world.account("M"), world.account("P"));
    let mut facts = TestFacts::default();
    facts.know(&a, 2);
    facts.know(&m, 2);
    facts.know(&p, 2);
    let held = holders(&[(&a, 2), (&p, 2)]);
    let mut team = book(&p, Some(row(6, &held, KeyVersionState::Ok)));
    let objects = world.step(
        "version 7 under a removed device's old key, then version 8 by its recipient",
        0,
    );
    take(&mut team, &objects);

    let progress = team.advance(&mut facts).await.unwrap();

    assert_eq!(refused(&progress, &objects[0]).unwrap().code(), "keys.stale");
    let after = team.row().unwrap();
    assert_eq!((after.version, after.state), (v(6), KeyVersionState::Stopped));
    assert_eq!(after.holders, row(6, &held, KeyVersionState::Ok).holders);
    assert!(!after.holders.iter().any(|holder| holder.account == m.id));

    // Judging the same objects again moves nothing.
    let again = team.advance(&mut facts).await.unwrap();
    assert!(again.events.is_empty());
    assert_eq!(team.row().unwrap().version, v(6));
}

#[tokio::test]
async fn a_stopped_device_takes_a_rotation_by_a_holder_it_counted_and_refuses_one_by_another_admin() {
    let world = world();
    let name = "a stopped device offered a rotation by a holder, and by a non-holder";
    let (a, o, p) = (world.account("A"), world.account("O"), world.account("P"));
    for (index, taken) in [(0, true), (1, false)] {
        let mut facts = TestFacts::default();
        facts.know(&a, 2);
        facts.know(&o, 2);
        facts.know(&p, 2);
        let mut team = book(
            &p,
            Some(row(6, &holders(&[(&a, 2), (&p, 2)]), KeyVersionState::Stopped)),
        );
        let objects = world.step(name, index);
        take(&mut team, &objects);

        let progress = team.advance(&mut facts).await.unwrap();

        let after = team.row().unwrap();
        if taken {
            assert_eq!((after.version, after.state), (v(7), KeyVersionState::Ok));
            assert_eq!(progress.events, [TeamEvent::Cleared { version: v(7) }]);
            assert!(after.holders.contains(&p.holder(2)) && after.holders.contains(&a.holder(2)));
        } else {
            assert_eq!(refused(&progress, &objects[0]).unwrap().code(), "keys.not_holder");
            assert_eq!((after.version, after.state), (v(6), KeyVersionState::Stopped));
        }
    }
}

#[tokio::test]
async fn a_stopped_device_takes_the_rotation_of_a_qualifying_admin_that_rotated_its_account_keys_since() {
    let world = world();
    let (a, p) = (world.account("A"), world.account("P"));
    let mut facts = TestFacts::default();
    facts.know(&a, 3);
    facts.know(&p, 2);
    let mut team = book(
        &p,
        Some(row(6, &holders(&[(&a, 2), (&p, 2)]), KeyVersionState::Stopped)),
    );
    let objects = world.step(
        "a stopped device whose qualifying admin rotated its account keys since",
        0,
    );
    let team_objects: Vec<KeyObject> = objects
        .into_iter()
        .filter(|object| object.id.kind().name() != "key.account")
        .collect();
    take(&mut team, &team_objects);

    let progress = team.advance(&mut facts).await.unwrap();

    assert_eq!(progress.events, [TeamEvent::Cleared { version: v(7) }]);
    assert_eq!(team.row().unwrap().state, KeyVersionState::Ok);
}

#[tokio::test]
async fn no_one_can_confirm_a_stopped_team_again_when_no_owner_or_admin_on_the_roster_held_its_version() {
    let world = world();
    let (a, o, m, p) = (
        world.account("A"),
        world.account("O"),
        world.account("M"),
        world.account("P"),
    );
    let mut facts = TestFacts::default();
    for account in [&a, &o, &m, &p] {
        facts.know(account, 2);
    }
    let held = holders(&[(&a, 2), (&p, 2)]);
    let without_a = roster(&[(&o, Role::Owner), (&m, Role::Member), (&p, Role::Member)]);
    let with_a = roster(&[(&a, Role::Admin), (&o, Role::Owner), (&p, Role::Member)]);
    let a_as_editor = roster(&[(&a, Role::Editor), (&o, Role::Owner), (&p, Role::Member)]);

    assert!(
        !roster::someone_can_reconfirm(&origin(), &mut facts, &without_a, &held)
            .await
            .unwrap()
    );
    assert!(
        roster::someone_can_reconfirm(&origin(), &mut facts, &with_a, &held)
            .await
            .unwrap()
    );
    assert!(
        !roster::someone_can_reconfirm(&origin(), &mut facts, &a_as_editor, &held)
            .await
            .unwrap()
    );
}

// S5-M2: the device stopped at 6. The server brings a new wrap of 6 to M under A's old key, calls M an admin, and offers
// M's rotation with a wrap to the device. M was never among the holders it counted for 6.
#[tokio::test]
async fn s5_m2_a_wrap_seen_after_the_stop_never_makes_a_holder_and_the_device_stays_stopped() {
    let world = world();
    let (a, m, p) = (world.account("A"), world.account("M"), world.account("P"));
    let mut facts = TestFacts::default();
    facts.know(&a, 2);
    facts.know(&m, 2);
    facts.know(&p, 2);
    let held = holders(&[(&a, 2), (&p, 2)]);
    let mut team = book(&p, Some(row(6, &held, KeyVersionState::Stopped)));
    let objects = world.step(
        "while stopped at 6, a wrap of 6 under a removed key, then M's rotation",
        0,
    );
    take(&mut team, &objects);

    let progress = team.advance(&mut facts).await.unwrap();

    let version = &objects[1];
    assert_eq!(refused(&progress, version).unwrap().code(), "keys.not_holder");
    let after = team.row().unwrap();
    assert_eq!((after.version, after.state), (v(6), KeyVersionState::Stopped));
    assert_eq!(after.holders, row(6, &held, KeyVersionState::Ok).holders);
    // The roster calling M an admin is no holder evidence: no one who held 6 is on it, so the team would end.
    let m_as_admin = roster(&[(&m, Role::Admin), (&p, Role::Member)]);
    assert!(
        !roster::someone_can_reconfirm(&origin(), &mut facts, &m_as_admin, &after.holders)
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn a_member_rotating_while_due_is_taken_with_every_holder_it_wraps_to() {
    let world = world();
    let (a, m, p) = (world.account("A"), world.account("M"), world.account("P"));
    let mut facts = TestFacts::default();
    for account in [&a, &m, &p] {
        facts.know(account, 2);
    }
    let mut team = book(
        &p,
        Some(row(6, &holders(&[(&a, 2), (&m, 2), (&p, 2)]), KeyVersionState::Ok)),
    );
    take(&mut team, &world.step("a member rotates while a rotation is due", 0));

    let progress = team.advance(&mut facts).await.unwrap();

    assert_eq!(progress.events, [TeamEvent::Advanced { version: v(7) }]);
    assert_eq!(
        team.row().unwrap().holders,
        row(7, &holders(&[(&a, 2), (&m, 2), (&p, 2)]), KeyVersionState::Ok).holders
    );
}

#[tokio::test]
async fn a_member_the_server_added_with_no_confirming_wrap_gets_no_key() {
    let world = world();
    let (a, e) = (world.account("A"), world.account("E"));
    let mut facts = TestFacts::default();
    facts.know(&a, 2);
    facts.know(&e, 1);
    let mut team = book(&e, None);
    take(&mut team, &[world.team_record("team 6")]);
    take(
        &mut team,
        &world.step("a member the server added with no confirming wrap", 0),
    );

    let progress = team.advance(&mut facts).await.unwrap();

    assert!(team.row().is_none());
    assert!(progress.events.is_empty());
}

#[tokio::test]
async fn a_wrap_naming_a_certificate_the_team_lacks_is_held_until_it_arrives() {
    let world = world();
    let (a, m, p) = (world.account("A"), world.account("M"), world.account("P"));
    let name = "a team version or wrap naming an account with no key.member at that av";
    let mut facts = TestFacts::default();
    facts.know(&a, 2);
    facts.know(&m, 1);
    facts.know(&p, 2);
    let mut team = book(&p, Some(row(6, &holders(&[(&a, 2), (&p, 2)]), KeyVersionState::Ok)));
    let wrap = world.step(name, 0);
    take(&mut team, &wrap);

    let waiting = team.advance(&mut facts).await.unwrap();

    assert!(waiting.held.contains(&wrap[0].id.to_wire()));
    assert!(waiting.refused.is_empty());
    assert!(!team.row().unwrap().holders.iter().any(|holder| holder.account == m.id));

    facts.know(&m, 2);
    let arrived = team.advance(&mut facts).await.unwrap();

    assert!(arrived.held.is_empty());
    assert!(team.row().unwrap().holders.contains(&m.holder(2)));
}

#[tokio::test]
async fn a_restart_shown_to_a_holder_is_not_holder() {
    let world = world();
    let (m, o) = (world.account("M"), world.account("O"));
    let mut facts = TestFacts::default();
    facts.know(&m, 2);
    facts.know(&o, 2);
    let mut team = book(&m, Some(row(6, &holders(&[(&m, 2)]), KeyVersionState::Ok)));
    let objects = world.step(
        "a restart shown to a holder, and a restart while a holder is on the roster",
        0,
    );
    take(&mut team, &objects);

    let progress = team.advance(&mut facts).await.unwrap();

    assert_eq!(refused(&progress, &objects[0]).unwrap().code(), "keys.not_holder");
    assert_eq!(team.row().unwrap().version, v(6));
}

#[tokio::test]
async fn a_sole_owner_who_reset_takes_its_own_restart_and_its_ring_opens_version_six() {
    let world = world();
    let (a, mut o) = (world.account("A"), world.account("O"));
    // O held 6 under the IK it had before its reset; its certificate at `av` 2 is under the new one.
    let before_reset = Ed25519Seed::generate().unwrap();
    let current = std::mem::replace(&mut o.ik, before_reset);
    o.sign_rotation(1);
    o.ik = current;
    let mut facts = TestFacts::default();
    facts.know(&a, 2);
    facts.know(&o, 2);
    let six = world.team_record("team 6");
    let mut held = row(6, &[o.holder(1)], KeyVersionState::Ok);
    held.record = six.version_record().unwrap().digest(&origin()).unwrap();
    let mut team = TeamBook::new(origin(), super::team(), o.id, Some(held));
    take(&mut team, &[six]);
    take(&mut team, &world.step("a sole owner who reset restarts its team", 0));

    let progress = team.advance(&mut facts).await.unwrap();

    assert_eq!(progress.events, [TeamEvent::Restarted { version: v(7) }]);
    assert_eq!(team.row().unwrap().holders, [o.holder(2)]);
    let keyring = TestKeyring { account: o.clone() };
    let six_key = secrets::team_key(&keyring, super::team(), &team, &mut facts, v(6), v(7))
        .await
        .unwrap();
    assert_eq!(six_key.expose().to_vec(), world.team_key(6));
}

#[tokio::test]
async fn a_team_scope_an_approval_imported_builds_its_holders_from_the_signer_and_the_wraps_it_accepts() {
    let world = world();
    let (a, p) = (world.account("A"), world.account("P"));
    let mut facts = TestFacts::default();
    facts.know(&a, 2);
    facts.know(&p, 2);
    let six = world.team_record("team 6");
    let mut imported = row(6, &[], KeyVersionState::Ok);
    imported.record = six.version_record().unwrap().digest(&origin()).unwrap();
    let mut team = TeamBook::new(origin(), super::team(), p.id, Some(imported));
    let six_key = tablepro_keys::keys::ScopeKey::from_slice(&world.team_key(6)).unwrap();
    take(&mut team, &[six, super::wrap(6, &six_key, (&a, 2), (&p, 2))]);

    team.advance(&mut facts).await.unwrap();

    let mut expected = vec![a.holder(2), p.holder(2)];
    expected.sort();
    assert_eq!(team.row().unwrap().holders, expected);
    assert_eq!(team.row().unwrap().state, KeyVersionState::Ok);
}

#[tokio::test]
async fn a_device_stopped_below_a_version_reads_no_key_of_it() {
    let world = world();
    let (a, m, p) = (world.account("A"), world.account("M"), world.account("P"));
    let mut facts = TestFacts::default();
    facts.know(&a, 2);
    facts.know(&m, 2);
    facts.know(&p, 2);
    let mut team = book(&p, Some(row(6, &holders(&[(&a, 2), (&p, 2)]), KeyVersionState::Ok)));
    take(
        &mut team,
        &world.step(
            "version 7 under a removed device's old key, then version 8 by its recipient",
            0,
        ),
    );
    team.advance(&mut facts).await.unwrap();
    let keyring = TestKeyring { account: p.clone() };

    let eight = secrets::team_key(
        &keyring,
        super::team(),
        &team,
        &mut facts,
        v(8),
        team.row().unwrap().version,
    )
    .await;

    assert_eq!(eight.unwrap_err().code(), "sync.not_allowed");
}
