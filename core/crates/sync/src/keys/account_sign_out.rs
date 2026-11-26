// Sign Out (0056, Account flows; 0051, Sign Out): the revoke for this row when online, under each DSK the row may
// hold, the one in force and the one an approval in flight brings, and under the DSK of a reset it proposed, so the
// row holds no key device and that reset ends. Then every key item and the key tables go. Nothing rotates (D7). What
// it erases is written down first, so a Sign Out cut off finishes at the next call.

use std::collections::BTreeSet;
use std::sync::Arc;

use tablepro_keys::body::KeyBody;
use tablepro_keys::encoding::{ResetId, Version};
use tablepro_keys::keys::Ed25519Seed;
use tablepro_keys::record_id::{KeyKind, KeyRecordId};

use super::KeyService;
use super::account::SigningOut;
use crate::api::device_store::DeviceStoreError;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::SignOutOutcome;
use crate::api::state::{PendingFlow, Row, RowRange, ScopeRow, Table};
use crate::api::transport::{DpopKey, TransportError};

impl KeyService {
    pub(crate) async fn erase_on_sign_out(&self) -> Result<SignOutOutcome, SyncError> {
        let _serial = self.serialized().await;
        // A device with no store holds no keys, so there is nothing to revoke or erase. One whose store is only away
        // this session still holds them there, and is not told it signed out.
        if let Err(SyncError::DeviceStore(DeviceStoreError::Unavailable { detail })) = self.signing_out().await {
            if self.holds_key_state().await? {
                return Err(DeviceStoreError::Unavailable { detail }.into());
            }
            return Ok(SignOutOutcome::Revoked);
        }
        let signing_out = match self.signing_out().await? {
            Some(signing_out) => signing_out,
            None => {
                let signing_out = self.what_sign_out_erases().await?;
                self.start_signing_out(&signing_out).await?;
                signing_out
            }
        };
        self.finish_signing_out(&signing_out).await
    }

    // A Sign Out a crash cut off finishes before anything else reads the device's keys.
    pub(crate) async fn finish_cut_off_sign_out(&self) -> Result<(), SyncError> {
        match self.signing_out().await {
            Ok(Some(signing_out)) => {
                self.finish_signing_out(&signing_out).await?;
            }
            Ok(None) | Err(SyncError::DeviceStore(DeviceStoreError::Unavailable { .. })) => {}
            Err(error) => return Err(error),
        }
        Ok(())
    }

    async fn what_sign_out_erases(&self) -> Result<SigningOut, SyncError> {
        let keys = self.device_keys().await?;
        let mut txn = self.begin().await?;
        let resets: Vec<ResetId> = txn
            .scan(&RowRange::Table(Table::KeyPending))
            .await?
            .iter()
            .filter_map(|row| match row {
                Row::KeyPending(pending) => match pending.flow {
                    PendingFlow::ResetProposal { reset } => Some(reset),
                    _ => None,
                },
                _ => None,
            })
            .collect();
        Ok(SigningOut { keys, resets })
    }

    // The `av`s whose account keys this device may hold: 1, its own pin's, each own candidate, and the one after each,
    // since a rotation stores its new keys before it holds its candidate. An applied certificate counts up to the `av`
    // after the newest of those, as the one a recovery opened before its own rotation, and above it only under the own
    // pin, which the server cannot sign. The key tables go only after the erasing, so a Sign Out cut off reads the
    // same ones again. Erasing an item that is not there succeeds, so no `av` is ever counted up to.
    async fn account_key_avs(&self) -> Result<BTreeSet<Version>, SyncError> {
        let mut txn = self.begin().await?;
        let mut named = BTreeSet::from([Version::FIRST]);
        if let Some(pin) = self.pin(txn.as_mut(), self.account()).await? {
            named.insert(pin.av);
        }
        let mut applied = Vec::new();
        for held in self
            .held_objects(txn.as_mut(), ScopeName::Personal, KeyKind::Account)
            .await?
        {
            let (KeyRecordId::Account { account, av }, KeyBody::Account(body)) = (held.object.id, &held.object.body)
            else {
                continue;
            };
            if account != self.account() {
                continue;
            }
            if held.applied {
                applied.push(body.certificate(account, av));
            } else {
                named.insert(av);
            }
        }
        let reach = named.last().and_then(|newest| newest.next().ok());
        for certificate in applied {
            let within = reach.is_some_and(|reach| certificate.av <= reach);
            if within
                || self
                    .verify_certificate(txn.as_mut(), ScopeName::Personal, &certificate)
                    .await
                    .is_ok()
            {
                named.insert(certificate.av);
            }
        }
        let after: Vec<Version> = named.iter().filter_map(|av| av.next().ok()).collect();
        named.extend(after);
        Ok(named)
    }

    async fn finish_signing_out(&self, signing_out: &SigningOut) -> Result<SignOutOutcome, SyncError> {
        let mut proofs: Vec<Ed25519Seed> = Vec::new();
        let mut held = [&signing_out.keys.current, &signing_out.keys.pending]
            .into_iter()
            .flatten()
            .map(|device| device.dsk.clone())
            .collect::<Vec<_>>();
        for reset in &signing_out.resets {
            if let Some(keys) = self.load_reset_keys(*reset).await? {
                held.push(keys.device.dsk.clone());
            }
        }
        for dsk in held {
            let public = dsk.public()?;
            let mut sent = false;
            for proof in &proofs {
                sent |= proof.public()? == public;
            }
            if !sent {
                proofs.push(dsk);
            }
        }
        let mut outcome = SignOutOutcome::Revoked;
        for dsk in proofs {
            match self.transport().revoke_key_device(DpopKey(Arc::new(dsk))).await {
                Ok(()) | Err(TransportError::DeviceRemoved) => {}
                Err(_) => {
                    outcome = SignOutOutcome::ErasedOffline;
                    break;
                }
            }
        }

        for av in self.account_key_avs().await? {
            self.erase_account_keys(av).await?;
        }
        for reset in &signing_out.resets {
            self.erase_reset_keys(*reset).await?;
        }
        self.clear_key_state().await?;
        // Last, since it holds the record of what this Sign Out erases.
        self.erase_device_keys().await?;
        Ok(outcome)
    }

    async fn holds_key_state(&self) -> Result<bool, SyncError> {
        let mut txn = self.begin().await?;
        for table in Table::KEY {
            if !txn.scan(&RowRange::Table(table)).await?.is_empty() {
                return Ok(true);
            }
        }
        Ok(false)
    }

    async fn clear_key_state(&self) -> Result<(), SyncError> {
        let mut txn = self.begin().await?;
        txn.clear_key_tables().await?;
        // The device joins again as a new one does, so the next pull of every scope, a team's included, starts from
        // a snapshot that serves the key objects the tables no longer hold.
        for row in txn.scan(&RowRange::Table(Table::Scopes)).await? {
            if let Row::Scope(row) = row {
                txn.put(Row::Scope(ScopeRow {
                    cursor: None,
                    key_version: None,
                    caught_up: false,
                    ..row
                }))
                .await?;
            }
        }
        txn.commit().await?;
        self.drafts().clear();
        self.clear_notices();
        Ok(())
    }
}
