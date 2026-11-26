// Personal envelopes and history entries (0056, Envelopes and history; Rollback): written only under the version
// signed under the account's current `av`, taken only under the version in force at their place and never below the
// copy held.

use secrecy::{ExposeSecret, SecretString};
use serde_json::Value;
use tablepro_keys::KeysError;
use tablepro_keys::body::{parse_sealed, sealed_json};
use tablepro_keys::check::check_not_below;
use tablepro_keys::encoding::{HistoryId, KeyPurpose, Scope, Version};
use tablepro_keys::envelope::{EnvelopeId, Sealed, open_envelope, open_history, seal_envelope, seal_history};
use tablepro_keys::json::{self, JsonValue};

use super::KeyService;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{KeyState, LockCause, OpenedEnvelope};
use crate::api::state::{KeyEnvelopeRow, KeyVersionState, Row, RowKey, StateTxn};

impl KeyService {
    // A stale or unanchored file handles no secret.
    fn check_trusted(&self) -> Result<(), SyncError> {
        if self.is_unanchored() {
            return Err(SyncError::Locked {
                cause: LockCause::Unanchored,
            });
        }
        if self.is_rebuilding() {
            return Err(SyncError::NotAllowed {
                what: "handle a secret before the key tables are rebuilt",
            });
        }
        Ok(())
    }

    // The version a device writes personal secrets or history under, refused while it is stopped or ended, and while
    // a newer account version it verified waits for the rest of its change set: then the newest version of the key is
    // one this device cannot open yet (0056, Writing).
    async fn writing_version(&self, txn: &mut dyn StateTxn, purpose: KeyPurpose) -> Result<Version, SyncError> {
        self.check_trusted()?;
        match self.state_of_keys(txn).await? {
            KeyState::Approved { .. } => {}
            KeyState::Locked { cause } => return Err(SyncError::Locked { cause }),
            _ => {
                return Err(SyncError::NotAllowed {
                    what: "write a personal secret on a device that is not approved",
                });
            }
        }
        if let Some(pin) = self.pin(txn, self.account).await?
            && let Some(newer) = self.own_certificate(txn, pin.av.next()?).await?
            && self.verify_certificate(txn, ScopeName::Personal, &newer).await.is_ok()
        {
            return Err(SyncError::NotAllowed {
                what: "write while a newer account version waits",
            });
        }
        let Some(current) = self.current_personal(txn, purpose).await? else {
            return Err(SyncError::NotAllowed {
                what: "write under a key not signed under the account's current version",
            });
        };
        match current.state {
            KeyVersionState::Ok => Ok(current.record.key.version),
            KeyVersionState::Stopped => Err(SyncError::Locked {
                cause: LockCause::PersonalStopped,
            }),
            KeyVersionState::Ended => Err(SyncError::Locked {
                cause: LockCause::AccountEnded,
            }),
        }
    }

