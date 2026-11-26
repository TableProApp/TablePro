// What a device pushes back after a new epoch, in 0051's order (Keys on the wire, After a restore), and where its
// push-back must wait or end instead (What cannot go back). Pure: the inputs are the key objects the device holds,
// what the server holds now, and the team rosters; `restore` gathers them and acts on the plan.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use tablepro_keys::encoding::{AccountId, KeyDeviceId, KeyPurpose, TeamId, Version, WrapPurpose};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::scope_key::{KeyRef, Start, VersionRecord};
use tablepro_keys::wrap::{Recipient, Wrap};

use crate::api::ids::ScopeName;
use crate::api::scopes::TeamMember;
use crate::api::state::{KeyVersionRow, KeyVersionState};
use crate::keys::HeldObject;

// Whether the server holds a key object now, in the current epoch.
pub(crate) trait ServerView {
    fn holds(&self, scope: ScopeName, id: &KeyRecordId) -> bool;

    // Whether the device knows where the object stands at all: a base it can judge. An object with none reads as
    // lacking, which is safe to push again everywhere but in an account set, whose older blob the server deleted.
    fn judged(&self, scope: ScopeName, id: &KeyRecordId) -> bool;
}

pub(crate) struct Inputs<'a> {
    pub account: AccountId,
    pub key_device: KeyDeviceId,
    // The newest `av` this device verified for its own account.
    pub newest_av: Version,
    // The server approves this device now, as the scopes body's `approved` says.
    pub approved: bool,
    pub personal: &'a [HeldObject],
    pub teams: Vec<TeamInputs<'a>>,
    pub server: &'a dyn ServerView,
}

pub(crate) struct TeamInputs<'a> {
    pub team: TeamId,
    pub objects: &'a [HeldObject],
    // The newest version this device verified, with its state.
    pub row: Option<&'a KeyVersionRow>,
    // `members`, only when read after the team's pull caught up (0051, `members`).
    pub roster: Option<&'a [TeamMember]>,
}

#[derive(Debug, Clone)]
pub(crate) struct PlannedSet {
    pub scope: ScopeName,
    pub objects: Vec<HeldObject>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TeamVerdict {
    // Everything the order lists for the team is planned.
    Done,
    // The team stops at `version` until the server holds every one of `awaiting`.
    Waits {
        version: Version,
        awaiting: Vec<KeyRecordId>,
    },
    // The awaited confirmation's author is no longer an owner or admin, so it cannot go back.
    Ends,
}

#[derive(Debug, Default)]
pub(crate) struct Plan {
    pub sets: Vec<PlannedSet>,
    pub teams: Vec<(TeamId, TeamVerdict)>,
    // An account certificate above the server's has no base to judge: nothing is planned rather than guessed.
    pub blind: bool,
}

pub(crate) fn plan(inputs: &Inputs<'_>) -> Plan {
    let mut plan = Plan::default();
    // An account `av` the device verified with no certificate it holds, or none it can judge: nothing above it can
    // go back.
    let Some(personal) = plan_personal(inputs) else {
        plan.blind = true;
        return plan;
    };
    // A device the server does not approve, and that no account change set going back certifies, can write no key
    // object: its approval was lost and is done again with a new key device (0051, After a restore).
    let authorized = inputs.approved || personal.first().is_some_and(|set| certifies(set, inputs.key_device));
    if !authorized {
        return plan;
    }
    plan.sets.extend(personal);
    for team in &inputs.teams {
        let (sets, verdict) = plan_team(inputs, team);
        plan.sets.extend(sets);
        plan.teams.push((team.team, verdict));
    }
    plan
}

struct Objects<'a> {
    by_id: BTreeMap<String, (&'a HeldObject, KeyRecordId)>,
}

impl<'a> Objects<'a> {
    fn of(held: &'a [HeldObject]) -> Self {
        let by_id = held
            .iter()
            .filter(|held| held.applied)
            .map(|held| (wire_key(&held.object.id), (held, held.object.id)))
            .collect();
        Self { by_id }
    }

    fn get(&self, id: &KeyRecordId) -> Option<&'a HeldObject> {
        self.by_id.get(&wire_key(id)).map(|(held, _)| *held)
    }

