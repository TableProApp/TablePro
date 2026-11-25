use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use aws_lc_rs::digest;
use tablepro_cloud_api::v2::types::Platform;
use url::Url;

use crate::machine_id::MachineId;
use crate::server::{ServerSettings, origin_text};

// tablepro-cloud registers one public OAuth client per app, each with its own redirect: Linux's and Windows's take
// the loopback one this crate listens on, on any port (api.md, OAuth). The Mac's is a custom scheme, which the host's
// web authenticator answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppClient {
    pub client_id: &'static str,
    pub platform: Platform,
    // For the User-Agent.
    pub system: &'static str,
    pub redirect: Redirect,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Redirect {
    // RFC 8252 section 7.3, on any port.
    Loopback,
    // RFC 8252 section 7.1: `<scheme>:/oauth/callback`.
    Scheme(&'static str),
}

impl Redirect {
    pub(crate) const CALLBACK_PATH: &'static str = "/oauth/callback";
}

impl AppClient {
    pub const LINUX: Self = Self {
        client_id: "tablepro-linux",
        platform: Platform::Linux,
        system: "Linux",
        redirect: Redirect::Loopback,
    };

    pub const WINDOWS: Self = Self {
        client_id: "tablepro-windows",
        platform: Platform::Windows,
        system: "Windows",
        redirect: Redirect::Loopback,
    };

    pub const MACOS: Self = Self {
        client_id: "tablepro-macos",
        platform: Platform::Macos,
        system: "macOS",
        redirect: Redirect::Scheme("app.tablepro"),
    };
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoints {
    pub(crate) authorize: String,
    pub(crate) token: String,
    pub(crate) revoke: String,
    pub(crate) api: String,
}

impl Endpoints {
    pub fn production() -> Self {
        Self::under("https://account.tablepro.app", "https://api.tablepro.app/v2")
    }

    pub fn new(account: &str, api: &str) -> Result<Self, url::ParseError> {
        let (account, api) = (Url::parse(account)?, Url::parse(api)?);
        Ok(Self::under(
            account.as_str().trim_end_matches('/'),
            api.as_str().trim_end_matches('/'),
        ))
    }

    fn under(account: &str, api: &str) -> Self {
        Self {
            authorize: format!("{account}/oauth/authorize"),
            token: format!("{account}/oauth/token"),
            revoke: format!("{account}/oauth/revoke"),
            api: api.to_owned(),
        }
    }

    // What a tablepro-cloud stack names as its entitlements' issuer and its licenses' origin.
    pub fn api_origin(&self) -> String {
        Url::parse(&self.api).map_or_else(|_| self.api.clone(), |url| origin_text(&url))
    }

    pub(crate) fn account_origin(&self) -> String {
        Url::parse(&self.authorize).map_or_else(|_| self.authorize.clone(), |url| origin_text(&url))
    }

    pub(crate) fn api(&self) -> &str {
        &self.api
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceDescription {
    pub name: String,
    pub app_version: String,
    pub os_version: String,
}

// The browser's page after the redirect, translated by the app.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CallbackPage {
    pub finished: String,
    pub unknown: String,
}

#[derive(Debug, Clone)]
pub struct AccountSettings {
    pub client: AppClient,
    pub server: ServerSettings,
    pub device: DeviceDescription,
    pub machine_id: MachineId,
    pub account_file: PathBuf,
    pub callback_page: CallbackPage,
    // The Mac's entitlement from before the core kept its account, adopted once while `account_file` is missing.
    pub legacy_entitlement_file: Option<PathBuf>,
}

// Names one sign-in among the others a user's secret store can hold: another server, or another build's state folder,
// keeps a refresh token of its own.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SignInKey {
    pub key: String,
    // tablepro.app's own service, which a sign-in kept before the key existed was always for.
    pub production: bool,
}

impl SignInKey {
    // 16 hex characters of SHA-256 over the API and the account file.
    pub fn of(api: &str, account_file: &Path) -> Self {
        let named = format!("{api}\n{}", account_file.display());
        let hash = digest::digest(&digest::SHA256, named.as_bytes());
        let key = hash
            .as_ref()
            .iter()
            .take(8)
            .fold(String::with_capacity(16), |mut text, byte| {
                let _ = write!(text, "{byte:02x}");
                text
            });
        Self {
            key,
            production: api == Endpoints::production().api,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_oauth_endpoints_hang_off_the_issuer() {
        let endpoints =
            Endpoints::new("http://account.localhost:5284", "http://api.localhost:5284/v2/").expect("the endpoints");

        assert_eq!(endpoints.authorize, "http://account.localhost:5284/oauth/authorize");
        assert_eq!(endpoints.token, "http://account.localhost:5284/oauth/token");
        assert_eq!(endpoints.revoke, "http://account.localhost:5284/oauth/revoke");
        assert_eq!(endpoints.api, "http://api.localhost:5284/v2");
    }

    #[test]
    fn each_app_signs_in_as_its_own_client_platform_and_redirect() {
        assert_eq!(
            (AppClient::LINUX.client_id, AppClient::LINUX.platform.to_string()),
            ("tablepro-linux", "linux".to_owned())
        );
        assert_eq!(
            (AppClient::WINDOWS.client_id, AppClient::WINDOWS.platform.to_string()),
            ("tablepro-windows", "windows".to_owned())
        );
        assert_eq!(
            (AppClient::MACOS.client_id, AppClient::MACOS.platform.to_string()),
            ("tablepro-macos", "macos".to_owned())
        );
        assert_eq!(AppClient::LINUX.redirect, Redirect::Loopback);
        assert_eq!(AppClient::MACOS.redirect, Redirect::Scheme("app.tablepro"));
    }

    #[test]
    fn each_server_and_state_folder_signs_in_under_a_key_of_its_own() {
        let file = Path::new("C:/Users/a/LocalState/account.json");
        let production = SignInKey::of("https://api.tablepro.app/v2", file);
        let local = SignInKey::of("http://api.localhost:5284/v2", file);
        let other_build = SignInKey::of(
            "https://api.tablepro.app/v2",
            Path::new("C:/Users/a/Dev/LocalState/account.json"),
        );
        // python3 -c 'import hashlib;print(hashlib.sha256(b"https://api.tablepro.app/v2\nC:/Users/a/LocalState/account.json").hexdigest()[:16])'
        let expected = "e6989de2b8e8cbc0";

        assert_eq!(production.key, expected);
        assert_ne!(production.key, local.key);
        assert_ne!(production.key, other_build.key);
        assert!(production.production && other_build.production);
        assert!(!local.production);
    }

    #[test]
    fn the_api_origin_is_the_issuer_a_stack_names() {
        let endpoints =
            Endpoints::new("http://account.localhost:5284", "http://api.localhost:5284/v2/").expect("the endpoints");

        assert_eq!(endpoints.api_origin(), "http://api.localhost:5284");
        assert_eq!(endpoints.account_origin(), "http://account.localhost:5284");
        assert_eq!(Endpoints::production().api_origin(), "https://api.tablepro.app");
    }

    #[test]
    fn production_is_tablepro_app_over_https() {
        let endpoints = Endpoints::production();

        assert_eq!(endpoints.token, "https://account.tablepro.app/oauth/token");
        assert_eq!(endpoints.api, "https://api.tablepro.app/v2");
    }
}
