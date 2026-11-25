// One team's key versions as a device sees them (0056, Teams; Rollback, Verifying and advancing): the version records,
// rings and wraps it holds, the version it advanced to with that version's holders, and whether the team stopped or
// ended there. `advance` applies 0056's rules in the order the objects came; it reads certificates and pins through
// `TeamFacts` and writes nothing itself.

use std::collections::{BTreeMap, BTreeSet};

use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::cert::AccountCertificate;
use tablepro_keys::check::check_signed_under_newest;
use tablepro_keys::encoding::{AccountId, KeyPurpose, Origin, TeamId, Version, WrapPurpose};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::scope_key::{Ring, Start, VersionRecord};
use tablepro_keys::wrap::{Recipient, Wrap};

use super::chain;
use super::facts::{Certificate, PinFacts, TeamFacts, known_pin};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::RefusedObject;
use crate::api::state::{Holder, KeyVersionRow, KeyVersionState, StoppedCause};

#[derive(Debug, Clone)]
struct Item<T> {
    record_id: String,
    value: T,
    // Arrived in this call, so a refusal or a hold is reported for it; one held from before is judged silently.
    fresh: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TeamEvent {
    // The version this account was confirmed with, taken on first use (0056, Teams, Joining).
    Joined { version: Version },
    Advanced { version: Version },
    // A version with `start` 1 taken on first use, with a notice that the team key started over.
    Restarted { version: Version },
    // A catch-up it could not verify: it keeps `at` and that version's holders, and writes nothing under the key.
    Stopped { at: Version },
    // An owner or admin that held the stopped version confirmed this device again (0056, Teams, A stopped device).
    Cleared { version: Version },
    // Another record at the version the device holds: a fork, which nothing clears.
    Ended,
}

#[derive(Debug, Default)]
pub(crate) struct Progress {
    pub(crate) events: Vec<TeamEvent>,
    pub(crate) refused: Vec<RefusedObject>,
    pub(crate) held: BTreeSet<String>,
}

impl Progress {
    fn refuse<T>(&mut self, item: &Item<T>, error: KeysError) {
        if item.fresh {
            self.refused.push(RefusedObject {
                record_id: item.record_id.clone(),
                error,
            });
        }
    }

    fn hold<T>(&mut self, item: &Item<T>) {
        if item.fresh {
            self.held.insert(item.record_id.clone());
        }
    }
}

enum Check<T> {
    Pass(T),
    // A certificate or pin that has not arrived, or an open alert: decided once it changes.
    Wait,
    Fail(KeysError),
}

enum WrapCheck {
    Holder(Holder),
    // Its wrapper is no holder yet; another wrap of the same version may make it one.
    NotYet,
    Wait,
    Fail(KeysError),
}

pub(crate) struct TeamBook {
    origin: Origin,
    team: TeamId,
    me: AccountId,
    row: Option<KeyVersionRow>,
    versions: BTreeMap<Version, Item<VersionRecord>>,
    wraps: BTreeMap<Version, Vec<Item<Wrap>>>,
    rings: BTreeMap<Version, Ring>,
}

impl TeamBook {
    pub(crate) fn new(origin: Origin, team: TeamId, me: AccountId, row: Option<KeyVersionRow>) -> Self {
        Self {
            origin,
            team,
            me,
            row,
            versions: BTreeMap::new(),
            wraps: BTreeMap::new(),
            rings: BTreeMap::new(),
        }
    }

    pub(crate) fn row(&self) -> Option<&KeyVersionRow> {
        self.row.as_ref()
    }

    pub(crate) fn into_row(self) -> Option<KeyVersionRow> {
        self.row
    }

    pub(crate) fn scope(&self) -> ScopeName {
        ScopeName::Team(self.team)
    }

    pub(crate) fn version_record(&self, version: Version) -> Option<&VersionRecord> {
        self.versions.get(&version).map(|item| &item.value)
    }

    pub(crate) fn ring(&self, version: Version) -> Option<&Ring> {
        self.rings.get(&version)
    }

