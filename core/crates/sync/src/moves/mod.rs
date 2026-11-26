// Moving personal data between providers (0054, Moving between providers): to TablePro Sync from iCloud, back to iCloud,
// the first upload of a device that had none, and deleting the iCloud zone a move left behind. The app keeps the
// provider (0054, The provider key) and switches its engines once a call here returns.

mod arrival;
mod back;

use std::sync::Arc;

pub(crate) use arrival::Arrival;

use crate::api::cloudkit::{CloudKitFailure, CloudKitTransport};
use crate::api::control::{MoveBackPlan, MovePlan};
use crate::api::error::SyncError;
use crate::api::state::{MovePhase, MoveRow, Provider, Row, RowKey, StateFiles, StateIdentity};
use crate::cloudkit::modify::{CloudKitSync, IcloudCopy, copy_rows};
use crate::service::ServiceSync;

pub struct MoveParts {
    pub service: Arc<ServiceSync>,
    // The iCloud engine while iCloud is the personal provider.
    pub icloud: Option<Arc<CloudKitSync>>,
    // CloudKit while iCloud is not the provider, for the move back and the zone.
    pub cloudkit: Option<Arc<dyn CloudKitTransport>>,
    pub files: Arc<dyn StateFiles>,
    // The iCloud account whose state file this device used last (`SyncConfig::icloud_account`).
    pub icloud_account: Option<String>,
    // Whether the managed values allow the provider now (0055); checked right before each commit a move makes, so a
    // revocation between two steps commits nothing more.
    pub allowed: Allowed,
}

pub type Allowed = Arc<dyn Fn(Provider) -> bool + Send + Sync>;

fn fence(allowed: &Allowed, provider: Provider) -> Result<(), SyncError> {
    if allowed(provider) {
        Ok(())
    } else {
        Err(SyncError::NotAllowed {
            what: "a move to a provider the managed policy no longer allows",
        })
    }
}

pub struct Mover {
    parts: MoveParts,
}

fn icloud_file(account: &str) -> StateIdentity {
    StateIdentity::ICloud {
        user_record_name: account.to_owned(),
    }
}

impl Mover {
    pub const fn new(parts: MoveParts) -> Self {
        Self { parts }
    }

    // What the move sheet shows: what goes up, what stays on the device, and the secrets sealed into envelopes.
    pub async fn plan_move_to_service(&self) -> Result<MovePlan, SyncError> {
        self.parts.service.personal_plan().await
    }

    // A last iCloud pass, then iCloud stops for good on this device, and the service's snapshot meets each local record
    // against the copy both providers last shared: the move marker's, else this device's CloudKit base. A record the
    // zone no longer lists since another device moved it is deleted on the service unless its content changed there.
    // A move that stops short (`sync.move_incomplete` or any other error once iCloud stopped) leaves iCloud stopped,
    // since the stores may already hold what the service brought; calling it again goes on from there.
    // One that went through already is done, so calling it again moves nothing twice.
    pub async fn move_to_service(&self) -> Result<(), SyncError> {
        let icloud = self.parts.icloud.as_ref().ok_or(SyncError::NotAllowed {
            what: "move to TablePro Sync while iCloud is not the provider",
        })?;
        if icloud
            .open_move()
            .await?
            .is_some_and(|row| row.phase == MovePhase::Done)
        {
            return Ok(());
        }
        fence(&self.parts.allowed, Provider::Service)?;
        icloud.stop_for_move().await?;
        let copy = icloud.copy_for_move().await?;
        self.parts.service.run_arrival(Arrival::from_icloud(copy)).await?;
        fence(&self.parts.allowed, Provider::Service)?;
        icloud.finish_move().await
    }

