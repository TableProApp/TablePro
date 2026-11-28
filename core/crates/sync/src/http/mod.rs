// The TablePro Sync transport (0051, Protocol; 0054, Transports): `/v2/sync` over HTTP for one sign-in. It is bound
// to that sign-in when it opens, so a call made after the sign-in ended or changed is refused rather than sent under
// another account. Each call carries the bearer, and the device's DPoP proof where the caller names one.

mod account;
mod errors;
mod wire;

use std::sync::{Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use reqwest::header::{AUTHORIZATION, ETAG, HeaderMap, HeaderValue};
use reqwest::{Method, RequestBuilder, Response, StatusCode};
use secrecy::{ExposeSecret as _, SecretString};
use tablepro_cloud_api::v2::types;
use tablepro_cloud_api::{ApiError, StepUpChallenge, dpop_nonce, dpop_nonce_challenge, read_capped};
use tablepro_keys::dpop::{DpopRequest, proof as dpop_proof};
use tablepro_keys::encoding::{AccountId, Origin, TeamId, Version};

use crate::api::ids::{Cursor, DeviceRowId, ScopeName};
use crate::api::scopes::ScopesAnswer;
use crate::api::transport::{
    DpopKey, Proof, PullRequest, PulledPage, PushAnswer, PushBatch, ServiceTransport, Transport, TransportError,
};

// A page stops at 4 MiB of records but never inside a change set, which can itself take a 4 MiB push and its 10,000
// records' columns (0051, Limits; Pull), so a page is bounded well above both. A push's answer holds one outcome per
// change, up to 10,000, and a scopes body one member row per seat of every team.
const PAGE_BYTES: usize = 32 << 20;
const ANSWER_BYTES: usize = 8 << 20;
const DPOP: &str = "DPoP";
const IDEMPOTENCY_KEY: &str = "Idempotency-Key";

// The sign-in a bearer is of.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignedInAs {
    // The `/v2` base, `https://api.tablepro.app/v2`.
    pub api: String,
    pub origin: String,
    // The sign-in key, which names the server and the account file.
    pub sign_in: String,
    pub account_id: Option<String>,
    pub device_id: Option<String>,
    pub session_id: Option<String>,
}

// A bearer and the sign-in it is of, read in one hold of the account's session (K2 hazard 13).
#[derive(Debug, Clone)]
pub struct SignedIn {
    pub token: SecretString,
    pub of: SignedInAs,
}

#[async_trait]
pub trait SignIn: Send + Sync {
    // The sign-in as the account holds it, with no call: the transport binds to it, so an engine opens offline.
    async fn signed_in_as(&self) -> Result<SignedInAs, TransportError>;

    async fn signed_in(&self) -> Result<SignedIn, TransportError>;

    // The server answered 401 to this token, so the next read refreshes it.
    async fn rejected(&self, token: &SecretString);
}

// What the transport was opened for, which every later call must still be.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Binding {
    pub api: String,
    pub origin: Origin,
    pub sign_in: String,
    pub account: AccountId,
    pub device_row: DeviceRowId,
    session_id: Option<String>,
}

impl Binding {
    fn of(signed_in: &SignedInAs) -> Result<Self, TransportError> {
        let account = signed_in.account_id.as_deref().and_then(wire::account);
        let device_row = signed_in.device_id.clone().map(DeviceRowId);
        let origin = Origin::parse(&signed_in.origin).map_err(|_| TransportError::Server {
            status: 0,
            code: "sync.bad_origin".to_owned(),
            retry_after_ms: None,
        })?;
        match (account, device_row) {
            (Some(account), Some(device_row)) if wire::device_row_ok(&device_row) => Ok(Self {
                api: signed_in.api.trim_end_matches('/').to_owned(),
                origin,
                sign_in: signed_in.sign_in.clone(),
                account,
                device_row,
                session_id: signed_in.session_id.clone(),
            }),
            // Not registered yet, as over the device limit, or a sign-in the server named no account for.
            _ => Err(TransportError::SignedOut),
        }
    }

    // The sign-in's id in the account's process, which a sign-in or a restore renews.
    pub fn session_id(&self) -> Option<&str> {
        self.session_id.as_deref()
    }

    // The same sign-in as the one the transport opened for: server, account, device row and session.
    pub fn holds(&self, signed_in: &SignedInAs) -> bool {
        Self::of(signed_in).is_ok_and(|now| now == *self)
    }
}

pub struct HttpTransport {
    sign_in: std::sync::Arc<dyn SignIn>,
    http: reqwest::Client,
    binding: Binding,
    // The server's last `DPoP-Nonce`, which the next proof carries (RFC 9449 section 8).
    nonce: Mutex<Option<String>>,
}

impl std::fmt::Debug for HttpTransport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HttpTransport")
            .field("binding", &self.binding)
            .finish_non_exhaustive()
    }
}

