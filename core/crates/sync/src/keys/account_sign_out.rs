// Sign Out (0056, Account flows; 0051, Sign Out): the revoke for this row when online, under each DSK the row may
// hold, the one in force and the one an approval in flight brings, and under the DSK of a reset it proposed, so the
// row holds no key device and that reset ends. Then every key item and the key tables go. Nothing rotates (D7). What
// it erases is written down first, so a Sign Out cut off finishes at the next call.

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
use crate::api::state::{PendingFlow, Row, RowKey, RowRange, ScopeRow, Table};
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
        let pinned = self.pin(txn.as_mut(), self.account()).await?.map(|pin| pin.av);
        // Only this device's own candidates and certificates that verify under its pin: an `av` the server alone made up
        // sets no bound.
        let mut certified = None;
        for held in self
            .held_objects(txn.as_mut(), ScopeName::Personal, KeyKind::Account)
            .await?
        {
            let (KeyRecordId::Account { av, .. }, KeyBody::Account(body)) = (&held.object.id, &held.object.body) else {
                continue;
            };
            let trusted = !held.applied
                || self
                    .verify_certificate(
                        txn.as_mut(),
                        ScopeName::Personal,
                        &body.certificate(self.account(), *av),
                    )
                    .await
                    .is_ok();
            if trusted {
                certified = certified.max(Some(*av));
            }
        }
        // One past the newest: a rotation stores its new keys before its push, and may have stopped there.
        let newest_av = pinned.max(certified).map_or(0, Version::get).saturating_add(1);
        Ok(SigningOut {
            keys,
            newest_av,
            resets,
        })
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

        for av in 1..=signing_out.newest_av {
            let Ok(av) = Version::new(av) else {
                break;
            };
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
        // The device joins again as a new one does, so its next pull of the key kinds starts from a snapshot.
        for scope in [ScopeName::Personal, ScopeName::History] {
            if let Some(Row::Scope(row)) = txn.get(&RowKey::Scope(scope)).await? {
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
