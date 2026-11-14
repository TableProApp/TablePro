use std::path::PathBuf;
use std::sync::Arc;

use chrono::Utc;
use tablepro_account::{
    Account, AccountSettings, AccountStatus, AppClient, CallbackPage, DeviceDescription, Endpoints, EntitlementKeys,
    MachineId,
};
use tablepro_session::runtime::Tasks;
use tokio::sync::watch;
use tokio_util::task::AbortOnDropHandle;

use super::account_info::{AccountStatusInfo, DeviceInfo, FeatureAccessTag, ProfileInfo};
use super::host_browser::{HostBrowser, HostBrowserBridge};
use crate::cancel_token::{CancelToken, token};
use crate::core_handle::Core;
use crate::error::CoreError;
use crate::runtime::on_runtime;

// What the app says about itself and where the account lives. Core ADR 0016 has the flow.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountConfig {
    // Both None for tablepro.app; a development build names its local stack's two.
    pub account_url: Option<String>,
    pub api_url: Option<String>,
    // The x of each Ed25519 key a development stack signs with; empty for the release keys.
    pub entitlement_keys: Vec<String>,
    pub device_name: String,
    pub app_version: String,
    pub os_version: String,
    // The device and entitlement are kept here between launches.
    pub account_file: String,
    // The browser's page once the sign-in comes back, in the app's language.
    pub callback_finished: String,
    pub callback_unknown: String,
    // None reads MachineGuid from the registry, the only source on Windows; elsewhere the host gives one.
    pub machine_guid: Option<String>,
}

// Told the account's status changed, on a runtime thread. It only schedules a read of `status` on the app's own
// thread: no work, and nothing that blocks.
#[uniffi::export(callback_interface)]
pub trait AccountListener: Send + Sync {
    fn status_changed(&self);
}

// One per app. Dropping it stops the refresh schedule.
#[derive(uniffi::Object)]
pub struct AccountService {
    pub(crate) account: Account,
    status: watch::Receiver<AccountStatus>,
    pub(crate) tasks: Tasks,
    _running: AbortOnDropHandle<()>,
}

#[uniffi::export]
impl Core {
    // Restores the last sign-in and keeps the entitlement fresh while the service lives.
    pub async fn open_account(
        &self,
        config: AccountConfig,
        browser: Box<dyn HostBrowser>,
        listener: Box<dyn AccountListener>,
    ) -> Result<Arc<AccountService>, CoreError> {
        let refresh_tokens = self.refresh_tokens();
        let tasks = self.tasks.clone();
        let browser = Arc::new(HostBrowserBridge::new(browser, tasks.clone()));
        let listener: Arc<dyn AccountListener> = Arc::from(listener);
        on_runtime(&self.tasks, async move {
            // Reading the registry and the system's certificates can block.
            let account = tasks
                .spawn_blocking_task(move || {
                    let settings = settings(config)?;
                    let vault = refresh_tokens(&settings);
                    let status = watch::Sender::new(AccountStatus::SignedOut);
                    Account::new(settings, vault, browser, status).map_err(CoreError::from)
                })
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))??;
            Ok(Arc::new(AccountService::start(account, listener, tasks)))
        })
        .await
    }
}

impl AccountService {
    fn start(account: Account, listener: Arc<dyn AccountListener>, tasks: Tasks) -> Self {
        let status = account.status();
        let mut changes = account.status();
        let running = {
            let account = account.clone();
            tasks.spawn_owned(async move {
                let signal = async move {
                    while changes.changed().await.is_ok() {
                        listener.status_changed();
                    }
                };
                tokio::join!(account.run(), signal);
            })
        };
        Self {
            account,
            status,
            tasks,
            _running: running,
        }
    }

    fn machine_id(&self) -> String {
        self.account.machine_id().as_str().to_owned()
    }
}

#[uniffi::export]
impl AccountService {
    pub fn status(&self) -> AccountStatusInfo {
        AccountStatusInfo::of(&self.status.borrow(), self.account.machine_id().as_str())
    }

    // From the entitlement's feature codes only: the app knows no plan or tier.
    pub fn feature_access(&self, feature: String) -> FeatureAccessTag {
        self.status.borrow().feature_access(&feature, Utc::now()).into()
    }

    // The cancel ends only the wait for the browser: once it has come back, the sign-in is kept.
    pub async fn sign_in(&self, cancel: Option<Arc<CancelToken>>) -> Result<(), CoreError> {
        let account = self.account.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            account
                .sign_in(async move { cancel.cancelled().await })
                .await
                .map_err(CoreError::from)
        })
        .await
    }

    // Signs out here even when the server could not be told, which the error then says.
    pub async fn sign_out(&self) -> Result<(), CoreError> {
        let account = self.account.clone();
        on_runtime(
            &self.tasks,
            async move { account.sign_out().await.map_err(CoreError::from) },
        )
        .await
    }

    // Refresh or Try Again, and after any change to the account.
    pub async fn refresh(&self) -> Result<(), CoreError> {
        let account = self.account.clone();
        on_runtime(&self.tasks, async move {
            account.refresh_entitlement().await.map_err(CoreError::from)
        })
        .await
    }

    // When the app comes back while past the device limit, since a slot may have been freed elsewhere. False when
    // it was not past the limit, so nothing was asked.
    pub async fn refresh_past_device_limit(&self) -> Result<bool, CoreError> {
        let account = self.account.clone();
        on_runtime(&self.tasks, async move {
            match account.refresh_past_device_limit().await {
                None => Ok(false),
                Some(refreshed) => refreshed.map(|()| true).map_err(CoreError::from),
            }
        })
        .await
    }

    pub async fn profile(&self) -> Result<ProfileInfo, CoreError> {
        let account = self.account.clone();
        on_runtime(&self.tasks, async move {
            account.profile().await.map(ProfileInfo::from).map_err(CoreError::from)
        })
        .await
    }

    pub async fn devices(&self) -> Result<Vec<DeviceInfo>, CoreError> {
        let account = self.account.clone();
        let machine_id = self.machine_id();
        on_runtime(&self.tasks, async move {
            let devices = account.devices().await?;
            Ok(devices
                .iter()
                .map(|device| DeviceInfo::of(device, &machine_id))
                .collect())
        })
        .await
    }

    pub async fn remove_device(&self, device_id: String) -> Result<(), CoreError> {
        let account = self.account.clone();
        on_runtime(&self.tasks, async move {
            account.remove_device(&device_id).await.map_err(CoreError::from)
        })
        .await
    }
}