    pub(crate) fn wraps_of(&self, version: Version) -> impl Iterator<Item = &Wrap> {
        self.wraps.get(&version).into_iter().flatten().map(|item| &item.value)
    }

    pub(crate) fn versions(&self) -> impl Iterator<Item = &VersionRecord> {
        self.versions.values().map(|item| &item.value)
    }

    // A team's `key.version`, `key.ring` or scope-key `key.wrap`; `key.member` goes to the pins instead. An object of
    // another scope or purpose is `keys.encoding`, and the device keeps none of it.
    pub(crate) fn check_shape(&self, object: &KeyObject) -> Result<(), KeysError> {
        let fits = match (&object.id, &object.body) {
            (KeyRecordId::Version(key), KeyBody::Version(_)) | (KeyRecordId::Ring(key), KeyBody::Ring(_)) => {
                self.is_team_key(key.owner, key.purpose)
            }
            (KeyRecordId::Wrap(target), KeyBody::Wrap(_)) => {
                target.owner == self.team.0
                    && target.purpose == WrapPurpose::Key(KeyPurpose::Team)
                    && matches!(target.recipient, Recipient::Account(_))
            }
            (KeyRecordId::Member { .. }, KeyBody::Member(_)) => true,
            _ => false,
        };
        if fits {
            Ok(())
        } else {
            Err(KeysError::Encoding {
                what: "not a key object of this team",
            })
        }
    }

    pub(crate) fn insert(&mut self, object: &KeyObject, fresh: bool) -> Result<(), KeysError> {
        self.check_shape(object)?;
        let record_id = object.id.to_wire();
        match (&object.id, &object.body) {
            (KeyRecordId::Version(key), KeyBody::Version(_)) => {
                let value = object
                    .version_record()
                    .ok_or(KeysError::Encoding { what: "version record" })?;
                self.versions.insert(
                    key.version,
                    Item {
                        record_id,
                        value,
                        fresh,
                    },
                );
            }
            (KeyRecordId::Ring(key), KeyBody::Ring(ring)) => {
                self.rings.insert(key.version, ring.clone());
            }
            (KeyRecordId::Wrap(target), KeyBody::Wrap(_)) => {
                let value = object.wrap().ok_or(KeysError::Encoding { what: "wrap" })?;
                let held = self.wraps.entry(target.version).or_default();
                match held.iter_mut().find(|item| item.record_id == record_id) {
                    Some(item) => item.fresh |= fresh,
                    None => held.push(Item {
                        record_id,
                        value,
                        fresh,
                    }),
                }
            }
            _ => {
                return Err(KeysError::Encoding {
                    what: "a certificate is no version, ring or wrap",
                });
            }
        }
        Ok(())
    }

    fn is_team_key(&self, owner: uuid::Uuid, purpose: KeyPurpose) -> bool {
        owner == self.team.0 && purpose == KeyPurpose::Team
    }

    pub(crate) async fn advance(&mut self, facts: &mut dyn TeamFacts) -> Result<Progress, SyncError> {
        let mut progress = Progress::default();
        if self.row.is_none() {
            self.join(facts, &mut progress).await?;
        }
        while let Some(row) = self.row.clone() {
            if row.state != KeyVersionState::Ended
                && let Some(item) = self.versions.get(&row.version).cloned()
                && item.value.digest(&self.origin)? != row.record
            {
                // Another signed record at the version held is a fork, which ends the team. One that no certificate
                // signs is refused as an alarm and ends nothing, so a server cannot end a team with junk alone.
                progress.refuse(&item, KeysError::Conflict);
                if record_signed(&self.origin, facts, &item.value).await? {
                    self.end(&mut progress);
                }
                break;
            }
            let moved = match (row.state, row.stopped_cause) {
                (KeyVersionState::Ended, _) => false,
                // A restore stop clears in the restore flow once the server holds what it waits for. A catch-up
                // failure met meanwhile still counts, and makes the stop one only re-confirmation clears (0062).
                (KeyVersionState::Stopped, Some(StoppedCause::RestoreWait)) => {
                    self.step(facts, &mut progress, false, true).await?;
                    false
                }
                (KeyVersionState::Stopped, _) => self.clear_stop(facts, &mut progress).await?,
                (KeyVersionState::Ok, _) => {
                    let waiting = self.grow(facts, &mut progress).await?;
                    self.step(facts, &mut progress, true, waiting).await?
                }
            };
            if !moved {
                break;
            }
        }
        self.hold_what_lies_ahead(&mut progress);
        Ok(progress)
    }