    fn all(&self) -> impl Iterator<Item = (&'a HeldObject, KeyRecordId)> + '_ {
        self.by_id.values().map(|(held, id)| (*held, *id))
    }

    fn version(&self, key: KeyRef) -> Option<(&'a HeldObject, VersionRecord)> {
        let held = self.get(&KeyRecordId::Version(key))?;
        held.object.version_record().map(|record| (held, record))
    }

    fn wraps(&self) -> impl Iterator<Item = (&'a HeldObject, Wrap)> + '_ {
        self.all()
            .filter_map(|(held, _)| held.object.wrap().map(|wrap| (held, wrap)))
    }
}

fn wire_key(id: &KeyRecordId) -> String {
    format!("{}\u{0}{}", id.kind().name(), id.to_wire())
}

fn certifies(set: &PlannedSet, key_device: KeyDeviceId) -> bool {
    set.objects.iter().any(
        |held| matches!(held.object.id, KeyRecordId::Device { key_device: certified, .. } if certified == key_device),
    )
}

fn plan_personal(inputs: &Inputs<'_>) -> Option<Vec<PlannedSet>> {
    let objects = Objects::of(inputs.personal);
    let account = inputs.account;
    let server_av = (1..=inputs.newest_av.get())
        .rev()
        .filter_map(|av| Version::new(av).ok())
        .find(|av| {
            inputs
                .server
                .holds(ScopeName::Personal, &KeyRecordId::Account { account, av: *av })
        });
    let first = server_av.map_or(1, |av| av.get() + 1);
    (first..=inputs.newest_av.get())
        .filter_map(|av| Version::new(av).ok())
        .map(|av| {
            let id = KeyRecordId::Account { account, av };
            inputs
                .server
                .judged(ScopeName::Personal, &id)
                .then(|| account_set(&objects, account, av, av == inputs.newest_av))
                .flatten()
        })
        .collect()
}

// The account change set at `av` as the device holds it: the certificate, the newest blob, the device certificates and
// `account` wraps of the devices it kept, and the personal and history versions signed at it with their rings and
// wraps. An approval's objects at that `av` (the device it certified has a `trust` wrap) are not among them: a lost
// approval is done again with a new key device.
fn account_set(objects: &Objects<'_>, account: AccountId, av: Version, newest: bool) -> Option<PlannedSet> {
    let certificate = objects.get(&KeyRecordId::Account { account, av })?;
    let mut set = vec![certificate.clone()];
    // Only the newest blob goes back: the server deletes each older one once a newer certificate applies, so an
    // older blob meets that deletion whenever another device put the newer certificate back first (0051, After a
    // restore: "Older recovery blobs ... are not among them").
    if newest {
        set.extend(objects.get(&KeyRecordId::Recovery { account, av }).cloned());
    }
    let approved_at_av: HashSet<KeyDeviceId> = objects
        .wraps()
        .filter(|(_, wrap)| wrap.target.purpose == WrapPurpose::Trust && wrap.target.version == av)
        .filter_map(|(_, wrap)| match wrap.target.recipient {
            Recipient::Device(device) => Some(device),
            Recipient::Account(_) => None,
        })
        .collect();
    let kept: Vec<KeyDeviceId> = objects
        .all()
        .filter_map(|(held, id)| match id {
            KeyRecordId::Device { key_device, av: at, .. } if at == av && !approved_at_av.contains(&key_device) => {
                set.push(held.clone());
                Some(key_device)
            }
            _ => None,
        })
        .collect();
    let mut versions = Vec::new();
    for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
        for (held, id) in objects.all() {
            let KeyRecordId::Version(key) = id else { continue };
            let signed_at_av = held
                .object
                .version_record()
                .is_some_and(|record| record.signer == account && record.signer_av == av);
            if key.purpose == purpose && key.owner == account.0 && signed_at_av {
                set.push(held.clone());
                set.extend(objects.get(&KeyRecordId::Ring(key)).cloned());
                versions.push(key);
            }
        }
    }
    for (held, wrap) in objects.wraps() {
        let target = wrap.target;
        let goes = match (target.purpose, target.recipient) {
            (WrapPurpose::Account, Recipient::Device(device)) => target.version == av && kept.contains(&device),
            (WrapPurpose::Key(_), Recipient::Account(recipient)) => {
                recipient == account
                    && target.recipient_version == av
                    && versions.iter().any(|key| {
                        key.owner == target.owner
                            && WrapPurpose::Key(key.purpose) == target.purpose
                            && key.version == target.version
                    })
            }
            _ => false,
        };
        if goes {
            set.push(held.clone());
        }
    }
    Some(PlannedSet {
        scope: ScopeName::Personal,
        objects: set,
    })
}

struct Team<'a> {
    team: TeamId,
    account: AccountId,
    objects: Objects<'a>,
    server: &'a dyn ServerView,
}

