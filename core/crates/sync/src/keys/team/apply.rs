// What a pull brings into a team (0056, Rollback, In order and Snapshots) and what the device decides on its roster.

use std::collections::BTreeMap;

use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::encoding::{TeamId, Version};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::wrap::Recipient;

use super::book::{Progress, TeamBook, TeamEvent, record_signed};
use super::roster;
use super::service_facts::{FactsCache, ServiceFacts};
use crate::api::error::SyncError;
use crate::api::ids::{EpochId, ScopeName};
use crate::api::key_flows::{ArrivalOrder, KeyApplied, KeyArrival, KeyNoticeKind, RefusedObject, Roster};
use crate::api::state::{KeyVersionState, PendingFlow, Row, RowRange, StateTxn, StoppedCause, Table};
use crate::api::transport::{PulledRecord, RejectedCode};
use crate::engine::Backoff;
use crate::keys::KeyService;

// What the commit of one call changed, told to the engine and the app once it landed.
#[derive(Default)]
struct Outcome {
    events: Vec<TeamEvent>,
    conflict: bool,
    superseded: bool,
    epoch: Option<EpochId>,
}

// A rotation a roster read made that the server refused: the version in force then, and the back-off before a roster
// read tries again at that version.
#[derive(Debug, Clone, Copy)]
pub(crate) struct RefusedRotation {
    version: Option<Version>,
    backoff: Backoff,
    until_us: i64,
}

// What judging a team again inside another flow's commit changed.
pub(crate) struct TeamJudged {
    team: TeamId,
    events: Vec<TeamEvent>,
    epoch: Option<EpochId>,
}

fn parse(record: &PulledRecord) -> Result<KeyObject, KeysError> {
    let fields = record.fields_json.as_deref().ok_or(KeysError::Encoding {
        what: "a key object with no fields",
    })?;
    KeyObject::parse(record.kind.as_str(), &record.record_id, fields.as_bytes())
}

// The records a call takes, each parsed. A snapshot carries no order: its certificates go to the pins first, each
// account's in ascending `av` so an endorsement is held before the replace it follows, then its versions are judged
// as one set.
fn arrival_order(arrival: &KeyArrival) -> Vec<(&PulledRecord, Result<KeyObject, KeysError>)> {
    let mut parsed: Vec<(&PulledRecord, Result<KeyObject, KeysError>)> = arrival
        .records
        .iter()
        .filter(|record| record.deleted.is_none())
        .map(|record| (record, parse(record)))
        .collect();
    if arrival.order == ArrivalOrder::Snapshot {
        parsed.sort_by_key(|(_, object)| match object {
            Ok(KeyObject {
                id: KeyRecordId::Member { account, av },
                ..
            }) => (0, Some((*account, *av))),
            _ => (1, None),
        });
    }
    parsed
}

fn merge(into: &mut Progress, from: Progress) {
    let offset = into.events.len();
    into.cleared.extend(from.cleared.into_iter().map(|mut clearing| {
        clearing.event += offset;
        clearing
    }));
    into.events.extend(from.events);
    for refused in from.refused {
        if !into.refused.iter().any(|held| held.record_id == refused.record_id) {
            into.refused.push(refused);
        }
    }
    into.held = from.held;
}

