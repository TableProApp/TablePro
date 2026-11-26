// Step 7 of Approving a device: what the new device keeps of its key tables and what it takes from the approver's
// trust plaintext (0056; 0054, `key_versions`). The comparison authenticated the approver's DSK and the account's IK,
// so the trust plaintext is the approver's own view. It still never raises a team scope the device holds, never
// makes current a personal or history version signed under an older `av`, and never clears a stop it does not
// clear itself (G0 S6-C1, S7-C1).

use tablepro_keys::KeysError;
use tablepro_keys::encoding::{AccountId, KeyPurpose, TeamId, Version};
use tablepro_keys::keys::Ed25519Public;
use tablepro_keys::sas::SasDevice;
use tablepro_keys::trust::{TrustPin, TrustPlaintext, TrustVersion};

use crate::api::ids::ScopeName;
use crate::api::state::{KeyDevicePinRow, KeyPinRow, KeyVersionRow, KeyVersionState};

// What the device holds when the approval change set arrives.
#[derive(Debug, Clone, Default)]
pub(crate) struct HeldTables {
    pub pins: Vec<KeyPinRow>,
    pub versions: Vec<KeyVersionRow>,
}

// What the comparison and the approval change set fixed.
#[derive(Debug, Clone)]
pub(crate) struct Approver<'a> {
    pub account: AccountId,
    // The IK the words covered.
    pub ik: Ed25519Public,
    // The `av` of the account keys and certificate the approval carries.
    pub av: Version,
    pub trust: &'a TrustPlaintext,
    pub device: SasDevice,
}

// What the device reads from its own `key_objects` while it merges.
pub(crate) trait MergeFacts {
    // The `signer_av` of the account's personal or history version record at `version` whose digest is `record`,
    // verified under the account's certificate at that `av`. `keys.conflict` when an applied record with another
    // digest sits at its id; None while the device holds no such record.
    fn version_signer(
        &self,
        purpose: KeyPurpose,
        version: Version,
        record: &[u8; 32],
    ) -> Result<Option<Version>, KeysError>;

