use std::io::ErrorKind;
use std::net::IpAddr;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use url::Url;

use crate::account_error::AccountError;
use crate::account_settings::Endpoints;
use crate::entitlement_keys::EntitlementKeys;
use crate::license_keys::LicenseKeys;
use crate::policy::ManagedPolicy;

// The API origin a person or an organization names tablepro.app by (core ADR 0044, App configuration).
pub(crate) const PRODUCTION_ORIGIN: &str = "https://api.tablepro.app";
const PRODUCTION_ACCOUNT_ORIGIN: &str = "https://account.tablepro.app";
const CHOICE_VERSION: u32 = 1;
// Metadata documents are a few hundred bytes; a server that sends more is not answering discovery.
const METADATA_LIMIT: usize = 64 * 1024;

// Where the account signs in.
#[derive(Debug, Clone)]
pub enum ServerSettings {
    // The organization's server, the person's, or tablepro.app. Each server's refresh token needs an item of its own.
    Resolved(ServerPolicy),
    // One server for good: tablepro.app for an app that offers no other, or a development stack. No license, nothing
    // chosen, and one refresh token item serves.
    Fixed(FixedServer),
}

impl ServerSettings {
    pub fn production() -> Self {
        Self::Fixed(FixedServer::production())
    }
}

// The managed values the host read at launch, which pick the server, and the keys a company server's license is checked
// against. `Account::apply_policy` passes values read later.
#[derive(Debug, Clone, Default)]
pub struct ServerPolicy {
    pub managed: ManagedPolicy,
    pub license_keys: LicenseKeys,
}

// A server's endpoints, and the keys and issuer of its entitlements.
#[derive(Debug, Clone)]
pub struct FixedServer {
    pub endpoints: Endpoints,
    pub keys: EntitlementKeys,
    // A tablepro-cloud stack names its API origin, `Endpoints::api_origin`.
    pub issuer: String,
}

impl FixedServer {
    pub fn production() -> Self {
        Self {
            endpoints: Endpoints::production(),
            keys: EntitlementKeys::release(),
            issuer: PRODUCTION_ORIGIN.to_owned(),
        }
    }
}

