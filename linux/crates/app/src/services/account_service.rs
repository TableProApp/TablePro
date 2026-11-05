use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use chrono::Utc;
use secrecy::SecretString;
use tablepro_account::{
    Account, AccountError, AccountSettings, AccountStatus, AppClient, BrowserLauncher, CallbackPage, DeviceDescription,
    Endpoints, EntitlementKeys, FeatureAccess, MachineId, RefreshTokenVault, Url,
};
use tablepro_core::credentials::SecretError;
use tablepro_linux_platform::{MACHINE_ID_FILES, SecretStore, read_machine_id};
use tablepro_session::runtime::Tasks;
use tokio::sync::{oneshot, watch};
use tokio_util::task::AbortOnDropHandle;

use crate::config;
use crate::i18n::gettext;

// Flatpak binds the host's first file into every sandbox at the first path, or else its second, as D-Bus's older
// copy, so the host build reads them in the same order and both builds are one device.
const MACHINE_ID_FILE: &str = "/etc/machine-id";
const DBUS_MACHINE_ID_FILE: &str = "/var/lib/dbus/machine-id";
// Flatpak writes the first at the root of every sandbox, and shows the host's os-release(5) at the second.
const FLATPAK_INFO: &str = "/.flatpak-info";
const HOST_OS_RELEASE: &str = "/run/host/os-release";
const PRODUCTION_PORTAL: &str = "https://account.tablepro.app";

// Whether the account could be built; it needs the machine ID and the service's address.
#[derive(Clone)]
pub enum AccountStart {
    Starting,
    Ready(Account),
    NoMachineId(String),
    Misconfigured(String),
    Failed(AccountError),
}

// What the Preferences page works through.
#[derive(Clone)]
pub struct AccountHandle {
    pub status: watch::Receiver<AccountStatus>,
    pub start: watch::Receiver<AccountStart>,
    // account.tablepro.app, or the development build's account service.
    pub portal: String,
}

impl AccountHandle {
    // Whether the person has paid, which losing the network cannot undo: a lapsed entitlement still names its licenses.
    // The same ID the account registers this computer with, once the account has started.
    pub fn machine_id(&self) -> Option<MachineId> {
        self.account().map(|account| account.machine_id().clone())
    }

    pub fn has_license(&self) -> bool {
        self.status
            .borrow()
            .entitlement()
            .is_some_and(|entitlement| !entitlement.claims().licenses.is_empty())
    }

    pub fn account(&self) -> Option<Account> {
        match &*self.start.borrow() {
            AccountStart::Ready(account) => Some(account.clone()),
            _ => None,
        }
    }
}

pub struct AccountService {
    handle: AccountHandle,
    _running: Option<AbortOnDropHandle<()>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Cloud {
    endpoints: Endpoints,
    keys_x: Vec<String>,
    portal: String,
}

impl AccountService {
    // Until startup, in an instance that only hands its command line over, and in tests.
    pub fn signed_out() -> Self {
        Self {
            handle: AccountHandle {
                status: watch::channel(AccountStatus::SignedOut).1,
                start: watch::channel(AccountStart::Starting).1,
                portal: PRODUCTION_PORTAL.to_owned(),
            },
            _running: None,
        }
    }

    pub fn start(
        tasks: &Tasks,
        account_file: &Path,
        vault: Arc<dyn RefreshTokenVault>,
        browser: Arc<dyn BrowserLauncher>,
    ) -> Self {
        let (sender, status) = watch::channel(AccountStatus::SignedOut);
        let (started, start) = watch::channel(AccountStart::Starting);
        let callback_page = CallbackPage {
            finished: gettext("You can close this tab and go back to TablePro."),
            unknown: gettext("TablePro is not waiting for this sign-in. Start it again from TablePro."),
        };
        let cloud = cloud(
            config::profile(),
            config::DEV_ACCOUNT_URL,
            config::DEV_API_URL,
            config::DEV_ENTITLEMENT_KEYS,
        );
        let portal = cloud
            .as_ref()
            .map_or(PRODUCTION_PORTAL, |cloud| cloud.portal.as_str())
            .to_owned();
        let account_file = account_file.to_owned();
        let running = tasks.spawn_owned(async move {
            let machine_id = match this_machine() {
                Ok(machine_id) => machine_id,
                Err(error) => {
                    tracing::warn!(%error, "the TablePro account needs a machine ID");
                    started.send_replace(AccountStart::NoMachineId(error.to_string()));
                    return;
                }
            };
            let (endpoints, keys) = match cloud.and_then(|cloud| cloud.keys().map(|keys| (cloud.endpoints, keys))) {
                Ok(settings) => settings,
                Err(detail) => {
                    tracing::error!(%detail, "the development build's account settings are not valid");
                    started.send_replace(AccountStart::Misconfigured(detail));
                    return;
                }
            };
            let settings = AccountSettings {
                client: AppClient::LINUX,
                endpoints,
                device: this_device(),
                machine_id,
                keys,
                account_file,
                callback_page,
            };
            match Account::new(settings, vault, browser, sender) {
                Ok(account) => {
                    started.send_replace(AccountStart::Ready(account.clone()));
                    account.run().await;
                }
                Err(error) => {
                    tracing::warn!(%error, "the TablePro account did not start");
                    started.send_replace(AccountStart::Failed(error));
                }
            }
        });
        Self {
            handle: AccountHandle { status, start, portal },
            _running: Some(running),
        }
    }

