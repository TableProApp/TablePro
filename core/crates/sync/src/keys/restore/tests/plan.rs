// The push-back order of 0051 (After a restore; What cannot go back) over the vectors' world, and the restore-ordering
// cases G0 rounds 5 to 8 settled: a confirmation before the later version that needs it (I5-M3), the wait for the
// holding of the version before (I6-H1), no wait for `start` 1 (I7-H1), the wait ending only for a confirmation
// whose author left the owners and admins (I7-M1, S8-M2) and only on a roster read after catch-up (S8-M1).

use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose, Version};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::scope_key::Start;

use super::fakes::Holds;
use super::world::{World, v};
use crate::api::ids::ScopeName;
use crate::api::scopes::{Role, TeamMember};
use crate::api::state::{KeyVersionRow, KeyVersionState};
use crate::keys::HeldObject;
use crate::keys::restore::plan::{Inputs, Plan, TeamInputs, TeamVerdict, plan};

const GENESIS: &str = "two genesis change sets, and an identical retry";
const ROTATION: &str = "a rotation while a reset is pending";
const APPROVAL: &str = "an approval over a stopped personal key and over an ended scope";
const RECOVERY: &str = "a recovery from a fresh row, then a call that needs approval";

fn ids(objects: &[HeldObject]) -> Vec<String> {
    objects
        .iter()
        .map(|held| format!("{} {}", held.object.id.kind().name(), held.object.id.to_wire()))
        .collect()
}

fn sorted(mut ids: Vec<String>) -> Vec<String> {
    ids.sort();
    ids
}

fn set_ids(plan: &Plan) -> Vec<Vec<String>> {
    plan.sets.iter().map(|set| ids(&set.objects)).collect()
}

fn dedup(mut objects: Vec<HeldObject>) -> Vec<HeldObject> {
    let mut seen = std::collections::HashSet::new();
    objects.retain(|held| seen.insert(held.object.id.to_wire() + held.object.id.kind().name()));
    objects
}

struct Personal {
    world: World,
    genesis: Vec<HeldObject>,
    rotation: Vec<HeldObject>,
    approval: Vec<HeldObject>,
}

impl Personal {
    fn new() -> Self {
        let world = World::load();
        Self {
            genesis: dedup(world.records_labelled(GENESIS, "B's genesis")),
            rotation: world.records_labelled(ROTATION, "B's rotation"),
            approval: world.records_labelled(APPROVAL, "B with PK 2"),
            world,
        }
    }

    fn b(&self) -> KeyDeviceId {
        self.world.certified_device(GENESIS, "B's genesis: device certificate")
    }

    fn n(&self) -> KeyDeviceId {
        self.world
            .certified_device(APPROVAL, "B with PK 2 and the ended team: the new device's certificate")
    }

    fn held(&self) -> Vec<HeldObject> {
        [self.genesis.clone(), self.rotation.clone(), self.approval.clone()].concat()
    }

    fn server_with(&self, objects: &[HeldObject]) -> Holds {
        Holds::default().with(ScopeName::Personal, objects.iter().map(|held| held.object.id))
    }

    fn plan(&self, device: KeyDeviceId, approved: bool, held: &[HeldObject], server: &Holds) -> Plan {
        plan(&Inputs {
            account: self.world.account("P"),
            key_device: device,
            newest_av: v(2),
            approved,
            personal: held,
            teams: Vec::new(),
            server,
        })
    }
}

#[test]
fn the_account_set_the_server_lacks_goes_back_without_the_approval_made_at_its_av() {
    let personal = Personal::new();
    let server = personal.server_with(&personal.genesis);

    let plan = personal.plan(personal.b(), true, &personal.held(), &server);

    assert_eq!(
        set_ids(&plan),
        [ids(&{
            let mut expected = personal.rotation.clone();
            let wraps: Vec<HeldObject> = expected
                .iter()
                .filter(|held| matches!(held.object.id, KeyRecordId::Wrap(_)))
                .cloned()
                .collect();
            expected.retain(|held| !matches!(held.object.id, KeyRecordId::Wrap(_)));
            let mut wraps = wraps;
            wraps.sort_by_key(|held| held.object.id.to_wire());
            expected.extend(wraps);
            expected
        })]
    );
    let pushed = &plan.sets[0].objects;
    assert!(
        pushed.iter().all(|held| personal.rotation.contains(held)),
        "exactly as held"
    );
    assert!(pushed.iter().all(|held| !personal.approval.contains(held)));
}

