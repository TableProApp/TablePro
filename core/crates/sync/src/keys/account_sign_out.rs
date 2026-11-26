// Sign Out (0056, Account flows; 0051, Sign Out): the revoke for this row when online, under this device's DSK and
// under the DSK of a reset it proposed, so the row holds no key device and that reset ends. Then the key tables and
// every key item go. Nothing rotates (D7).

use std::sync::Arc;

use tablepro_keys::body::KeyBody;
use tablepro_keys::encoding::{ResetId, Version};
use tablepro_keys::keys::Ed25519Seed;
use tablepro_keys::record_id::{KeyKind, KeyRecordId};

use super::KeyService;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::SignOutOutcome;
use crate::api::state::{PendingFlow, Row, RowKey, RowRange, ScopeRow, Table};
use crate::api::transport::{DpopKey, TransportError};

impl KeyService {
    pub(crate) async fn erase_on_sign_out(&self) -> Result<SignOutOutcome, SyncError> {
        let _serial = self.serialized().await;
        let held = self.device_keys().await?;
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
        let certified = self
            .held_objects(txn.as_mut(), ScopeName::Personal, KeyKind::Account)
            .await?
            .iter()
            .filter_map(|held| match (&held.object.id, &held.object.body) {
                (KeyRecordId::Account { av, .. }, KeyBody::Account(_)) => Some(*av),
                _ => None,
            })
            .max();
        drop(txn);

        let mut proofs: Vec<Ed25519Seed> = held.current.iter().map(|device| device.dsk.clone()).collect();
        for reset in &resets {
            if let Some(keys) = self.reset_keys(*reset).await? {
                let public = keys.device.dsk.public()?;
                let mut sent = false;
                for proof in &proofs {
                    sent |= proof.public()? == public;
                }
                if !sent {
                    proofs.push(keys.device.dsk.clone());
                }
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

        // The secrets go first: a crash before the tables clear leaves a device with no keys to use, never keys
        // with no record of them.
        self.erase_device_keys().await?;
        // One past the newest: a rotation stores its new keys before its push, and may have stopped there.
        let newest = pinned.max(certified).map_or(0, Version::get).saturating_add(1);
        for av in 1..=newest {
            let Ok(av) = Version::new(av) else {
                break;
            };
            self.erase_account_keys(av).await?;
        }
        for reset in resets {
            self.erase_reset_keys(reset).await?;
        }
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
        Ok(outcome)
    }
}
