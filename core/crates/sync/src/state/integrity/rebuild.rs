// When a stale file's rebuild ends (0054, A stale file): once the server shows every anchored pin and version. The
// anchored rows stand in the key tables from the open on, so the key flows already take nothing below them; this only
// says when the device may accept wraps and envelopes and write secrets again.

use std::collections::HashMap;

use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::encoding::{AccountId, Origin, TeamId, Version};
use tablepro_keys::keys::Ed25519Public;
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::scope_key::KeyRef;
use tablepro_records::Kind;

use crate::api::error::SyncError;
use crate::api::ids::{KindName, ScopeName};
use crate::api::state::{Checkpoint, KeyVersionState, Row, RowKey, RowRange, StateTxn, StoppedCause, Table};

// The IK of each certificate the key tables hold in force, by account and `av`: `key.account` in the personal scope,
// `key.member` in a team.
async fn certificates(txn: &mut dyn StateTxn) -> Result<HashMap<(AccountId, Version), Ed25519Public>, SyncError> {
    let kinds = [KindName::of(Kind::KeyAccount), KindName::of(Kind::KeyMember)];
    let mut held = HashMap::new();
    for row in txn.scan(&RowRange::Table(Table::KeyObjects)).await? {
        let Row::KeyObject(row) = row else { continue };
        if !row.applied || !kinds.contains(&row.kind) {
            continue;
        }
        let object = KeyObject::parse(row.kind.as_str(), &row.record_id, row.fields.as_bytes())?;
        match (object.id, object.body) {
            (KeyRecordId::Account { account, av }, KeyBody::Account(body))
            | (KeyRecordId::Member { account, av }, KeyBody::Member(body)) => {
                held.insert((account, av), body.certificate(account, av).ik);
            }
            _ => {}
        }
    }
    Ok(held)
}

// The scopes the device reads now, beside the personal and history scopes it always reads: each team whose pull caught
// up, with the members its roster names.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Reading {
    pub teams: HashMap<TeamId, Vec<AccountId>>,
}

impl Reading {
    // Its own account's pin, and the pin of each member of a team it reads.
    fn meets(&self, own: AccountId, account: AccountId) -> bool {
        account == own || self.teams.values().any(|members| members.contains(&account))
    }

    fn reads(&self, scope: ScopeName) -> bool {
        match scope {
            ScopeName::Team(team) => self.teams.contains_key(&team),
            ScopeName::Personal | ScopeName::History => true,
        }
    }
}

// Each anchored pin is shown when the pin stands at its `av` or above under an IK the anchor did not see replaced, and
// the certificate at that `av` under that IK is in force. Each anchored version is shown when the version record at it
// with the anchored digest is in force. Only what the device still reads is waited for: a team it left, or an account
// it no longer shares a team with, can never be shown, and its anchored rows stay in the key tables as the floor any
// later copy is held to. A row that ended waits for nothing, since nothing clears it, and nor does a team stopped until
// a version the server lost comes back (0062): its signer's device decides when, and the stop already keeps the team
// from writing.
pub async fn rebuild_shown(
    txn: &mut dyn StateTxn,
    origin: &Origin,
    account: AccountId,
    checkpoint: &Checkpoint,
    reading: &Reading,
) -> Result<bool, SyncError> {
    let certificates = certificates(txn).await?;
    for anchored in checkpoint.pins.iter().filter(|pin| reading.meets(account, pin.account)) {
        let Some(Row::KeyPin(pin)) = txn.get(&RowKey::KeyPin(anchored.account)).await? else {
            return Ok(false);
        };
        let shown = pin.av >= anchored.av
            && !anchored.replaced.contains(&pin.ik)
            && certificates.get(&(anchored.account, pin.av)) == Some(&pin.ik);
        if !shown {
            return Ok(false);
        }
    }
    for anchored in &checkpoint.versions {
        let waits_on_signer = anchored.stopped_cause == Some(StoppedCause::RestoreWait);
        if anchored.state == KeyVersionState::Ended || waits_on_signer || !reading.reads(anchored.scope) {
            continue;
        }
        let owner = match anchored.scope {
            ScopeName::Team(team) => team.0,
            ScopeName::Personal | ScopeName::History => account.0,
        };
        let id = KeyRecordId::Version(KeyRef {
            owner,
            purpose: anchored.purpose,
            version: anchored.version,
        });
        let key = RowKey::KeyObject(anchored.scope, KindName::of(Kind::KeyVersion), id.to_wire());
        let Some(Row::KeyObject(row)) = txn.get(&key).await? else {
            return Ok(false);
        };
        if !row.applied {
            return Ok(false);
        }
        let object = KeyObject::parse(row.kind.as_str(), &row.record_id, row.fields.as_bytes())?;
        let digest = object
            .version_record()
            .map(|record| record.digest(origin))
            .transpose()?;
        if digest != Some(anchored.record) {
            return Ok(false);
        }
    }
    Ok(true)
}