// What the app shows about the server and whether the person may pick another.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerInfo {
    pub api_origin: String,
    // None until a company server's discovery has run.
    pub account_origin: Option<String>,
    pub host: String,
    pub is_production: bool,
    // The organization named this server, and the person has not picked another.
    pub is_managed: bool,
    pub others_allowed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ServerError {
    #[error("{0:?} is not a server address")]
    NotAUrl(String),
    #[error("{0} is not https")]
    Insecure(String),
    #[error("{0} answers no TablePro server metadata ({1})")]
    NotTablePro(String, String),
    #[error("the server's {0} does not match the address asked")]
    Mismatch(&'static str),
    #[error("the organization manages which server this app signs in to")]
    Managed,
    #[error("a company server does not take {0}")]
    Unsupported(&'static str),
}

impl ServerError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotAUrl(_) => "account.server_invalid",
            Self::Insecure(_) => "account.server_insecure",
            Self::NotTablePro(..) => "account.server_not_tablepro",
            Self::Mismatch(_) => "account.server_mismatch",
            Self::Managed => "account.server_managed",
            Self::Unsupported(_) => "account.server_unsupported",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ServerKind {
    Production,
    Company,
    Development,
}

// The server the policy and the person's choice resolve to, before any request. `origin` is the API's, as
// `origin_text` writes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Target {
    pub origin: String,
    pub kind: ServerKind,
    pub managed: bool,
    pub others_allowed: bool,
}

impl Target {
    pub(crate) fn api(&self) -> String {
        format!("{}/v2", self.origin)
    }
}

// The organization's value first while it allows no other; then the person's choice; then the organization's value
// as the default; then tablepro.app. A value that is not a server address is ignored and logged.
pub(crate) fn resolve(policy: &ManagedPolicy, chosen: Option<&str>, loopback_http: bool) -> Target {
    let values = policy.values();
    let managed = values
        .and_then(|values| values.account_server_url.as_deref())
        .filter(|text| !text.trim().is_empty())
        .and_then(|text| match parse_origin(text, loopback_http) {
            Ok(origin) => Some(origin),
            Err(error) => {
                tracing::warn!(%error, "the managed account server is not used");
                None
            }
        });
    let others_allowed = match (&managed, values.and_then(|values| values.allow_other_account_servers)) {
        (Some(_), Some(false)) => false,
        (None, Some(false)) => {
            tracing::warn!("AllowOtherAccountServers is false with no AccountServerURL, so it is ignored");
            true
        }
        _ => true,
    };
    let chosen = chosen
        .filter(|_| others_allowed)
        .and_then(|text| parse_origin(text, loopback_http).ok());
    let (origin, from_policy) = match (chosen, managed) {
        (Some(chosen), managed) => {
            let same = managed.as_ref() == Some(&chosen);
            (chosen, same)
        }
        (None, Some(managed)) => (managed, true),
        (None, None) => (PRODUCTION_ORIGIN.to_owned(), false),
    };
    let kind = match origin == PRODUCTION_ORIGIN {
        true => ServerKind::Production,
        false => ServerKind::Company,
    };
    Target {
        origin,
        kind,
        managed: from_policy,
        others_allowed,
    }
}

pub(crate) fn fixed_target(server: &FixedServer) -> Target {
    let origin = server.endpoints.api_origin();
    let kind = match server.endpoints == Endpoints::production() {
        true => ServerKind::Production,
        false => ServerKind::Development,
    };
    Target {
        origin,
        kind,
        managed: false,
        others_allowed: false,
    }
}

pub(crate) fn origin_text(origin: &Url) -> String {
    origin.origin().ascii_serialization()
}

// What a person types or an organization sets: an https origin such as https://api.example.com, a bare host taken as
// https. Http only for a loopback host in a development build.
pub(crate) fn parse_origin(text: &str, loopback_http: bool) -> Result<String, ServerError> {
    let trimmed = text.trim();
    let written = match trimmed.contains("://") {
        true => trimmed.to_owned(),
        false => format!("https://{trimmed}"),
    };
    let url = Url::parse(&written).map_err(|_| ServerError::NotAUrl(trimmed.to_owned()))?;
    secure(&url, loopback_http)?;
    let plain = url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && matches!(url.path(), "" | "/");
    if !plain || url.host().is_none() {
        return Err(ServerError::NotAUrl(trimmed.to_owned()));
    }
    Ok(origin_text(&url))
}

pub(crate) fn secure(url: &Url, loopback_http: bool) -> Result<(), ServerError> {
    match url.scheme() {
        "https" => Ok(()),
        "http" if loopback_http && is_loopback(url) => Ok(()),
        "http" => Err(ServerError::Insecure(origin_text(url))),
        _ => Err(ServerError::NotAUrl(url.to_string())),
    }
}

// RFC 6761 reserves .localhost for the loopback interface.
fn is_loopback(url: &Url) -> bool {
    match url.host() {
        Some(url::Host::Ipv4(address)) => IpAddr::V4(address).is_loopback(),
        Some(url::Host::Ipv6(address)) => IpAddr::V6(address).is_loopback(),
        Some(url::Host::Domain(name)) => name == "localhost" || name.ends_with(".localhost"),
        None => false,
    }
}

// Http to a loopback host is for development stacks; a release build never takes it.
// The crate's own tests run their stub servers in every profile: the Linux packages test with --release.
pub(crate) fn loopback_http_allowed() -> bool {
    cfg!(any(debug_assertions, test))
}

// A company server's endpoints, from RFC 9728 and OpenID Connect discovery.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Discovered {
    pub resource: String,
    pub issuer: String,
    // RFC 9207: its authorization responses always name the issuer, so one that does not is refused.
    pub iss_parameter_supported: bool,
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    pub revocation_endpoint: String,
    pub jwks_uri: String,
}

impl Discovered {
    pub(crate) fn endpoints(&self) -> Endpoints {
        Endpoints {
            authorize: self.authorization_endpoint.clone(),
            token: self.token_endpoint.clone(),
            revoke: self.revocation_endpoint.clone(),
            api: format!("{}/v2", self.resource),
        }
    }
}