    // A flow that uses the version the device holds checks first that the record it holds there is the anchored one.
    pub(crate) fn check_anchor(&self) -> Result<(), SyncError> {
        if let Some(row) = &self.row
            && let Some(item) = self.versions.get(&row.version)
            && item.value.digest(&self.origin)? != row.record
        {
            return Err(KeysError::Conflict.into());
        }
        Ok(())
    }

    // Whether this account holds the version the device advanced to, under its current IK.
    pub(crate) async fn own_holds(&self, facts: &mut dyn TeamFacts) -> Result<bool, SyncError> {
        let Some(row) = &self.row else { return Ok(false) };
        account_holds(&self.origin, facts, &row.holders, self.me).await
    }

    // Another record at an id the device holds: a fork, which ends the team on the device whatever its state.
    pub(crate) fn end_now(&mut self) -> bool {
        match &mut self.row {
            Some(row) if row.state != KeyVersionState::Ended => {
                row.state = KeyVersionState::Ended;
                row.stopped_cause = None;
                true
            }
            _ => false,
        }
    }

    fn end(&mut self, progress: &mut Progress) {
        if self.end_now() {
            progress.events.push(TeamEvent::Ended);
        }
    }

    fn stop(&mut self, record_id: &str, error: KeysError, progress: &mut Progress) {
        if let Some(row) = &mut self.row {
            row.stop(StoppedCause::CatchUp);
            progress.refused.push(RefusedObject {
                record_id: record_id.to_owned(),
                error,
            });
            progress.events.push(TeamEvent::Stopped { at: row.version });
        }
    }

    fn take(&mut self, version: Version, digest: [u8; 32], holders: BTreeSet<Holder>) {
        self.row = Some(KeyVersionRow {
            scope: ScopeName::Team(self.team),
            purpose: KeyPurpose::Team,
            version,
            record: digest,
            holders: holders.into_iter().collect(),
            state: KeyVersionState::Ok,
            stopped_cause: None,
            epoch: None,
        });
    }

    // Joining: the lowest version with a wrap to this account whose wrapper and record verify. Its signer and this
    // account are its first holders; the rule applies from there on.
    async fn join(&mut self, facts: &mut dyn TeamFacts, progress: &mut Progress) -> Result<(), SyncError> {
        let versions: Vec<Version> = self.versions.keys().copied().collect();
        for version in versions {
            let wraps: Vec<Item<Wrap>> = self
                .wraps
                .get(&version)
                .into_iter()
                .flatten()
                .filter(|item| item.value.target.recipient == Recipient::Account(self.me))
                .cloned()
                .collect();
            if wraps.is_empty() {
                continue;
            }
            let Some(item) = self.versions.get(&version).cloned() else {
                continue;
            };
            let signer = match usable_signer(facts, item.value.signer, item.value.signer_av).await? {
                Check::Pass((certificate, _)) => certificate,
                Check::Wait => {
                    progress.hold(&item);
                    continue;
                }
                Check::Fail(error) => {
                    progress.refuse(&item, error);
                    continue;
                }
            };
            if let Err(error) = item.value.verify(&self.origin, &signer.ask) {
                progress.refuse(&item, error);
                continue;
            }
            for wrap in &wraps {
                match self.first_use_wrap(facts, &wrap.value).await? {
                    Check::Pass(own) => {
                        let holders = BTreeSet::from([
                            Holder {
                                account: signer.account,
                                ik: signer.ik,
                            },
                            own,
                        ]);
                        let digest = item.value.digest(&self.origin)?;
                        self.take(version, digest, holders);
                        progress.events.push(TeamEvent::Joined { version });
                        return Ok(());
                    }
                    Check::Wait => progress.hold(wrap),
                    Check::Fail(error) => progress.refuse(wrap, error),
                }
            }
        }
        Ok(())
    }

