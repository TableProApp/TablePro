// The personal and history keys (0056, Keys; Rollback, Per scope key): a new version exactly when the account's `av`
// changes, so the one a device writes under is the one signed under the account's current `av`. Personal envelopes
// and history entries are sealed and opened under them.

use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyBody, KeyObject, VersionBody, WrapBody};
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose, Version, WrapPurpose};
use tablepro_keys::keys::{AccountKeys, ScopeKey};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::scope_key::{KeyRef, Ring, Start, VersionRecord};
use tablepro_keys::wrap::{Recipient, Wrap, Wrapper, scope_key_target};

use super::KeyService;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::state::{KeyVersionRow, KeyVersionState, Row, RowKey, StateTxn};

// One personal or history key version an account change set brings.
pub struct ScopeKeyPlan<'a> {
    pub version: Version,
    pub key: &'a ScopeKey,
    pub start: Start,
    // The version below, sealed in the ring: needed with `start` 0, and with `start` 1 only when the signer holds it.
    pub previous: Option<&'a ScopeKey>,
}

// The personal or history version a device writes under, with its record and that record's digest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CurrentPersonal {
    pub record: VersionRecord,
    pub digest: [u8; 32],
    pub state: KeyVersionState,
}

impl KeyService {
    // The version record, its ring when it has one, and its wrap to the account's AEK at `av`, signed by the ASK at
    // `av` with `wrapper` as the writing key device.
    pub fn personal_version_objects(
        &self,
        purpose: KeyPurpose,
        plan: &ScopeKeyPlan<'_>,
        av: Version,
        signer: &AccountKeys,
        wrapper: KeyDeviceId,
    ) -> Result<Vec<KeyObject>, SyncError> {
        if purpose == KeyPurpose::Team {
            return Err(SyncError::Malformed {
                what: "a team key in the personal scope",
            });
        }
        if plan.start == Start::Next && plan.previous.is_none() {
            return Err(KeysError::Ring.into());
        }
        let account = self.account;
        let key = KeyRef {
            owner: account.0,
            purpose,
            version: plan.version,
        };
        let record = VersionRecord::sign(&self.origin, key, plan.start, plan.key, account, av, &signer.ask)?;
        let mut objects = vec![KeyObject {
            id: KeyRecordId::Version(key),
            body: KeyBody::Version(VersionBody::of(&record)),
        }];
        if let Some(previous) = plan.previous {
            objects.push(KeyObject {
                id: KeyRecordId::Ring(key),
                body: KeyBody::Ring(Ring::seal(&self.origin, key, plan.key, previous)?),
            });
        }
        let target = scope_key_target(key, account, av);
        let wrap = Wrap::seal_scope_key(
            &self.origin,
            target,
            &signer.aek.public()?,
            plan.key,
            Wrapper {
                account,
                av,
                key_device: wrapper,
            },
            &signer.ask,
        )?;
        objects.push(KeyObject {
            id: KeyRecordId::Wrap(target),
            body: KeyBody::Wrap(WrapBody::of(&wrap)),
        });
        Ok(objects)
    }

    // The version of `purpose` (`personal` or `history`) signed under the account's current `av`. None when the device
    // holds none: before genesis or approval, or after a catch-up it could not verify.
    pub async fn current_personal(
        &self,
        txn: &mut dyn StateTxn,
        purpose: KeyPurpose,
    ) -> Result<Option<CurrentPersonal>, SyncError> {
        let Some(row) = self.personal_row(txn, purpose).await? else {
            return Ok(None);
        };
        let Some(pin) = self.pin(txn, self.account).await? else {
            return Ok(None);
        };
        let Some(record) = self.personal_record(txn, purpose, row.version).await? else {
            return Ok(None);
        };
        let digest = record.digest(&self.origin)?;
        if digest != row.record {
            return Err(KeysError::Conflict.into());
        }
        if record.signer_av != pin.av {
            return Ok(None);
        }
        Ok(Some(CurrentPersonal {
            record,
            digest,
            state: row.state,
        }))
    }

    pub(crate) async fn personal_row(
        &self,
        txn: &mut dyn StateTxn,
        purpose: KeyPurpose,
    ) -> Result<Option<KeyVersionRow>, SyncError> {
        match txn.get(&RowKey::KeyVersion(ScopeName::Personal, purpose)).await? {
            Some(Row::KeyVersion(row)) => Ok(Some(row)),
            _ => Ok(None),
        }
    }

    // The version record the personal scope holds at `version`, unverified.
    pub(crate) async fn personal_record(
        &self,
        txn: &mut dyn StateTxn,
        purpose: KeyPurpose,
        version: Version,
    ) -> Result<Option<VersionRecord>, SyncError> {
        let key = KeyRef {
            owner: self.account.0,
            purpose,
            version,
        };
        let held = self
            .held_object(
                txn,
                ScopeName::Personal,
                KeyKind::Version,
                &KeyRecordId::Version(key).to_wire(),
            )
            .await?;
        Ok(held.and_then(|held| held.object.version_record()))
    }

