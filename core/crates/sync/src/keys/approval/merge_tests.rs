// The merge rows of 0056's Vectors, with the G0 attacks S6-C1 and S7-C1, which must fail closed.

use std::collections::HashMap;

use tablepro_keys::KeysError;
use tablepro_keys::encoding::{AccountId, KeyDeviceId, KeyPurpose, TeamId, Version};
use tablepro_keys::keys::{Ed25519Public, X25519Public};
use tablepro_keys::sas::SasDevice;
use tablepro_keys::trust::{PinHow, TrustPin, TrustPlaintext, TrustVersion};
use uuid::Uuid;

use super::merge::{Approver, HeldTables, Merge, MergeFacts, Merged, merge};
use crate::api::ids::ScopeName;
use crate::api::state::{Holder, KeyPinRow, KeyVersionRow, KeyVersionState, StoppedCause};

const P: AccountId = AccountId(Uuid::from_u128(0x11));
const A: AccountId = AccountId(Uuid::from_u128(0x22));
const TEAM: TeamId = TeamId(Uuid::from_u128(0x33));

fn v(value: u32) -> Version {
    Version::new(value).unwrap()
}

fn ik(byte: u8) -> Ed25519Public {
    Ed25519Public([byte; 32])
}

#[derive(Default)]
struct Facts {
    // (purpose, version) to (digest, signer av, applied).
    versions: HashMap<(KeyPurpose, u32), ([u8; 32], u32, bool)>,
    endorsements: HashMap<(AccountId, Ed25519Public), (Ed25519Public, u32)>,
}

impl Facts {
    fn version(mut self, purpose: KeyPurpose, version: u32, digest: u8, signer_av: u32, applied: bool) -> Self {
        self.versions
            .insert((purpose, version), ([digest; 32], signer_av, applied));
        self
    }

    fn endorse(mut self, account: AccountId, from: Ed25519Public, to: Ed25519Public, av: u32) -> Self {
        self.endorsements.insert((account, from), (to, av));
        self
    }
}

impl MergeFacts for Facts {
    fn version_signer(
        &self,
        purpose: KeyPurpose,
        version: Version,
        record: &[u8; 32],
    ) -> Result<Option<Version>, KeysError> {
        match self.versions.get(&(purpose, version.get())) {
            None => Ok(None),
            Some((digest, _, true)) if digest != record => Err(KeysError::Conflict),
            Some((digest, _, false)) if digest != record => Ok(None),
            Some((_, signer_av, _)) => Ok(Some(v(*signer_av))),
        }
    }

    fn endorsed_by(&self, account: AccountId, ik: &Ed25519Public) -> Option<(Ed25519Public, Version)> {
        self.endorsements.get(&(account, *ik)).map(|(next, av)| (*next, v(*av)))
    }
}

fn pin(account: AccountId, ik: Ed25519Public, av: u32) -> KeyPinRow {
    KeyPinRow {
        account,
        ik,
        av: v(av),
        how: PinHow::Compared,
        alert: false,
        replaced: Vec::new(),
    }
}

fn trust_pin(account: AccountId, ik: Ed25519Public, av: u32) -> TrustPin {
    TrustPin {
        account,
        ik,
        av: v(av),
        how: PinHow::FirstUse,
        alert: false,
        replaced: Vec::new(),
    }
}

fn personal_row(purpose: KeyPurpose, version: u32, digest: u8) -> KeyVersionRow {
    KeyVersionRow {
        scope: ScopeName::Personal,
        purpose,
        version: v(version),
        record: [digest; 32],
        holders: Vec::new(),
        state: KeyVersionState::Ok,
        stopped_cause: None,
        epoch: None,
    }
}

fn team_row(version: u32, digest: u8, state: KeyVersionState) -> KeyVersionRow {
    KeyVersionRow {
        scope: ScopeName::Team(TEAM),
        purpose: KeyPurpose::Team,
        version: v(version),
        record: [digest; 32],
        holders: vec![
            Holder {
                account: A,
                ik: ik(0xa2),
            },
            Holder {
                account: P,
                ik: ik(0xb1),
            },
        ],
        stopped_cause: (state == KeyVersionState::Stopped).then_some(StoppedCause::CatchUp),
        state,
        epoch: None,
    }
}

fn trust_version(owner: Uuid, purpose: KeyPurpose, version: u32, digest: u8) -> TrustVersion {
    TrustVersion {
        owner,
        purpose,
        version: v(version),
        record: [digest; 32],
    }
}

