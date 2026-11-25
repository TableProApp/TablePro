use std::path::PathBuf;
use std::sync::Arc;

use chrono::Utc;
use secrecy::SecretString;
use tablepro_account::{
    Account, AccountHosts, AccountSettings, AccountStatus, CallbackPage, DeviceDescription, Endpoints, EntitlementKeys,
    FixedServer, LicenseKeys, MachineId, OfflineFileError, ServerPolicy, ServerSettings, read_offline_file_blocking,
};
use tablepro_ai::ModelCatalog;
use tablepro_session::runtime::Tasks;
use tokio::sync::{broadcast, watch};
use tokio_util::task::AbortOnDropHandle;

use super::account_info::{
    AccessTokenInfo, AccountStatusInfo, AppClientTag, DeviceInfo, FeatureAccessTag, ProfileInfo, ServerInfo,
    ServerLicenseInfo, SignOutCauseTag,
};
use super::host_browser::{HostBrowser, HostBrowserBridge};
use super::managed_policy::ManagedPolicyArg;
use super::web_authenticator::{HostWebAuthenticator, HostWebAuthenticatorBridge};
use crate::cancel_token::{CancelToken, token};
use crate::core_handle::Core;
use crate::error::CoreError;
use crate::runtime::on_runtime;

// What the app says about itself and where the account lives. Core ADRs 0016 and 0046 have the flow.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountConfig {
    // A development build's local stack, both or neither; a release build refuses them, as it refuses every key
    // below. None signs in to the server the policy and the person pick.
    pub account_url: Option<String>,
    pub api_url: Option<String>,
    // The x of each Ed25519 key a development stack signs entitlements with; empty for the release keys.
    pub entitlement_keys: Vec<String>,
    pub device_name: String,
    pub app_version: String,
    pub os_version: String,
    // The device and entitlement are kept here between launches, and the server choice beside it.
    pub account_file: String,
    // The browser's page once the sign-in comes back, in the app's language.
    pub callback_finished: String,
    pub callback_unknown: String,
    // None reads MachineGuid from the registry, the only source on Windows. Unused when `machine_id` is given.
    pub machine_guid: Option<String>,
    pub client: AppClientTag,
    // A 64-hex ID the host derived itself: the Mac's SHA-256 of its hardware UUID.
    pub machine_id: Option<String>,
    // The managed values the host read at launch, which pick the server (core ADR 0055).
    pub policy: ManagedPolicyArg,
    // The Mac's Account/entitlement.jwt, adopted once while `account_file` is missing.
    pub legacy_entitlement_file: Option<String>,
    // The x of each license key a development build trusts; empty for the release keys.
    pub license_keys: Vec<String>,
}

// Told the account's status changed, on a runtime thread. It only schedules a read of `status` on the app's own
// thread: no work, and nothing that blocks.
#[uniffi::export(callback_interface)]
pub trait AccountListener: Send + Sync {
    fn status_changed(&self);

    // A sign-in ended, and why. `status_changed` follows or has come.
    fn signed_out(&self, cause: SignOutCauseTag);
}

// One per app. Dropping it stops the refresh schedule.
#[derive(uniffi::Object)]
pub struct AccountService {
    pub(crate) account: Account,
    status: watch::Receiver<AccountStatus>,
    pub(crate) tasks: Tasks,
    // The core's AI model catalog, which refreshes from tablepro.app only while the values allow it.
    ai_catalog: ModelCatalog,
    _running: AbortOnDropHandle<()>,
}

