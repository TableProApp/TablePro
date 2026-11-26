// Changing the personal provider (core ADR 0054, Moving between providers; 0055): the core side of each change, after
// which the app keeps the new provider and opens sync again with it.

use std::future::Future;
use std::sync::Arc;

use tablepro_account::SyncProvider;
use tablepro_sync::SyncError;
use tablepro_sync::api::cloudkit::{
    CloudKitAccount, CloudKitChanges, CloudKitFailure, CloudKitFetched, CloudKitOutcome, CloudKitRecord,
    CloudKitTransport,
};
use tablepro_sync::api::state::{MovePhase, Provider};
use tablepro_sync::moves::{MoveParts, Mover};
use tablepro_sync::service::ServiceMode;

use super::service::{MoveBackPlanInfo, MovePlanInfo, SyncPlatformTag, SyncService};
use crate::account::{AccountService, SyncProviderTag};
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
        let (account, platform) = (self.account.clone(), self.config.platform);
        let allowed: tablepro_sync::moves::Allowed = Arc::new(move |provider| {
            let tag = match provider {
                Provider::Service => SyncProviderTag::TableproSync,
                Provider::ICloud => SyncProviderTag::Icloud,
            };
            allowed(account.as_deref(), platform, tag)
        });
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
                allowed,
            });
            work(mover).await.map_err(CoreError::from)
        })
        .await
    }

    // What the managed policy leaves this platform (0055); with no account there is no policy to hold it to.
    pub(crate) fn allows(&self, provider: SyncProviderTag) -> bool {
        allowed(self.account.as_deref(), self.config.platform, provider)
    }

    // A move never brings personal data to a provider the values forbid.
    fn allows_target(&self, provider: SyncProviderTag) -> Result<(), SyncError> {
        if self.allows(provider) {
            Ok(())
        } else {
            Err(SyncError::NotAllowed {
                what: "move to a provider the managed policy does not allow",
            })
        }
    }
}

pub(crate) fn allowed(account: Option<&AccountService>, platform: SyncPlatformTag, provider: SyncProviderTag) -> bool {
    let Some(account) = account else {
        return true;
    };
    let offered: &[SyncProvider] = match platform {
        SyncPlatformTag::Macos | SyncPlatformTag::Ios => {
            &[SyncProvider::Off, SyncProvider::ICloud, SyncProvider::TableProSync]
        }
        SyncPlatformTag::Linux | SyncPlatformTag::Windows => &[SyncProvider::Off, SyncProvider::TableProSync],
    };
    account.account.policy().sync_choices(offered).contains(provider.into())
}

// CloudKit as the engines and the moves reach it: a call is refused before it goes, and its answer dropped, once the
// values forbid iCloud traffic, so a move or a pass in flight commits nothing of it (0055, When a value applies).
pub(crate) struct PolicyFenced {
    pub(crate) inner: Arc<dyn CloudKitTransport>,
    pub(crate) account: Option<Arc<AccountService>>,
    pub(crate) platform: SyncPlatformTag,
}

impl PolicyFenced {
    fn check(&self) -> Result<(), CloudKitFailure> {
        if allowed(self.account.as_deref(), self.platform, SyncProviderTag::Icloud) {
            Ok(())
        } else {
            Err(CloudKitFailure::Restricted)
        }
    }

    async fn fenced<T>(&self, call: impl Future<Output = Result<T, CloudKitFailure>>) -> Result<T, CloudKitFailure> {
        self.check()?;
        let answer = call.await;
        self.check()?;
        answer
    }
}

#[async_trait::async_trait]
impl CloudKitTransport for PolicyFenced {
    async fn account_status(&self) -> Result<CloudKitAccount, CloudKitFailure> {
        self.fenced(self.inner.account_status()).await
    }

    async fn ensure_zone(&self, account: String) -> Result<(), CloudKitFailure> {
        self.fenced(self.inner.ensure_zone(account)).await
    }

    async fn delete_zone(&self, account: String) -> Result<(), CloudKitFailure> {
        self.fenced(self.inner.delete_zone(account)).await
    }

    async fn fetch_changes(&self, account: String, token: Option<Vec<u8>>) -> Result<CloudKitChanges, CloudKitFailure> {
        self.fenced(self.inner.fetch_changes(account, token)).await
    }

    async fn fetch_records(
        &self,
        account: String,
        names: Vec<String>,
    ) -> Result<Vec<CloudKitFetched>, CloudKitFailure> {
        self.fenced(self.inner.fetch_records(account, names)).await
    }