impl std::fmt::Debug for AccountService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AccountService").finish_non_exhaustive()
    }
}

fn settings(config: AccountConfig) -> Result<AccountSettings, CoreError> {
    let endpoints = match (config.account_url.as_deref(), config.api_url.as_deref()) {
        (None, None) => Endpoints::production(),
        (Some(account), Some(api)) => Endpoints::new(account, api)
            .map_err(|error| CoreError::failed("ffi.account_config", format!("{account} or {api}: {error}")))?,
        _ => {
            return Err(CoreError::failed(
                "ffi.account_config",
                "account_url and api_url go together",
            ));
        }
    };
    let keys = match config.entitlement_keys.is_empty() {
        true => EntitlementKeys::release(),
        false => EntitlementKeys::from_public_keys(config.entitlement_keys.iter().map(String::as_str))
            .map_err(|error| CoreError::failed("ffi.account_config", error.to_string()))?,
    };
    let guid = match config.machine_guid {
        Some(guid) => guid,
        None => system_machine_guid()?,
    };
    let machine_id = MachineId::derive_machine_guid(&guid)
        .ok_or_else(|| CoreError::failed("account.no_machine_id", "MachineGuid is not a GUID"))?;
    Ok(AccountSettings {
        client: AppClient::WINDOWS,
        endpoints,
        device: DeviceDescription {
            name: config.device_name,
            app_version: config.app_version,
            os_version: config.os_version,
        },
        machine_id,
        keys,
        account_file: PathBuf::from(config.account_file),
        callback_page: CallbackPage {
            finished: config.callback_finished,
            unknown: config.callback_unknown,
        },
    })
}

#[cfg(windows)]
fn system_machine_guid() -> Result<String, CoreError> {
    super::machine_guid::read_machine_guid().map_err(|detail| CoreError::failed("account.no_machine_id", detail))
}

#[cfg(not(windows))]
fn system_machine_guid() -> Result<String, CoreError> {
    Err(CoreError::failed(
        "account.no_machine_id",
        "this platform's machine ID is not read by the core",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> AccountConfig {
        AccountConfig {
            account_url: None,
            api_url: None,
            entitlement_keys: Vec::new(),
            device_name: "Lab".to_owned(),
            app_version: "1.0.0".to_owned(),
            os_version: "Windows 11".to_owned(),
            account_file: "account.json".to_owned(),
            callback_finished: String::new(),
            callback_unknown: String::new(),
            machine_guid: Some("d3b07384-d113-4ec6-a2f1-6a3f0c2e9b7a".to_owned()),
        }
    }

    #[test]
    fn no_urls_is_tablepro_app_and_both_name_a_local_stack() {
        let production = settings(config()).unwrap();
        let local = settings(AccountConfig {
            account_url: Some("http://account.localhost:5284".to_owned()),
            api_url: Some("http://api.localhost:5284/v2".to_owned()),
            ..config()
        })
        .unwrap();

        assert_eq!(production.endpoints, Endpoints::production());
        assert_eq!(
            local.endpoints,
            Endpoints::new("http://account.localhost:5284", "http://api.localhost:5284/v2").unwrap()
        );
        assert_eq!(production.client, AppClient::WINDOWS);
    }

    #[test]
    fn half_a_local_stack_a_bad_key_or_a_bad_guid_is_refused() {
        let half = settings(AccountConfig {
            api_url: Some("http://api.localhost:5284/v2".to_owned()),
            ..config()
        });
        let keyless = settings(AccountConfig {
            entitlement_keys: vec!["not a key".to_owned()],
            ..config()
        });
        let guidless = settings(AccountConfig {
            machine_guid: Some("not a guid".to_owned()),
            ..config()
        });

        assert_eq!(half.unwrap_err().code(), "ffi.account_config");
        assert_eq!(keyless.unwrap_err().code(), "ffi.account_config");
        assert_eq!(guidless.unwrap_err().code(), "account.no_machine_id");
    }

    #[test]
    fn the_machine_id_is_the_guid_s_hmac() {
        let settings = settings(config()).unwrap();

        assert_eq!(
            settings.machine_id.as_str(),
            "304a889059f4befc83a542069ca52d990fd963e22766f6db230543bfddf7e336"
        );
    }
}