    pub fn handle(&self) -> AccountHandle {
        self.handle.clone()
    }

    pub fn feature_access(&self, feature: &str) -> FeatureAccess {
        self.handle.status.borrow().feature_access(feature, Utc::now())
    }
}

fn this_machine() -> Result<MachineId, String> {
    let text = read_machine_id(&MACHINE_ID_FILES.map(Path::new)).map_err(|error| error.to_string())?;
    MachineId::derive(&text).ok_or_else(|| format!("{} does not hold a machine ID", MACHINE_ID_FILES[0]))
}

impl Cloud {
    fn keys(&self) -> Result<EntitlementKeys, String> {
        if self.keys_x.is_empty() {
            return Ok(EntitlementKeys::release());
        }
        EntitlementKeys::from_public_keys(self.keys_x.iter().map(String::as_str)).map_err(|error| error.to_string())
    }
}

// A release build always signs in to tablepro.app, whatever it was built with.
fn cloud(profile: config::Profile, account: &str, api: &str, keys: &str) -> Result<Cloud, String> {
    let production = || Cloud {
        endpoints: Endpoints::production(),
        keys_x: Vec::new(),
        portal: PRODUCTION_PORTAL.to_owned(),
    };
    let (account, api) = (account.trim(), api.trim());
    if profile == config::Profile::Default || (account.is_empty() && api.is_empty() && keys.trim().is_empty()) {
        return Ok(production());
    }
    if account.is_empty() || api.is_empty() {
        return Err("dev_account_url and dev_api_url go together".to_owned());
    }
    let endpoints = Endpoints::new(account, api).map_err(|error| format!("{account} or {api}: {error}"))?;
    Ok(Cloud {
        endpoints,
        keys_x: keys
            .split(',')
            .map(str::trim)
            .filter(|x| !x.is_empty())
            .map(str::to_owned)
            .collect(),
        portal: account.trim_end_matches('/').to_owned(),
    })
}

fn this_device() -> DeviceDescription {
    DeviceDescription {
        name: glib::host_name().to_string(),
        app_version: config::VERSION.to_owned(),
        os_version: os_name(),
    }
}

pub(crate) fn os_name() -> String {
    os_release_value("PRETTY_NAME").unwrap_or_else(|| "Linux".to_owned())
}

// The distribution and its version without the edition, such as "Fedora Linux 43", for the usage heartbeat.
pub(crate) fn os_version() -> String {
    let name = os_release_value("NAME").unwrap_or_else(|| "Linux".to_owned());
    match os_release_value("VERSION_ID") {
        Some(version) => format!("{name} {version}"),
        None => name,
    }
}

fn os_release_value(key: &str) -> Option<String> {
    match host_os_release(Path::new(FLATPAK_INFO), Path::new(HOST_OS_RELEASE)) {
        Some(os_release) => value_of(&os_release, key),
        None => glib::os_info(key)
            .map(String::from)
            .filter(|value| !value.trim().is_empty()),
    }
}

// Inside Flatpak, the os-release GLib reads is the runtime's, such as "GNOME 50".
fn host_os_release(flatpak_info: &Path, host_os_release: &Path) -> Option<String> {
    if !flatpak_info.exists() {
        return None;
    }
    std::fs::read_to_string(host_os_release).ok()
}

// GLib unquotes os-release values the same way.
fn value_of(os_release: &str, key: &str) -> Option<String> {
    let prefix = format!("{key}=");
    let value = os_release
        .lines()
        .find_map(|line| line.trim().strip_prefix(prefix.as_str()))?;
    let value = glib::shell_unquote(value).ok()?.into_string().ok()?;
    (!value.trim().is_empty()).then_some(value)
}

// The refresh token is one keyring item of its own, like the MCP token.
pub(crate) struct KeyringRefreshToken(pub Arc<SecretStore>);

#[async_trait]
impl RefreshTokenVault for KeyringRefreshToken {
    async fn load_refresh_token(&self) -> Result<Option<SecretString>, SecretError> {
        self.0.load_account_token().await
    }

    async fn store_refresh_token(&self, token: &SecretString) -> Result<(), SecretError> {
        self.0
            .store_account_token(token, &gettext("TablePro account sign-in"))
            .await
    }