    // The wrap a person confirmed, taken on first use: its wrapper's certificate and signature, under no holder rule.
    async fn first_use_wrap(&self, facts: &mut dyn TeamFacts, wrap: &Wrap) -> Result<Check<Holder>, SyncError> {
        let wrapper = match usable_signer(facts, wrap.wrapper.account, wrap.wrapper.av).await? {
            Check::Pass((certificate, _)) => certificate,
            Check::Wait => return Ok(Check::Wait),
            Check::Fail(error) => return Ok(Check::Fail(error)),
        };
        let recipient = match recipient_certificate(facts, self.me, wrap.target.recipient_version).await? {
            Check::Pass(certificate) => certificate,
            Check::Wait => return Ok(Check::Wait),
            Check::Fail(error) => return Ok(Check::Fail(error)),
        };
        Ok(match wrap.verify(&self.origin, &recipient.aek, &wrapper.ask) {
            Ok(()) => Check::Pass(Holder {
                account: self.me,
                ik: recipient.ik,
            }),
            Err(error) => Check::Fail(error),
        })
    }

    // The version after the one held. A version that would advance and fails a check stops the device there, since
    // versions step by one and nothing above it can count until an owner or admin confirms it again.
    // `take` is false while a restore stop waits: the version is judged, and a failure stops the team as a catch-up,
    // but a version that passes waits for the restore flow.
    // `waiting` is true while the evidence for the held version's holders is incomplete: a version above whose signer
    // is no holder yet is then held rather than refused, as an object waiting on a certificate is (0056, Rollback).
    async fn step(
        &mut self,
        facts: &mut dyn TeamFacts,
        progress: &mut Progress,
        take: bool,
        waiting: bool,
    ) -> Result<bool, SyncError> {
        let Some(row) = self.row.clone() else { return Ok(false) };
        let Ok(next) = row.version.next() else { return Ok(false) };
        let Some(item) = self.versions.get(&next).cloned() else {
            return Ok(false);
        };
        let record = &item.value;
        let (signer, pin) = match usable_signer(facts, record.signer, record.signer_av).await? {
            Check::Pass(found) => found,
            Check::Wait => {
                progress.hold(&item);
                return Ok(false);
            }
            Check::Fail(error) => {
                self.stop(&item.record_id, error, progress);
                return Ok(false);
            }
        };
        let refusal = match record.verify(&self.origin, &signer.ask) {
            Err(error) => Some(error),
            Ok(()) => match record.start {
                Start::Next => {
                    if holds(&self.origin, facts, &row.holders, &signer).await? {
                        check_signed_under_newest(record.signer_av, pin.av).err()
                    } else if waiting || row.holders.is_empty() {
                        progress.hold(&item);
                        return Ok(false);
                    } else {
                        Some(KeysError::NotHolder)
                    }
                }
                // A restart replaces a key a member holds, so a holder never takes one; any other member takes it on
                // first use (0056, Teams, No holder left).
                Start::Over => {
                    if account_holds(&self.origin, facts, &row.holders, self.me).await? {
                        Some(KeysError::NotHolder)
                    } else {
                        check_signed_under_newest(record.signer_av, pin.av).err()
                    }
                }
            },
        };
        if let Some(error) = refusal {
            self.stop(&item.record_id, error, progress);
            return Ok(false);
        }
        if !take {
            return Ok(false);
        }
        let event = match record.start {
            Start::Next => TeamEvent::Advanced { version: next },
            Start::Over => TeamEvent::Restarted { version: next },
        };
        let holders = BTreeSet::from([Holder {
            account: signer.account,
            ik: signer.ik,
        }]);
        let digest = record.digest(&self.origin)?;
        self.take(next, digest, holders);
        progress.events.push(event);
        Ok(true)
    }

