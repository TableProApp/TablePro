use std::sync::Arc;
use std::sync::atomic::Ordering;

use aws_lc_rs::hmac;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::Utc;
use reqwest::StatusCode;
use reqwest::header::{ACCEPT, AUTHORIZATION};
use secrecy::{ExposeSecret as _, SecretString};
use serde::Deserialize;

use super::{AccessToken, Account, Call, Licensed, Server, Session, SignOutCause, Trust};
use crate::account_error::AccountError;
use crate::account_file::{self, AccountFile};
use crate::account_settings::SignInKey;
use crate::account_status::{AccountStatus, EntitlementProblem};
use crate::cloud_api::{rate_limited, refusal};
use crate::entitlement::EntitlementError;
use crate::entitlement_keys::EntitlementKeys;
use crate::license::{License, LicenseError};
use crate::license_keys::LicenseKeys;
use crate::server::{
    self, Choice, ServerError, ServerKind, ServerSettings, choice_file, loopback_http_allowed, parse_origin,
    read_capped, write_choice,
};

// A license is a few kilobytes and a JWKS lists two keys.
const LICENSE_LIMIT: usize = 64 * 1024;
const JWKS_LIMIT: usize = 64 * 1024;
// The Mac's entitlement file holds one token.
const LEGACY_LIMIT: u64 = 64 * 1024;

#[derive(Deserialize)]
struct LicenseAnswer {
    license: String,
}

impl Account {
    // A company server's endpoints, from this run's discovery, found again when `fresh`. The session must be held, so
    // the server changes under no other call.
    pub(super) async fn connection(&self, _held: &mut Session, fresh: bool) -> Result<Arc<Server>, AccountError> {
        let server = self.current();
        if !server.is_company() || (server.connection.is_some() && !fresh) {
            return Ok(server);
        }
        let discovered = server::discover(&self.inner.http, &server.target.origin, loopback_http_allowed()).await?;
        let connected = Arc::new(server.discovered(self.inner.settings.client, &self.inner.http, discovered)?);
        self.inner.server.send_replace(connected.clone());
        Ok(connected)
    }

    // The person's pick: a company server's API origin, or None for the organization's server or tablepro.app. A
    // server other than the one signed in to signs out of that one first; the same one keeps the sign-in.
    pub async fn choose_server(&self, url: Option<&str>) -> Result<(), AccountError> {
        let ServerSettings::Resolved(policy) = &self.inner.settings.server else {
            return Err(ServerError::Managed.into());
        };
        let loopback = loopback_http_allowed();
        let chosen = url.map(|text| parse_origin(text, loopback)).transpose()?;
        let mut session = self.inner.session.lock().await;
        let current = self.current();
        if !current.target.others_allowed {
            return Err(ServerError::Managed.into());
        }
        let target = server::resolve(policy, chosen.as_deref(), loopback);
        let discovered = match target.kind {
            ServerKind::Company => Some(server::discover(&self.inner.http, &target.origin, loopback).await?),
            ServerKind::Production | ServerKind::Development => None,
        };
        let path = choice_file(&self.inner.settings.account_file);
        write_choice(&path, &Choice { chosen: chosen.clone() }).await?;
        let next = Server::build(
            &self.inner.settings,
            &self.inner.http,
            self.inner.vaults.as_ref(),
            target,
            chosen,
            discovered,
        )?;
        self.inner.attempts.fetch_add(1, Ordering::SeqCst);
        if next.target.origin != current.target.origin {
            if let Some(refresh) = session.refresh.clone() {
                // A run that started offline has not found the previous server's endpoints yet.
                let revoked = match self.connection(&mut session, false).await {
                    Ok(previous) => match previous.connection() {
                        Ok(connection) => connection.oauth.revoke(&refresh).await,
                        Err(error) => Err(error),
                    },
                    Err(error) => Err(error),
                };
                if let Err(error) = revoked {
                    tracing::warn!(%error, "the previous server's sign-in was not revoked");
                }
            }
            self.forget(&mut session, SignOutCause::ServerChanged).await;
        }
        tracing::info!(
            production = next.target.kind == ServerKind::Production,
            "chose the account server"
        );
        self.inner.server.send_replace(Arc::new(next));
        self.inner.status.send_modify(|_| {});
        Ok(())
    }