    // The IK `ik` endorsed for `account`, and the `av` of that replace, from a replace certificate the device holds
    // and verified under `ik`.
    fn endorsed_by(&self, account: AccountId, ik: &Ed25519Public) -> Option<(Ed25519Public, Version)>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Merge {
    Merged(Box<Merged>),
    // The approver's version record has not arrived: held until it does, never refused for that (0056, Rollback).
    Waiting { purpose: KeyPurpose, version: Version },
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct Merged {
    // Every row the key tables hold after the merge.
    pub pins: Vec<KeyPinRow>,
    pub versions: Vec<KeyVersionRow>,
    pub device_pins: Vec<KeyDevicePinRow>,
    pub alerts_opened: Vec<AccountId>,
    // Another account whose pinned IK the device followed to the one it endorsed.
    pub replaced: Vec<AccountId>,
    // Personal or history stops this approval cleared.
    pub resumed: Vec<KeyPurpose>,
    // Held team scopes the approver holds at a higher version: only a hint for the device's own pull.
    pub hints: Vec<TeamId>,
}

pub(crate) const PERSONAL_PURPOSES: [KeyPurpose; 2] = [KeyPurpose::Personal, KeyPurpose::History];

// The scope a personal or history row of `key_versions` is kept under: both key objects live in the personal scope.
pub(crate) const fn personal_row_scope(_purpose: KeyPurpose) -> ScopeName {
    ScopeName::Personal
}

pub(crate) fn merge(held: &HeldTables, approver: &Approver<'_>, facts: &dyn MergeFacts) -> Result<Merge, KeysError> {
    check_trust_owners(approver)?;
    let mut merged = Merged::default();
    merge_pins(held, approver, facts, &mut merged)?;
    for purpose in PERSONAL_PURPOSES {
        match merge_personal(held, approver, facts, purpose)? {
            Personal::Row { row, resumed } => {
                if resumed {
                    merged.resumed.push(purpose);
                }
                merged.versions.push(row);
            }
            Personal::Waiting(version) => return Ok(Merge::Waiting { purpose, version }),
        }
    }
    merge_teams(held, approver, &mut merged)?;
    merged.device_pins = vec![KeyDevicePinRow {
        key_device: approver.device.key_device,
        dek: approver.device.dek,
        dsk: approver.device.dsk,
    }];
    Ok(Merge::Merged(Box::new(merged)))
}

// A personal or history version names its own account; any other owner is not this account's trust.
fn check_trust_owners(approver: &Approver<'_>) -> Result<(), KeysError> {
    let foreign = approver
        .trust
        .versions
        .iter()
        .any(|version| version.purpose != KeyPurpose::Team && version.owner != approver.account.0);
    if foreign {
        return Err(KeysError::Mismatch {
            what: "the trust plaintext names another account's personal or history key",
        });
    }
    Ok(())
}

fn pin_row(pin: &TrustPin) -> KeyPinRow {
    KeyPinRow {
        account: pin.account,
        ik: pin.ik,
        av: pin.av,
        how: pin.how,
        alert: pin.alert,
        replaced: pin.replaced.clone(),
    }
}

// Each IK once, in the order it was replaced: the device's list, then what only the approver saw.
fn union(first: &[Ed25519Public], second: &[Ed25519Public]) -> Vec<Ed25519Public> {
    let mut out = first.to_vec();
    for ik in second {
        if !out.contains(ik) {
            out.push(*ik);
        }
    }
    out
}

fn merge_pins(
    held: &HeldTables,
    approver: &Approver<'_>,
    facts: &dyn MergeFacts,
    merged: &mut Merged,
) -> Result<(), KeysError> {
    let own = held.pins.iter().find(|pin| pin.account == approver.account);
    merged.pins.push(merge_own_pin(own, approver)?);
    for pin in held.pins.iter().filter(|pin| pin.account != approver.account) {
        let offered = approver
            .trust
            .pins
            .iter()
            .find(|offered| offered.account == pin.account);
        let row = match offered {
            Some(offered) => merge_other_pin(pin, offered, facts, merged),
            None => pin.clone(),
        };
        merged.pins.push(row);
    }
    for offered in &approver.trust.pins {
        let new = offered.account != approver.account && !held.pins.iter().any(|pin| pin.account == offered.account);
        if new {
            let mut row = pin_row(offered);
            if row.replaced.contains(&row.ik) && !row.alert {
                row.alert = true;
                merged.alerts_opened.push(row.account);
            }
            merged.pins.push(row);
        }
    }
    merged.pins.sort_by_key(|pin| pin.account);
    Ok(())
}

// The device's own account takes the approver's pin and alerts, which the comparison authenticated, when the
// approver's `av` is at or above its own. That also clears an own-account lock after a reset elsewhere.
fn merge_own_pin(own: Option<&KeyPinRow>, approver: &Approver<'_>) -> Result<KeyPinRow, KeysError> {
    let offered = approver
        .trust
        .pins
        .iter()
        .find(|pin| pin.account == approver.account)
        .filter(|pin| pin.ik == approver.ik && pin.av == approver.av)
        .ok_or(KeysError::Mismatch {
            what: "the trust plaintext's own-account pin is not the compared IK at the approval's av",
        })?;
    let mut row = pin_row(offered);
    if let Some(own) = own {
        if approver.av < own.av {
            return Err(KeysError::Stale {
                held: own.av.get(),
                offered: approver.av.get(),
            });
        }
        row.replaced = union(&own.replaced, &offered.replaced);
    }
    if row.replaced.contains(&approver.ik) {
        return Err(KeysError::RetiredIk);
    }
    Ok(row)
}

// Another account keeps the device's pin and its `how`, follows a higher `av` under the same IK, adds the approver's
// open alerts and merges the replaced lists. An IK in the merged list is never current: the device follows the IK
// that replaced it only through an endorsement it holds, and otherwise opens the key-change alert. So does a pin under
// another IK that no endorsement the device holds explains.
fn merge_other_pin(pin: &KeyPinRow, offered: &TrustPin, facts: &dyn MergeFacts, merged: &mut Merged) -> KeyPinRow {
    let replaced = union(&pin.replaced, &offered.replaced);
    let mut row = KeyPinRow {
        account: pin.account,
        ik: pin.ik,
        av: pin.av,
        how: pin.how,
        alert: pin.alert || offered.alert,
        replaced,
    };
    let retired = row.replaced.contains(&pin.ik);
    if offered.ik == pin.ik && !retired {
        row.av = row.av.max(offered.av);
    } else if !retired && pin.replaced.contains(&offered.ik) {
        // The approver is behind on a replace this device already followed.
    } else {
        let target = (!row.replaced.contains(&offered.ik)).then_some(offered.ik);
        match follow(pin.account, pin.ik, &row.replaced, target, facts) {
            Some((ik, av, passed)) => {
                row.replaced = union(&row.replaced, &passed);
                row.ik = ik;
                row.how = tablepro_keys::trust::PinHow::Replaced;
                row.av = if Some(ik) == target { av.max(offered.av) } else { av };
                merged.replaced.push(pin.account);
            }
            None => row.alert = true,
        }
    }
    // The approver pinned an IK that neither is current here nor was replaced on the way to it.
    if row.ik != offered.ik && !row.replaced.contains(&offered.ik) {
        row.alert = true;
    }
    if row.alert && !pin.alert {
        merged.alerts_opened.push(pin.account);
    }
    row
}

// Walks the replace endorsements the device holds from `from`, past every IK the merged list retired, to the first
// one it did not. Stops at `target` when the walk meets it. None when no endorsement leaves `from`.
fn follow(
    account: AccountId,
    from: Ed25519Public,
    retired: &[Ed25519Public],
    target: Option<Ed25519Public>,
    facts: &dyn MergeFacts,
) -> Option<(Ed25519Public, Version, Vec<Ed25519Public>)> {
    let mut passed = vec![from];
    let mut current = from;
    let mut reached = None;
    for _ in 0..=retired.len() + 1 {
        let Some((next, av)) = facts.endorsed_by(account, &current) else {
            break;
        };
        if passed.contains(&next) {
            break;
        }
        reached = Some((next, av));
        if Some(next) == target || !retired.contains(&next) {
            break;
        }
        passed.push(next);
        current = next;
    }
    let (ik, av) = reached?;
    if retired.contains(&ik) {
        return None;
    }
    Some((ik, av, passed))
}

enum Personal {
    Row { row: KeyVersionRow, resumed: bool },
    Waiting(Version),
}

// The current personal or history version is the one signed under the merged current `av`, the device's own or the
// approver's. One signed under an older `av` is never current, however high its number (S7-C1).
fn merge_personal(
    held: &HeldTables,
    approver: &Approver<'_>,
    facts: &dyn MergeFacts,
    purpose: KeyPurpose,
) -> Result<Personal, KeysError> {
    let own = held
        .versions
        .iter()
        .find(|row| row.purpose == purpose && row.scope == personal_row_scope(purpose));
    if let Some(own) = own.filter(|own| own.state == KeyVersionState::Ended) {
        return Ok(Personal::Row {
            row: own.clone(),
            resumed: false,
        });
    }
    let offered = approver
        .trust
        .versions
        .iter()
        .find(|version| version.purpose == purpose && version.owner == approver.account.0);
    if let (Some(own), Some(offered)) = (own, offered)
        && own.version == offered.version
        && own.record != offered.record
    {
        return Err(KeysError::Conflict);
    }
    let own_signer = match own {
        Some(own) => facts.version_signer(purpose, own.version, &own.record)?,
        None => None,
    };
    let offered_signer = match offered {
        Some(offered) => facts.version_signer(purpose, offered.version, &offered.record)?,
        None => None,
    };
    let current = |signer: Option<Version>| signer == Some(approver.av);
    let pick = match (
        own.filter(|_| current(own_signer)),
        offered.filter(|_| current(offered_signer)),
    ) {
        (Some(own), Some(offered)) if offered.version > own.version => Some((offered.version, offered.record)),
        (Some(own), _) => Some((own.version, own.record)),
        (None, Some(offered)) => Some((offered.version, offered.record)),
        (None, None) => None,
    };
    let Some((version, record)) = pick else {
        if let (Some(offered), None) = (offered, offered_signer) {
            return Ok(Personal::Waiting(offered.version));
        }
        let best = [own_signer, offered_signer].into_iter().flatten().max();
        return Err(KeysError::Stale {
            held: approver.av.get(),
            offered: best.map_or(0, Version::get),
        });
    };
    Ok(Personal::Row {
        row: KeyVersionRow {
            scope: personal_row_scope(purpose),
            purpose,
            version,
            record,
            holders: Vec::new(),
            state: KeyVersionState::Ok,
            stopped_cause: None,
            epoch: None,
        },
        resumed: own.is_some_and(|own| own.state == KeyVersionState::Stopped),
    })
}

// A team scope the device holds keeps its version, record, holders and state; the approver's higher version is only
// a hint (S6-C1). A team scope new to the device takes the approver's version and record, and its holders come from
// the wraps it then accepts. At an equal version another record is `keys.conflict`.
fn merge_teams(held: &HeldTables, approver: &Approver<'_>, merged: &mut Merged) -> Result<(), KeysError> {
    let offered: Vec<&TrustVersion> = approver
        .trust
        .versions
        .iter()
        .filter(|version| version.purpose == KeyPurpose::Team)
        .collect();
    for row in held.versions.iter().filter(|row| row.purpose == KeyPurpose::Team) {
        let ScopeName::Team(team) = row.scope else {
            merged.versions.push(row.clone());
            continue;
        };
        if let Some(offer) = offered.iter().find(|offer| offer.owner == team.0)
            && row.state != KeyVersionState::Ended
        {
            if offer.version == row.version && offer.record != row.record {
                return Err(KeysError::Conflict);
            }
            if offer.version > row.version {
                merged.hints.push(team);
            }
        }
        merged.versions.push(row.clone());
    }
    for offer in offered {
        let team = TeamId(offer.owner);
        let held_team = held
            .versions
            .iter()
            .any(|row| row.purpose == KeyPurpose::Team && row.scope == ScopeName::Team(team));
        if !held_team {
            merged.versions.push(KeyVersionRow {
                scope: ScopeName::Team(team),
                purpose: KeyPurpose::Team,
                version: offer.version,
                record: offer.record,
                holders: Vec::new(),
                state: KeyVersionState::Ok,
                stopped_cause: None,
                epoch: None,
            });
        }
    }
    Ok(())
}