// What one try of a call sends, rebuilt for each retry with a fresh proof.
struct Call<'a> {
    method: Method,
    path: String,
    query: Vec<(&'static str, String)>,
    headers: Vec<(&'static str, String)>,
    body: Option<Vec<u8>>,
    proof: Option<&'a DpopKey>,
}

impl HttpTransport {
    // Reads the sign-in once and keeps it; an account with no device row yet is not one to sync.
    pub async fn open(sign_in: std::sync::Arc<dyn SignIn>, http: reqwest::Client) -> Result<Self, TransportError> {
        let binding = Binding::of(&sign_in.signed_in_as().await?)?;
        Ok(Self {
            sign_in,
            http,
            binding,
            nonce: Mutex::new(None),
        })
    }

    pub fn binding(&self) -> &Binding {
        &self.binding
    }

    fn nonce(&self) -> MutexGuard<'_, Option<String>> {
        self.nonce.lock().unwrap_or_else(PoisonError::into_inner)
    }

    async fn token(&self) -> Result<SecretString, TransportError> {
        let now = self.sign_in.signed_in().await?;
        if !self.binding.holds(&now.of) {
            return Err(TransportError::SignedOut);
        }
        Ok(now.token)
    }

    fn request(&self, call: &Call<'_>, token: &SecretString) -> Result<RequestBuilder, TransportError> {
        let url = format!("{}{}", self.binding.api, call.path);
        let mut request = self
            .http
            .request(call.method.clone(), &url)
            .header(AUTHORIZATION, sensitive(&format!("Bearer {}", token.expose_secret()))?);
        if !call.query.is_empty() {
            request = request.query(&call.query);
        }
        for (name, value) in &call.headers {
            request = request.header(*name, value);
        }
        if let Some(key) = call.proof {
            let nonce = self.nonce().clone();
            let iat = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |since| since.as_secs());
            let signed = dpop_proof(
                &key.0,
                DpopRequest {
                    method: call.method.as_str(),
                    url: &url,
                    access_token: token.expose_secret(),
                    iat,
                    nonce: nonce.as_deref(),
                },
            )
            .map_err(|error| TransportError::Server {
                status: 0,
                code: error.code().to_owned(),
                retry_after_ms: None,
            })?;
            request = request.header(DPOP, sensitive(&signed)?);
        }
        if let Some(body) = &call.body {
            request = request
                .header(reqwest::header::CONTENT_TYPE, "application/json")
                .body(body.clone());
        }
        Ok(request)
    }

    // One retry with the server's nonce and one with a fresh token; a 401 after both ends the sign-in's calls. Every
    // other answer goes back to the caller as it came.
    async fn send(&self, call: &Call<'_>) -> Result<Response, TransportError> {
        let (mut nonce_retried, mut token_retried) = (false, false);
        loop {
            let token = self.token().await?;
            let answer = self
                .request(call, &token)?
                .send()
                .await
                .map_err(|error| TransportError::Network {
                    detail: tablepro_cloud_api::http_text(error),
                })?;
            if let Some(nonce) = dpop_nonce(answer.headers()) {
                *self.nonce() = Some(nonce);
            }
            if answer.status() != StatusCode::UNAUTHORIZED {
                return Ok(answer);
            }
            if let Some(challenge) = StepUpChallenge::from_headers(answer.headers()) {
                return Err(errors::step_up(challenge));
            }
            if call.proof.is_some() && dpop_nonce_challenge(answer.headers()).is_some() {
                if nonce_retried {
                    return Err(TransportError::UseDpopNonce);
                }
                nonce_retried = true;
                continue;
            }
            if token_retried {
                return Err(TransportError::SignedOut);
            }
            token_retried = true;
            self.sign_in.rejected(&token).await;
        }
    }

    async fn body(answer: Response, limit: usize) -> Result<(StatusCode, HeaderMap, Vec<u8>), TransportError> {
        let (status, headers) = (answer.status(), answer.headers().clone());
        let body = read_capped(answer, limit).await.map_err(|error| match error {
            ApiError::Unreachable(detail) => TransportError::Network { detail },
            // Past the cap: a retry reads the same answer, so no status lets the scheduler try again.
            _ => TransportError::Server {
                status: 0,
                code: "answer_too_large".to_owned(),
                retry_after_ms: None,
            },
        })?;
        Ok((status, headers, body))
    }

    // A 2xx answer's body; any other status as its refusal.
    async fn answered(&self, call: &Call<'_>, limit: usize) -> Result<Vec<u8>, TransportError> {
        let (status, headers, body) = Self::body(self.send(call).await?, limit).await?;
        if status.is_success() {
            Ok(body)
        } else {
            Err(errors::refusal(status, &headers, &body))
        }
    }

    fn proof(proof: &Proof) -> Option<&DpopKey> {
        match proof {
            Proof::None => None,
            Proof::Dpop(key) => Some(key),
        }
    }
}

// A credential in a header, which a request's Debug never prints.
fn sensitive(value: &str) -> Result<HeaderValue, TransportError> {
    let mut header = HeaderValue::from_str(value).map_err(|_| TransportError::Server {
        status: 0,
        code: "bad_credential".to_owned(),
        retry_after_ms: None,
    })?;
    header.set_sensitive(true);
    Ok(header)
}

fn stopped_path(team: TeamId) -> String {
    format!("/sync/scopes/{}/stopped", ScopeName::Team(team).wire())
}