    // GET /v2/license, then the JWKS it admits (core ADR 0044, How an app trusts a customer's server).
    pub(super) async fn fetch_license(&self, session: &mut Session, keys: &LicenseKeys) -> Result<(), AccountError> {
        session.waited(Call::License)?;
        let server = self.current();
        let access = self.access(session, false).await?;
        let fetched = self.license_token(&server.api, &access).await;
        let token = session.answered(Call::License, fetched)?;
        let license = Arc::new(License::verify(&token, keys, &server.target.origin, Utc::now())?);
        // The license applies before the keys come, so a JWKS that fails to load never keeps what it took away.
        if let Some(licensed) = session.licensed.as_mut() {
            licensed.license = license.clone();
            self.relicense(session).await;
        }
        let jwks_uri = server
            .connection()?
            .discovered
            .as_ref()
            .map(|discovered| discovered.jwks_uri.clone())
            .ok_or_else(|| ServerError::NotTablePro(server.target.origin.clone(), "no jwks_uri".to_owned()))?;
        let jwks = self.jwks(&jwks_uri).await?;
        let keys = EntitlementKeys::from_jwks(jwks.as_bytes())
            .map_err(|error| ServerError::NotTablePro(server.target.origin.clone(), error.to_string()))?;
        session.licensed = Some(Licensed { license, keys, jwks });
        Ok(())
    }

    // By hand, not through the generated client, so a server that sends more than a license is cut off.
    async fn license_token(&self, api: &str, access: &SecretString) -> Result<String, AccountError> {
        let response = self
            .inner
            .http
            .get(format!("{api}/license"))
            .header(ACCEPT, "application/json")
            .header(AUTHORIZATION, format!("Bearer {}", access.expose_secret()))
            .send()
            .await
            .map_err(AccountError::unreachable)?;
        let status = response.status();
        if status == StatusCode::TOO_MANY_REQUESTS {
            return Err(rate_limited(response.headers()));
        }
        let body = read_capped(response, LICENSE_LIMIT).await?;
        if !status.is_success() {
            return Err(match refusal(status.as_u16(), &body) {
                AccountError::Refused { code, .. } if code == "license_not_installed" => {
                    LicenseError::NotInstalled.into()
                }
                other => other,
            });
        }
        serde_json::from_slice::<LicenseAnswer>(&body)
            .map(|answer| answer.license)
            .map_err(|error| AccountError::Protocol(crate::cloud_api::schema_mismatch(&error)))
    }

    async fn jwks(&self, uri: &str) -> Result<String, AccountError> {
        let response = self
            .inner
            .http
            .get(uri)
            .header(ACCEPT, "application/json")
            .send()
            .await
            .map_err(AccountError::unreachable)?;
        let status = response.status();
        if !status.is_success() {
            return Err(ServerError::NotTablePro(uri.to_owned(), format!("HTTP {}", status.as_u16())).into());
        }
        let body = read_capped(response, JWKS_LIMIT).await?;
        String::from_utf8(body).map_err(|_| AccountError::Protocol("the JWKS is not UTF-8".to_owned()))
    }

    // The license and keys a company server gave last time, checked again now: a key revoked since admits nothing,
    // and keys whose tag this sign-in did not write are not taken.
    pub(super) fn licensed_from(
        &self,
        file: &AccountFile,
        refresh: &SecretString,
    ) -> Result<Option<Licensed>, AccountError> {
        let server = self.current();
        let Trust::Licensed(keys) = &server.trust else {
            return Ok(None);
        };
        let (Some(token), Some(jwks)) = (file.license.as_deref(), file.entitlement_keys.as_deref()) else {
            return Ok(None);
        };
        let license = License::verify(token, keys, &server.target.origin, Utc::now())?;
        let keys = EntitlementKeys::from_jwks(jwks.as_bytes())
            .map_err(|error| ServerError::NotTablePro(server.target.origin.clone(), error.to_string()))?;
        let licensed = Licensed {
            license: Arc::new(license),
            keys,
            jwks: jwks.to_owned(),
        };
        let tagged = file
            .trust_tag
            .as_deref()
            .is_some_and(|tag| trust_tag_matches(tag, refresh, &server.api, &licensed));
        if !tagged {
            tracing::warn!("the kept license and keys are not this sign-in's, so the next refresh fetches them");
            return Ok(None);
        }
        Ok(Some(licensed))
    }