#[test]
fn a_restore_to_before_genesis_puts_back_every_account_set_in_ascending_av() {
    let personal = Personal::new();

    let plan = personal.plan(personal.b(), false, &personal.held(), &Holds::default());

    assert_eq!(plan.sets.len(), 2);
    assert_eq!(
        plan.sets[0].objects[0].object.id.to_wire(),
        personal.genesis[0].object.id.to_wire()
    );
    assert!(matches!(plan.sets[1].objects[0].object.id, KeyRecordId::Account { av, .. } if av == v(2)));
    let blobs = |set: usize| {
        plan.sets[set]
            .objects
            .iter()
            .filter(|held| matches!(held.object.id, KeyRecordId::Recovery { .. }))
            .count()
    };
    assert_eq!((blobs(0), blobs(1)), (0, 1), "only the newest blob goes back");
}

#[test]
fn a_device_whose_approval_the_restore_lost_pushes_nothing() {
    let personal = Personal::new();
    let server = personal.server_with(&personal.genesis);

    let plan = personal.plan(personal.n(), false, &personal.held(), &server);

    assert!(plan.sets.is_empty() && plan.teams.is_empty());
}

#[test]
fn a_recovery_from_a_fresh_row_goes_back_from_the_device_it_certifies() {
    let personal = Personal::new();
    let recovery = personal
        .world
        .records_labelled(RECOVERY, "N's recovery from a fresh row");
    let held = [personal.genesis.clone(), recovery.clone()].concat();

    let plan = personal.plan(personal.n(), false, &held, &personal.server_with(&personal.genesis));

    assert_eq!(plan.sets.len(), 1);
    assert_eq!(plan.sets[0].objects.len(), recovery.len());
}

#[test]
fn an_av_the_device_verified_with_no_certificate_held_puts_nothing_back() {
    let personal = Personal::new();
    let held: Vec<HeldObject> = personal
        .held()
        .into_iter()
        .filter(|held| !matches!(held.object.id, KeyRecordId::Account { av, .. } if av == v(2)))
        .collect();

    let plan = personal.plan(personal.b(), true, &held, &personal.server_with(&personal.genesis));

    assert!(plan.sets.is_empty());
}

#[test]
fn an_unapplied_candidate_is_not_pushed_back() {
    let personal = Personal::new();
    let mut held = personal.held();
    for object in &mut held {
        if matches!(object.object.id, KeyRecordId::Recovery { av, .. } if av == v(2)) {
            object.applied = false;
        }
    }

    let plan = personal.plan(personal.b(), true, &held, &personal.server_with(&personal.genesis));

    assert!(
        !plan.sets[0]
            .objects
            .iter()
            .any(|held| matches!(held.object.id, KeyRecordId::Recovery { .. }))
    );
}

// The server still holds the account's own certificates: these cases lose team objects only.
fn own_certificates(world: &World, name: &str) -> Vec<KeyRecordId> {
    (1..=2)
        .map(|av| KeyRecordId::Account {
            account: world.account(name),
            av: v(av),
        })
        .collect()
}

struct TeamCase {
    world: World,
    me: &'static str,
    newest: u32,
    state: KeyVersionState,
    held: Vec<HeldObject>,
    server: Vec<HeldObject>,
    roster: Option<Vec<TeamMember>>,
}

impl TeamCase {
    fn new(me: &'static str, newest: u32) -> Self {
        Self {
            world: World::load(),
            me,
            newest,
            state: KeyVersionState::Ok,
            held: Vec::new(),
            server: Vec::new(),
            roster: None,
        }
    }

    fn scope(&self) -> ScopeName {
        ScopeName::Team(self.world.team)
    }

    fn hold(&mut self, objects: impl IntoIterator<Item = HeldObject>) -> &mut Self {
        self.held.extend(objects);
        self
    }