impl Team<'_> {
    fn scope(&self) -> ScopeName {
        ScopeName::Team(self.team)
    }

    fn key(&self, version: Version) -> KeyRef {
        KeyRef {
            owner: self.team.0,
            purpose: KeyPurpose::Team,
            version,
        }
    }

    fn server_holds(&self, id: &KeyRecordId) -> bool {
        self.server.holds(self.scope(), id)
    }

    // Wraps of `version` this account signed, in record id order.
    fn own_wraps(&self, version: Version) -> Vec<(&HeldObject, Wrap)> {
        self.objects
            .wraps()
            .filter(|(_, wrap)| {
                wrap.target.purpose == WrapPurpose::Key(KeyPurpose::Team)
                    && wrap.target.version == version
                    && wrap.wrapper.account == self.account
            })
            .collect()
    }

    // The awaited wrap confirmed the account when the account held no wrap of the version before it, and did not
    // sign it (0051, What cannot go back). Without that version's record the device cannot tell, so it is no
    // confirmation and the device keeps waiting.
    fn held_no_wrap(&self, version: Version) -> bool {
        let Some((_, record)) = self.objects.version(self.key(version)) else {
            return false;
        };
        let wrapped = self.objects.wraps().any(|(_, wrap)| {
            wrap.target.purpose == WrapPurpose::Key(KeyPurpose::Team)
                && wrap.target.version == version
                && wrap.target.recipient == Recipient::Account(self.account)
        });
        record.signer != self.account && !wrapped && !self.holders(version).contains(&self.account)
    }

    // The accounts that hold `version` by what the device holds: its signer, then each recipient of a wrap of it
    // that a holder signed (0056, Teams, Holders). The server's checks count accounts the same way.
    fn holders(&self, version: Version) -> BTreeSet<AccountId> {
        let mut holders = BTreeSet::new();
        let Some((_, record)) = self.objects.version(self.key(version)) else {
            return holders;
        };
        holders.insert(record.signer);
        let wraps: Vec<Wrap> = self
            .objects
            .wraps()
            .map(|(_, wrap)| wrap)
            .filter(|wrap| wrap.target.purpose == WrapPurpose::Key(KeyPurpose::Team) && wrap.target.version == version)
            .collect();
        loop {
            let before = holders.len();
            for wrap in &wraps {
                if let Recipient::Account(recipient) = wrap.target.recipient
                    && holders.contains(&wrap.wrapper.account)
                {
                    holders.insert(recipient);
                }
            }
            if holders.len() == before {
                return holders;
            }
        }
    }
}

fn plan_team(inputs: &Inputs<'_>, team: &TeamInputs<'_>) -> (Vec<PlannedSet>, TeamVerdict) {
    let team_view = Team {
        team: team.team,
        account: inputs.account,
        objects: Objects::of(team.objects),
        server: inputs.server,
    };
    let mut sets = member_sets(&team_view);
    let Some(row) = team.row else {
        return (sets, TeamVerdict::Done);
    };
    if row.state == KeyVersionState::Ended {
        return (Vec::new(), TeamVerdict::Done);
    }
    let newest = row.version;
    let server_newest = (1..=newest.get())
        .rev()
        .filter_map(|version| Version::new(version).ok())
        .find(|version| team_view.server_holds(&KeyRecordId::Version(team_view.key(*version))));
    let first_lacking = server_newest.map_or(1, |version| version.get() + 1);
    let first_own_wrap = (1..first_lacking)
        .filter_map(|version| Version::new(version).ok())
        .find(|version| {
            team_view
                .own_wraps(*version)
                .iter()
                .any(|(held, _)| !team_view.server_holds(&held.object.id))
        })
        .map_or(first_lacking, Version::get);
    for number in first_own_wrap.min(first_lacking)..=newest.get() {
        let Ok(version) = Version::new(number) else { break };
        match version_step(&team_view, team.roster, version) {
            Step::Push(mut step) => sets.append(&mut step),
            // A team that ends takes nothing more, the sets planned before the end included.
            Step::Stop(TeamVerdict::Ends) => return (Vec::new(), TeamVerdict::Ends),
            Step::Stop(verdict) => return (sets, verdict),
        }
    }
    (sets, TeamVerdict::Done)
}

// The account's own `key.member` records the server lacks, each alone, oldest first.
fn member_sets(team: &Team<'_>) -> Vec<PlannedSet> {
    team.objects
        .all()
        .filter_map(|(held, id)| match id {
            KeyRecordId::Member { account, av } if account == team.account && !team.server_holds(&id) => {
                Some((av, held))
            }
            _ => None,
        })
        .collect::<BTreeMap<Version, &HeldObject>>()
        .into_values()
        .map(|held| PlannedSet {
            scope: team.scope(),
            objects: vec![held.clone()],
        })
        .collect()
}

enum Step {
    Push(Vec<PlannedSet>),
    Stop(TeamVerdict),
}