#[derive(Deserialize)]
struct ResourceMetadata {
    resource: String,
    #[serde(default)]
    authorization_servers: Vec<String>,
    jwks_uri: Option<String>,
}

#[derive(Deserialize)]
struct ProviderMetadata {
    issuer: String,
    authorization_endpoint: String,
    token_endpoint: String,
    revocation_endpoint: Option<String>,
    // A server from before tablepro-cloud sent `iss` leaves it out.
    #[serde(default)]
    authorization_response_iss_parameter_supported: bool,
}

// RFC 9728 section 3.3: the resource must be the origin asked. OpenID Connect Discovery section 4.3: the issuer must be
// the authorization server named. Every endpoint is https and on the issuer's origin, so a server cannot send the
// person to one sign-in page and the code to another token endpoint; the issuer is never tablepro.app's, whose tokens
// would then reach this API; and the keys come from the API's own origin.
pub(crate) async fn discover(
    http: &reqwest::Client,
    origin: &str,
    loopback_http: bool,
) -> Result<Discovered, AccountError> {
    let resource_text = origin.to_owned();
    let metadata: ResourceMetadata = fetch_json(
        http,
        &format!("{resource_text}/.well-known/oauth-protected-resource"),
        &resource_text,
    )
    .await?;
    let named = Url::parse(&metadata.resource).map_err(|_| ServerError::Mismatch("resource"))?;
    if origin_text(&named) != resource_text || !matches!(named.path(), "" | "/") {
        return Err(ServerError::Mismatch("resource").into());
    }
    let issuer = metadata
        .authorization_servers
        .first()
        .ok_or_else(|| ServerError::NotTablePro(resource_text.clone(), "no authorization server".to_owned()))?
        .clone();
    let issuer_url = Url::parse(&issuer).map_err(|_| ServerError::NotAUrl(issuer.clone()))?;
    secure(&issuer_url, loopback_http)?;
    if origin_text(&issuer_url) == PRODUCTION_ACCOUNT_ORIGIN {
        return Err(ServerError::Mismatch("issuer").into());
    }
    let provider: ProviderMetadata = fetch_json(
        http,
        &format!("{}/.well-known/openid-configuration", issuer.trim_end_matches('/')),
        &resource_text,
    )
    .await?;
    if provider.issuer != issuer {
        return Err(ServerError::Mismatch("issuer").into());
    }
    let revocation_endpoint = provider
        .revocation_endpoint
        .ok_or_else(|| ServerError::NotTablePro(resource_text.clone(), "no revocation endpoint".to_owned()))?;
    let jwks_uri = metadata
        .jwks_uri
        .ok_or_else(|| ServerError::NotTablePro(resource_text.clone(), "no jwks_uri".to_owned()))?;
    let keys = Url::parse(&jwks_uri).map_err(|_| ServerError::NotAUrl(jwks_uri.clone()))?;
    if origin_text(&keys) != resource_text {
        return Err(ServerError::Mismatch("jwks_uri").into());
    }
    for endpoint in [
        &provider.authorization_endpoint,
        &provider.token_endpoint,
        &revocation_endpoint,
    ] {
        let url = Url::parse(endpoint).map_err(|_| ServerError::NotAUrl(endpoint.clone()))?;
        secure(&url, loopback_http)?;
        if origin_text(&url) != origin_text(&issuer_url) {
            return Err(ServerError::Mismatch("OAuth endpoints").into());
        }
    }
    secure(&keys, loopback_http)?;
    Ok(Discovered {
        resource: resource_text,
        issuer,
        iss_parameter_supported: provider.authorization_response_iss_parameter_supported,
        authorization_endpoint: provider.authorization_endpoint,
        token_endpoint: provider.token_endpoint,
        revocation_endpoint,
        jwks_uri,
    })
}

