// What a pull brings into a team (0056, Rollback, In order and Snapshots) and what the device decides on its roster.

use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::encoding::{TeamId, Version};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::wrap::Recipient;

use super::book::{Progress, TeamBook, TeamEvent};
use super::roster;
use super::service_facts::{FactsCache, ServiceFacts};
use crate::api::error::SyncError;
use crate::api::ids::{EpochId, ScopeName};
use crate::api::key_flows::{ArrivalOrder, KeyApplied, KeyArrival, KeyNoticeKind, RefusedObject, Roster};
use crate::api::state::{KeyVersionState, PendingFlow, Row, RowRange, StateTxn, StoppedCause, Table};
use crate::api::transport::{PulledRecord, RejectedCode};
use crate::keys::KeyService;

// What the commit of one call changed, told to the engine and the app once it landed.
#[derive(Default)]
struct Outcome {
    events: Vec<TeamEvent>,
    conflict: bool,
    superseded: bool,
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
        let mut txn = self.begin().await?;
        let mut book = self.load_team(&mut *txn, team).await?;
        let before = book.row().cloned();
        // The replay position: the newest version record the server served at or before each place, which the
        // honest server writes by, apart from the version this device verified. Only a pull moves it (0056, Rollback,
        // In order; 0054, `scopes`).
        let mut in_force = self.scope_row(&mut *txn, arrival.scope).await?.key_version;
        let mut own_member_av = self.own_member_av(&mut *txn, arrival.scope).await?;
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
            if arrival.order == ArrivalOrder::InOrder && boundary && pending {
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
                    if book.check_shape(&object).is_ok() {
                        in_force = in_force.max(Some(key.version));
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
        let step = self.advance_team(&mut *txn, &mut book, &mut cache).await?;
        merge(&mut progress, step);
        let mut applied = self
            .commit_team(txn, team, before.as_ref(), book, &mut outcome, progress)
            .await?;
        applied.in_force = in_force;
        Ok(applied)
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
        match self.hold_object(txn, scope, object, true).await {
            Ok(()) => {}
            Err(SyncError::Keys(KeysError::Conflict)) => {
                refuse(progress, &record_id, KeysError::Conflict);
                outcome.conflict = true;
                // Another version record at an id the device holds is a fork of the team's keys, which ends it.
                if object.id.kind() == KeyKind::Version && book.end_now() {
                    progress.events.push(TeamEvent::Ended);
                }
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
                cache.forget(*account);
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
        let scope = ScopeName::Team(team);
        let mut after = book.into_row();
        if let Some(row) = &mut after {
            if row.state == KeyVersionState::Ended && row.epoch.is_none() {
                row.epoch = self.scope_row(&mut *txn, scope).await?.epoch;
            }
            self.put_team_row(&mut *txn, before, row).await?;
            outcome.epoch = row.epoch;
        }
        txn.commit().await?;
        outcome.events.extend(progress.events);
        self.tell(team, outcome).await?;
        Ok(KeyApplied {
            in_force: None,
            held: progress.held.into_iter().collect(),
            refused: progress.refused,
        })
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
        if !roster.caught_up {
            return Ok(());
        }
        self.rosters().put(team, roster.clone());
        self.end_unconfirmable_stop(team, &roster).await?;
        if self.own_account_in_team_missing(team).await? {
            self.publish_certificates(team, false).await?;
        }
        if roster.rotation_due && self.may_rotate_unprompted(team, &roster).await? {
            match self.rotate(team, &[]).await {
                // Another holder's rotation landed first and met the mark.
                Err(SyncError::Rejected {
                    code: RejectedCode::CreateOnly,
                }) => {}
                other => other?,
            }
        }
        Ok(())
    }

    // A stopped team whose version no owner or admin on the roster held ends on the device, which withdraws its report
    // (0056, Teams, A stopped device).
    async fn end_unconfirmable_stop(&self, team: TeamId, roster: &Roster) -> Result<(), SyncError> {
        let mut txn = self.begin().await?;
        let book = self.load_team(&mut *txn, team).await?;
        let Some(row) = book.row().cloned() else { return Ok(()) };
        if row.state != KeyVersionState::Stopped {
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
        if row.stopped_cause == Some(StoppedCause::RestoreWait) {
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
    // out: this device's own account rotation not yet written, or another member's, which that member's app writes.
    async fn may_rotate_unprompted(&self, team: TeamId, roster: &Roster) -> Result<bool, SyncError> {
        let mut txn = self.begin().await?;
        let pending = txn.scan(&RowRange::Table(Table::KeyPending)).await?;
        if pending.iter().any(|row| {
            matches!(
                row,
                Row::KeyPending(pending) if matches!(pending.flow, PendingFlow::AccountRotation { .. })
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
        if roster::rotation_left_to_a_member(&book, &mut facts, roster, self.account()).await? {
            return Ok(false);
        }
        book.own_holds(&mut facts).await
    }

    pub(super) fn roster_of(&self, team: TeamId) -> Result<Roster, SyncError> {
        self.rosters().get(team).ok_or(SyncError::NotAllowed {
            what: "act on a team before its roster is read",
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