    // The forward move while iCloud traffic is forbidden (0055: TablePro Sync forced, `ICloudSyncAllowed` off): iCloud
    // stops at once with no last pass and no zone fetch, and each record meets the service against this device's
    // CloudKit base, so its unsent iCloud edits merge rather than losing to the server. Deletions come only from what
    // those bases record.
    // The engine may never have started, as when the values forbade iCloud at launch: the state file it used last
    // holds the bases then.
    pub async fn move_to_service_without_icloud(&self) -> Result<(), SyncError> {
        if let Some(icloud) = &self.parts.icloud {
            if icloud
                .open_move()
                .await?
                .is_some_and(|row| row.phase == MovePhase::Done)
            {
                return Ok(());
            }
            fence(&self.parts.allowed, Provider::Service)?;
            let copy = icloud.copy_without_icloud().await?;
            self.parts.service.run_arrival(Arrival::from_icloud(copy)).await?;
            fence(&self.parts.allowed, Provider::Service)?;
            return icloud.finish_move().await;
        }
        let account = self.parts.icloud_account.as_ref().ok_or(SyncError::NotAllowed {
            what: "move from an iCloud state file this device never used",
        })?;
        let state = self.parts.files.open(icloud_file(account)).await?;
        let held = match state.begin().await?.get(&RowKey::Move).await? {
            Some(Row::Move(row)) => Some(row.phase),
            _ => None,
        };
        if held == Some(MovePhase::Done) {
            return Ok(());
        }
        let moving = |phase| {
            Row::Move(MoveRow {
                from: Some(Provider::ICloud),
                target: Provider::Service,
                phase,
            })
        };
        if held.is_none() {
            fence(&self.parts.allowed, Provider::Service)?;
            let mut txn = state.begin().await?;
            txn.put(moving(MovePhase::Open)).await?;
            txn.commit().await?;
        }
        let (bases, kept_off) = copy_rows(state.as_ref()).await?;
        let copy = IcloudCopy {
            account: Some(account.clone()),
            bases,
            listed: None,
            kept_off,
        };
        self.parts.service.run_arrival(Arrival::from_icloud(copy)).await?;
        fence(&self.parts.allowed, Provider::Service)?;
        let mut txn = state.begin().await?;
        txn.put(moving(MovePhase::Done)).await?;
        txn.commit().await?;
        Ok(())
    }

    // A device on no provider turning TablePro Sync on (0055, choices): no base to merge against, so the server's copy
    // wins and what it lacks goes up as a create. An iCloud state file left from before goes, since its bases no
    // longer say anything of the device's records.
    pub async fn first_upload(&self) -> Result<(), SyncError> {
        if self.parts.icloud.is_some() {
            return Err(SyncError::NotAllowed {
                what: "first upload while iCloud is the provider",
            });
        }
        fence(&self.parts.allowed, Provider::Service)?;
        if let Some(account) = &self.parts.icloud_account {
            self.parts.files.delete(icloud_file(account)).await?;
        }
        self.parts.service.run_arrival(Arrival::FirstUpload).await.map(|_| ())
    }

    // How many iCloud records the move back deletes, which the person confirms first.
    pub async fn plan_move_to_icloud(&self) -> Result<MoveBackPlan, SyncError> {
        let back = self.move_back().await?;
        Ok(MoveBackPlan {
            icloud_deletions: u64::try_from(back.len()).unwrap_or(u64::MAX),
        })
    }

    // Refused unless `confirmed_deletions` is the count the plan gives now. Personal data then rests on the service, and
    // the app turns iCloud on as it does today.
    // Personal service sync rests from the moment the count is checked, so no pass changes the stores between what the
    // move keeps and what iCloud then reads; the `moves` row keeps it resting after a restart until the move ends.
    pub async fn move_to_icloud(&self, confirmed_deletions: u64) -> Result<(), SyncError> {
        let mut back = self.move_back().await?;
        if u64::try_from(back.len()).unwrap_or(u64::MAX) != confirmed_deletions {
            return Err(SyncError::NotAllowed {
                what: "move back with another count of iCloud deletions than the person confirmed",
            });
        }
        fence(&self.parts.allowed, Provider::ICloud)?;
        self.parts.service.leave_for_icloud().await?;
        self.parts
            .service
            .set_mode(crate::service::ServiceMode::TeamsOnly)
            .await;
        back.held_now(&self.parts.service).await?;
        back.delete(&self.parts.allowed).await?;
        back.keep_the_rest(&self.parts.allowed).await?;
        drop(back);
        fence(&self.parts.allowed, Provider::ICloud)?;
        self.parts.service.left_for_icloud().await
    }

    // The zone a move left stays until the person deletes it, with this device's iCloud state file.
    pub async fn delete_icloud_zone(&self) -> Result<(), SyncError> {
        if self.parts.icloud.is_some() {
            return Err(SyncError::NotAllowed {
                what: "delete the iCloud zone while iCloud is the provider",
            });
        }
        let account = self.parts.icloud_account.as_ref().ok_or(SyncError::NotAllowed {
            what: "delete an iCloud zone this device never used",
        })?;
        let transport = self.transport()?;
        fence(&self.parts.allowed, Provider::ICloud)?;
        match transport.delete_zone(account.clone()).await {
            Ok(()) | Err(CloudKitFailure::ZoneNotFound | CloudKitFailure::ZoneDeletedByUser) => {}
            Err(failure) => return Err(failure.into()),
        }
        fence(&self.parts.allowed, Provider::ICloud)?;
        self.parts.files.delete(icloud_file(account)).await?;
        Ok(())
    }

    fn transport(&self) -> Result<&Arc<dyn CloudKitTransport>, SyncError> {
        self.parts.cloudkit.as_ref().ok_or(SyncError::NotAllowed {
            what: "iCloud without a CloudKit transport",
        })
    }
}