    // Objects the server holds again, which the device also holds.
    fn back(&mut self, objects: impl IntoIterator<Item = HeldObject>) -> &mut Self {
        for object in objects {
            self.server.push(object.clone());
            if !self.held.contains(&object) {
                self.held.push(object);
            }
        }
        self
    }

    fn roster(&mut self, members: &[(&str, Role)]) -> &mut Self {
        self.roster = Some(
            members
                .iter()
                .map(|(name, role)| TeamMember {
                    account: self.world.account(name),
                    role: *role,
                })
                .collect(),
        );
        self
    }

    fn plan(&self) -> (Vec<Vec<String>>, TeamVerdict) {
        let row = KeyVersionRow {
            scope: self.scope(),
            purpose: KeyPurpose::Team,
            version: v(self.newest),
            record: [0; 32],
            holders: Vec::new(),
            state: self.state,
            stopped_cause: None,
            epoch: None,
        };
        let server = Holds::default()
            .with(self.scope(), self.server.iter().map(|held| held.object.id))
            .with(ScopeName::Personal, own_certificates(&self.world, self.me));
        let plan = plan(&Inputs {
            account: self.world.account(self.me),
            key_device: self.world.device(self.me),
            newest_av: v(2),
            approved: true,
            personal: &[],
            teams: vec![TeamInputs {
                team: self.world.team,
                objects: &self.held,
                row: Some(&row),
                roster: self.roster.as_deref(),
            }],
            server: &server,
        });
        let verdict = plan.teams[0].1.clone();
        (set_ids(&plan), verdict)
    }

    fn version(&self, version: u32, signer: &str, start: Start) -> HeldObject {
        self.world.team_version(version, signer, 2, start)
    }

    fn wrap(&self, version: u32, wrapper: &str, recipient: &str) -> HeldObject {
        self.world.team_wrap(version, (wrapper, 2), (recipient, 2))
    }

    fn members(&self, names: &[&str]) -> Vec<HeldObject> {
        names.iter().map(|name| self.world.member(name, 2)).collect()
    }
}

const PUSHED_BACK: &str = "a team version pushed back after a restore by its signer's device";
const ONLY_ANOTHER: &str = "a version only another member signed, missing after a restore";
const TWO_ADMINS: &str = "a rotation and a confirmation by two admins, after a restore";

fn one(held: &HeldObject) -> Vec<String> {
    ids(std::slice::from_ref(held))
}

#[test]
fn the_signer_pushes_back_its_lost_version_with_its_ring_and_rotation_wraps_exactly_as_held() {
    let mut case = TeamCase::new("A", 7);
    let world = World::load();
    let v6 = case.version(6, "A", Start::Next);
    let v7 = world.record(PUSHED_BACK, "version 7 by A");
    let ring = world.record(PUSHED_BACK, "its ring");
    let to_m = world.record(PUSHED_BACK, "version 7 to M");
    let members = case.members(&["A", "M"]);
    let to_m_6 = case.wrap(6, "A", "M");
    case.back(members)
        .back([v6, to_m_6])
        .hold([v7.clone(), ring.clone(), to_m.clone()]);

    let (sets, verdict) = case.plan();

    assert_eq!(sets, [[one(&v7), one(&ring), one(&to_m)].concat()]);
    assert_eq!(verdict, TeamVerdict::Done);
}

#[test]
fn a_version_only_another_member_signed_stops_the_team_until_its_signer_pushes_it_back() {
    let mut case = TeamCase::new("P", 7);
    let world = World::load();
    let v7 = world.record(ONLY_ANOTHER, "version 7 by A");
    let members = case.members(&["A", "P"]);
    let v6 = case.version(6, "A", Start::Next);
    case.back(members).back([v6]).hold([v7.clone()]);

    let (sets, verdict) = case.plan();

    assert!(sets.is_empty());
    assert_eq!(
        verdict,
        TeamVerdict::Waits {
            version: v(7),
            awaiting: vec![v7.object.id]
        }
    );
    case.back([v7]);
    assert_eq!(case.plan(), (Vec::new(), TeamVerdict::Done));
}