    // The holders of the version held: its signer, then each recipient of a wrap a holder signed under its newest
    // `av`, until no wrap adds one. While the team is stopped nothing here runs, so its holders stay as they were.
    // True when some of the evidence still waits for a certificate, so a version above is not judged on it yet.
    async fn grow(&mut self, facts: &mut dyn TeamFacts, progress: &mut Progress) -> Result<bool, SyncError> {
        let Some(row) = self.row.clone() else { return Ok(false) };
        let mut holders: BTreeSet<Holder> = row.holders.iter().copied().collect();
        if holders.is_empty() {
            // A version an approval imported, with its record and no holders yet (0056, Approving a device, step 7).
            let Some(item) = self.versions.get(&row.version).cloned() else {
                return Ok(true);
            };
            match recipient_certificate(facts, item.value.signer, item.value.signer_av).await? {
                Check::Pass(signer) => {
                    holders.insert(Holder {
                        account: signer.account,
                        ik: signer.ik,
                    });
                }
                Check::Wait => {
                    progress.hold(&item);
                    return Ok(true);
                }
                Check::Fail(error) => {
                    progress.refuse(&item, error);
                    return Ok(true);
                }
            }
        }
        let wraps = self.wraps.get(&row.version).cloned().unwrap_or_default();
        let mut open: Vec<&Item<Wrap>> = wraps.iter().collect();
        let mut waiting = false;
        loop {
            let mut added = false;
            let mut still = Vec::new();
            for item in open {
                match wrap_check(&self.origin, facts, &holders, &item.value, true).await? {
                    WrapCheck::Holder(holder) => added |= holders.insert(holder),
                    WrapCheck::NotYet => still.push(item),
                    WrapCheck::Wait => {
                        waiting = true;
                        progress.hold(item);
                    }
                    WrapCheck::Fail(error) => progress.refuse(item, error),
                }
            }
            open = still;
            if !added {
                break;
            }
        }
        // A wrap held for a missing certificate may be the one that makes a wrapper a holder, so its wrapper's wraps
        // wait with it rather than being refused (0056, Rollback).
        for item in open {
            if waiting {
                progress.hold(item);
            } else {
                progress.refuse(item, KeysError::NotHolder);
            }
        }
        if let Some(row) = &mut self.row {
            row.holders = holders.into_iter().collect();
        }
        Ok(waiting)
    }

    // A stopped device takes a later version only from an owner's or admin's re-confirming rotation: the version and
    // its wrap to this account both signed, under their signers' newest `av`, by holders it had accepted for the
    // version it stopped at. A wrap of that version it first sees now never makes a holder (S5-M2).
    async fn clear_stop(&mut self, facts: &mut dyn TeamFacts, progress: &mut Progress) -> Result<bool, SyncError> {
        let Some(row) = self.row.clone() else { return Ok(false) };
        let Ok(above) = row.version.next() else {
            return Ok(false);
        };
        let frozen: BTreeSet<Holder> = row.holders.iter().copied().collect();
        let candidates: Vec<Item<VersionRecord>> = self.versions.range(above..).map(|(_, item)| item.clone()).collect();
        for item in candidates {
            let record = &item.value;
            let (signer, pin) = match usable_signer(facts, record.signer, record.signer_av).await? {
                Check::Pass(found) => found,
                Check::Wait => {
                    progress.hold(&item);
                    continue;
                }
                Check::Fail(error) => {
                    progress.refuse(&item, error);
                    continue;
                }
            };
            if let Err(error) = record.verify(&self.origin, &signer.ask) {
                progress.refuse(&item, error);
                continue;
            }
            if !holds(&self.origin, facts, &row.holders, &signer).await? {
                progress.refuse(&item, KeysError::NotHolder);
                continue;
            }
            if let Err(error) = check_signed_under_newest(record.signer_av, pin.av) {
                progress.refuse(&item, error);
                continue;
            }
            // A restart replaces a key a member holds, so it never clears the stop of a device whose account held
            // the stopped version (0056, Teams, No holder left).
            if record.start == Start::Over && account_holds(&self.origin, facts, &row.holders, self.me).await? {
                progress.refuse(&item, KeysError::NotHolder);
                continue;
            }
            let own_wraps: Vec<Item<Wrap>> = self
                .wraps
                .get(&record.key.version)
                .into_iter()
                .flatten()
                .filter(|wrap| wrap.value.target.recipient == Recipient::Account(self.me))
                .cloned()
                .collect();
            for wrap in &own_wraps {
                match wrap_check(&self.origin, facts, &frozen, &wrap.value, false).await? {
                    WrapCheck::Holder(own) => {
                        let holders = BTreeSet::from([
                            Holder {
                                account: signer.account,
                                ik: signer.ik,
                            },
                            own,
                        ]);
                        let version = record.key.version;
                        let digest = record.digest(&self.origin)?;
                        self.take(version, digest, holders);
                        progress.events.push(TeamEvent::Cleared { version });
                        return Ok(true);
                    }
                    WrapCheck::NotYet => progress.refuse(wrap, KeysError::NotHolder),
                    WrapCheck::Wait => progress.hold(wrap),
                    WrapCheck::Fail(error) => progress.refuse(wrap, error),
                }
            }
        }
        Ok(false)
    }