    async fn modify(
        &self,
        account: String,
        saves: Vec<CloudKitRecord>,
        deletes: Vec<String>,
    ) -> Result<Vec<CloudKitOutcome>, CloudKitFailure> {
        self.fenced(self.inner.modify(account, saves, deletes)).await
    }
}

// The provider in use stops at once once the values no longer allow it, with no last pass (0055, Leaving a provider):
// iCloud's engine stops, and TablePro Sync keeps its teams and key objects while personal data rests, until the person
// confirms the move the profile leaves.
pub(crate) fn hold_to_policy(service: &std::sync::Weak<SyncService>) -> impl Future<Output = ()> + Send + 'static {
    let service = std::sync::Weak::clone(service);
    async move {
        let Some(mut values) = service
            .upgrade()
            .and_then(|held| held.account.as_ref().map(|account| account.account.watch_policy()))
        else {
            return;
        };
        loop {
            let Some(held) = service.upgrade() else {
                return;
            };
            held.leave_a_forbidden_provider().await;
            drop(held);
            if values.changed().await.is_err() {
                return;
            }
        }
    }
}

impl SyncService {
    // Whatever the provider in use or a move under way: a provider the values forbid carries no personal data from now,
    // so an arrival in flight on TablePro Sync stops at its next check and commits nothing more.
    pub(crate) async fn leave_a_forbidden_provider(&self) {
        if !self.allows(SyncProviderTag::Icloud)
            && let Ok(engine) = &self.icloud
        {
            engine.stop();
        }
        if !self.allows(SyncProviderTag::TableproSync) {
            self.service.forbid_personal();
            self.service.forbid_by_policy();
            if let Ok(engine) = self.service.now() {
                engine.sync.forbid_personal();
                engine.sync.set_mode(ServiceMode::TeamsOnly).await;
            }
        }
        // A server the values no longer allow gets no more calls from the account, and sync on it, teams included,
        // stops at once, so an answer it holds back lands nowhere (0055, When a value applies).
        if let Some(account) = &self.account
            && !account
                .account
                .policy()
                .allows_server(&account.account.server().api_origin)
            && let Ok(engine) = self.service.now()
        {
            engine.stop();
        }
    }
}

// A move between providers this device started and the app has not finished: its target, and whether everything
// arrived, so the app keeps the target as its provider and opens sync again with it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct OpenMoveInfo {
    pub target: SyncProviderTag,
    pub done: bool,
}

impl SyncService {
    async fn open_move_now(&self) -> Result<Option<OpenMoveInfo>, SyncError> {
        let moved_out = match &self.icloud {
            Ok(engine) => engine.sync.open_move().await?,
            // The values forbid iCloud or it is not the provider: the file it used last is read, with no CloudKit call.
            Err(_) => self.icloud_file_move().await?,
        };
        if self.config.provider == SyncProviderTag::Icloud
            && let Some(row) = moved_out
        {
            return Ok(Some(OpenMoveInfo {
                target: SyncProviderTag::TableproSync,
                done: row.phase == MovePhase::Done,
            }));
        }
        let Ok(engine) = self.service.now() else {
            return Ok(None);
        };
        Ok(engine.sync.move_row().await?.and_then(|row| {
            let target = match row.target {
                Provider::Service if self.config.provider != SyncProviderTag::TableproSync => {
                    SyncProviderTag::TableproSync
                }
                Provider::ICloud if self.config.provider == SyncProviderTag::TableproSync => SyncProviderTag::Icloud,
                Provider::Service | Provider::ICloud => return None,
            };
            Some(OpenMoveInfo {
                target,
                done: row.phase == MovePhase::Done,
            })
        }))
    }
}

impl SyncService {
    async fn icloud_file_move(&self) -> Result<Option<tablepro_sync::api::state::MoveRow>, SyncError> {
        let (Some(files), Some(account)) = (&self.files, &self.config.icloud_account) else {
            return Ok(None);
        };
        let state = files
            .open(tablepro_sync::api::state::StateIdentity::ICloud {
                user_record_name: account.clone(),
            })
            .await?;
        // A restored file's move is no consent to move today's data.
        if state.opened().sync_tables == tablepro_sync::api::state::SyncTrust::Refill {
            let mut txn = state.begin().await?;
            txn.delete(&tablepro_sync::api::state::RowKey::Move).await?;
            txn.commit().await?;
            return Ok(None);
        }
        let row = state
            .begin()
            .await?
            .get(&tablepro_sync::api::state::RowKey::Move)
            .await?;
        Ok(match row {
            Some(tablepro_sync::api::state::Row::Move(row)) if row.target == Provider::Service => Some(row),
            _ => None,
        })
    }