#[uniffi::export]
impl Core {
    // Restores the last sign-in and keeps the entitlement fresh while the service lives. The Mac passes its web
    // authenticator, which a client with a custom-scheme redirect signs in through.
    pub async fn open_account(
        &self,
        config: AccountConfig,
        browser: Box<dyn HostBrowser>,
        web_authenticator: Option<Box<dyn HostWebAuthenticator>>,
        listener: Box<dyn AccountListener>,
    ) -> Result<Arc<AccountService>, CoreError> {
        let vaults = self.refresh_tokens();
        let tasks = self.tasks.clone();
        let ai_catalog = self.ai_catalog.clone();
        let browser = Arc::new(HostBrowserBridge::new(browser, tasks.clone()));
        let web_authenticator = web_authenticator.map(|host| {
            Arc::new(HostWebAuthenticatorBridge::new(host, tasks.clone()))
                as Arc<dyn tablepro_account::WebAuthenticator>
        });
        let listener: Arc<dyn AccountListener> = Arc::from(listener);
        on_runtime(&self.tasks, async move {
            let policy = config.policy.clone().into();
            // Reading the registry, the server choice and the system's certificates can block.
            let account = tasks
                .spawn_blocking_task(move || {
                    let settings = settings(config, cfg!(debug_assertions))?;
                    let hosts = AccountHosts {
                        vaults,
                        browser,
                        web_authenticator,
                    };
                    let status = watch::Sender::new(AccountStatus::SignedOut);
                    Account::open(settings, hosts, status).map_err(CoreError::from)
                })
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))??;
            // A development stack's server takes no values at launch, so they come here.
            account.apply_policy(policy).await;
            ai_catalog.allow_refresh(account.allows_tablepro_requests());
            Ok(Arc::new(AccountService::start(account, listener, tasks, ai_catalog)))
        })
        .await
    }
}

