// When a stale file's rebuild ends (0054, A stale file): once the server shows every anchored pin and version. The
// anchored rows stand in the key tables from the open on, so the key flows already take nothing below them; this only
// says when the device may accept wraps and envelopes and write secrets again.

use std::collections::HashMap;

use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::encoding::{AccountId, Origin, Version};
use tablepro_keys::keys::Ed25519Public;
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::scope_key::KeyRef;
use tablepro_records::Kind;

use crate::api::error::SyncError;
use crate::api::ids::{KindName, ScopeName};
use crate::api::state::{Checkpoint, KeyVersionState, Row, RowKey, RowRange, StateTxn, Table};

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

// Each anchored pin is shown when the pin stands at its `av` or above under an IK the anchor did not see replaced, and
// the certificate at that `av` under that IK is in force. Each anchored version is shown when the version record at it
// with the anchored digest is in force; a row that ended waits for nothing, since nothing clears it.
pub async fn rebuild_shown(
    txn: &mut dyn StateTxn,
    origin: &Origin,
    account: AccountId,
    checkpoint: &Checkpoint,
) -> Result<bool, SyncError> {
    let certificates = certificates(txn).await?;
    for anchored in &checkpoint.pins {
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
        if anchored.state == KeyVersionState::Ended {
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
