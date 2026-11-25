use std::sync::Arc;

use crate::account_error::AccountError;
use crate::account_settings::{AccountSettings, AppClient, Endpoints, SignInKey};
use crate::entitlement_keys::EntitlementKeys;
use crate::license::License;
use crate::license_keys::LicenseKeys;
use crate::loopback::ExpectedIssuer;
use crate::oauth::OAuth;
use crate::server::{
    Discovered, PRODUCTION_ORIGIN, ServerError, ServerInfo, ServerKind, ServerSettings, Target, fixed_target,
};
use crate::token_vault::{RefreshTokenVault, RefreshTokenVaults};

// The server the account talks to, replaced whole when the person picks another or discovery runs. Only changed while
// the session is held, so a call that holds it sees one server throughout.
pub(crate) struct Server {
    pub target: Target,
    // What the person picked, as kept in account-server.json.
    pub chosen: Option<String>,
    pub api: String,
    // None for a company server until this run's discovery has answered.
    pub connection: Option<Connection>,
    pub trust: Trust,
    // The `iss` its entitlements name: the API origin.
    pub issuer: String,
    pub vault: Arc<dyn RefreshTokenVault>,
    pub sign_in: SignInKey,
}

pub(crate) struct Connection {
    pub endpoints: Endpoints,
    pub oauth: OAuth,
    pub discovered: Option<Discovered>,
}

#[derive(Clone)]
pub(crate) enum Trust {
    // tablepro.app's keys compiled in, or a development stack's.
    Fixed(EntitlementKeys),
    // A company server's keys, admitted only through its license (core ADR 0044, How an app trusts a customer's server).
    Licensed(LicenseKeys),
}

// What a company server's license admitted: the license and the keys its JWKS named, with both as they came.
#[derive(Clone)]
pub(crate) struct Licensed {
    pub license: Arc<License>,
    pub keys: EntitlementKeys,
    pub jwks: String,
}

impl Server {
    pub(crate) fn build(
        settings: &AccountSettings,
        http: &reqwest::Client,
        vaults: &dyn RefreshTokenVaults,
        target: Target,
        chosen: Option<String>,
        discovered: Option<Discovered>,
    ) -> Result<Self, AccountError> {
        let client = settings.client;
        let (api, endpoints, trust, issuer) = match (&settings.server, target.kind) {
            (ServerSettings::Fixed(fixed), _) => (
                fixed.endpoints.api().to_owned(),
                Some((fixed.endpoints.clone(), None)),
                Trust::Fixed(fixed.keys.clone()),
                fixed.issuer.clone(),
            ),
            (ServerSettings::Resolved(_), ServerKind::Production | ServerKind::Development) => (
                target.api(),
                Some((Endpoints::production(), None)),
                Trust::Fixed(EntitlementKeys::release()),
                PRODUCTION_ORIGIN.to_owned(),
            ),
            (ServerSettings::Resolved(policy), ServerKind::Company) => {
                let usable = discovered.filter(|discovered| discovered.resource == target.origin);
                (
                    target.api(),
                    usable.map(|discovered| (discovered.endpoints(), Some(discovered))),
                    Trust::Licensed(policy.license_keys.clone()),
                    target.origin.clone(),
                )
            }
        };
        let connection = endpoints
            .map(|(endpoints, discovered)| connect(client, http, endpoints, discovered))
            .transpose()?;
        let sign_in = SignInKey::of(&api, &settings.account_file);
        Ok(Self {
            target,
            chosen,
            api,
            connection,
            trust,
            issuer,
            vault: vaults.vault(&sign_in),
            sign_in,
        })
    }

    pub(crate) fn initial(
        settings: &AccountSettings,
        http: &reqwest::Client,
        vaults: &dyn RefreshTokenVaults,
    ) -> Result<Self, AccountError> {
        match &settings.server {
            ServerSettings::Fixed(fixed) => Self::build(settings, http, vaults, fixed_target(fixed), None, None),
            ServerSettings::Resolved(policy) => {
                let choice = crate::server::read_choice_blocking(&crate::server::choice_file(&settings.account_file));
                let loopback = crate::server::loopback_http_allowed();
                let target = crate::server::resolve(policy, choice.chosen.as_deref(), loopback);
                Self::build(settings, http, vaults, target, choice.chosen, None)
            }
        }
    }

    // The same server with the endpoints discovery found.
    pub(crate) fn discovered(
        &self,
        client: AppClient,
        http: &reqwest::Client,
        discovered: Discovered,
    ) -> Result<Self, AccountError> {
        let endpoints = discovered.endpoints();
        Ok(Self {
            target: self.target.clone(),
            chosen: self.chosen.clone(),
            api: self.api.clone(),
            connection: Some(connect(client, http, endpoints, Some(discovered))?),
            trust: self.trust.clone(),
            issuer: self.issuer.clone(),
            vault: self.vault.clone(),
            sign_in: self.sign_in.clone(),
        })
    }

    pub(crate) fn connection(&self) -> Result<&Connection, AccountError> {
        self.connection.as_ref().ok_or_else(|| {
            AccountError::Server(ServerError::NotTablePro(
                self.target.origin.clone(),
                "not discovered yet".to_owned(),
            ))
        })
    }

    // RFC 9207 section 2.4. A company server's discovery says whether its answers name it. tablepro.app's always do, which
    // the build knows as it knows its endpoints; a development stack may predate that.
    pub(crate) fn expected_issuer(&self) -> Result<ExpectedIssuer, AccountError> {
        let connection = self.connection()?;
        Ok(match &connection.discovered {
            Some(discovered) => ExpectedIssuer {
                issuer: discovered.issuer.clone(),
                required: discovered.iss_parameter_supported,
            },
            None => ExpectedIssuer {
                issuer: connection.endpoints.account_origin(),
                required: self.target.kind == ServerKind::Production,
            },
        })
    }

    pub(crate) fn is_company(&self) -> bool {
        self.target.kind == ServerKind::Company
    }

    pub(crate) fn info(&self) -> ServerInfo {
        let host = url::Url::parse(&self.target.origin)
            .ok()
            .and_then(|url| url.host_str().map(str::to_owned))
            .unwrap_or_else(|| self.target.origin.clone());
        ServerInfo {
            api_origin: self.target.origin.clone(),
            account_origin: self
                .connection
                .as_ref()
                .map(|connection| connection.endpoints.account_origin()),
            host,
            is_production: self.target.kind == ServerKind::Production,
            is_managed: self.target.managed,
            others_allowed: self.target.others_allowed,
        }
    }
}

fn connect(
    client: AppClient,
    http: &reqwest::Client,
    endpoints: Endpoints,
    discovered: Option<Discovered>,
) -> Result<Connection, AccountError> {
    Ok(Connection {
        oauth: OAuth::new(client, &endpoints, http.clone())?,
        endpoints,
        discovered,
    })
}