#[test]
fn an_admin_s_confirmation_goes_back_alone_once_the_version_another_admin_rotated_is_back() {
    let world = World::load();
    let v7 = world.record(TWO_ADMINS, "version 7 by A");
    let ring = world.record(TWO_ADMINS, "its ring");
    let to_o = world.record(TWO_ADMINS, "version 7 to O");
    let confirms_p = world.record(TWO_ADMINS, "O confirms P at version 7");

    let mut admin = TeamCase::new("A", 7);
    let members = admin.members(&["A", "O", "P"]);
    let v6 = admin.version(6, "A", Start::Next);
    let to_o_6 = admin.wrap(6, "A", "O");
    admin.back(members.clone()).back([v6.clone(), to_o_6.clone()]).hold([
        v7.clone(),
        ring.clone(),
        to_o.clone(),
        confirms_p.clone(),
    ]);
    let (sets, verdict) = admin.plan();
    assert_eq!(sets, [[one(&v7), one(&ring), one(&to_o)].concat()]);
    assert_eq!(verdict, TeamVerdict::Done);

    let mut other = TeamCase::new("O", 7);
    other
        .back(members)
        .back([v6, to_o_6])
        .hold([v7.clone(), ring.clone(), to_o.clone(), confirms_p.clone()]);
    assert_eq!(
        other.plan(),
        (
            Vec::new(),
            TeamVerdict::Waits {
                version: v(7),
                awaiting: vec![v7.object.id]
            }
        )
    );
    other.back([v7, ring, to_o]);
    assert_eq!(other.plan(), (vec![one(&confirms_p)], TeamVerdict::Done));
}

// Three admins: A rotates to version 2, O confirms P at version 2, then P signs version 3. The restore keeps version
// 1 (0051's three-admin test).
struct ThreeAdmins {
    v1: Vec<HeldObject>,
    v2: Vec<HeldObject>,
    confirms_p: HeldObject,
    v3: Vec<HeldObject>,
    members: Vec<HeldObject>,
}

impl ThreeAdmins {
    fn new(case: &TeamCase) -> Self {
        Self {
            v1: vec![
                case.version(1, "A", Start::Over),
                case.wrap(1, "A", "A"),
                case.wrap(1, "A", "O"),
            ],
            v2: vec![
                case.version(2, "A", Start::Next),
                case.world.team_ring(2),
                case.wrap(2, "A", "A"),
                case.wrap(2, "A", "O"),
            ],
            confirms_p: case.wrap(2, "O", "P"),
            v3: vec![
                case.version(3, "P", Start::Next),
                case.world.team_ring(3),
                case.wrap(3, "P", "A"),
                case.wrap(3, "P", "O"),
                case.wrap(3, "P", "P"),
            ],
            members: case.members(&["A", "O", "P"]),
        }
    }

    fn all(&self) -> Vec<HeldObject> {
        [
            self.v1.clone(),
            self.v2.clone(),
            vec![self.confirms_p.clone()],
            self.v3.clone(),
        ]
        .concat()
    }
}

#[test]
fn the_third_admin_waits_for_the_version_then_for_the_confirmation_then_pushes_its_own() {
    let mut case = TeamCase::new("P", 3);
    let three = ThreeAdmins::new(&case);
    case.back(three.members.clone())
        .back(three.v1.clone())
        .hold(three.all());
    case.roster(&[("A", Role::Admin), ("O", Role::Admin), ("P", Role::Admin)]);
    assert!(matches!(case.plan().1, TeamVerdict::Waits { version, .. } if version == v(2)));

    case.back(three.v2.clone());
    let (sets, verdict) = case.plan();
    assert!(sets.is_empty());
    assert_eq!(
        verdict,
        TeamVerdict::Waits {
            version: v(3),
            awaiting: vec![three.confirms_p.object.id]
        }
    );

    case.back([three.confirms_p.clone()]);
    let (sets, verdict) = case.plan();
    assert_eq!(verdict, TeamVerdict::Done);
    assert_eq!(sets.len(), 1);
    assert_eq!(sorted(sets[0].clone()), sorted(ids(&three.v3)));
    assert_eq!(
        sets[0][..2],
        ids(&three.v3)[..2],
        "the version, then its ring, then its wraps"
    );
}

