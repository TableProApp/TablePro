// A restart of a team key another account signed, met by a device that held a version of it: held until the person
// compares the restarting owner's six words and accepts, as a key change is (0064). Accepting without comparing is not
// offered.

use std::collections::BTreeSet;

use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::cert::AccountCertificate;
use tablepro_keys::check::check_signed_under_newest;
use tablepro_keys::encoding::TeamId;
use tablepro_keys::keys::Ed25519Public;
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::scope_key::{Start, VersionRecord};
use tablepro_keys::trust::PinHow;
use tablepro_keys::wrap::Recipient;

use super::facts::{Certificate, TeamFacts, known_pin};
use super::service_facts::{FactsCache, ServiceFacts};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::HeldRestart;
use crate::api::state::{Holder, KeyPinRow, KeyVersionState, Row, StateTxn, StopClear, StoppedCause};
use crate::keys::KeyService;

impl KeyService {
    pub(super) async fn held_team_restart(&self, team: TeamId) -> Result<Option<HeldRestart>, SyncError> {
        let mut txn = self.begin().await?;
        let Some((record, signer)) = self.restart_held(&mut *txn, team).await? else {
            return Ok(None);
        };
        Ok(Some(HeldRestart {
            team,
            version: record.key.version,
            signer: signer.account,
            signer_ik: signer.ik,
            words: self.fingerprint_of(signer.account, &signer.ik)?,
        }))
    }

    // The person compared the words of `signer_ik`: the restart applies with its signer as a holder, and this account
    // too when the restart wrapped the key to it. The signer's pin is `compared` under that IK.
    pub(super) async fn accept_held_restart(&self, team: TeamId, signer_ik: Ed25519Public) -> Result<(), SyncError> {
        let scope = ScopeName::Team(team);
        let mut txn = self.begin().await?;
        let (record, signer) = self.restart_held(&mut *txn, team).await?.ok_or(SyncError::NotAllowed {
            what: "accept a restart this device does not hold",
        })?;
        if signer.ik != signer_ik {
            return Err(SyncError::NotAllowed {
                what: "accept a restart under another key than the one compared",
            });
        }
        let pin = self.pin(&mut *txn, signer.account).await?;
        if pin.as_ref().is_some_and(|pin| pin.alert || pin.ik != signer.ik) {
            return Err(SyncError::NotAllowed {
                what: "accept a restart while its signer's key change is open",
            });
        }
        txn.put(Row::KeyPin(KeyPinRow {
            account: signer.account,
            ik: signer.ik,
            av: pin.as_ref().map_or(signer.av, |pin| pin.av.max(signer.av)),
            how: PinHow::Compared,
            alert: false,
            replaced: pin.map(|pin| pin.replaced).unwrap_or_default(),
        }))
        .await?;
        let book = self.load_team(&mut *txn, team).await?;
        let Some(before) = book.row().cloned() else {
            return Err(SyncError::NotAllowed {
                what: "accept a restart this device does not hold",
            });
        };
        let mut holders = BTreeSet::from([Holder {
            account: signer.account,
            ik: signer.ik,
        }]);
        for wrap in book.wraps_of(record.key.version) {
            let to_me = wrap.target.recipient == Recipient::Account(self.account());
            if !to_me || wrap.wrapper.account != signer.account || wrap.wrapper.av != signer.av {
                continue;
            }
            let Some(own) = self.own_certificate(&mut *txn, wrap.target.recipient_version).await? else {
                continue;
            };
            if own.verify(self.origin()).is_ok() && wrap.verify(self.origin(), &own.aek, &signer.ask).is_ok() {
                holders.insert(Holder {
                    account: self.account(),
                    ik: own.ik,
                });
            }
        }
        let mut row = before.clone();
        row.clear_stop(StopClear::AcceptedRestart)
            .map_err(|_| SyncError::NotAllowed {
                what: "accept a restart this device does not hold",
            })?;
        row.version = record.key.version;
        row.record = record.digest(self.origin())?;
        row.holders = holders.into_iter().collect();
        self.put_team_row(&mut *txn, Some(&before), &row).await?;
        txn.commit().await?;
        self.hooks().resume_scope(scope);
        self.hooks().pass_soon();
        Ok(())
    }

    // The restart the team row is held at, the version after the one held, and its signer's certificate in the team,
    // which verifies itself and the record.
    async fn restart_held(
        &self,
        txn: &mut dyn StateTxn,
        team: TeamId,
    ) -> Result<Option<(VersionRecord, AccountCertificate)>, SyncError> {
        let scope = ScopeName::Team(team);
        let book = self.load_team(txn, team).await?;
        let held = book.row().filter(|row| {
            row.state == KeyVersionState::Stopped && row.stopped_cause == Some(StoppedCause::RestartHeld)
        });
        let Some(row) = held else { return Ok(None) };
        let next = row.version.next()?;
        let Some(record) = book
            .version_record(next)
            .filter(|record| record.start == Start::Over && record.signer != self.account())
            .cloned()
        else {
            return Ok(None);
        };
        let id = KeyRecordId::Member {
            account: record.signer,
            av: record.signer_av,
        }
        .to_wire();
        let Some(KeyObject {
            body: KeyBody::Member(body),
            ..
        }) = self.applied_object(txn, scope, KeyKind::Member, &id).await?
        else {
            return Ok(None);
        };
        let certificate = body.certificate(record.signer, record.signer_av);
        certificate.verify(self.origin())?;
        record.verify(self.origin(), &certificate.ask)?;
        // Judged again as advancing judges a version: the person's words vouch for the IK, never for an old ASK the
        // account rotated away from since (0056, Rollback, Advancing).
        let mut cache = FactsCache::default();
        let mut facts = ServiceFacts {
            service: self,
            txn,
            scope,
            cache: &mut cache,
        };
        if !matches!(
            facts.certificate(record.signer, record.signer_av).await?,
            Some(Certificate::Usable(_))
        ) {
            return Err(KeysError::NotHolder.into());
        }
        let pin = known_pin(&mut facts, record.signer)
            .await?
            .filter(|pin| !pin.alert)
            .ok_or(SyncError::NotAllowed {
                what: "accept a restart while its signer's key change is open",
            })?;
        check_signed_under_newest(record.signer_av, pin.av)?;
        Ok(Some((record, certificate)))
    }
}