    // A personal or history version record checked under the own account's certificate at the `av` it names. None
    // while that certificate has not arrived.
    pub(crate) async fn verified_personal_record(
        &self,
        txn: &mut dyn StateTxn,
        record: &VersionRecord,
    ) -> Result<Option<VersionRecord>, SyncError> {
        if record.signer != self.account || record.key.owner != self.account.0 {
            return Err(KeysError::Signature.into());
        }
        let Some(certificate) = self
            .certificate_at(txn, ScopeName::Personal, self.account, record.signer_av)
            .await?
        else {
            return Ok(None);
        };
        record.verify(&self.origin, &certificate.ask)?;
        Ok(Some(record.clone()))
    }

    // The key at one version, through its wrap to AEK or by walking the rings down from a version the device opened,
    // each checked against its record's `kid`.
    pub async fn personal_key(
        &self,
        txn: &mut dyn StateTxn,
        purpose: KeyPurpose,
        version: Version,
    ) -> Result<ScopeKey, SyncError> {
        let newest = self
            .personal_row(txn, purpose)
            .await?
            .map(|row| row.version)
            .ok_or(SyncError::NotAllowed {
                what: "read a personal key this device does not hold",
            })?;
        if version > newest {
            return Err(KeysError::Step {
                held: newest.get(),
                offered: version.get(),
            }
            .into());
        }
        let mut above = version;
        let mut failed = None;
        // A wrap a server planted fails to open and must not hide a version above whose ring reaches this one.
        let mut key = loop {
            match self.open_personal_wrap(txn, purpose, above).await {
                Ok(Some(key)) => break key,
                Ok(None) => {}
                Err(SyncError::Keys(error)) => failed = Some(error),
                Err(other) => return Err(other),
            }
            if above == newest {
                return Err(failed.map_or(
                    SyncError::NotAllowed {
                        what: "read a personal key this device holds no wrap of",
                    },
                    SyncError::Keys,
                ));
            }
            above = above.next()?;
        };
        while above > version {
            let below = above.previous().ok_or(KeysError::Ring)?;
            let ring_key = KeyRef {
                owner: self.account.0,
                purpose,
                version: above,
            };
            let ring = self
                .held_object(
                    txn,
                    ScopeName::Personal,
                    KeyKind::Ring,
                    &KeyRecordId::Ring(ring_key).to_wire(),
                )
                .await?
                .and_then(|held| match held.object.body {
                    KeyBody::Ring(ring) => Some(ring),
                    _ => None,
                })
                .ok_or(SyncError::NotAllowed {
                    what: "read a personal key whose ring this device does not hold",
                })?;
            let record = self.verified_record_at(txn, purpose, below).await?;
            key = ring.open(&self.origin, ring_key, &key, &record)?;
            above = below;
        }
        Ok(key)
    }

    async fn verified_record_at(
        &self,
        txn: &mut dyn StateTxn,
        purpose: KeyPurpose,
        version: Version,
    ) -> Result<VersionRecord, SyncError> {
        let not_held = SyncError::NotAllowed {
            what: "read a personal key whose version record this device does not hold",
        };
        let record = self
            .personal_record(txn, purpose, version)
            .await?
            .ok_or(not_held.clone())?;
        self.verified_personal_record(txn, &record).await?.ok_or(not_held)
    }

    // A wrap of `version` to the own account at an `av` whose AEK this device holds, signed by the own account.
    async fn open_personal_wrap(
        &self,
        txn: &mut dyn StateTxn,
        purpose: KeyPurpose,
        version: Version,
    ) -> Result<Option<ScopeKey>, SyncError> {
        let wraps: Vec<Wrap> = self
            .held_objects(txn, ScopeName::Personal, KeyKind::Wrap)
            .await?
            .iter()
            .filter(|held| held.applied)
            .filter_map(|held| held.object.wrap())
            .filter(|wrap| {
                wrap.target.owner == self.account.0
                    && wrap.target.purpose == WrapPurpose::Key(purpose)
                    && wrap.target.version == version
                    && wrap.target.recipient == Recipient::Account(self.account)
                    && wrap.wrapper.account == self.account
            })
            .collect();
        if wraps.is_empty() {
            return Ok(None);
        }
        let record = self.verified_record_at(txn, purpose, version).await?;
        let mut failed = None;
        for wrap in wraps {
            let recipient_av = wrap.target.recipient_version;
            let Some(keys) = self.account_keys(recipient_av).await? else {
                continue;
            };
            let Some(recipient) = self
                .certificate_at(txn, ScopeName::Personal, self.account, recipient_av)
                .await?
            else {
                continue;
            };
            let Some(wrapper) = self
                .certificate_at(txn, ScopeName::Personal, self.account, wrap.wrapper.av)
                .await?
            else {
                continue;
            };
            // A wrap planted beside the one this device can open must not hide it.
            match wrap.open_scope_key(&self.origin, &keys.aek, &recipient.aek, &wrapper.ask, &record) {
                Ok(key) => return Ok(Some(key)),
                Err(error) => failed = Some(error),
            }
        }
        match failed {
            Some(error) => Err(error.into()),
            None => Ok(None),
        }
    }
}
