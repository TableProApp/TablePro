// Changing the personal provider (core ADR 0054, Moving between providers; 0055): the core side of each change, after
// which the app keeps the new provider and opens sync again with it.

use std::future::Future;
use std::sync::Arc;

use tablepro_account::SyncProvider;
use tablepro_sync::SyncError;
use tablepro_sync::moves::{MoveParts, Mover};
use tablepro_sync::service::ServiceMode;

use super::service::{MoveBackPlanInfo, MovePlanInfo, SyncPlatformTag, SyncService};
use crate::account::SyncProviderTag;
use crate::error::CoreError;
use crate::runtime::on_runtime;

impl SyncService {
    // A move runs over TablePro Sync's engine, the iCloud engine while iCloud is the provider, and CloudKit and the
    // state files for the move back and the zone.
    async fn on_mover<T, F>(&self, work: impl FnOnce(Mover) -> F + Send + 'static) -> Result<T, CoreError>
    where
        T: Send + 'static,
        F: Future<Output = Result<T, SyncError>> + Send + 'static,
    {
        let slot = Arc::clone(&self.service);
        let icloud = self.icloud.as_ref().ok().map(|engine| Arc::clone(&engine.sync));
        let (cloudkit, files, icloud_account) = (self.cloudkit.clone(), self.files.clone(), self.icloud_account());
        on_runtime(&self.tasks, async move {
            let engine = slot.engine().await?;
            let files = files.ok_or(SyncError::NotAllowed {
                what: "move between providers on a Core opened without storage",
            })?;
            let mover = Mover::new(MoveParts {
                service: Arc::clone(&engine.sync),
                icloud,
                cloudkit,
                files,
                icloud_account,
            });
            work(mover).await.map_err(CoreError::from)
        })
        .await
    }

    // What the managed policy leaves this platform (0055); with no account there is no policy to hold it to.
    fn allows(&self, provider: SyncProviderTag) -> bool {
        let Some(account) = &self.account else {
            return true;
        };
        let offered: &[SyncProvider] = match self.config.platform {
            SyncPlatformTag::Macos | SyncPlatformTag::Ios => {
                &[SyncProvider::Off, SyncProvider::ICloud, SyncProvider::TableProSync]
            }
            SyncPlatformTag::Linux | SyncPlatformTag::Windows => &[SyncProvider::Off, SyncProvider::TableProSync],
        };
        account.account.policy().sync_choices(offered).contains(provider.into())
    }
}

#[uniffi::export]
impl SyncService {
    // The core side of moving personal data to `provider`, among what the managed policy allows: the forward move from
    // iCloud, the first upload from Off, or personal sync stopping. The move back to iCloud needs the count the person
    // confirmed, so it goes through `move_to_icloud`. The app then keeps the provider and opens sync again with it.
    pub async fn choose_provider(&self, provider: SyncProviderTag) -> Result<(), CoreError> {
        if !self.allows(provider) {
            return Err(SyncError::NotAllowed {
                what: "choose a provider the managed policy does not allow",
            }
            .into());
        }
        match (self.config.provider, provider) {
            (SyncProviderTag::Icloud, SyncProviderTag::TableproSync) => self.move_to_service().await,
            (SyncProviderTag::Off, SyncProviderTag::TableproSync) => self.first_upload().await,
            (SyncProviderTag::TableproSync, SyncProviderTag::Icloud) => Err(SyncError::NotAllowed {
                what: "move back to iCloud without the count of iCloud deletions the person confirmed",
            }
            .into()),
            (SyncProviderTag::Icloud, SyncProviderTag::Off) => {
                if let Ok(engine) = &self.icloud {
                    engine.stop();
                }
                Ok(())
            }
            (SyncProviderTag::TableproSync, SyncProviderTag::Off) => {
                let slot = Arc::clone(&self.service);
                on_runtime(&self.tasks, async move {
                    if let Ok(engine) = slot.engine().await {
                        engine.sync.set_mode(ServiceMode::TeamsOnly).await;
                    }
                    Ok(())
                })
                .await
            }
            // iCloud's first pass after the app opens sync again is the whole of it; the provider it has needs nothing.
            (SyncProviderTag::Off, SyncProviderTag::Icloud)
            | (SyncProviderTag::Off, SyncProviderTag::Off)
            | (SyncProviderTag::Icloud, SyncProviderTag::Icloud)
            | (SyncProviderTag::TableproSync, SyncProviderTag::TableproSync) => Ok(()),
        }
    }

    pub async fn plan_move_to_service(&self) -> Result<MovePlanInfo, CoreError> {
        self.on_mover(move |mover| async move { mover.plan_move_to_service().await.map(MovePlanInfo::from) })
            .await
    }

    // From iCloud: a last iCloud pass, iCloud stops, and each record meets the service's copy (0054).
    pub async fn move_to_service(&self) -> Result<(), CoreError> {
        self.on_mover(move |mover| async move { mover.move_to_service().await })
            .await
    }

    // From Off: what this device holds goes up under the normal merge, the server's copy winning a conflict.
    pub async fn first_upload(&self) -> Result<(), CoreError> {
        self.on_mover(move |mover| async move { mover.first_upload().await })
            .await
    }

    pub async fn plan_move_to_icloud(&self) -> Result<MoveBackPlanInfo, CoreError> {
        self.on_mover(move |mover| async move { mover.plan_move_to_icloud().await.map(MoveBackPlanInfo::from) })
            .await
    }

    // Refused unless the count is the plan's, which the person confirmed.
    pub async fn move_to_icloud(&self, confirmed_deletions: u64) -> Result<(), CoreError> {
        self.on_mover(move |mover| async move { mover.move_to_icloud(confirmed_deletions).await })
            .await
    }

    // The zone a move left, with this device's iCloud state file, once the person asks.
    pub async fn delete_icloud_zone(&self) -> Result<(), CoreError> {
        self.on_mover(move |mover| async move { mover.delete_icloud_zone().await })
            .await
    }
}