    // The app opened sync with the target of a move that went through: the move has told it.
    pub(crate) async fn acknowledge_moves(&self) {
        let Ok(engine) = self.service.now() else {
            return;
        };
        let Ok(Some(row)) = engine.sync.move_row().await else {
            return;
        };
        let kept = match row.target {
            Provider::Service => self.config.provider == SyncProviderTag::TableproSync,
            Provider::ICloud => self.config.provider == SyncProviderTag::Icloud,
        };
        if kept && let Err(error) = engine.sync.clear_done_move().await {
            tracing::warn!(code = error.code(), "a finished move's row stayed");
        }
    }
}

// A move a restart cut short goes on as soon as sync opens: iCloud stays stopped meanwhile, and the arrival goes on
// from the bases its first try committed (0054, Moving between providers). A move back waits for the person, who
// confirms its count again.
pub(crate) fn resume_open_move(service: &std::sync::Weak<SyncService>) -> impl Future<Output = ()> + Send + 'static {
    let service = std::sync::Weak::clone(service);
    async move {
        let Some(held) = service.upgrade() else {
            return;
        };
        let open = match held.open_move_now().await {
            Ok(Some(open)) if !open.done && open.target == SyncProviderTag::TableproSync => open,
            Ok(_) => return,
            Err(error) => {
                tracing::warn!(code = error.code(), "the move this device started could not be read");
                return;
            }
        };
        let resumed = match held.config.provider {
            SyncProviderTag::Icloud => held.move_to_service().await,
            SyncProviderTag::Off => held.first_upload().await,
            SyncProviderTag::TableproSync => Ok(()),
        };
        if let Err(error) = resumed {
            tracing::warn!(code = error.code(), target = ?open.target, "the move this device started did not finish");
        }
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

    // A move this device started that the app has not finished: the app keeps `target` as its provider once `done`.
    pub async fn open_move(&self) -> Result<Option<OpenMoveInfo>, CoreError> {
        Ok(self.open_move_now().await?)
    }

    pub async fn plan_move_to_service(&self) -> Result<MovePlanInfo, CoreError> {
        self.on_mover(move |mover| async move { mover.plan_move_to_service().await.map(MovePlanInfo::from) })
            .await
    }

    // From iCloud: a last iCloud pass, iCloud stops, and each record meets the service's copy (0054). While the values
    // forbid iCloud traffic, no iCloud call runs and the copies meet the service against this device's CloudKit bases.
    pub async fn move_to_service(&self) -> Result<(), CoreError> {
        self.allows_target(SyncProviderTag::TableproSync)?;
        if self.allows(SyncProviderTag::Icloud) {
            self.on_mover(move |mover| async move { mover.move_to_service().await })
                .await
        } else {
            self.on_mover(move |mover| async move { mover.move_to_service_without_icloud().await })
                .await
        }
    }

    // From Off: what this device holds goes up under the normal merge, the server's copy winning a conflict.
    pub async fn first_upload(&self) -> Result<(), CoreError> {
        self.allows_target(SyncProviderTag::TableproSync)?;
        self.on_mover(move |mover| async move { mover.first_upload().await })
            .await
    }

    pub async fn plan_move_to_icloud(&self) -> Result<MoveBackPlanInfo, CoreError> {
        self.allows_target(SyncProviderTag::Icloud)?;
        self.on_mover(move |mover| async move { mover.plan_move_to_icloud().await.map(MoveBackPlanInfo::from) })
            .await
    }

    // Refused unless the count is the plan's, which the person confirmed.
    pub async fn move_to_icloud(&self, confirmed_deletions: u64) -> Result<(), CoreError> {
        self.allows_target(SyncProviderTag::Icloud)?;
        self.on_mover(move |mover| async move { mover.move_to_icloud(confirmed_deletions).await })
            .await
    }

    // The zone a move left, with this device's iCloud state file, once the person asks.
    pub async fn delete_icloud_zone(&self) -> Result<(), CoreError> {
        self.allows_target(SyncProviderTag::Icloud)?;
        self.on_mover(move |mover| async move { mover.delete_icloud_zone().await })
            .await
    }
}