fn approver_device() -> SasDevice {
    SasDevice {
        key_device: KeyDeviceId(Uuid::from_u128(0x44)),
        dek: X25519Public([4; 32]),
        dsk: Ed25519Public([5; 32]),
    }
}

// The approver at `av` 2 under IK 0xb1, with personal and history version 2 under it.
fn trust_at_av2() -> TrustPlaintext {
    TrustPlaintext {
        pins: vec![trust_pin(P, ik(0xb1), 2)],
        versions: vec![
            trust_version(P.0, KeyPurpose::Personal, 2, 0x20),
            trust_version(P.0, KeyPurpose::History, 2, 0x21),
        ],
    }
}

fn facts_av2() -> Facts {
    Facts::default()
        .version(KeyPurpose::Personal, 2, 0x20, 2, true)
        .version(KeyPurpose::History, 2, 0x21, 2, true)
}

fn run(held: &HeldTables, trust: &TrustPlaintext, av: u32, facts: &Facts) -> Result<Merge, KeysError> {
    let approver = Approver {
        account: P,
        ik: ik(0xb1),
        av: v(av),
        trust,
        device: approver_device(),
    };
    merge(held, &approver, facts)
}

fn merged(held: &HeldTables, trust: &TrustPlaintext, av: u32, facts: &Facts) -> Merged {
    match run(held, trust, av, facts).unwrap() {
        Merge::Merged(merged) => *merged,
        Merge::Waiting { .. } => panic!("the merge waits"),
    }
}

fn version_of(merged: &Merged, scope: ScopeName, purpose: KeyPurpose) -> &KeyVersionRow {
    merged
        .versions
        .iter()
        .find(|row| row.scope == scope && row.purpose == purpose)
        .unwrap()
}

fn pin_of(merged: &Merged, account: AccountId) -> &KeyPinRow {
    merged.pins.iter().find(|pin| pin.account == account).unwrap()
}

#[test]
fn a_device_with_no_key_tables_takes_what_the_approver_sent() {
    let mut trust = trust_at_av2();
    trust.pins.push(trust_pin(A, ik(0xa2), 2));

    let merged = merged(&HeldTables::default(), &trust, 2, &facts_av2());

    assert_eq!(pin_of(&merged, P).ik, ik(0xb1));
    assert_eq!(pin_of(&merged, A).av, v(2));
    assert_eq!(
        version_of(&merged, ScopeName::Personal, KeyPurpose::Personal).version,
        v(2)
    );
    assert_eq!(
        version_of(&merged, ScopeName::Personal, KeyPurpose::History).record,
        [0x21; 32]
    );
    assert_eq!(merged.device_pins.len(), 1);
    assert_eq!(merged.device_pins[0].key_device, approver_device().key_device);
}

#[test]
fn an_approver_below_the_device_s_own_av_is_keys_stale() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 2)],
        versions: vec![personal_row(KeyPurpose::Personal, 2, 0x20)],
    };
    let mut trust = trust_at_av2();
    trust.pins = vec![trust_pin(P, ik(0xb1), 1)];
    let facts = Facts::default().version(KeyPurpose::Personal, 1, 0x10, 1, true);

    let error = run(&held, &trust, 1, &facts).unwrap_err();

    assert_eq!(error.code(), "keys.stale");
}

#[test]
fn a_trust_plaintext_whose_own_pin_is_not_the_compared_ik_is_keys_mismatch() {
    let mut other_ik = trust_at_av2();
    other_ik.pins = vec![trust_pin(P, ik(0xb9), 2)];
    let mut no_own = trust_at_av2();
    no_own.pins.clear();

    assert_eq!(
        run(&HeldTables::default(), &other_ik, 2, &facts_av2())
            .unwrap_err()
            .code(),
        "keys.mismatch"
    );
    assert_eq!(
        run(&HeldTables::default(), &no_own, 2, &facts_av2())
            .unwrap_err()
            .code(),
        "keys.mismatch"
    );
}

#[test]
fn an_own_ik_the_device_saw_replaced_never_comes_back() {
    let mut own = pin(P, ik(0xb2), 2);
    own.replaced = vec![ik(0xb1)];
    let held = HeldTables {
        pins: vec![own],
        versions: Vec::new(),
    };

    let error = run(&held, &trust_at_av2(), 2, &facts_av2()).unwrap_err();

    assert_eq!(error.code(), "keys.retired_ik");
}

