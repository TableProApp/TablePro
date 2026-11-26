// Pins (0056, Pins): per account a device meets, its own included, the IK it pinned, the newest `av` verified under
// it, how it pinned, an open alert and the IKs it saw replaced. Verifying checks an object's certificate against the
// pin and moves nothing; advancing moves the pin forward only (0056, Rollback).

use tablepro_keys::KeysError;
use tablepro_keys::body::KeyBody;
use tablepro_keys::cert::{AccountCertificate, IkChange};
use tablepro_keys::encoding::{AccountId, Version};
use tablepro_keys::fingerprint::{fingerprint, fingerprint_words, qr_text};
use tablepro_keys::keys::Ed25519Public;
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::trust::{PinHow, Replaced, replace_point};

use super::KeyService;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{Fingerprint, KeyNoticeKind};
use crate::api::state::{KeyPinRow, Row, RowKey, StateTxn};

// Where a verified certificate's IK stands against the account's pin.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IkStanding {
    Pinned,
    // An IK the pin saw replaced: its certificates verify the objects signed under them, never as the newest.
    Replaced,
    // A newer IK the pinned one endorsed through a chain of replaces the scope holds, not followed yet.
    Endorsed,
}

// What offering a certificate as an account's newest did to its pin.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PinChange {
    // The first certificate of an account this device meets.
    FirstUse,
    // At or below the pinned `av` under the pinned IK: verified, nothing moves.
    Unchanged,
    // The pinned IK at a higher `av`, followed silently.
    Followed { from: Version },
    // A new IK the pinned one endorsed, followed with a notice.
    Replaced { previous: Ed25519Public },
    // An IK change with no endorsement: an alert opens and the pin stays (`keys.unendorsed` fails nothing else).
    Alert,
}

// Whether a pin's replaced list holds `ik`, which is never current again (0056, Pins, Replace).
pub(crate) fn seen_replaced(replaced: &[Replaced], ik: &Ed25519Public) -> bool {
    replace_point(replaced, ik).is_some()
}

// A walk up an account's certificates from its pin: where the pin can move, and what stopped it.
pub(crate) struct Walk {
    pub(crate) ik: Ed25519Public,
    pub(crate) av: Version,
    pub(crate) replaced: Vec<Replaced>,
    pub(crate) endorsed: bool,
    pub(crate) stop: Option<KeysError>,
}

impl KeyService {
    pub async fn pin(&self, txn: &mut dyn StateTxn, account: AccountId) -> Result<Option<KeyPinRow>, SyncError> {
        match txn.get(&RowKey::KeyPin(account)).await? {
            Some(Row::KeyPin(row)) => Ok(Some(row)),
            _ => Ok(None),
        }
    }

    // The certificate `scope` holds for `account` at `av`, unverified: `key.account` in the personal scope, `key.member`
    // in a team.
    pub(crate) async fn held_certificate(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        account: AccountId,
        av: Version,
    ) -> Result<Option<AccountCertificate>, SyncError> {
        let (kind, id) = match scope {
            ScopeName::Team(_) => (KeyKind::Member, KeyRecordId::Member { account, av }),
            ScopeName::Personal | ScopeName::History => (KeyKind::Account, KeyRecordId::Account { account, av }),
        };
        let held = self.applied_object(txn, scope, kind, &id.to_wire()).await?;
        Ok(held.and_then(|object| match object.body {
            KeyBody::Account(body) | KeyBody::Member(body) => Some(body.certificate(account, av)),
            _ => None,
        }))
    }

    // Walks from the pin up to `target`, one `av` at a time through the certificates `scope` holds, `offered` standing
    // in at its own `av`. Each step keeps the IK or follows an endorsement of it; the walk stops at a gap, an IK the pin
    // saw replaced or an unendorsed change, and says which.
    pub(crate) async fn walk(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        pin: &KeyPinRow,
        offered: &AccountCertificate,
    ) -> Result<Walk, SyncError> {
        let mut walk = Walk {
            ik: pin.ik,
            av: pin.av,
            replaced: pin.replaced.clone(),
            endorsed: false,
            stop: None,
        };
        while walk.av < offered.av {
            let next = walk.av.next()?;
            let certificate = if next == offered.av {
                offered.clone()
            } else {
                match self.held_certificate(txn, scope, offered.account, next).await? {
                    Some(certificate) => certificate,
                    None => {
                        walk.stop = Some(KeysError::Step {
                            held: walk.av.get(),
                            offered: offered.av.get(),
                        });
                        break;
                    }
                }
            };
            if certificate.ik != walk.ik && seen_replaced(&walk.replaced, &certificate.ik) {
                walk.stop = Some(KeysError::RetiredIk);
                break;
            }
            match certificate.ik_change(&self.origin, &walk.ik) {
                Ok(IkChange::Same) => {}
                Ok(IkChange::Endorsed) => {
                    walk.replaced.push(Replaced { ik: walk.ik, av: next });
                    walk.ik = certificate.ik;
                    walk.endorsed = true;
                }
                Err(error) => {
                    walk.stop = Some(error);
                    break;
                }
            }
            walk.av = next;
        }
        Ok(walk)
    }