#[test]
fn the_confirming_admin_puts_its_confirmation_back_before_the_later_version_that_needs_it() {
    let mut case = TeamCase::new("O", 3);
    let three = ThreeAdmins::new(&case);
    case.back(three.members.clone())
        .back(three.v1.clone())
        .back(three.v2.clone())
        .hold(three.all());

    let (sets, verdict) = case.plan();

    assert_eq!(sets, [one(&three.confirms_p)]);
    assert!(matches!(verdict, TeamVerdict::Waits { version, .. } if version == v(3)));
}

#[test]
fn the_wait_ends_when_the_confirmation_s_author_is_no_longer_an_owner_or_admin_on_a_caught_up_roster() {
    let mut case = TeamCase::new("P", 3);
    let three = ThreeAdmins::new(&case);
    case.back(three.members.clone())
        .back(three.v1.clone())
        .back(three.v2.clone())
        .hold(three.all());
    assert!(
        matches!(case.plan().1, TeamVerdict::Waits { .. }),
        "no roster read after catch-up yet"
    );

    case.roster(&[("A", Role::Admin), ("O", Role::Editor), ("P", Role::Member)]);
    assert_eq!(case.plan(), (Vec::new(), TeamVerdict::Ends));

    case.roster(&[("A", Role::Admin), ("P", Role::Member)]);
    assert_eq!(
        case.plan().1,
        TeamVerdict::Ends,
        "an author off the roster cannot put it back either"
    );
}

#[test]
fn a_rotation_wrap_whose_author_is_now_an_editor_keeps_the_device_waiting() {
    // A rotated version 2 to the holders of version 1, P among them; A is then an editor, and a holder can still put
    // version 2 back while the team is `rotation_due` (S8-M2).
    let mut case = TeamCase::new("P", 3);
    let v1 = vec![
        case.version(1, "A", Start::Over),
        case.wrap(1, "A", "A"),
        case.wrap(1, "A", "P"),
    ];
    let v2_record = case.version(2, "A", Start::Next);
    let to_p = case.wrap(2, "A", "P");
    let v3 = vec![
        case.version(3, "P", Start::Next),
        case.world.team_ring(3),
        case.wrap(3, "P", "P"),
    ];
    let members = case.members(&["P"]);
    let a_member = case.world.member("A", 2);
    case.back(members)
        .back(v1)
        .back([v2_record])
        .hold([to_p.clone(), a_member])
        .hold(v3);
    case.roster(&[("A", Role::Editor), ("P", Role::Member)]);

    let (sets, verdict) = case.plan();

    assert!(sets.is_empty());
    assert_eq!(
        verdict,
        TeamVerdict::Waits {
            version: v(3),
            awaiting: vec![
                to_p.object.id,
                KeyRecordId::Member {
                    account: case.world.account("A"),
                    av: v(2)
                }
            ]
        }
    );
}

#[test]
fn version_1_and_a_restart_go_back_with_no_wait() {
    let mut case = TeamCase::new("A", 1);
    let v1 = vec![case.version(1, "A", Start::Over), case.wrap(1, "A", "A")];
    let confirms_o = case.wrap(1, "A", "O");
    let members = case.members(&["A"]);
    case.hold(members.clone()).hold(v1.clone()).hold([confirms_o.clone()]);
    let (sets, verdict) = case.plan();
    assert_eq!(sets, [one(&members[0]), ids(&v1), one(&confirms_o)]);
    assert_eq!(verdict, TeamVerdict::Done);

    let mut restart = TeamCase::new("A", 5);
    let v4 = restart.version(4, "O", Start::Next);
    let v5 = vec![
        restart.version(5, "A", Start::Over),
        restart.world.team_ring(5),
        restart.wrap(5, "A", "A"),
    ];
    let members = restart.members(&["A", "O"]);
    restart.back(members).back([v4]).hold(v5.clone());
    assert_eq!(restart.plan(), (vec![ids(&v5)], TeamVerdict::Done));
}