#[test]
fn a_device_locked_by_its_own_account_s_reset_takes_the_resetting_device_s_pin() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb0), 1)],
        versions: vec![personal_row(KeyPurpose::Personal, 1, 0x10)],
    };

    let merged = merged(&held, &trust_at_av2(), 2, &facts_av2());

    let own = pin_of(&merged, P);
    assert_eq!((own.ik, own.av), (ik(0xb1), v(2)));
    assert_eq!(
        version_of(&merged, ScopeName::Personal, KeyPurpose::Personal).version,
        v(2)
    );
}

#[test]
fn another_account_pinned_under_another_ik_opens_an_alert() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 2), pin(A, ik(0xa1), 1)],
        versions: Vec::new(),
    };
    let mut trust = trust_at_av2();
    trust.pins.push(trust_pin(A, ik(0xa9), 3));

    let merged = merged(&held, &trust, 2, &facts_av2());

    let a = pin_of(&merged, A);
    assert_eq!((a.ik, a.av, a.alert), (ik(0xa1), v(1), true));
    assert_eq!(merged.alerts_opened, vec![A]);
}

#[test]
fn another_account_follows_a_higher_av_under_the_same_ik_and_keeps_its_how() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 2), pin(A, ik(0xa1), 1)],
        versions: Vec::new(),
    };
    let mut trust = trust_at_av2();
    let mut offered = trust_pin(A, ik(0xa1), 4);
    offered.alert = true;
    trust.pins.push(offered);

    let merged = merged(&held, &trust, 2, &facts_av2());

    let a = pin_of(&merged, A);
    assert_eq!((a.av, a.how, a.alert), (v(4), PinHow::Compared, true));
}

#[test]
fn a_pinned_ik_the_trust_lists_as_replaced_is_followed_only_with_an_endorsement() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 2), pin(A, ik(0xa1), 1)],
        versions: Vec::new(),
    };
    let mut trust = trust_at_av2();
    let mut offered = trust_pin(A, ik(0xa2), 2);
    offered.replaced = vec![ik(0xa1)];
    trust.pins.push(offered);
    let endorsed = facts_av2().endorse(A, ik(0xa1), ik(0xa2), 2);

    let followed = merged(&held, &trust, 2, &endorsed);
    let alerted = merged(&held, &trust, 2, &facts_av2());

    let a = pin_of(&followed, A);
    assert_eq!((a.ik, a.how, a.alert), (ik(0xa2), PinHow::Replaced, false));
    assert_eq!(a.replaced, vec![ik(0xa1)]);
    assert_eq!(followed.replaced, vec![A]);
    let a = pin_of(&alerted, A);
    assert_eq!((a.ik, a.alert), (ik(0xa1), true));
    assert_eq!(a.replaced, vec![ik(0xa1)]);
}

#[test]
fn an_approver_behind_on_a_replace_the_device_followed_changes_nothing() {
    let mut a = pin(A, ik(0xa2), 2);
    a.replaced = vec![ik(0xa1)];
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 2), a.clone()],
        versions: Vec::new(),
    };
    let mut trust = trust_at_av2();
    trust.pins.push(trust_pin(A, ik(0xa1), 1));

    let merged = merged(&held, &trust, 2, &facts_av2());

    assert_eq!(pin_of(&merged, A), &a);
    assert!(merged.alerts_opened.is_empty());
}

#[test]
fn an_approver_with_a_lower_personal_version_leaves_the_device_s_own() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 2)],
        versions: vec![personal_row(KeyPurpose::Personal, 3, 0x30)],
    };
    let facts = facts_av2().version(KeyPurpose::Personal, 3, 0x30, 2, true);

    let merged = merged(&held, &trust_at_av2(), 2, &facts);

    assert_eq!(
        version_of(&merged, ScopeName::Personal, KeyPurpose::Personal).version,
        v(3)
    );
}

#[test]
fn another_record_at_an_equal_personal_version_is_keys_conflict() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 2)],
        versions: vec![personal_row(KeyPurpose::Personal, 2, 0x29)],
    };

    let error = run(&held, &trust_at_av2(), 2, &facts_av2()).unwrap_err();

    assert_eq!(error, KeysError::Conflict);
}