    // Verifying: the certificate's signature, then its IK against the pin, through the replace certificates `scope`
    // holds for the account (`key.account` in the personal scope, `key.member` in a team).
    pub async fn verify_certificate(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        certificate: &AccountCertificate,
    ) -> Result<IkStanding, SyncError> {
        certificate.verify(&self.origin)?;
        let pin = self.pin(txn, certificate.account).await?.ok_or(SyncError::NotAllowed {
            what: "verify a certificate of an account with no pin",
        })?;
        if certificate.ik == pin.ik {
            return Ok(IkStanding::Pinned);
        }
        // An IK seen replaced verifies only certificates below the `av` of the replace certificate that retired it, as
        // the pin keeps it; the certificates a server serves on either side never move that point (0066, Replace
        // points).
        if let Some(point) = replace_point(&pin.replaced, &certificate.ik) {
            return if certificate.av < point {
                Ok(IkStanding::Replaced)
            } else {
                Err(KeysError::RetiredIk.into())
            };
        }
        if certificate.av <= pin.av {
            return Err(KeysError::Signature.into());
        }
        let walk = self.walk(txn, scope, &pin, certificate).await?;
        match walk.stop {
            Some(error) => Err(error.into()),
            None if walk.ik == certificate.ik => Ok(IkStanding::Endorsed),
            None => Err(KeysError::Unendorsed.into()),
        }
    }

    // The certificate at `av` that `scope` holds for `account`, verified as above. None while it has not arrived, so
    // an object naming it is held rather than refused.
    pub async fn certificate_at(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        account: AccountId,
        av: Version,
    ) -> Result<Option<AccountCertificate>, SyncError> {
        let Some(certificate) = self.held_certificate(txn, scope, account, av).await? else {
            return Ok(None);
        };
        self.verify_certificate(txn, scope, &certificate).await?;
        Ok(Some(certificate))
    }

    // Advancing: offers `certificate` as the account's newest and moves its pin as 0056's Pins says, raising the
    // notice or alert. An IK the pin saw replaced is `keys.retired_ik`. The own account only verifies here: it moves
    // through the personal scope, where its keys come with it, never through a team's copy.
    pub async fn offer_certificate(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        certificate: &AccountCertificate,
    ) -> Result<PinChange, SyncError> {
        certificate.verify(&self.origin)?;
        let account = certificate.account;
        if account == self.account {
            self.verify_certificate(txn, scope, certificate).await?;
            return Ok(PinChange::Unchanged);
        }
        let Some(pin) = self.pin(txn, account).await? else {
            txn.put(Row::KeyPin(KeyPinRow {
                account,
                ik: certificate.ik,
                av: certificate.av,
                how: PinHow::FirstUse,
                alert: false,
                replaced: Vec::new(),
            }))
            .await?;
            return Ok(PinChange::FirstUse);
        };
        if certificate.av <= pin.av {
            self.verify_certificate(txn, scope, certificate).await?;
            return Ok(PinChange::Unchanged);
        }
        if certificate.ik != pin.ik && seen_replaced(&pin.replaced, &certificate.ik) {
            return Err(KeysError::RetiredIk.into());
        }
        let walk = self.walk(txn, scope, &pin, certificate).await?;
        match walk.stop {
            // The endorsed replaces before the unendorsed step still count: the pin follows them, then alerts.
            Some(KeysError::Unendorsed) => {
                txn.put(Row::KeyPin(KeyPinRow {
                    account,
                    ik: walk.ik,
                    av: walk.av,
                    how: if walk.endorsed { PinHow::Replaced } else { pin.how },
                    alert: true,
                    replaced: walk.replaced,
                }))
                .await?;
                if walk.endorsed {
                    self.raise_notice(KeyNoticeKind::RecoveryKeyReplaced { account })?;
                }
                if !pin.alert {
                    self.raise_notice(KeyNoticeKind::KeysChanged { account })?;
                }
                Ok(PinChange::Alert)
            }
            Some(error) => Err(error.into()),
            None => {
                let change = if walk.endorsed {
                    PinChange::Replaced { previous: pin.ik }
                } else {
                    PinChange::Followed { from: pin.av }
                };
                let how = if walk.endorsed { PinHow::Replaced } else { pin.how };
                txn.put(Row::KeyPin(KeyPinRow {
                    account,
                    ik: walk.ik,
                    av: walk.av,
                    how,
                    alert: pin.alert,
                    replaced: walk.replaced,
                }))
                .await?;
                if walk.endorsed {
                    self.raise_notice(KeyNoticeKind::RecoveryKeyReplaced { account })?;
                }
                Ok(change)
            }
        }
    }

    // The six words and the `TPF1:` code of an account's IK.
    pub fn fingerprint_of(&self, account: AccountId, ik: &Ed25519Public) -> Result<Fingerprint, SyncError> {
        let digest = fingerprint(&self.origin, account, ik)?;
        Ok(Fingerprint {
            words: fingerprint_words(&digest).into_iter().map(str::to_owned).collect(),
            qr: qr_text(&digest),
        })
    }
}
