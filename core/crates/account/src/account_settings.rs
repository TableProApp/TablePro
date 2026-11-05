use std::path::PathBuf;

use url::Url;

use crate::cloud_api::v2::types::Platform;
use crate::entitlement_keys::EntitlementKeys;
use crate::machine_id::MachineId;

// tablepro-cloud registers one public OAuth client per app, each with its own redirect: the loopback one
// this crate listens on is the Linux client's (api.md, OAuth). Another app adds its own once the server does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppClient {
    pub client_id: &'static str,
    pub platform: Platform,
    // For the User-Agent.
    pub system: &'static str,
}

impl AppClient {
    pub const LINUX: Self = Self {
        client_id: "tablepro-linux",
        platform: Platform::Linux,
        system: "Linux",
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
    pub endpoints: Endpoints,
    pub device: DeviceDescription,
    pub machine_id: MachineId,
    pub keys: EntitlementKeys,
    pub account_file: PathBuf,
    pub callback_page: CallbackPage,
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
    fn production_is_tablepro_app_over_https() {
        let endpoints = Endpoints::production();

        assert_eq!(endpoints.token, "https://account.tablepro.app/oauth/token");
        assert_eq!(endpoints.api, "https://api.tablepro.app/v2");
    }
}