// 0064: a wrap to a recipient whose `key.member` the server lacks leaves its version's set and goes back on its own.
#[test]
fn a_wrap_to_a_recipient_the_server_has_no_certificate_for_goes_back_alone() {
    let mut case = TeamCase::new("A", 7);
    let v6 = case.version(6, "A", Start::Next);
    let to_m_6 = case.wrap(6, "A", "M");
    let v7 = vec![
        case.version(7, "A", Start::Next),
        case.world.team_ring(7),
        case.wrap(7, "A", "A"),
    ];
    let to_m = case.wrap(7, "A", "M");
    let own = case.members(&["A"]);
    case.back(own).back([v6, to_m_6]).hold(v7.clone()).hold([to_m.clone()]);

    let (sets, verdict) = case.plan();

    assert_eq!(sets, [ids(&v7), one(&to_m)]);
    assert_eq!(verdict, TeamVerdict::Done);
}

#[test]
fn a_later_confirmation_leaves_the_rotation_set_and_goes_back_alone() {
    let mut case = TeamCase::new("A", 7);
    let v6 = case.version(6, "A", Start::Next);
    let to_m_6 = case.wrap(6, "A", "M");
    let v7 = vec![
        case.version(7, "A", Start::Next),
        case.world.team_ring(7),
        case.wrap(7, "A", "A"),
        case.wrap(7, "A", "M"),
    ];
    let confirms_p = case.wrap(7, "A", "P");
    let under_av_3 = case.world.team_wrap(7, ("A", 3), ("E", 1));
    let members = case.members(&["A", "M", "P"]);
    case.back(members)
        .back([v6, to_m_6])
        .hold(v7.clone())
        .hold([confirms_p.clone(), under_av_3.clone()]);

    let (sets, _) = case.plan();

    let mut alone = vec![one(&confirms_p), one(&under_av_3)];
    alone.sort();
    assert_eq!(sets[0], ids(&v7));
    let mut rest = sets[1..].to_vec();
    rest.sort();
    assert_eq!(rest, alone);
}

#[test]
fn own_key_member_records_go_back_first_each_alone_oldest_first() {
    let mut case = TeamCase::new("A", 6);
    let first = case.world.member("A", 1);
    let second = case.world.member("A", 2);
    let v6 = case.version(6, "A", Start::Next);
    case.back([v6]).hold([second.clone(), first.clone()]);

    let (sets, verdict) = case.plan();

    assert_eq!(sets, [one(&first), one(&second)]);
    assert_eq!(verdict, TeamVerdict::Done);
}

#[test]
fn a_lost_confirmation_a_plain_member_signed_still_goes_back_alone() {
    let mut case = TeamCase::new("M", 6);
    let v6 = case.version(6, "A", Start::Next);
    let to_m = case.wrap(6, "A", "M");
    let confirms_p = case.wrap(6, "M", "P");
    let members = case.members(&["A", "M"]);
    case.back(members).back([v6, to_m]).hold([confirms_p.clone()]);

    assert_eq!(case.plan(), (vec![one(&confirms_p)], TeamVerdict::Done));
}

#[test]
fn the_holding_waits_for_the_wrap_signer_s_key_member() {
    let mut case = TeamCase::new("P", 7);
    let v6 = case.version(6, "A", Start::Next);
    let to_p = case.wrap(6, "A", "P");
    let v7 = vec![
        case.version(7, "P", Start::Next),
        case.world.team_ring(7),
        case.wrap(7, "P", "P"),
    ];
    let a_member = case.world.member("A", 2);
    let members = case.members(&["P"]);
    case.back(members)
        .back([v6, to_p])
        .hold([a_member.clone()])
        .hold(v7.clone());

    let (sets, verdict) = case.plan();
    assert!(sets.is_empty());
    assert_eq!(
        verdict,
        TeamVerdict::Waits {
            version: v(7),
            awaiting: vec![a_member.object.id]
        }
    );

    case.back([a_member]);
    assert_eq!(case.plan(), (vec![ids(&v7)], TeamVerdict::Done));
}

#[test]
fn an_ended_team_puts_nothing_back_whatever_another_device_restores() {
    let mut case = TeamCase::new("A", 7);
    let v7 = vec![case.version(7, "A", Start::Next), case.world.team_ring(7)];
    let members = case.members(&["A"]);
    case.hold(members).hold(v7);
    case.state = KeyVersionState::Ended;

    assert_eq!(case.plan(), (Vec::new(), TeamVerdict::Done));
}

