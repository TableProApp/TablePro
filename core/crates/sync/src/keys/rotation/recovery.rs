// Recovery with R (0056, Account flows, Recovery): a device with no approved device at hand reads the newest
// certificate and blob, which any signed-in device may read, derives IK, checks the certificate, opens the blob and
// checks its keys, then reads the personal and history keys in force so the rotation carries them into its rings.

use tablepro_keys::KeysError;
use tablepro_keys::body::KeyBody;
use tablepro_keys::cert::AccountCertificate;
use tablepro_keys::encoding::{KeyPurpose, Version, WrapPurpose};
use tablepro_keys::keys::{AccountKeys, Ed25519Public};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::scope_key::VersionRecord;
use tablepro_keys::wrap::{Recipient, Wrap};

use super::plan::CurrentKey;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::state::StateTxn;
use crate::keys::KeyService;
use crate::keys::pins::seen_replaced;

pub(crate) struct Recovered {
    pub certificate: AccountCertificate,
    pub keys: AccountKeys,
    pub current: Vec<CurrentKey>,
}

impl KeyService {
    async fn certificate_under(
        &self,
        txn: &mut dyn StateTxn,
        av: Version,
        ik: &Ed25519Public,
    ) -> Result<Option<AccountCertificate>, SyncError> {
        let id = KeyRecordId::Account {
            account: self.account(),
            av,
        };
        let Some(held) = self
            .held_object(txn, ScopeName::Personal, KeyKind::Account, &id.to_wire())
            .await?
        else {
            return Ok(None);
        };
        let KeyBody::Account(body) = &held.object.body else {
            return Ok(None);
        };
        let certificate = body.certificate(self.account(), av);
        certificate.verify(self.origin())?;
        if certificate.ik != *ik {
            return Err(KeysError::Signature.into());
        }
        Ok(Some(certificate))
    }

    // R against the newest certificate: its IK must be the one R gives, and the blob at that `av` must open to the
    // keys it names. A server can withhold or serve an older version, never forge one.
    pub(crate) async fn read_with_recovery_key(
        &self,
        txn: &mut dyn StateTxn,
        recovery: &RecoveryKey,
    ) -> Result<Recovered, SyncError> {
        let newest = self.newest_own_certificate(txn).await?;
        let ik = recovery.identity_seed(self.origin(), self.account())?.public()?;
        if newest.ik != ik {
            return Err(KeysError::Signature.into());
        }
        let blob_id = KeyRecordId::Recovery {
            account: self.account(),
            av: newest.av,
        };
        let blob = match self
            .held_object(txn, ScopeName::Personal, KeyKind::Recovery, &blob_id.to_wire())
            .await?
            .map(|held| held.object.body)
        {
            Some(KeyBody::Recovery(blob)) => blob,
            _ => {
                return Err(SyncError::Unknown {
                    what: "the recovery blob at the newest av",
                });
            }
        };
        let keys = recovery.open_blob(self.origin(), self.account(), newest.av, &blob)?;
        keys.check_against(&newest.ask, &newest.aek)?;
        let mut current = Vec::new();
        for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
            current.push(self.key_in_force(txn, &newest, &keys, purpose).await?);
        }
        Ok(Recovered {
            certificate: newest,
            keys,
            current,
        })
    }

    // The version signed under the certificate's `av`, through its wrap to that AEK, checked against its `kid`.
    async fn key_in_force(
        &self,
        txn: &mut dyn StateTxn,
        certificate: &AccountCertificate,
        keys: &AccountKeys,
        purpose: KeyPurpose,
    ) -> Result<CurrentKey, SyncError> {
        let account = self.account();
        let mut record: Option<VersionRecord> = None;
        for held in self.held_objects(txn, ScopeName::Personal, KeyKind::Version).await? {
            let Some(candidate) = held.object.version_record() else {
                continue;
            };
            let in_force = held.applied
                && candidate.key.owner == account.0
                && candidate.key.purpose == purpose
                && candidate.signer == account
                && candidate.signer_av == certificate.av;
            if in_force
                && record
                    .as_ref()
                    .is_none_or(|record| record.key.version < candidate.key.version)
            {
                candidate.verify(self.origin(), &certificate.ask)?;
                record = Some(candidate);
            }
        }
        let record = record.ok_or(SyncError::Unknown {
            what: "the personal or history version signed under the newest av",
        })?;
        let wrap = self
            .held_objects(txn, ScopeName::Personal, KeyKind::Wrap)
            .await?
            .into_iter()
            .filter_map(|held| held.object.wrap())
            .find(|wrap: &Wrap| {
                wrap.target.owner == account.0
                    && wrap.target.purpose == WrapPurpose::Key(purpose)
                    && wrap.target.version == record.key.version
                    && wrap.target.recipient == Recipient::Account(account)
                    && wrap.target.recipient_version == certificate.av
            })
            .ok_or(SyncError::Unknown {
                what: "the wrap of the key in force to the newest AEK",
            })?;
        let wrapper = if wrap.wrapper.av == certificate.av {
            certificate.clone()
        } else {
            self.certificate_under(txn, wrap.wrapper.av, &certificate.ik)
                .await?
                .ok_or(SyncError::Unknown {
                    what: "the wrapper's certificate",
                })?
        };
        let key = wrap.open_scope_key(self.origin(), &keys.aek, &certificate.aek, &wrapper.ask, &record)?;
        Ok(CurrentKey {
            purpose,
            version: record.key.version,
            key,
        })
    }

    // The highest certificate the device holds for its own account that verifies under its own IK. A pinned newer
    // `av`, or an IK the pin saw replaced, is refused, so a server cannot show a device an older account than it knows.
    pub(crate) async fn newest_own_certificate(&self, txn: &mut dyn StateTxn) -> Result<AccountCertificate, SyncError> {
        let account = self.account();
        let mut newest: Option<AccountCertificate> = None;
        for held in self.held_objects(txn, ScopeName::Personal, KeyKind::Account).await? {
            let (KeyRecordId::Account { account: owner, av }, KeyBody::Account(body)) =
                (&held.object.id, &held.object.body)
            else {
                continue;
            };
            if *owner != account || !held.applied {
                continue;
            }
            let certificate = body.certificate(account, *av);
            if certificate.verify(self.origin()).is_ok() && newest.as_ref().is_none_or(|newest| newest.av < *av) {
                newest = Some(certificate);
            }
        }
        let newest = newest.ok_or(SyncError::NotAllowed {
            what: "use the account's keys before it has any",
        })?;
        if let Some(pin) = self.pin(txn, account).await? {
            if newest.av < pin.av {
                return Err(KeysError::Stale {
                    held: pin.av.get(),
                    offered: newest.av.get(),
                }
                .into());
            }
            if seen_replaced(&pin.replaced, &newest.ik) {
                return Err(KeysError::RetiredIk.into());
            }
        }
        Ok(newest)
    }
}
