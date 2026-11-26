// Fingerprints, the QR comparison and key-change alerts (0056, Pins): an alert stays open until the person compares
// or accepts on this device, bound to the IK they were shown.

use tablepro_keys::body::KeyBody;
use tablepro_keys::cert::AccountCertificate;
use tablepro_keys::encoding::AccountId;
use tablepro_keys::fingerprint::{fingerprint, parse_qr};
use tablepro_keys::keys::Ed25519Public;
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::trust::{PinHow, Replaced};

use super::KeyService;
use super::pins::seen_replaced;
use crate::api::error::SyncError;
use crate::api::key_flows::{Acceptance, Fingerprint, KeyChange, KeyNoticeKind};
use crate::api::state::{KeyPinRow, Row, RowRange, StateTxn, Table};

impl KeyService {
    pub(crate) async fn fingerprint_of_account(&self, account: AccountId) -> Result<Fingerprint, SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let mut txn = self.begin().await?;
        let pin = self
            .pin(txn.as_mut(), account)
            .await?
            .ok_or(SyncError::Unknown { what: "pin" })?;
        self.fingerprint_of(account, &pin.ik)
    }

    // A scanned `TPF1:` code against the pinned IK. A match is a comparison, unless an alert is open: that waits for
    // the person to compare the IK offered instead.
    pub(crate) async fn compare_scanned(&self, account: AccountId, text: &str) -> Result<bool, SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let mut txn = self.begin().await?;
        let pin = self
            .pin(txn.as_mut(), account)
            .await?
            .ok_or(SyncError::Unknown { what: "pin" })?;
        let scanned = parse_qr(text)?;
        let matches = scanned == fingerprint(self.origin(), account, &pin.ik)?;
        if matches && !pin.alert && pin.how != PinHow::Compared {
            txn.put(Row::KeyPin(KeyPinRow {
                how: PinHow::Compared,
                ..pin
            }))
            .await?;
            txn.commit().await?;
        }
        Ok(matches)
    }

    pub(crate) async fn open_key_change(
        &self,
        txn: &mut dyn StateTxn,
        account: AccountId,
    ) -> Result<Option<KeyChange>, SyncError> {
        let Some(pin) = self.pin(txn, account).await? else {
            return Ok(None);
        };
        if !pin.alert {
            return Ok(None);
        }
        let Some(offered) = self.offered_certificate(txn, &pin).await? else {
            return Ok(None);
        };
        Ok(Some(KeyChange {
            account,
            pinned: self.fingerprint_of(account, &pin.ik)?,
            offered: self.fingerprint_of(account, &offered.ik)?,
            offered_ik: offered.ik,
        }))
    }

    // Re-confirming after an alert. Accepting without comparing is recorded as `first_use`. The IK it replaces joins the
    // replaced list, so the server cannot offer it as the newest again, and objects signed under it still verify.
    pub(crate) async fn reconfirm(
        &self,
        account: AccountId,
        offered: Ed25519Public,
        how: Acceptance,
    ) -> Result<(), SyncError> {
        if account == self.account() {
            return Err(SyncError::NotAllowed {
                what: "accept a new identity of this device's own account; another device approves it",
            });
        }
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let mut txn = self.begin().await?;
        let pin = self
            .pin(txn.as_mut(), account)
            .await?
            .filter(|pin| pin.alert)
            .ok_or(SyncError::Unknown { what: "key change" })?;
        let certificate = self
            .offered_certificate(txn.as_mut(), &pin)
            .await?
            .filter(|certificate| certificate.ik == offered)
            .ok_or(SyncError::Unknown { what: "key change" })?;
        let mut replaced = pin.replaced;
        if !seen_replaced(&replaced, &pin.ik) {
            replaced.push(Replaced {
                ik: pin.ik,
                av: certificate.av,
            });
        }
        txn.put(Row::KeyPin(KeyPinRow {
            account,
            ik: certificate.ik,
            av: certificate.av,
            how: match how {
                Acceptance::Compared => PinHow::Compared,
                Acceptance::WithoutComparing => PinHow::FirstUse,
            },
            alert: false,
            replaced,
        }))
        .await?;
        txn.commit().await?;
        for notice in self.held_notices() {
            if notice.kind == (KeyNoticeKind::KeysChanged { account }) {
                self.dismiss(notice.id);
            }
        }
        Ok(())
    }

    // The newest certificate any scope holds for an account under an IK other than its pin's: what an alert offers.
    async fn offered_certificate(
        &self,
        txn: &mut dyn StateTxn,
        pin: &KeyPinRow,
    ) -> Result<Option<AccountCertificate>, SyncError> {
        let prefix = format!("{}/", pin.account.to_wire());
        let mut newest: Option<AccountCertificate> = None;
        for row in txn.scan(&RowRange::Table(Table::KeyObjects)).await? {
            let Row::KeyObject(row) = row else {
                continue;
            };
            if !matches!(row.kind.as_str(), "key.account" | "key.member") || !row.record_id.starts_with(&prefix) {
                continue;
            }
            let Ok(object) =
                tablepro_keys::body::KeyObject::parse(row.kind.as_str(), &row.record_id, row.fields.as_bytes())
            else {
                continue;
            };
            let certificate = match (&object.id, &object.body) {
                (
                    KeyRecordId::Account { av, .. } | KeyRecordId::Member { av, .. },
                    KeyBody::Account(body) | KeyBody::Member(body),
                ) => body.certificate(pin.account, *av),
                _ => continue,
            };
            let offered = certificate.av > pin.av
                && certificate.ik != pin.ik
                && !seen_replaced(&pin.replaced, &certificate.ik)
                && certificate.verify(self.origin()).is_ok();
            if offered && newest.as_ref().is_none_or(|held| held.av < certificate.av) {
                newest = Some(certificate);
            }
        }
        Ok(newest)
    }
}