impl AccountService {
    fn start(account: Account, listener: Arc<dyn AccountListener>, tasks: Tasks, ai_catalog: ModelCatalog) -> Self {
        let status = account.status();
        let mut changes = account.status();
        let mut sign_outs = account.sign_outs();
        let running = {
            let account = account.clone();
            tasks.spawn_owned(async move {
                let signal = {
                    let listener = listener.clone();
                    async move {
                        while changes.changed().await.is_ok() {
                            listener.status_changed();
                        }
                    }
                };
                let causes = async move {
                    loop {
                        match sign_outs.recv().await {
                            Ok(cause) => listener.signed_out(cause.into()),
                            Err(broadcast::error::RecvError::Lagged(_)) => {}
                            Err(broadcast::error::RecvError::Closed) => break,
                        }
                    }
                };
                tokio::join!(account.run(), signal, causes);
            })
        };
        Self {
            account,
            status,
            tasks,
            ai_catalog,
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

    pub fn server(&self) -> ServerInfo {
        self.account.server().into()
    }

    // Share-link reads and the AI catalog refresh, wherever the host still makes them itself, ask this before any
    // request to tablepro.app.
    pub fn allows_tablepro_requests(&self) -> bool {
        self.account.allows_tablepro_requests()
    }

    // The managed values read again, at a change the OS reported. They apply at once; when they no longer allow the
    // server signed in to, the account calls it no more until the next launch.
    pub async fn apply_policy(&self, policy: ManagedPolicyArg) {
        let account = self.account.clone();
        let ai_catalog = self.ai_catalog.clone();
        let _ = on_runtime(&self.tasks, async move {
            account.apply_policy(policy.into()).await;
            ai_catalog.allow_refresh(account.allows_tablepro_requests());
            Ok::<_, CoreError>(())
        })
        .await;
    }

    // A company server's license, once this app verified it.
    pub fn license(&self) -> Option<ServerLicenseInfo> {
        self.account
            .license()
            .map(|license| ServerLicenseInfo::of(&license, Utc::now()))
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

    // A company server's API origin, or None for the organization's server or tablepro.app. Another server than the
    // one signed in to signs out of it; refused with account.server_managed when the organization allows no other.
    pub async fn choose_server(&self, url: Option<String>) -> Result<(), CoreError> {
        let account = self.account.clone();
        on_runtime(&self.tasks, async move {
            account.choose_server(url.as_deref()).await.map_err(CoreError::from)
        })
        .await
    }

    // A bearer for the app's own /v2 client, such as the Team Library's and the share links'.
    pub async fn access_token(&self) -> Result<AccessTokenInfo, CoreError> {
        let account = self.account.clone();
        on_runtime(&self.tasks, async move {
            account
                .access_token()
                .await
                .map(AccessTokenInfo::from)
                .map_err(CoreError::from)
        })
        .await
    }

    // The API answered 401 to this token, so the next `access_token` refreshes it.
    pub async fn access_token_rejected(&self, token: SecretString) {
        let account = self.account.clone();
        let _ = on_runtime(&self.tasks, async move {
            account.access_token_rejected(&token).await;
            Ok::<_, CoreError>(())
        })
        .await;
    }

    // A license key a Mac stored before accounts, traded for a sign-in on tablepro.app.
    pub async fn use_license_key(&self, key: SecretString) -> Result<(), CoreError> {
        let account = self.account.clone();
        on_runtime(&self.tasks, async move {
            account.use_license_key(&key).await.map_err(CoreError::from)
        })
        .await
    }

    // An offline file from tablepro.app's portal, read here so a file far too large is never all read.
    pub async fn import_offline_file(&self, path: String) -> Result<(), CoreError> {
        let account = self.account.clone();
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            let token = tasks
                .spawn_blocking_task(move || read_offline_file_blocking(std::path::Path::new(&path)))
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))?
                .map_err(|error| match error {
                    OfflineFileError::Read { .. } => {
                        CoreError::failed("account.offline_file_unreadable", error.to_string())
                    }
                    OfflineFileError::TooLarge { .. } => {
                        CoreError::failed("account.offline_file_too_large", error.to_string())
                    }
                })?;
            account.import_offline_file(&token).await.map_err(CoreError::from)
        })
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

// A development stack and test keys reach only a development build: a release build signs in where the policy and the
// person say, trusting the keys it ships (core ADR 0044, Out of scope). The fields stay in every build so the bindings
// match.
fn settings(config: AccountConfig, development: bool) -> Result<AccountSettings, CoreError> {
    let overridden = config.account_url.is_some()
        || config.api_url.is_some()
        || !config.entitlement_keys.is_empty()
        || !config.license_keys.is_empty();
    if overridden && !development {
        return Err(CoreError::failed(
            "ffi.account_config",
            "a release build takes no development server or keys",
        ));
    }
    let config_error = |detail: String| CoreError::failed("ffi.account_config", detail);
    let license_keys = match config.license_keys.is_empty() {
        true => LicenseKeys::release(),
        false => LicenseKeys::from_public_keys(config.license_keys.iter().map(String::as_str))
            .map_err(|error| config_error(error.to_string()))?,
    };
    let server = match (config.account_url.as_deref(), config.api_url.as_deref()) {
        (None, None) if !config.entitlement_keys.is_empty() => {
            return Err(config_error(
                "entitlement_keys go with account_url and api_url".to_owned(),
            ));
        }
        (None, None) => ServerSettings::Resolved(ServerPolicy {
            managed: config.policy.into(),
            license_keys,
        }),
        (Some(account), Some(api)) => {
            let endpoints =
                Endpoints::new(account, api).map_err(|error| config_error(format!("{account} or {api}: {error}")))?;
            let keys = match config.entitlement_keys.is_empty() {
                true => EntitlementKeys::release(),
                false => EntitlementKeys::from_public_keys(config.entitlement_keys.iter().map(String::as_str))
                    .map_err(|error| config_error(error.to_string()))?,
            };
            ServerSettings::Fixed(FixedServer {
                issuer: endpoints.api_origin(),
                endpoints,
                keys,
            })
        }
        _ => return Err(config_error("account_url and api_url go together".to_owned())),
    };
    let machine_id = match (config.machine_id, config.machine_guid) {
        (Some(id), _) => MachineId::from_hex(&id).ok_or_else(|| {
            CoreError::failed(
                "account.no_machine_id",
                "the host's machine ID is not 64 hex characters",
            )
        })?,
        (None, guid) => {
            let guid = match guid {
                Some(guid) => guid,
                None => system_machine_guid()?,
            };
            MachineId::derive_machine_guid(&guid)
                .ok_or_else(|| CoreError::failed("account.no_machine_id", "MachineGuid is not a GUID"))?
        }
    };
    Ok(AccountSettings {
        client: config.client.into(),
        server,
        device: DeviceDescription {
            name: config.device_name,
            app_version: config.app_version,
            os_version: config.os_version,
        },
        machine_id,
        account_file: PathBuf::from(config.account_file),
        callback_page: CallbackPage {
            finished: config.callback_finished,
            unknown: config.callback_unknown,
        },
        legacy_entitlement_file: config.legacy_entitlement_file.map(PathBuf::from),
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
    use tablepro_account::{AppClient, ServerSettings};

    use super::*;
    use crate::account::managed_policy::ManagedPolicyValues;

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
            client: AppClientTag::Windows,
            machine_id: None,
            policy: ManagedPolicyArg::Read {
                values: ManagedPolicyValues::default(),
            },
            legacy_entitlement_file: None,
            license_keys: Vec::new(),
        }
    }

    fn development(config: AccountConfig) -> Result<AccountSettings, CoreError> {
        settings(config, true)
    }

    #[test]
    fn no_urls_resolves_the_server_and_both_name_a_local_stack() {
        let production = development(config()).unwrap();
        let local = development(AccountConfig {
            account_url: Some("http://account.localhost:5284".to_owned()),
            api_url: Some("http://api.localhost:5284/v2".to_owned()),
            ..config()
        })
        .unwrap();

        assert!(matches!(production.server, ServerSettings::Resolved(_)));
        let ServerSettings::Fixed(stack) = local.server else {
            panic!("not a development stack");
        };
        assert_eq!(
            stack.endpoints,
            Endpoints::new("http://account.localhost:5284", "http://api.localhost:5284/v2").unwrap()
        );
        assert_eq!(stack.issuer, "http://api.localhost:5284");
        assert_eq!(production.client, AppClient::WINDOWS);
    }

    #[test]
    fn half_a_local_stack_a_bad_key_or_a_bad_guid_is_refused() {
        let half = development(AccountConfig {
            api_url: Some("http://api.localhost:5284/v2".to_owned()),
            ..config()
        });
        let keyless = development(AccountConfig {
            entitlement_keys: vec!["not a key".to_owned()],
            ..config()
        });
        let guidless = development(AccountConfig {
            machine_guid: Some("not a guid".to_owned()),
            ..config()
        });

        assert_eq!(half.unwrap_err().code(), "ffi.account_config");
        assert_eq!(keyless.unwrap_err().code(), "ffi.account_config");
        assert_eq!(guidless.unwrap_err().code(), "account.no_machine_id");
    }

    #[test]
    fn the_machine_id_is_the_guid_s_hmac() {
        let settings = development(config()).unwrap();

        assert_eq!(
            settings.machine_id.as_str(),
            "304a889059f4befc83a542069ca52d990fd963e22766f6db230543bfddf7e336"
        );
    }

    #[test]
    fn a_release_build_refuses_a_development_server_and_test_keys() {
        let overrides = [
            AccountConfig {
                account_url: Some("http://account.localhost:5284".to_owned()),
                api_url: Some("http://api.localhost:5284/v2".to_owned()),
                ..config()
            },
            AccountConfig {
                entitlement_keys: vec![tablepro_account::fakes::PUBLIC_X.to_owned()],
                ..config()
            },
            AccountConfig {
                license_keys: vec![tablepro_account::fakes::PUBLIC_X.to_owned()],
                ..config()
            },
        ];

        for config in overrides {
            assert_eq!(
                settings(config.clone(), false).unwrap_err().code(),
                "ffi.account_config",
                "{config:?}"
            );
        }
        assert!(settings(config(), false).is_ok());
    }

    #[test]
    fn the_mac_passes_its_client_its_own_machine_id_its_policy_and_its_old_entitlement() {
        let mac = settings(
            AccountConfig {
                client: AppClientTag::Macos,
                machine_guid: None,
                machine_id: Some("E4338B8603DE2523305FDFCB87319BE2033974658AD97F0C975834D209715658".to_owned()),
                policy: ManagedPolicyArg::Read {
                    values: ManagedPolicyValues {
                        account_server_url: Some("https://tablepro.corp.example".to_owned()),
                        allow_other_account_servers: Some(false),
                        personal_sync_provider: Some(vec!["tablepro-sync".to_owned()]),
                        ..ManagedPolicyValues::default()
                    },
                },
                legacy_entitlement_file: Some(
                    "/Users/a/Library/Application Support/TablePro/Account/entitlement.jwt".to_owned(),
                ),
                ..config()
            },
            false,
        )
        .unwrap();
        let short = settings(
            AccountConfig {
                machine_id: Some("abc".to_owned()),
                ..config()
            },
            false,
        );

        assert_eq!(mac.client, AppClient::MACOS);
        assert_eq!(mac.machine_id.as_str(), tablepro_account::fakes::MACHINE);
        let ServerSettings::Resolved(policy) = mac.server else {
            panic!("not resolved");
        };
        let values = policy.managed.values().expect("values");
        assert_eq!(
            values.account_server_url.as_deref(),
            Some("https://tablepro.corp.example")
        );
        assert_eq!(values.allow_other_account_servers, Some(false));
        assert_eq!(
            values.personal_sync_provider.as_deref(),
            Some(["tablepro-sync".to_owned()].as_slice())
        );
        assert!(mac.legacy_entitlement_file.is_some());
        assert_eq!(short.unwrap_err().code(), "account.no_machine_id");
    }
}