    // What arrived above the version the device ends on waits for the versions below it. A team this account was
    // never confirmed in holds nothing back: it has no version to wait from.
    fn hold_what_lies_ahead(&self, progress: &mut Progress) {
        let Some(row) = &self.row else { return };
        if row.state != KeyVersionState::Ok {
            return;
        }
        let Ok(above) = row.version.next() else { return };
        for (_, item) in self.versions.range(above..) {
            if !progress
                .refused
                .iter()
                .any(|refused| refused.record_id == item.record_id)
            {
                progress.hold(item);
            }
        }
        for (_, wraps) in self.wraps.range(above..) {
            for item in wraps {
                progress.hold(item);
            }
        }
    }
}

// A signer's certificate at the `av` it names and its pin, when neither is missing nor under an alert.
async fn usable_signer(
    facts: &mut dyn TeamFacts,
    account: AccountId,
    av: Version,
) -> Result<Check<(AccountCertificate, PinFacts)>, SyncError> {
    let certificate = match facts.certificate(account, av).await? {
        None | Some(Certificate::Alerted(_)) => return Ok(Check::Wait),
        Some(Certificate::Invalid(error)) => return Ok(Check::Fail(error)),
        // An IK seen replaced verifies the past and never advances: whatever it signs now is forged or stale.
        Some(Certificate::Retired(_)) => return Ok(Check::Fail(KeysError::RetiredIk)),
        Some(Certificate::Usable(certificate)) => certificate,
    };
    Ok(match known_pin(facts, account).await? {
        Some(pin) if !pin.alert => Check::Pass((certificate, pin)),
        _ => Check::Wait,
    })
}

// A recipient's certificate, for the AEK a wrap names and the IK its holder pair records. A recipient under an alert
// still becomes a holder: a holder wrapped to that key, and the alert keeps its own objects from counting.
async fn recipient_certificate(
    facts: &mut dyn TeamFacts,
    account: AccountId,
    av: Version,
) -> Result<Check<AccountCertificate>, SyncError> {
    Ok(match facts.certificate(account, av).await? {
        None => Check::Wait,
        Some(Certificate::Invalid(error)) => Check::Fail(error),
        Some(Certificate::Usable(certificate) | Certificate::Alerted(certificate)) => Check::Pass(certificate),
        // Under a replaced IK, only an `av` from before the replace is a real recipient.
        Some(Certificate::Retired(certificate)) => match known_pin(facts, account).await? {
            Some(pin) if certificate.av < pin.av => Check::Pass(certificate),
            _ => Check::Fail(KeysError::RetiredIk),
        },
    })
}

// `holders` are the ones the wrapper must be among. In `grow` they are the wrapped version's own, so a recipient already
// counted needs no second check; a stopped device's are another version's, so every wrap is checked in full.
async fn wrap_check(
    origin: &Origin,
    facts: &mut dyn TeamFacts,
    holders: &BTreeSet<Holder>,
    wrap: &Wrap,
    counted: bool,
) -> Result<WrapCheck, SyncError> {
    let Recipient::Account(recipient) = wrap.target.recipient else {
        return Ok(WrapCheck::Fail(KeysError::Encoding {
            what: "a team wrap to a device",
        }));
    };
    let recipient = match recipient_certificate(facts, recipient, wrap.target.recipient_version).await? {
        Check::Pass(certificate) => certificate,
        Check::Wait => return Ok(WrapCheck::Wait),
        Check::Fail(error) => return Ok(WrapCheck::Fail(error)),
    };
    let holder = Holder {
        account: recipient.account,
        ik: recipient.ik,
    };
    if counted && holders.contains(&holder) {
        return Ok(WrapCheck::Holder(holder));
    }
    let (wrapper, pin) = match usable_signer(facts, wrap.wrapper.account, wrap.wrapper.av).await? {
        Check::Pass(found) => found,
        Check::Wait => return Ok(WrapCheck::Wait),
        Check::Fail(error) => return Ok(WrapCheck::Fail(error)),
    };
    if !holds_set(origin, facts, holders, &wrapper).await? {
        return Ok(WrapCheck::NotYet);
    }
    if let Err(error) = check_signed_under_newest(wrap.wrapper.av, pin.av) {
        return Ok(WrapCheck::Fail(error));
    }
    Ok(match wrap.verify(origin, &recipient.aek, &wrapper.ask) {
        Ok(()) => WrapCheck::Holder(holder),
        Err(error) => WrapCheck::Fail(error),
    })
}

pub(crate) async fn holds(
    origin: &Origin,
    facts: &mut dyn TeamFacts,
    holders: &[Holder],
    signer: &AccountCertificate,
) -> Result<bool, SyncError> {
    let pairs: Vec<Holder> = holders
        .iter()
        .filter(|holder| holder.account == signer.account)
        .copied()
        .collect();
    if pairs.is_empty() {
        return Ok(false);
    }
    if pairs.iter().any(|holder| holder.ik == signer.ik) {
        return Ok(true);
    }
    let certificates = facts.chain(signer.account).await?;
    Ok(pairs
        .iter()
        .any(|holder| chain::matches(origin, holder, signer, &certificates)))
}

async fn holds_set(
    origin: &Origin,
    facts: &mut dyn TeamFacts,
    holders: &BTreeSet<Holder>,
    signer: &AccountCertificate,
) -> Result<bool, SyncError> {
    let holders: Vec<Holder> = holders.iter().copied().collect();
    holds(origin, facts, &holders, signer).await
}

// An account holds a version under its current IK: the one its pin follows, through its certificate at the pin's
// `av` when the IK changed by endorsed replaces since it became a holder.
pub(crate) async fn account_holds(
    origin: &Origin,
    facts: &mut dyn TeamFacts,
    holders: &[Holder],
    account: AccountId,
) -> Result<bool, SyncError> {
    let Some(pin) = known_pin(facts, account).await? else {
        return Ok(false);
    };
    if holders
        .iter()
        .any(|holder| holder.account == account && holder.ik == pin.ik)
    {
        return Ok(true);
    }
    match facts.certificate(account, pin.av).await? {
        Some(Certificate::Usable(current)) if current.ik == pin.ik => holds(origin, facts, holders, &current).await,
        _ => Ok(false),
    }
}

// Whether a version record verifies under its signer's certificate at the `av` it names: verifying only.
pub(crate) async fn record_signed(
    origin: &Origin,
    facts: &mut dyn TeamFacts,
    record: &VersionRecord,
) -> Result<bool, SyncError> {
    Ok(facts
        .certificate(record.signer, record.signer_av)
        .await?
        .as_ref()
        .and_then(Certificate::verifying)
        .is_some_and(|signer| record.verify(origin, &signer.ask).is_ok()))
}