// S7-C1: C, kept on `av` 1, took personal versions 2 and 3 signed under the old account key and still holds its
// version 2. B, at `av` 2 with version 2 signed under it, approves C: the approval fails, and no old-key version
// becomes current through it.
#[test]
fn s7_c1_a_stale_device_holding_old_key_versions_is_refused_with_keys_conflict() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 1)],
        versions: vec![personal_row(KeyPurpose::Personal, 3, 0x13)],
    };
    let facts =
        facts_av2()
            .version(KeyPurpose::Personal, 2, 0x12, 1, true)
            .version(KeyPurpose::Personal, 3, 0x13, 1, true);

    let error = run(&held, &trust_at_av2(), 2, &facts).unwrap_err();

    assert_eq!(error, KeysError::Conflict);
}

// S7-C1 after an anchored rebuild that kept only C's version 3: C takes `av` 2 and B's version 2, and its version 3
// signed under `av` 1 is never current, however high its number.
#[test]
fn s7_c1_after_a_rebuild_the_old_key_version_is_never_current() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 1)],
        versions: vec![personal_row(KeyPurpose::Personal, 3, 0x13)],
    };
    let facts = facts_av2().version(KeyPurpose::Personal, 3, 0x13, 1, true);

    let merged = merged(&held, &trust_at_av2(), 2, &facts);

    assert_eq!(pin_of(&merged, P).av, v(2));
    let personal = version_of(&merged, ScopeName::Personal, KeyPurpose::Personal);
    assert_eq!((personal.version, personal.record), (v(2), [0x20; 32]));
}

// S7-C1 the other way: C, at `av` 2 but holding personal version 3 signed under `av` 1, approves B. B keeps its
// version 2.
#[test]
fn s7_c1_an_approver_offering_an_old_key_version_leaves_the_device_s_current_one() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 2)],
        versions: vec![
            personal_row(KeyPurpose::Personal, 2, 0x20),
            personal_row(KeyPurpose::History, 2, 0x21),
        ],
    };
    let mut trust = trust_at_av2();
    trust.versions[0] = trust_version(P.0, KeyPurpose::Personal, 3, 0x13);
    let facts = facts_av2().version(KeyPurpose::Personal, 3, 0x13, 1, true);

    let merged = merged(&held, &trust, 2, &facts);

    let personal = version_of(&merged, ScopeName::Personal, KeyPurpose::Personal);
    assert_eq!((personal.version, personal.record), (v(2), [0x20; 32]));
}

#[test]
fn neither_side_holding_a_version_under_the_merged_av_is_keys_stale() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 1)],
        versions: vec![personal_row(KeyPurpose::Personal, 2, 0x12)],
    };
    let mut trust = trust_at_av2();
    trust.versions[0] = trust_version(P.0, KeyPurpose::Personal, 2, 0x12);
    let facts = facts_av2().version(KeyPurpose::Personal, 2, 0x12, 1, true);

    let error = run(&held, &trust, 2, &facts).unwrap_err();

    assert_eq!(error.code(), "keys.stale");
}

#[test]
fn an_approver_version_record_not_yet_held_waits() {
    let facts = Facts::default().version(KeyPurpose::History, 2, 0x21, 2, true);

    let merge = run(&HeldTables::default(), &trust_at_av2(), 2, &facts).unwrap();

    assert_eq!(
        merge,
        Merge::Waiting {
            purpose: KeyPurpose::Personal,
            version: v(2)
        }
    );
}

#[test]
fn a_stopped_personal_key_clears_only_with_the_version_under_the_current_av_and_an_ended_scope_stays_ended() {
    let mut stopped = personal_row(KeyPurpose::Personal, 1, 0x10);
    stopped.stop(StoppedCause::CatchUp);
    let ended = team_row(4, 0x40, KeyVersionState::Ended);
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 1)],
        versions: vec![stopped, ended.clone()],
    };
    let mut trust = trust_at_av2();
    trust.versions.push(trust_version(TEAM.0, KeyPurpose::Team, 5, 0x50));

    let merged = merged(&held, &trust, 2, &facts_av2());

    let personal = version_of(&merged, ScopeName::Personal, KeyPurpose::Personal);
    assert_eq!((personal.version, personal.state), (v(2), KeyVersionState::Ok));
    assert_eq!(merged.resumed, vec![KeyPurpose::Personal]);
    assert_eq!(version_of(&merged, ScopeName::Team(TEAM), KeyPurpose::Team), &ended);
}