#[async_trait]
impl Transport for HttpTransport {
    async fn pull(&self, request: PullRequest) -> Result<PulledPage, TransportError> {
        let mut query = Vec::new();
        match request.cursor {
            None => {}
            Some(Cursor::Service(cursor)) => query.push(("cursor", cursor)),
            Some(Cursor::CloudKit(_)) => return Err(TransportError::ValidationFailed),
        }
        if let Some(limit) = request.limit {
            query.push(("limit", limit.to_string()));
        }
        let call = Call {
            method: Method::GET,
            path: format!("/sync/scopes/{}/changes", request.scope.wire()),
            query,
            headers: Vec::new(),
            body: None,
            proof: Self::proof(&request.proof),
        };
        let body = self.answered(&call, PAGE_BYTES).await?;
        wire::page(&body).map_err(|_| errors::malformed(StatusCode::OK))
    }

    async fn push(&self, batch: PushBatch) -> Result<PushAnswer, TransportError> {
        let (Some(epoch), Some(key)) = (batch.epoch, &batch.idempotency_key) else {
            return Err(TransportError::ValidationFailed);
        };
        let body = wire::push_body(epoch, &batch.changes).map_err(|_| TransportError::ValidationFailed)?;
        let call = Call {
            method: Method::POST,
            path: format!("/sync/scopes/{}/changes", batch.scope.wire()),
            query: Vec::new(),
            headers: vec![(IDEMPOTENCY_KEY, key.0.clone())],
            body: Some(body),
            proof: Self::proof(&batch.proof),
        };
        let answer = self.answered(&call, ANSWER_BYTES).await?;
        let outcomes = wire::outcomes(&answer, &batch.changes).map_err(|_| errors::malformed(StatusCode::OK))?;
        Ok(PushAnswer { outcomes })
    }
}

#[async_trait]
impl ServiceTransport for HttpTransport {
    async fn scopes(&self, if_none_match: Option<String>, proof: Proof) -> Result<ScopesAnswer, TransportError> {
        let call = Call {
            method: Method::GET,
            path: "/sync/scopes".to_owned(),
            query: Vec::new(),
            headers: if_none_match
                .iter()
                .map(|etag| ("If-None-Match", etag.clone()))
                .collect(),
            body: None,
            proof: Self::proof(&proof),
        };
        let (status, headers, body) = Self::body(self.send(&call).await?, ANSWER_BYTES).await?;
        match status {
            StatusCode::NOT_MODIFIED if if_none_match.is_some() => Ok(ScopesAnswer::NotModified),
            // 0051, Releases: a server with no `/v2/sync`.
            StatusCode::NOT_FOUND => Err(TransportError::ServerTooOld),
            status if status.is_success() => {
                let parsed: types::SyncScopes = serde_json::from_slice(&body).map_err(|_| errors::malformed(status))?;
                let etag = headers
                    .get(ETAG)
                    .and_then(|value| value.to_str().ok())
                    .ok_or_else(|| errors::malformed(status))?
                    .to_owned();
                Ok(ScopesAnswer::Body {
                    body: Box::new(wire::scopes(parsed).map_err(|_| errors::malformed(status))?),
                    etag,
                })
            }
            status => Err(errors::refusal(status, &headers, &body)),
        }
    }

    async fn revoke_key_device(&self, proof: DpopKey) -> Result<(), TransportError> {
        let call = Call {
            method: Method::DELETE,
            path: "/sync/key-device".to_owned(),
            query: Vec::new(),
            headers: Vec::new(),
            body: None,
            proof: Some(&proof),
        };
        self.answered(&call, ANSWER_BYTES).await.map(|_| ())
    }

    async fn report_stopped(&self, team: TeamId, version: Version, proof: DpopKey) -> Result<(), TransportError> {
        let call = Call {
            method: Method::PUT,
            path: stopped_path(team),
            query: Vec::new(),
            headers: Vec::new(),
            body: Some(format!(r#"{{"version":{}}}"#, version.get()).into_bytes()),
            proof: Some(&proof),
        };
        self.answered(&call, ANSWER_BYTES).await.map(|_| ())
    }

    async fn withdraw_stopped(&self, team: TeamId, proof: DpopKey) -> Result<(), TransportError> {
        let call = Call {
            method: Method::DELETE,
            path: stopped_path(team),
            query: Vec::new(),
            headers: Vec::new(),
            body: None,
            proof: Some(&proof),
        };
        self.answered(&call, ANSWER_BYTES).await.map(|_| ())
    }

    async fn remove_device_row(&self, device: DeviceRowId, proof: DpopKey) -> Result<(), TransportError> {
        if !wire::device_row_ok(&device) {
            return Err(TransportError::ValidationFailed);
        }
        let call = Call {
            method: Method::DELETE,
            path: format!("/devices/{}", device.0),
            query: Vec::new(),
            headers: Vec::new(),
            body: None,
            proof: Some(&proof),
        };
        self.answered(&call, ANSWER_BYTES).await.map(|_| ())
    }
}

#[cfg(test)]
mod tests;