    // A license just verified applies at once to the entitlement held, before the next one comes, and is kept.
    pub(super) async fn relicense(&self, session: &mut Session) {
        let held = match &*self.inner.status.borrow() {
            AccountStatus::SignedIn(signed_in) => Some((
                signed_in.entitlement.as_ref().map(|it| it.token().to_owned()),
                signed_in.problem.clone(),
            )),
            AccountStatus::SignedOut | AccountStatus::Offline(_) => None,
        };
        let Some((token, problem)) = held else {
            return;
        };
        let (entitlement, expired) = match token.as_deref() {
            Some(token) => self.kept(session, token),
            None => (None, None),
        };
        self.write_file(session, entitlement.as_ref().map(|it| it.token().to_owned()))
            .await;
        self.publish(session, entitlement, expired.or(problem));
    }

    // A bearer for the app's own /v2 calls, such as the Team Library's, refreshed first when it is about to end.
    pub async fn access_token(&self) -> Result<AccessToken, AccountError> {
        let mut session = self.inner.session.lock().await;
        let taken = self.access(&mut session, false).await;
        let token = self.ended_by(&mut session, taken).await?;
        Ok(AccessToken {
            token,
            api: self.current().api.clone(),
        })
    }

    // The API answered 401 to this token, so the next call refreshes it, whatever its expiry says.
    pub async fn access_token_rejected(&self, token: &SecretString) {
        let mut session = self.inner.session.lock().await;
        if session
            .access
            .as_ref()
            .is_some_and(|(held, _)| held.expose_secret() == token.expose_secret())
        {
            session.access = None;
        }
    }

    // A Mac's license key from before accounts, traded for a sign-in on tablepro.app (api.md, Legacy key exchange). A
    // company server never sees one.
    pub async fn use_license_key(&self, key: &SecretString) -> Result<(), AccountError> {
        let attempt = self.inner.attempts.fetch_add(1, Ordering::SeqCst) + 1;
        let server = {
            let mut session = self.inner.session.lock().await;
            self.connection(&mut session, false).await?
        };
        if server.is_company() {
            return Err(ServerError::Unsupported("a license key").into());
        }
        let settings = &self.inner.settings;
        let tokens = server
            .connection()?
            .oauth
            .exchange_license_key(key, &settings.machine_id, &settings.device)
            .await?;
        tracing::info!("exchanged a license key for a sign-in");
        self.commit_sign_in(attempt, &server, tokens).await
    }

    // The Mac kept its entitlement in Account/entitlement.jwt and its refresh token in the Keychain. With no
    // account.json yet, they sign this run in as they were, with the device the entitlement names, so nothing
    // registers again. True when signed in.
    pub(super) async fn adopt_legacy(&self, session: &mut Session) -> bool {
        let Some(path) = self.inner.settings.legacy_entitlement_file.clone() else {
            return false;
        };
        if self.current().target.kind == ServerKind::Company {
            return false;
        }
        let Some(token) = read_legacy(&path).await else {
            return false;
        };
        let refresh = match self.current().vault.load_refresh_token().await {
            Ok(Some(refresh)) => refresh,
            Ok(None) => return self.adopt_offline_file(session, &path, &token).await,
            Err(error) => {
                tracing::warn!(%error, "the keyring gave no account sign-in, so the Mac's entitlement waits for the next run");
                return false;
            }
        };
        *session = Session {
            refresh: Some(refresh),
            remembered: true,
            ..Session::default()
        };
        let (entitlement, problem) = match self.verify(session, &token, Utc::now()) {
            Ok(entitlement) => (Some(entitlement), None),
            Err(AccountError::Entitlement(EntitlementError::Expired(at))) => {
                (self.lapsed(session, &token, at), Some(EntitlementProblem::Expired))
            }
            Err(error) => {
                tracing::info!(%error, "the Mac's entitlement is not this machine's, so the device registers again");
                (None, None)
            }
        };
        if let Some(entitlement) = &entitlement {
            session.device_id = Some(entitlement.claims().dev.clone());
            session.account_id = Some(entitlement.claims().sub.clone());
        }
        let file = self.file_for(session, entitlement.as_ref().map(|it| it.token().to_owned()));
        // Until account.json holds the sign-in, the old file is the only thing that opens the Keychain next launch.
        match account_file::write(&self.inner.settings.account_file, &file).await {
            Ok(()) => remove_legacy(&path).await,
            Err(error) => tracing::warn!(%error, "the account file was not written, so the Mac's entitlement stays"),
        }
        tracing::info!(device = session.device_id.is_some(), "adopted the Mac's sign-in");
        self.publish(session, entitlement, problem);
        true
    }