impl KeyService {
    pub(super) async fn apply_team(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let ScopeName::Team(team) = arrival.scope else {
            return Err(SyncError::NotAllowed {
                what: "apply team objects outside a team",
            });
        };
        // A stale file keeps what the server serves, so its rebuild sees the anchored versions, but takes no wrap until
        // the server showed every anchored pin and version (0054, A stale file). The commit that ends the rebuild
        // judges each team on what it kept meanwhile.
        let rebuilding = self.is_rebuilding();
        let mut txn = self.begin().await?;
        let mut book = self.load_team(&mut *txn, team).await?;
        let before = book.row().cloned();
        // The replay position: the newest version record the server served at or before each place, which the
        // honest server writes by, apart from the version this device verified. Only a pull moves it, from where the
        // engine says the page stands, never back from the one stored (0056, Rollback, In order; 0054, `scopes`).
        let stored = self.scope_row(&mut *txn, arrival.scope).await?.key_version;
        let mut in_force = arrival.in_force.max(stored);
        let mut own_member_av = self.own_member_av(&mut *txn, arrival.scope).await?;
        let mut served: BTreeMap<Version, KeyObject> = BTreeMap::new();
        let mut cache = FactsCache::default();
        let mut progress = Progress::default();
        let mut outcome = Outcome::default();
        // Versions, rings or wraps taken since the last advance. In order, a certificate or the next version record
        // is judged only after what came before it.
        let mut pending = false;
        for (record, object) in arrival_order(&arrival) {
            let object = match object {
                Ok(object) => object,
                Err(error) => {
                    refuse(&mut progress, &record.record_id, error);
                    continue;
                }
            };
            let boundary = matches!(object.id, KeyRecordId::Member { .. } | KeyRecordId::Version(_));
            if arrival.order == ArrivalOrder::InOrder && boundary && pending && !rebuilding {
                let step = self.advance_team(&mut *txn, &mut book, &mut cache).await?;
                merge(&mut progress, step);
                pending = false;
            }
            self.take_object(&mut *txn, &mut book, &mut cache, &object, &mut progress, &mut outcome)
                .await?;
            let kept = !progress
                .refused
                .iter()
                .any(|refused| refused.record_id == record.record_id);
            match object.id {
                KeyRecordId::Member { account, av } => {
                    if kept && account == self.account() {
                        own_member_av = own_member_av.max(Some(av));
                    }
                }
                KeyRecordId::Version(key) => {
                    pending = true;
                    if kept {
                        served.insert(key.version, object.clone());
                        if arrival.order == ArrivalOrder::InOrder {
                            in_force = self
                                .replay(&mut *txn, &mut cache, arrival.scope, in_force, &served)
                                .await?;
                        }
                    }
                }
                KeyRecordId::Wrap(target) => {
                    pending = true;
                    if arrival.order == ArrivalOrder::InOrder
                        && target.recipient == Recipient::Account(self.account())
                        && own_member_av.is_some_and(|newest| target.recipient_version < newest)
                        && in_force.is_none_or(|version| target.version >= version)
                    {
                        // A wrap of the version in force to an `av` this account had left when the team showed its
                        // newer certificate: a teammate was kept on the old view (0056, Teams, A member checks what
                        // reaches it).
                        outcome.superseded = true;
                    }
                }
                _ => pending = true,
            }
        }
        if arrival.order == ArrivalOrder::Snapshot {
            in_force = self
                .replay(&mut *txn, &mut cache, arrival.scope, in_force, &served)
                .await?;
        }
        if !rebuilding {
            let step = self.advance_team(&mut *txn, &mut book, &mut cache).await?;
            merge(&mut progress, step);
        }
        let mut applied = self
            .commit_team(txn, team, before.as_ref(), book, &mut outcome, progress)
            .await?;
        applied.in_force = in_force;
        Ok(applied)
    }

    // The replay position moves one version at a time, to each next version record served that verifies under its
    // signer's certificate, as the honest server writes them; a record far above or one no certificate signs leaves
    // it where it is.
    async fn replay(
        &self,
        txn: &mut dyn StateTxn,
        cache: &mut FactsCache,
        scope: ScopeName,
        mut in_force: Option<Version>,
        served: &BTreeMap<Version, KeyObject>,
    ) -> Result<Option<Version>, SyncError> {
        let mut facts = ServiceFacts {
            service: self,
            txn,
            scope,
            cache,
        };
        loop {
            let next = match in_force {
                Some(version) => version.next()?,
                None => Version::FIRST,
            };
            let Some(record) = served.get(&next).and_then(KeyObject::version_record) else {
                return Ok(in_force);
            };
            if !record_signed(self.origin(), &mut facts, &record).await? {
                return Ok(in_force);
            }
            in_force = Some(next);
        }
    }