    async fn delete_refresh_token(&self) -> Result<(), SecretError> {
        self.0.delete_account_token().await
    }
}

// UriLauncher belongs to the GTK thread, so the call goes there and its answer comes back.
pub(crate) struct DesktopBrowser;

#[async_trait]
impl BrowserLauncher for DesktopBrowser {
    async fn open(&self, url: &Url) -> Result<(), String> {
        let (answer, answered) = oneshot::channel();
        let uri = url.to_string();
        glib::MainContext::default().invoke(move || {
            gtk4::UriLauncher::new(&uri).launch(None::<&gtk4::Window>, gio::Cancellable::NONE, move |result| {
                let _ = answer.send(result.map_err(|error| error.to_string()));
            });
        });
        answered.await.map_err(|_| "the application stopped".to_owned())?
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FEDORA: &str =
        "NAME=\"Fedora Linux\"\nVERSION_ID=43\nPRETTY_NAME=\"Fedora Linux 43 (Workstation Edition)\"\n";

    #[test]
    fn the_pretty_name_is_read_quoted_or_bare() {
        let cases = [
            (FEDORA, Some("Fedora Linux 43 (Workstation Edition)")),
            (
                "PRETTY_NAME='Debian GNU/Linux 13 (trixie)'\n",
                Some("Debian GNU/Linux 13 (trixie)"),
            ),
            ("PRETTY_NAME=Arch\n", Some("Arch")),
            ("PRETTY_NAME=\"Say \\\"hi\\\"\"\n", Some("Say \"hi\"")),
            ("NAME=Linux\nPRETTY_NAME=\"\"\n", None),
            ("NAME=Linux\n", None),
        ];

        for (os_release, name) in cases {
            assert_eq!(value_of(os_release, "PRETTY_NAME").as_deref(), name, "{os_release:?}");
        }
    }

    #[test]
    fn the_host_name_comes_from_run_host_inside_flatpak_only() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let (flatpak_info, host) = (dir.path().join(".flatpak-info"), dir.path().join("os-release"));
        std::fs::write(&host, FEDORA).expect("the host's os-release");

        let outside = host_os_release(&flatpak_info, &host);
        std::fs::write(&flatpak_info, "[Application]\nname=app.tablepro.TablePro\n").expect("the Flatpak info");
        let inside = host_os_release(&flatpak_info, &host);
        std::fs::remove_file(&host).expect("removed");
        let without_host = host_os_release(&flatpak_info, &host);

        assert_eq!(outside, None);
        assert_eq!(
            inside
                .as_deref()
                .and_then(|text| value_of(text, "PRETTY_NAME"))
                .as_deref(),
            Some("Fedora Linux 43 (Workstation Edition)")
        );
        assert_eq!(
            inside
                .as_deref()
                .and_then(|text| value_of(text, "VERSION_ID"))
                .as_deref(),
            Some("43")
        );
        assert_eq!(without_host, None);
    }

    #[test]
    fn a_release_build_signs_in_to_tablepro_app_whatever_it_was_built_with() {
        let production = cloud(
            config::Profile::Default,
            "http://account.localhost:5284",
            "http://api.localhost:5284/v2",
            "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
        )
        .expect("the settings");
        let unset = cloud(config::Profile::Development, "", " ", "").expect("the settings");

        for chosen in [production, unset] {
            assert_eq!(chosen.endpoints, Endpoints::production());
            assert_eq!(chosen.portal, PRODUCTION_PORTAL);
            assert!(chosen.keys_x.is_empty());
        }
    }

    #[test]
    fn a_development_build_takes_a_local_stack_and_its_keys() {
        let local = cloud(
            config::Profile::Development,
            "http://account.localhost:5284/",
            "http://api.localhost:5284/v2",
            " 11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo, ",
        )
        .expect("the settings");

        assert_eq!(
            local.endpoints,
            Endpoints::new("http://account.localhost:5284", "http://api.localhost:5284/v2").expect("the endpoints")
        );
        assert_eq!(local.portal, "http://account.localhost:5284");
        assert_eq!(local.keys().expect("the keys").kids().count(), 1);
    }

    #[test]
    fn half_a_local_stack_or_a_bad_key_is_refused_rather_than_production() {
        let half = cloud(config::Profile::Development, "http://account.localhost:5284", "", "");
        let keyless = cloud(
            config::Profile::Development,
            "",
            "",
            "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
        );
        let bad_key = cloud(
            config::Profile::Development,
            "http://account.localhost:5284",
            "http://api.localhost:5284/v2",
            "not a key",
        )
        .expect("the settings")
        .keys();

        assert!(half.is_err());
        assert!(keyless.is_err());
        assert!(bad_key.is_err());
    }

    #[test]
    fn before_the_account_starts_every_feature_is_signed_out() {
        let service = AccountService::signed_out();

        assert_eq!(service.feature_access("env_var_references"), FeatureAccess::SignedOut);
    }
}