#[test]
fn a_team_the_device_holds_no_version_of_only_puts_its_key_member_back() {
    let world = World::load();
    let member = world.member("P", 2);
    let held = vec![member.clone()];
    let server = Holds::default().with(ScopeName::Personal, own_certificates(&world, "P"));

    let plan = plan(&Inputs {
        account: world.account("P"),
        key_device: world.device("P"),
        newest_av: Version::new(2).unwrap(),
        approved: true,
        personal: &[],
        teams: vec![TeamInputs {
            team: world.team,
            objects: &held,
            row: None,
            roster: None,
        }],
        server: &server,
    });

    assert_eq!(set_ids(&plan), [one(&member)]);
    assert_eq!(plan.teams, [(world.team, TeamVerdict::Done)]);
}

#[test]
fn a_version_the_server_holds_but_the_device_does_not_still_lets_its_own_wraps_go_back() {
    let mut case = TeamCase::new("A", 6);
    let confirms_p = case.wrap(5, "A", "P");
    let v5 = case.version(5, "O", Start::Next);
    let v6 = case.version(6, "O", Start::Next);
    let members = case.members(&["A", "O", "P"]);
    case.back(members).hold([confirms_p.clone()]);
    case.server.push(v5);
    case.server.push(v6);

    assert_eq!(case.plan(), (vec![one(&confirms_p)], TeamVerdict::Done));
}

#[test]
fn the_holding_of_a_version_whose_record_the_device_lacks_is_read_from_the_wrap_to_it() {
    let mut case = TeamCase::new("P", 7);
    let v6 = case.version(6, "A", Start::Next);
    let to_p = case.wrap(6, "A", "P");
    let v7 = vec![
        case.version(7, "P", Start::Next),
        case.world.team_ring(7),
        case.wrap(7, "P", "P"),
    ];
    let members = case.members(&["A", "P"]);
    case.back(members).back([to_p]).hold(v7.clone());
    case.server.push(v6);

    assert_eq!(case.plan(), (vec![ids(&v7)], TeamVerdict::Done));
}

#[test]
fn a_team_that_ends_on_a_lost_confirmation_takes_none_of_the_sets_planned_before() {
    let mut case = TeamCase::new("P", 3);
    let three = ThreeAdmins::new(&case);
    let others = case.members(&["A", "O"]);
    let own = case.world.member("P", 2);
    case.back(others)
        .back(three.v1.clone())
        .back(three.v2.clone())
        .hold(three.all())
        .hold([own]);
    case.roster(&[("A", Role::Admin), ("O", Role::Member), ("P", Role::Member)]);

    assert_eq!(case.plan(), (Vec::new(), TeamVerdict::Ends));
}

#[test]
fn without_the_record_of_the_version_before_the_device_cannot_call_the_wrap_a_confirmation_and_waits() {
    let mut case = TeamCase::new("P", 3);
    let three = ThreeAdmins::new(&case);
    let held: Vec<HeldObject> = three
        .all()
        .into_iter()
        .filter(|held| held.object.id != three.v1[0].object.id)
        .collect();
    case.back(three.members.clone()).back(three.v2.clone()).hold(held);
    case.server.push(three.v1[0].clone());
    case.roster(&[("A", Role::Admin), ("O", Role::Member), ("P", Role::Member)]);

    assert!(matches!(case.plan().1, TeamVerdict::Waits { version, .. } if version == v(3)));
}

// 0064: an account change set needs no blob, so a certificate with no base reads as lacking and its group goes back,
// the older one without its blob.
#[test]
fn an_account_certificate_with_no_base_goes_back_and_only_the_newest_carries_a_blob() {
    let personal = Personal::new();
    let held = personal.held();

    let plan = plan(&Inputs {
        account: personal.world.account("P"),
        key_device: personal.b(),
        newest_av: v(2),
        approved: true,
        personal: &held,
        teams: Vec::new(),
        server: &super::fakes::Unjudged,
    });

    assert!(!plan.blind);
    let blobs: Vec<usize> = plan
        .sets
        .iter()
        .map(|set| {
            set.objects
                .iter()
                .filter(|held| held.object.id.kind() == tablepro_keys::record_id::KeyKind::Recovery)
                .count()
        })
        .collect();
    assert_eq!(blobs, [0, 1]);
}