    async fn own_member_av(&self, txn: &mut dyn StateTxn, scope: ScopeName) -> Result<Option<Version>, SyncError> {
        Ok(self
            .held_objects(txn, scope, KeyKind::Member)
            .await?
            .iter()
            .filter_map(|held| match held.object.id {
                KeyRecordId::Member { account, av } if account == self.account() => Some(av),
                _ => None,
            })
            .max())
    }

    // A restore wait that cleared in `txn`: the versions held above the one the team waited at are judged now, as a
    // pull judges them, so a restart that passed during the wait is held for the person's words and a next version
    // that passed is taken, instead of the row reading as current under the older key until another key object
    // arrives (0062, 0064). The events are told once `txn` committed.
    pub(crate) async fn judge_resumed_team(
        &self,
        txn: &mut dyn StateTxn,
        team: TeamId,
    ) -> Result<TeamJudged, SyncError> {
        let mut book = self.load_team(txn, team).await?;
        let before = book.row().cloned();
        let mut cache = FactsCache::default();
        let progress = self.advance_team(txn, &mut book, &mut cache).await?;
        if let Some(row) = book.into_row() {
            self.put_team_row(txn, before.as_ref(), &row).await?;
        }
        Ok(TeamJudged {
            team,
            events: progress.events,
            epoch: None,
        })
    }

    // A stale file's rebuild ended in `txn`: the team takes the wraps its pulls kept while the rebuild took none, as
    // an arrival with nothing new would judge them. The events are told once `txn` committed.
    pub(crate) async fn judge_rebuilt_team(
        &self,
        txn: &mut dyn StateTxn,
        team: TeamId,
    ) -> Result<TeamJudged, SyncError> {
        let mut book = self.load_team(txn, team).await?;
        let before = book.row().cloned();
        let mut cache = FactsCache::default();
        let progress = self.advance_team(txn, &mut book, &mut cache).await?;
        let mut outcome = Outcome::default();
        let progress = self
            .settle_team(txn, team, before.as_ref(), book, &mut outcome, progress)
            .await?;
        Ok(TeamJudged {
            team,
            events: progress.events,
            epoch: outcome.epoch,
        })
    }

    pub(crate) async fn tell_judged(&self, judged: &TeamJudged) -> Result<(), SyncError> {
        let outcome = Outcome {
            events: judged.events.clone(),
            epoch: judged.epoch,
            ..Outcome::default()
        };
        self.tell(judged.team, &outcome).await
    }

    async fn advance_team(
        &self,
        txn: &mut dyn StateTxn,
        book: &mut TeamBook,
        cache: &mut FactsCache,
    ) -> Result<Progress, SyncError> {
        let scope = book.scope();
        let mut facts = ServiceFacts {
            service: self,
            txn,
            scope,
            cache,
        };
        book.advance(&mut facts).await
    }