// S6-C1: B saw A's rotation and holds team version 6. C, which the server kept behind, took version 7 under A's old
// key and version 8 from M, and approves B. B keeps version 6 with its holders and state, stopped or not; version 8
// is only a hint its own Advancing checks refuse.
#[test]
fn s6_c1_a_held_team_scope_keeps_its_version_holders_and_state_stopped_or_not() {
    for state in [KeyVersionState::Ok, KeyVersionState::Stopped] {
        let held = HeldTables {
            pins: vec![pin(P, ik(0xb1), 2), pin(A, ik(0xa2), 2)],
            versions: vec![
                personal_row(KeyPurpose::Personal, 2, 0x20),
                personal_row(KeyPurpose::History, 2, 0x21),
                team_row(6, 0x60, state),
            ],
        };
        let mut trust = trust_at_av2();
        trust.pins.push(trust_pin(A, ik(0xa2), 1));
        trust.versions.push(trust_version(TEAM.0, KeyPurpose::Team, 8, 0x80));

        let merged = merged(&held, &trust, 2, &facts_av2());

        assert_eq!(
            version_of(&merged, ScopeName::Team(TEAM), KeyPurpose::Team),
            &team_row(6, 0x60, state)
        );
        assert_eq!(merged.hints, vec![TEAM]);
        assert_eq!(pin_of(&merged, A).av, v(2), "a lower av never becomes the newest");
    }
}

#[test]
fn another_record_at_an_equal_team_version_is_keys_conflict() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 2)],
        versions: vec![team_row(6, 0x60, KeyVersionState::Ok)],
    };
    let mut trust = trust_at_av2();
    trust.versions.push(trust_version(TEAM.0, KeyPurpose::Team, 6, 0x61));

    let error = run(&held, &trust, 2, &facts_av2()).unwrap_err();

    assert_eq!(error, KeysError::Conflict);
}

// S6-C1 with no copy of the team on B: a team scope new to the device takes the approver's version and record, `ok`,
// and its holders come only from the wraps it then accepts.
#[test]
fn a_team_scope_new_to_the_device_takes_the_approver_s_version_with_no_holders() {
    let mut trust = trust_at_av2();
    trust.versions.push(trust_version(TEAM.0, KeyPurpose::Team, 8, 0x80));

    let merged = merged(&HeldTables::default(), &trust, 2, &facts_av2());

    let team = version_of(&merged, ScopeName::Team(TEAM), KeyPurpose::Team);
    assert_eq!(
        (team.version, team.record, team.state),
        (v(8), [0x80; 32], KeyVersionState::Ok)
    );
    assert!(team.holders.is_empty());
}

#[test]
fn a_trust_plaintext_naming_another_account_s_personal_key_is_keys_mismatch() {
    let mut trust = trust_at_av2();
    trust.versions.push(trust_version(A.0, KeyPurpose::Personal, 9, 0x90));

    let error = run(&HeldTables::default(), &trust, 2, &facts_av2()).unwrap_err();

    assert_eq!(error.code(), "keys.mismatch");
}

#[test]
fn a_scope_the_trust_leaves_out_stays_as_it_was() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 2), pin(A, ik(0xa1), 1)],
        versions: vec![
            personal_row(KeyPurpose::Personal, 2, 0x20),
            personal_row(KeyPurpose::History, 2, 0x21),
            team_row(6, 0x60, KeyVersionState::Ok),
        ],
    };

    let merged = merged(&held, &trust_at_av2(), 2, &facts_av2());

    assert_eq!(pin_of(&merged, A), &pin(A, ik(0xa1), 1));
    assert_eq!(
        version_of(&merged, ScopeName::Team(TEAM), KeyPurpose::Team),
        &team_row(6, 0x60, KeyVersionState::Ok)
    );
}

#[test]
fn an_endorsement_chain_that_does_not_reach_the_approver_s_ik_still_opens_an_alert() {
    let held = HeldTables {
        pins: vec![pin(P, ik(0xb1), 2), pin(A, ik(0xa1), 1)],
        versions: Vec::new(),
    };
    let mut trust = trust_at_av2();
    let mut offered = trust_pin(A, ik(0xa2), 2);
    offered.replaced = vec![ik(0xa1)];
    trust.pins.push(offered);
    let facts = facts_av2().endorse(A, ik(0xa1), ik(0xa3), 2);

    let merged = merged(&held, &trust, 2, &facts);

    let a = pin_of(&merged, A);
    assert_eq!((a.ik, a.alert), (ik(0xa3), true));
    assert_eq!(merged.alerts_opened, vec![A]);
}