    pub(crate) async fn seal_personal(
        &self,
        envelope: &EnvelopeId,
        secret: &SecretString,
        dest: &Value,
    ) -> Result<Value, SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let mut txn = self.begin().await?;
        let kv = self.writing_version(txn.as_mut(), KeyPurpose::Personal).await?;
        let key = self.personal_key(txn.as_mut(), KeyPurpose::Personal, kv).await?;
        let dest = to_json_value(dest)?;
        let sealed = seal_envelope(
            &key,
            &self.origin,
            Scope::Personal(self.account),
            envelope,
            kv,
            secret.expose_secret(),
            &dest,
        )?;
        let record_id = envelope.to_wire();
        let held = self.held_envelope(txn.as_mut(), &record_id).await?;
        if held.is_none_or(|held| held < kv) {
            txn.put(Row::KeyEnvelope(KeyEnvelopeRow {
                scope: ScopeName::Personal,
                record_id,
                kv,
            }))
            .await?;
        }
        txn.commit().await?;
        sealed_fields(&sealed)
    }

    pub(crate) async fn open_personal(
        &self,
        envelope: &EnvelopeId,
        fields: &Value,
        in_force: Option<Version>,
    ) -> Result<OpenedEnvelope, SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        self.check_trusted()?;
        let mut txn = self.begin().await?;
        let sealed = parse_fields(fields)?;
        let newest = self
            .personal_row(txn.as_mut(), KeyPurpose::Personal)
            .await?
            .map(|row| row.version)
            .ok_or(SyncError::NotAllowed {
                what: "open a personal secret before holding the personal key",
            })?;
        match in_force {
            Some(in_force) if sealed.kv != in_force => {
                return Err(if sealed.kv < in_force {
                    KeysError::Stale {
                        held: in_force.get(),
                        offered: sealed.kv.get(),
                    }
                } else {
                    KeysError::Step {
                        held: in_force.get(),
                        offered: sealed.kv.get(),
                    }
                }
                .into());
            }
            _ if sealed.kv > newest => {
                return Err(KeysError::Step {
                    held: newest.get(),
                    offered: sealed.kv.get(),
                }
                .into());
            }
            _ => {}
        }
        let record_id = envelope.to_wire();
        if let Some(held) = self.held_envelope(txn.as_mut(), &record_id).await? {
            check_not_below(held, sealed.kv)?;
        }
        let key = self.personal_key(txn.as_mut(), KeyPurpose::Personal, sealed.kv).await?;
        let opened = open_envelope(&key, &self.origin, Scope::Personal(self.account), envelope, &sealed)?;
        txn.put(Row::KeyEnvelope(KeyEnvelopeRow {
            scope: ScopeName::Personal,
            record_id,
            kv: sealed.kv,
        }))
        .await?;
        txn.commit().await?;
        Ok(OpenedEnvelope {
            secret: opened.secret,
            dest: from_json_value(&opened.dest)?,
            kv: sealed.kv,
        })
    }

    async fn held_envelope(&self, txn: &mut dyn StateTxn, record_id: &str) -> Result<Option<Version>, SyncError> {
        match txn
            .get(&RowKey::KeyEnvelope(ScopeName::Personal, record_id.to_owned()))
            .await?
        {
            Some(Row::KeyEnvelope(row)) => Ok(Some(row.kv)),
            _ => Ok(None),
        }
    }

    pub(crate) async fn seal_history(&self, entry: HistoryId, plaintext: &Value) -> Result<Value, SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let mut txn = self.begin().await?;
        let kv = self.writing_version(txn.as_mut(), KeyPurpose::History).await?;
        let key = self.personal_key(txn.as_mut(), KeyPurpose::History, kv).await?;
        let sealed = seal_history(&key, &self.origin, self.account, entry, kv, &to_json_value(plaintext)?)?;
        sealed_fields(&sealed)
    }

    // History has no order against its key's versions, so an entry under any version up to the newest is taken.
    pub(crate) async fn open_history(&self, entry: HistoryId, fields: &Value) -> Result<Value, SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        self.check_trusted()?;
        let mut txn = self.begin().await?;
        let sealed = parse_fields(fields)?;
        let key = self.personal_key(txn.as_mut(), KeyPurpose::History, sealed.kv).await?;
        let opened = open_history(&key, &self.origin, self.account, entry, &sealed)?;
        from_json_value(opened.expose())
    }
}

fn to_json_value(value: &Value) -> Result<JsonValue, SyncError> {
    let text = serde_json::to_vec(value).map_err(|_| SyncError::Malformed { what: "JSON value" })?;
    Ok(json::parse(&text)?)
}

fn from_json_value(value: &JsonValue) -> Result<Value, SyncError> {
    serde_json::from_str(&value.to_json()).map_err(|_| SyncError::Malformed { what: "JSON value" })
}

fn parse_fields(fields: &Value) -> Result<Sealed, SyncError> {
    let text = serde_json::to_vec(fields).map_err(|_| SyncError::Malformed { what: "sealed fields" })?;
    Ok(parse_sealed(&text)?)
}

fn sealed_fields(sealed: &Sealed) -> Result<Value, SyncError> {
    serde_json::from_str(&sealed_json(sealed)).map_err(|_| SyncError::Malformed { what: "sealed fields" })
}