    async fn take_object(
        &self,
        txn: &mut dyn StateTxn,
        book: &mut TeamBook,
        cache: &mut FactsCache,
        object: &KeyObject,
        progress: &mut Progress,
        outcome: &mut Outcome,
    ) -> Result<(), SyncError> {
        let scope = book.scope();
        let record_id = object.id.to_wire();
        // An object that is no key object of this team, or a certificate its own IK does not sign, is never kept, so
        // it can neither take an id a real object needs nor be pushed back after a restore.
        if let Err(error) = book.check_shape(object) {
            refuse(progress, &record_id, error);
            return Ok(());
        }
        if let (KeyRecordId::Member { account, av }, KeyBody::Member(body)) = (&object.id, &object.body)
            && let Err(error) = body.certificate(*account, *av).verify(self.origin())
        {
            refuse(progress, &record_id, error);
            return Ok(());
        }
        // At the version held only the anchored record counts, so another is never kept where it would take the
        // anchored record's id (0056, Rollback, Per scope key).
        if let (Some(row), Some(record)) = (book.row(), object.version_record())
            && record.key.version == row.version
            && record.digest(self.origin())? != row.record
        {
            refuse(progress, &record_id, KeysError::Conflict);
            outcome.conflict = true;
            return Ok(());
        }
        match self.hold_object(txn, scope, object, true).await {
            Ok(()) => {}
            Err(SyncError::Keys(KeysError::Conflict)) => {
                refuse(progress, &record_id, KeysError::Conflict);
                outcome.conflict = true;
                return Ok(());
            }
            Err(other) => return Err(other),
        }
        match (&object.id, &object.body) {
            (KeyRecordId::Member { account, av }, KeyBody::Member(body)) => {
                let certificate = body.certificate(*account, *av);
                match self.offer_certificate(txn, scope, &certificate).await {
                    Ok(_) => {}
                    Err(SyncError::Keys(error)) => refuse(progress, &record_id, error),
                    Err(other) => return Err(other),
                }
                cache.learn(&certificate);
            }
            _ => {
                if let Err(error) = book.insert(object, true) {
                    refuse(progress, &record_id, error);
                }
            }
        }
        Ok(())
    }

    async fn commit_team(
        &self,
        mut txn: Box<dyn StateTxn>,
        team: TeamId,
        before: Option<&crate::api::state::KeyVersionRow>,
        book: TeamBook,
        outcome: &mut Outcome,
        progress: Progress,
    ) -> Result<KeyApplied, SyncError> {
        let progress = self
            .settle_team(&mut *txn, team, before, book, outcome, progress)
            .await?;
        txn.commit().await?;
        outcome.events.extend(progress.events);
        self.tell(team, outcome).await?;
        Ok(KeyApplied {
            in_force: None,
            held: progress.held.into_iter().collect(),
            refused: progress.refused,
        })
    }

    // The team's row as the book left it, in `txn`.
    async fn settle_team(
        &self,
        txn: &mut dyn StateTxn,
        team: TeamId,
        before: Option<&crate::api::state::KeyVersionRow>,
        book: TeamBook,
        outcome: &mut Outcome,
        progress: Progress,
    ) -> Result<Progress, SyncError> {
        let scope = ScopeName::Team(team);
        let mut after = book.into_row();
        let mut progress = progress;
        let mut prior = before.cloned();
        // A cleared catch-up stop moves only through the stop flow's check and write, which queues the withdrawal of
        // its report in this commit. One it does not take leaves the team where it stopped, with nothing after it.
        for clearing in std::mem::take(&mut progress.cleared) {
            match self
                .clear_catch_up_stop(&mut *txn, &clearing.stopped, clearing.cleared.clone(), &clearing.wrap)
                .await
            {
                Ok(()) => prior = Some(clearing.cleared),
                Err(SyncError::Keys(_) | SyncError::NotAllowed { .. }) => {
                    tracing::debug!(%scope, "a re-confirmation the stop check did not take");
                    progress.events.truncate(clearing.event);
                    after = Some(clearing.stopped);
                    break;
                }
                Err(other) => return Err(other),
            }
        }
        if let Some(row) = &mut after {
            if row.state == KeyVersionState::Ended && row.epoch.is_none() {
                row.epoch = self.scope_row(&mut *txn, scope).await?.epoch;
            }
            self.put_team_row(&mut *txn, prior.as_ref(), row).await?;
            outcome.epoch = row.epoch;
        }
        Ok(progress)
    }