    // With no sign-in, the Mac kept an imported offline file in the same place. One that still verifies for this
    // machine becomes the account file's offline file; anything else is a sign-in that ended.
    async fn adopt_offline_file(&self, session: &mut Session, path: &std::path::Path, token: &str) -> bool {
        let offline = self
            .verify(session, token, Utc::now())
            .ok()
            .filter(|entitlement| entitlement.claims().offline);
        let Some(entitlement) = offline else {
            remove_legacy(path).await;
            return false;
        };
        let file = AccountFile {
            account_id: Some(entitlement.claims().sub.clone()),
            entitlement: Some(token.to_owned()),
            offline_only: true,
            server: Some(self.current().api.clone()),
            ..AccountFile::default()
        };
        match account_file::write(&self.inner.settings.account_file, &file).await {
            Ok(()) => remove_legacy(path).await,
            Err(error) => tracing::warn!(%error, "the account file was not written, so the Mac's offline file stays"),
        }
        *session = Session::default();
        tracing::info!("adopted the Mac's offline file");
        self.inner
            .status
            .send_replace(AccountStatus::Offline(Box::new(entitlement)));
        true
    }

    // An account file of a server this run does not sign in to, as when the organization named another: its token
    // goes from the keyring and the run starts signed out.
    pub(super) async fn leave_other_server(&self, session: &mut Session, api: &str) {
        let vault = self
            .inner
            .vaults
            .vault(&SignInKey::of(api, &self.inner.settings.account_file));
        if let Err(error) = vault.delete_refresh_token().await {
            tracing::warn!(%error, "the other server's sign-in was not removed from the keyring");
        }
        if let Err(error) = account_file::remove(&self.inner.settings.account_file).await {
            tracing::warn!(%error, "the account file was not removed");
        }
        self.signed_out(session);
        let _ = self.inner.sign_outs.send(SignOutCause::ServerChanged);
    }
}

// HMAC-SHA256 keyed with the refresh token, which only the platform's secret store holds, over what the tag binds.
pub(super) fn trust_tag(refresh: &SecretString, api: &str, licensed: &Licensed) -> String {
    let key = hmac::Key::new(hmac::HMAC_SHA256, refresh.expose_secret().as_bytes());
    URL_SAFE_NO_PAD.encode(hmac::sign(&key, &tagged(api, licensed)))
}

fn trust_tag_matches(tag: &str, refresh: &SecretString, api: &str, licensed: &Licensed) -> bool {
    let Ok(tag) = URL_SAFE_NO_PAD.decode(tag) else {
        return false;
    };
    let key = hmac::Key::new(hmac::HMAC_SHA256, refresh.expose_secret().as_bytes());
    hmac::verify(&key, &tagged(api, licensed), &tag).is_ok()
}

fn tagged(api: &str, licensed: &Licensed) -> Vec<u8> {
    [api, licensed.license.token(), &licensed.jwks].join("\0").into_bytes()
}

async fn read_legacy(path: &std::path::Path) -> Option<String> {
    let path = path.to_owned();
    let read = tokio::task::spawn_blocking(move || {
        use std::io::Read as _;
        let file = std::fs::File::open(&path)?;
        let mut text = String::new();
        file.take(LEGACY_LIMIT).read_to_string(&mut text)?;
        Ok::<_, std::io::Error>(text)
    })
    .await;
    match read {
        Ok(Ok(text)) => Some(text.trim().to_owned()).filter(|token| !token.is_empty()),
        Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotFound => None,
        Ok(Err(error)) => {
            tracing::warn!(%error, "the Mac's entitlement was not read");
            None
        }
        Err(error) => {
            tracing::warn!(%error, "the Mac's entitlement was not read");
            None
        }
    }
}

// The account file is its one home from here.
async fn remove_legacy(path: &std::path::Path) {
    match tokio::fs::remove_file(path).await {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => tracing::warn!(%error, "the Mac's entitlement was not removed"),
    }
}