fn version_step(team: &Team<'_>, roster: Option<&[TeamMember]>, version: Version) -> Step {
    let key = team.key(version);
    let mut sets = Vec::new();
    let mut rotated: HashSet<String> = HashSet::new();
    if !team.server_holds(&KeyRecordId::Version(key)) {
        let Some((record_held, record)) = team
            .objects
            .version(key)
            .filter(|(_, record)| record.signer == team.account)
        else {
            // A version another account signed, or one whose record the device does not hold: the team waits for it
            // to come back from its signer's device (0051, What cannot go back).
            return Step::Stop(TeamVerdict::Waits {
                version,
                awaiting: vec![KeyRecordId::Version(key)],
            });
        };
        if record.start == Start::Next
            && let Some(verdict) = wait_for_holding(team, roster, version)
        {
            return Step::Stop(verdict);
        }
        let objects = version_set(team, record_held, &record);
        rotated.extend(objects.iter().map(|held| wire_key(&held.object.id)));
        sets.push(PlannedSet {
            scope: team.scope(),
            objects,
        });
    }
    for (held, _) in team.own_wraps(version) {
        if !rotated.contains(&wire_key(&held.object.id)) && !team.server_holds(&held.object.id) {
            sets.push(PlannedSet {
                scope: team.scope(),
                objects: vec![held.clone()],
            });
        }
    }
    Step::Push(sets)
}

// The version record, its ring, and the wraps its own change set carried: for `start` 0 those its signer made at
// its `av` to holders of the version before; for `start` 1 the signer's wrap to itself. Its other wraps of the
// version are confirmations made after, which go back alone.
fn version_set(team: &Team<'_>, record_held: &HeldObject, record: &VersionRecord) -> Vec<HeldObject> {
    let version = record.key.version;
    let mut objects = vec![record_held.clone()];
    objects.extend(team.objects.get(&KeyRecordId::Ring(record.key)).cloned());
    // The signer held the version before, or it could not have signed this one.
    let mut previous_holders = match (record.start, version.previous()) {
        (Start::Next, Some(previous)) => team.holders(previous),
        _ => BTreeSet::new(),
    };
    previous_holders.insert(team.account);
    for (held, wrap) in team.own_wraps(version) {
        let in_set = wrap.wrapper.av == record.signer_av
            && matches!(wrap.target.recipient, Recipient::Account(recipient) if previous_holders.contains(&recipient));
        if in_set {
            objects.push(held.clone());
        }
    }
    objects
}

// Before a `start` 0 version this account signed goes back, the server must hold what makes the account a holder of
// the version before: that version, a wrap of it to the account, and that wrap's signer's `key.member`. None when it
// does; else the wait, or the end when the awaited wrap confirmed the account and its author is no longer an owner
// or admin in a roster read after the team's pull caught up (0051, What cannot go back).
fn wait_for_holding(team: &Team<'_>, roster: Option<&[TeamMember]>, version: Version) -> Option<TeamVerdict> {
    let previous = version.previous()?;
    let previous_key = team.key(previous);
    let previous_id = KeyRecordId::Version(previous_key);
    let signed_it = team
        .objects
        .version(previous_key)
        .is_some_and(|(_, record)| record.signer == team.account);
    if signed_it {
        return None;
    }
    let to_account: Vec<Wrap> = team
        .objects
        .wraps()
        .map(|(_, wrap)| wrap)
        .filter(|wrap| {
            wrap.target.purpose == WrapPurpose::Key(KeyPurpose::Team)
                && wrap.target.version == previous
                && wrap.target.recipient == Recipient::Account(team.account)
        })
        .collect();
    let member_of = |wrap: &Wrap| KeyRecordId::Member {
        account: wrap.wrapper.account,
        av: wrap.wrapper.av,
    };
    let held_by_server = team.server_holds(&previous_id)
        && to_account
            .iter()
            .any(|wrap| team.server_holds(&KeyRecordId::Wrap(wrap.target)) && team.server_holds(&member_of(wrap)));
    if held_by_server {
        return None;
    }
    let mut awaiting = vec![previous_id];
    for wrap in &to_account {
        awaiting.push(KeyRecordId::Wrap(wrap.target));
        awaiting.push(member_of(wrap));
    }
    awaiting.retain(|id| !team.server_holds(id));
    let confirmation = previous.previous().is_none_or(|before| team.held_no_wrap(before));
    let authors_gone = roster.is_some_and(|members| {
        !to_account.is_empty()
            && to_account.iter().all(|wrap| {
                !members
                    .iter()
                    .any(|member| member.account == wrap.wrapper.account && member.role.manages_keys())
            })
    });
    if confirmation && authors_gone && team.server_holds(&previous_id) {
        return Some(TeamVerdict::Ends);
    }
    Some(TeamVerdict::Waits { version, awaiting })
}