    // Once the commit landed: the engine's hooks, the notices, and the certificate copied in again after a superseded
    // wrap.
    async fn tell(&self, team: TeamId, outcome: &Outcome) -> Result<(), SyncError> {
        let scope = ScopeName::Team(team);
        for event in &outcome.events {
            match event {
                TeamEvent::Stopped { .. } => {
                    self.hooks().stop_scope(scope, StoppedCause::CatchUp);
                    self.raise_notice(KeyNoticeKind::ScopeStopped {
                        scope,
                        cause: StoppedCause::CatchUp,
                    })?;
                }
                TeamEvent::Cleared { .. } => self.hooks().resume_scope(scope),
                TeamEvent::Ended => {
                    self.hooks().end_scope(scope, outcome.epoch);
                    self.raise_notice(KeyNoticeKind::ScopeEnded { scope })?;
                }
                TeamEvent::Restarted { .. } => {
                    self.raise_notice(KeyNoticeKind::TeamKeyRestarted { team })?;
                }
                TeamEvent::RestartHeld { signer, .. } => {
                    self.hooks().stop_scope(scope, StoppedCause::RestartHeld);
                    self.raise_notice(KeyNoticeKind::RestartHeld { team, signer: *signer })?;
                }
                TeamEvent::Joined { .. } | TeamEvent::Advanced { .. } => {}
            }
        }
        if outcome.conflict {
            self.raise_notice(KeyNoticeKind::Conflict { scope })?;
        }
        if outcome.superseded {
            self.raise_notice(KeyNoticeKind::SupersededWrap { team })?;
            // The alarm reports the split; copying the certificate in again is what the member can add, and a failed
            // copy is retried when the roster is next read.
            let _ = self.publish_certificates(team, true).await;
        }
        Ok(())
    }

    pub(super) async fn decide_on_roster(&self, team: TeamId, roster: Roster) -> Result<(), SyncError> {
        // A roster read before the team's pull caught up is no evidence of anything (0051, `members`).
        if !roster.caught_up() {
            return Ok(());
        }
        self.rosters().put(team, roster.clone());
        let scope = {
            let mut txn = self.begin().await?;
            self.scope_row(&mut *txn, ScopeName::Team(team)).await?
        };
        if !crate::keys::roster_in_epoch(&roster, &scope) {
            return Ok(());
        }
        self.end_unconfirmable_stop(team, &roster).await?;
        if self.own_account_in_team_missing(team).await? {
            self.publish_certificates(team, false).await?;
        }
        if roster.rotation_due && self.may_rotate_unprompted(team, &roster).await? {
            let version = self.team_version(team).await?;
            if self.rotation_backs_off(team, version) {
                return Ok(());
            }
            match self.rotate(team, &[]).await {
                // Another holder's rotation landed first and met the mark.
                Ok(())
                | Err(SyncError::Rejected {
                    code: RejectedCode::CreateOnly,
                }) => {
                    self.refused_rotations().remove(&team);
                }
                Err(error @ SyncError::Rejected { .. }) => {
                    self.refuse_rotation(team, version);
                    return Err(error);
                }
                Err(other) => return Err(other),
            }
        }
        Ok(())
    }

    async fn team_version(&self, team: TeamId) -> Result<Option<Version>, SyncError> {
        let mut txn = self.begin().await?;
        let book = self.load_team(&mut *txn, team).await?;
        Ok(book.row().map(|row| row.version))
    }

    // A refusal at this version waits out its back-off; a version that moved since is a new try.
    fn rotation_backs_off(&self, team: TeamId, version: Option<Version>) -> bool {
        let now = self.now_us();
        let mut refused = self.refused_rotations();
        match refused.get(&team) {
            Some(held) if held.version == version => now < held.until_us,
            Some(_) => {
                refused.remove(&team);
                false
            }
            None => false,
        }
    }

    fn refuse_rotation(&self, team: TeamId, version: Option<Version>) {
        let now = self.now_us();
        let mut refused = self.refused_rotations();
        let held = refused
            .entry(team)
            .and_modify(|held| {
                if held.version != version {
                    *held = RefusedRotation {
                        version,
                        backoff: Backoff::STANDARD,
                        until_us: now,
                    };
                }
            })
            .or_insert(RefusedRotation {
                version,
                backoff: Backoff::STANDARD,
                until_us: now,
            });
        let wait_us = i64::try_from(held.backoff.failed(None))
            .unwrap_or(i64::MAX)
            .saturating_mul(1_000);
        held.until_us = now.saturating_add(wait_us);
    }