async fn fetch_json<T: serde::de::DeserializeOwned>(
    http: &reqwest::Client,
    url: &str,
    server: &str,
) -> Result<T, AccountError> {
    let response = http
        .get(url)
        .header(reqwest::header::ACCEPT, "application/json")
        .send()
        .await
        .map_err(AccountError::unreachable)?;
    let status = response.status();
    if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
        return Err(crate::cloud_api::rate_limited(response.headers()));
    }
    // A server that is down is still the server; only an answer it gives says it is not TablePro's.
    if status.is_server_error() {
        return Err(AccountError::Refused {
            status: status.as_u16(),
            code: "unavailable".to_owned(),
            detail: format!("{server} answered HTTP {}", status.as_u16()),
        });
    }
    if !status.is_success() {
        return Err(ServerError::NotTablePro(server.to_owned(), format!("HTTP {}", status.as_u16())).into());
    }
    let body = read_capped(response, METADATA_LIMIT).await?;
    serde_json::from_slice(&body)
        .map_err(|error| ServerError::NotTablePro(server.to_owned(), format!("{:?}", error.classify())).into())
}

// A body past the limit is refused before it is all read.
pub(crate) async fn read_capped(mut response: reqwest::Response, limit: usize) -> Result<Vec<u8>, AccountError> {
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(AccountError::unreachable)? {
        if body.len() + chunk.len() > limit {
            return Err(AccountError::Protocol(format!(
                "the answer is larger than {limit} bytes"
            )));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

// The person's choice, kept beside the account file so a sign-out keeps it. Discovery is never kept: a file another
// process can write must not say where a refresh token goes.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Choice {
    pub chosen: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct StoredChoice {
    version: u32,
    #[serde(flatten)]
    choice: Choice,
}

pub(crate) fn choice_file(account_file: &Path) -> PathBuf {
    account_file.with_file_name("account-server.json")
}

// Read as empty when missing, unreadable or of another version: the server is then the policy's or tablepro.app.
pub(crate) fn read_choice_blocking(path: &Path) -> Choice {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == ErrorKind::NotFound => return Choice::default(),
        Err(error) => {
            tracing::warn!(%error, "the account server choice was not read");
            return Choice::default();
        }
    };
    match serde_json::from_slice::<StoredChoice>(&bytes) {
        Ok(stored) if stored.version == CHOICE_VERSION => stored.choice,
        Ok(stored) => {
            tracing::warn!(
                version = stored.version,
                "the account server choice is of another version"
            );
            Choice::default()
        }
        Err(error) => {
            tracing::warn!(%error, "the account server choice does not read");
            Choice::default()
        }
    }
}

pub(crate) async fn write_choice(path: &Path, choice: &Choice) -> Result<(), AccountError> {
    let stored = StoredChoice {
        version: CHOICE_VERSION,
        choice: choice.clone(),
    };
    let bytes = serde_json::to_vec_pretty(&stored).map_err(|error| storage_error(path, &error))?;
    let target = path.to_owned();
    tokio::task::spawn_blocking(move || tablepro_storage::fs::write_private_blocking(&target, &bytes))
        .await
        .map_err(|error| storage_error(path, &error))?
        .map_err(|error| storage_error(path, &error))
}

fn storage_error(path: &Path, error: &dyn std::fmt::Display) -> AccountError {
    AccountError::Storage {
        path: path.display().to_string(),
        detail: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy(managed: Option<&str>, allow: Option<bool>) -> ManagedPolicy {
        ManagedPolicy::Values(crate::policy::PolicyValues {
            account_server_url: managed.map(str::to_owned),
            allow_other_account_servers: allow,
            ..Default::default()
        })
    }

    fn origin(target: &Target) -> String {
        target.origin.clone()
    }

    #[test]
    fn nothing_set_is_tablepro_app() {
        let target = resolve(&policy(None, None), None, false);

        assert_eq!(origin(&target), PRODUCTION_ORIGIN);
        assert_eq!(target.kind, ServerKind::Production);
        assert!(!target.managed);
        assert!(target.others_allowed);
        assert_eq!(target.api(), "https://api.tablepro.app/v2");
    }

    #[test]
    fn the_person_s_choice_comes_before_tablepro_app() {
        let target = resolve(&policy(None, None), Some("https://api.example.com"), false);

        assert_eq!(origin(&target), "https://api.example.com");
        assert_eq!(target.kind, ServerKind::Company);
        assert!(!target.managed);
    }

    #[test]
    fn a_managed_server_that_allows_no_other_wins_over_the_person_s_choice() {
        let target = resolve(
            &policy(Some("https://tablepro.corp.example"), Some(false)),
            Some("https://api.example.com"),
            false,
        );

        assert_eq!(origin(&target), "https://tablepro.corp.example");
        assert!(target.managed);
        assert!(!target.others_allowed);
    }

    #[test]
    fn a_managed_server_that_allows_others_is_the_default_the_person_may_leave() {
        let managed = policy(Some("https://tablepro.corp.example"), None);

        let default = resolve(&managed, None, false);
        let left = resolve(&managed, Some("https://api.tablepro.app"), false);
        let same = resolve(&managed, Some("https://tablepro.corp.example/"), false);

        assert_eq!(origin(&default), "https://tablepro.corp.example");
        assert!(default.managed && default.others_allowed);
        assert_eq!(left.kind, ServerKind::Production);
        assert!(!left.managed);
        assert!(same.managed);
    }

    #[test]
    fn allow_other_servers_alone_has_nothing_to_hold_the_person_to() {
        let target = resolve(&policy(None, Some(false)), Some("https://api.example.com"), false);

        assert_eq!(origin(&target), "https://api.example.com");
        assert!(target.others_allowed);
    }

    #[test]
    fn a_managed_value_that_is_not_a_server_is_ignored() {
        let target = resolve(&policy(Some("http://tablepro.corp.example"), Some(false)), None, false);

        assert_eq!(target.kind, ServerKind::Production);
        assert!(!target.managed);
        assert!(target.others_allowed);
    }

    #[test]
    fn an_origin_is_https_with_no_path_and_a_bare_host_reads_as_https() {
        let parsed = |text: &str| parse_origin(text, false);

        assert_eq!(
            parsed("https://API.Example.com/").as_deref(),
            Ok("https://api.example.com")
        );
        assert_eq!(parsed(" api.example.com ").as_deref(), Ok("https://api.example.com"));
        assert_eq!(
            parsed("https://api.example.com:8443").as_deref(),
            Ok("https://api.example.com:8443")
        );
        assert!(matches!(
            parsed("http://api.example.com"),
            Err(ServerError::Insecure(_))
        ));
        for refused in [
            "",
            "https://api.example.com/v2",
            "https://ada@api.example.com",
            "https://api.example.com/?x=1",
            "https://api.example.com/#x",
            "ftp://api.example.com",
            "https://",
        ] {
            assert!(parsed(refused).is_err(), "{refused:?}");
        }
    }

    #[test]
    fn http_reaches_only_a_loopback_host_and_only_in_a_development_build() {
        for loopback in [
            "http://127.0.0.1:5284",
            "http://[::1]:5284",
            "http://api.localhost:5284",
        ] {
            assert!(parse_origin(loopback, true).is_ok(), "{loopback}");
            assert!(
                matches!(parse_origin(loopback, false), Err(ServerError::Insecure(_))),
                "{loopback}"
            );
        }
        assert!(matches!(
            parse_origin("http://10.0.0.1:5284", true),
            Err(ServerError::Insecure(_))
        ));
    }

    #[test]
    fn a_choice_reads_back_and_a_broken_or_newer_one_reads_as_none() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let path = choice_file(&dir.path().join("account.json"));
        let choice = Choice {
            chosen: Some("https://api.example.com".to_owned()),
        };

        tokio::runtime::Builder::new_current_thread()
            .build()
            .expect("a runtime")
            .block_on(write_choice(&path, &choice))
            .expect("written");
        let read = read_choice_blocking(&path);
        std::fs::write(&path, r#"{"version":2,"chosen":"https://api.example.com"}"#).expect("written");
        let newer = read_choice_blocking(&path);
        std::fs::write(&path, "not json").expect("written");
        let broken = read_choice_blocking(&path);

        assert_eq!(read, choice);
        assert_eq!(newer, Choice::default());
        assert_eq!(broken, Choice::default());
        assert_eq!(
            path.file_name().and_then(|name| name.to_str()),
            Some("account-server.json")
        );
    }
}