    // A stopped team whose version no owner or admin on the roster held ends on the device, which withdraws its report
    // (0056, Teams, A stopped device).
    pub(crate) async fn end_unconfirmable_stop(&self, team: TeamId, roster: &Roster) -> Result<(), SyncError> {
        let mut txn = self.begin().await?;
        let book = self.load_team(&mut *txn, team).await?;
        let Some(row) = book.row().cloned() else { return Ok(()) };
        // Only a catch-up stop waits on an owner's or admin's re-confirmation; a restore wait or a held restart
        // clears by its own event, whoever is on the roster (0062, 0064).
        if row.state != KeyVersionState::Stopped || row.stopped_cause != Some(StoppedCause::CatchUp) {
            return Ok(());
        }
        let mut cache = FactsCache::default();
        let mut facts = ServiceFacts {
            service: self,
            txn: &mut *txn,
            scope: ScopeName::Team(team),
            cache: &mut cache,
        };
        if roster::someone_can_reconfirm(self.origin(), &mut facts, roster, &row.holders).await? {
            return Ok(());
        }
        let mut ended = row.clone();
        ended.state = KeyVersionState::Ended;
        ended.stopped_cause = None;
        ended.epoch = self.scope_row(&mut *txn, ScopeName::Team(team)).await?.epoch;
        self.put_team_row(&mut *txn, Some(&row), &ended).await?;
        txn.commit().await?;
        let outcome = Outcome {
            events: vec![TeamEvent::Ended],
            epoch: ended.epoch,
            ..Outcome::default()
        };
        self.tell(team, &outcome).await
    }

    async fn own_account_in_team_missing(&self, team: TeamId) -> Result<bool, SyncError> {
        let mut txn = self.begin().await?;
        let Some(own) = self.own_account(&mut *txn).await? else {
            return Ok(false);
        };
        let id = KeyRecordId::Member {
            account: self.account(),
            av: own.av,
        }
        .to_wire();
        Ok(self
            .held_object(&mut *txn, ScopeName::Team(team), KeyKind::Member, &id)
            .await?
            .is_none())
    }

    // Any holder rotates while the team is due, unless a removal review still has to choose whom the rotation leaves
    // out: this device's own account rotation that has not written this team yet, or another member's, which that
    // member's app writes. A team the flow already wrote waits for nothing, whatever other team keeps the flow open.
    async fn may_rotate_unprompted(&self, team: TeamId, roster: &Roster) -> Result<bool, SyncError> {
        let mut txn = self.begin().await?;
        let pending = txn.scan(&RowRange::Table(Table::KeyPending)).await?;
        if pending.iter().any(|row| {
            matches!(
                row,
                Row::KeyPending(pending) if matches!(pending.flow, PendingFlow::AccountRotation { .. })
                    && crate::keys::rotation::rotation_still_rotates(&pending.state, team)
            )
        }) {
            return Ok(false);
        }
        let book = self.load_team(&mut *txn, team).await?;
        if book.row().is_none_or(|row| row.state != KeyVersionState::Ok) {
            return Ok(false);
        }
        let mut cache = FactsCache::default();
        let mut facts = ServiceFacts {
            service: self,
            txn: &mut *txn,
            scope: ScopeName::Team(team),
            cache: &mut cache,
        };
        if roster::rotation_left_to_a_member(&book, &mut facts, roster).await? {
            return Ok(false);
        }
        book.own_holds(&mut facts).await
    }

    pub(super) async fn roster_of(&self, txn: &mut dyn StateTxn, team: TeamId) -> Result<Roster, SyncError> {
        self.current_roster(txn, team).await?.ok_or(SyncError::NotAllowed {
            what: "act on a team before its roster is read in the epoch it syncs in",
        })
    }
}

fn refuse(progress: &mut Progress, record_id: &str, error: KeysError) {
    if !progress.refused.iter().any(|held| held.record_id == record_id) {
        progress.refused.push(RefusedObject {
            record_id: record_id.to_owned(),
            error,
        });
    }
}
