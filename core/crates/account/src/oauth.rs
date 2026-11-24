use std::borrow::Cow;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use oauth2::basic::{BasicClient, BasicErrorResponseType, BasicTokenResponse};
use oauth2::{
    AuthUrl, AuthorizationCode, ClientId, CsrfToken, EndpointNotSet, EndpointSet, HttpClientError, HttpRequest,
    HttpResponse, PkceCodeChallenge, PkceCodeVerifier, RedirectUrl, RefreshToken, RequestTokenError, Scope,
    TokenResponse, TokenUrl,
};
use secrecy::{ExposeSecret, SecretString};
use url::Url;

use crate::account_error::AccountError;
use crate::account_settings::{AppClient, DeviceDescription, Endpoints};
use crate::cloud_api::rate_limited;
use crate::machine_id::MachineId;
use crate::server::read_capped;

const SCOPES: [&str; 4] = ["openid", "email", "offline_access", "app"];
// The server's access token lifetime, for an answer without expires_in.
const ACCESS_TOKEN_LIFETIME: Duration = Duration::from_secs(15 * 60);
// RFC 8693, with tablepro-cloud's own subject token type (api.md, Legacy key exchange).
const TOKEN_EXCHANGE: &str = "urn:ietf:params:oauth:grant-type:token-exchange";
const LICENSE_KEY_TOKEN_TYPE: &str = "https://account.tablepro.app/token-types/license-key";
// A token answer is a few kilobytes.
const TOKEN_ANSWER_LIMIT: usize = 64 * 1024;

type Client = BasicClient<EndpointSet, EndpointNotSet, EndpointNotSet, EndpointNotSet, EndpointSet>;

pub(crate) struct OAuth {
    client: Client,
    app: AppClient,
    http: reqwest::Client,
    token: String,
    revoke: String,
}

pub(crate) struct Authorization {
    pub url: Url,
    pub state: CsrfToken,
    pub verifier: PkceCodeVerifier,
    pub redirect_uri: RedirectUrl,
}

pub(crate) struct Tokens {
    pub access: SecretString,
    pub lifetime: Duration,
    pub refresh: Option<SecretString>,
}

impl OAuth {
    pub(crate) fn new(app: AppClient, endpoints: &Endpoints, http: reqwest::Client) -> Result<Self, AccountError> {
        let client = BasicClient::new(ClientId::new(app.client_id.to_owned()))
            .set_auth_uri(AuthUrl::new(endpoints.authorize.clone()).map_err(protocol)?)
            .set_token_uri(TokenUrl::new(endpoints.token.clone()).map_err(protocol)?);
        Ok(Self {
            client,
            app,
            http,
            token: endpoints.token.clone(),
            revoke: endpoints.revoke.clone(),
        })
    }

    // The machine's fields name it on the confirmation screen.
    pub(crate) fn authorization(
        &self,
        redirect_uri: String,
        device: &DeviceDescription,
    ) -> Result<Authorization, AccountError> {
        let redirect_uri = RedirectUrl::new(redirect_uri).map_err(protocol)?;
        let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
        let (url, state) = self
            .client
            .authorize_url(CsrfToken::new_random)
            .set_redirect_uri(Cow::Borrowed(&redirect_uri))
            .add_scopes(SCOPES.map(|scope| Scope::new(scope.to_owned())))
            .set_pkce_challenge(challenge)
            .add_extra_param("machine_name", device.name.clone())
            .add_extra_param("app_version", device.app_version.clone())
            .add_extra_param("os_version", device.os_version.clone())
            .url();
        Ok(Authorization {
            url,
            state,
            verifier,
            redirect_uri,
        })
    }

    pub(crate) async fn exchange_code(
        &self,
        code: String,
        authorization: Authorization,
    ) -> Result<Tokens, AccountError> {
        let limited = Arc::new(OnceLock::new());
        let http = |request| execute(self.http.clone(), request, limited.clone());
        let answer = self
            .client
            .exchange_code(AuthorizationCode::new(code))
            .set_pkce_verifier(authorization.verifier)
            .set_redirect_uri(Cow::Owned(authorization.redirect_uri))
            .request_async(&http)
            .await;
        answer.map(tokens).map_err(|error| grant_error(error, limited.get()))
    }

    // A license key stored by a Mac from before accounts, traded for tokens already bound to this machine's device.
    pub(crate) async fn exchange_license_key(
        &self,
        key: &SecretString,
        machine_id: &MachineId,
        device: &DeviceDescription,
    ) -> Result<Tokens, AccountError> {
        let scope = SCOPES.join(" ");
        let form = [
            ("grant_type", TOKEN_EXCHANGE),
            ("client_id", self.app.client_id),
            ("subject_token", key.expose_secret()),
            ("subject_token_type", LICENSE_KEY_TOKEN_TYPE),
            ("scope", &scope),
            ("machine_id", machine_id.as_str()),
            ("machine_name", &device.name),
            ("platform", &self.app.platform.to_string()),
            ("app_version", &device.app_version),
            ("os_version", &device.os_version),
        ];
        let response = self
            .http
            .post(&self.token)
            .header(reqwest::header::ACCEPT, "application/json")
            .form(&form)
            .send()
            .await
            .map_err(AccountError::unreachable)?;
        let status = response.status();
        if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            return Err(rate_limited(response.headers()));
        }
        let body = read_capped(response, TOKEN_ANSWER_LIMIT).await?;
        match status.is_success() {
            true => exchanged(&body),
            false => Err(exchange_refused(status.as_u16(), &body)),
        }
    }

    pub(crate) async fn refresh(&self, refresh: &SecretString) -> Result<Tokens, AccountError> {
        let limited = Arc::new(OnceLock::new());
        let http = |request| execute(self.http.clone(), request, limited.clone());
        let token = RefreshToken::new(refresh.expose_secret().to_owned());
        let answer = self.client.exchange_refresh_token(&token).request_async(&http).await;
        answer.map(tokens).map_err(|error| grant_error(error, limited.get()))
    }

    // RFC 7009 by hand: oauth2 refuses a revocation URL that is not https.
    pub(crate) async fn revoke(&self, refresh: &SecretString) -> Result<(), AccountError> {
        let form = [
            ("token", refresh.expose_secret()),
            ("token_type_hint", "refresh_token"),
            ("client_id", self.app.client_id),
        ];
        let response = self
            .http
            .post(&self.revoke)
            .form(&form)
            .send()
            .await
            .map_err(AccountError::unreachable)?;
        match response.status().is_success() {
            true => Ok(()),
            false => Err(AccountError::Refused {
                status: response.status().as_u16(),
                code: "revoke".to_owned(),
                detail: response.text().await.unwrap_or_default(),
            }),
        }
    }
}

// oauth2 keeps neither the status nor the headers of an error answer, so a 429 is noted here.
async fn execute(
    client: reqwest::Client,
    request: HttpRequest,
    limited: Arc<OnceLock<AccountError>>,
) -> Result<HttpResponse, HttpClientError<reqwest::Error>> {
    let (parts, body) = request.into_parts();
    let response = client
        .request(parts.method, parts.uri.to_string())
        .headers(parts.headers)
        .body(body)
        .send()
        .await
        .map_err(Box::new)?;
    if response.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
        drop(limited.set(rate_limited(response.headers())));
    }
    let mut answer = http::Response::builder().status(response.status());
    if let Some(headers) = answer.headers_mut() {
        headers.extend(response.headers().clone());
    }
    let body = response.bytes().await.map_err(Box::new)?;
    Ok(answer.body(body.to_vec())?)
}

#[derive(serde::Deserialize)]
struct ExchangeAnswer {
    access_token: String,
    expires_in: Option<u64>,
    refresh_token: Option<String>,
}

#[derive(serde::Deserialize)]
struct ExchangeRefusal {
    error: String,
    error_description: Option<String>,
}

fn exchanged(body: &[u8]) -> Result<Tokens, AccountError> {
    let answer: ExchangeAnswer = serde_json::from_slice(body)
        .map_err(|error| AccountError::Protocol(crate::cloud_api::schema_mismatch(&error)))?;
    if answer.access_token.is_empty() {
        return Err(AccountError::Protocol("the exchange gave no access token".to_owned()));
    }
    Ok(Tokens {
        access: SecretString::from(answer.access_token),
        lifetime: answer.expires_in.map_or(ACCESS_TOKEN_LIFETIME, Duration::from_secs),
        refresh: answer.refresh_token.map(SecretString::from),
    })
}

// invalid_grant here is the key: unknown, its license revoked or its account locked.
fn exchange_refused(status: u16, body: &[u8]) -> AccountError {
    match serde_json::from_slice::<ExchangeRefusal>(body) {
        Ok(refusal) if refusal.error == "invalid_grant" => AccountError::SignInRefused {
            error: refusal.error,
            description: refusal.error_description,
        },
        Ok(refusal) => AccountError::Refused {
            status,
            code: refusal.error,
            detail: refusal.error_description.unwrap_or_default(),
        },
        Err(_) => AccountError::Protocol(format!("HTTP {status} without an OAuth error")),
    }
}

fn tokens(response: BasicTokenResponse) -> Tokens {
    Tokens {
        access: SecretString::from(response.access_token().secret().to_owned()),
        lifetime: response.expires_in().unwrap_or(ACCESS_TOKEN_LIFETIME),
        refresh: response
            .refresh_token()
            .map(|token| SecretString::from(token.secret().to_owned())),
    }
}

// invalid_grant: the token's family was revoked, its device removed, or a token replayed.
fn grant_error(
    error: RequestTokenError<HttpClientError<reqwest::Error>, oauth2::basic::BasicErrorResponse>,
    limited: Option<&AccountError>,
) -> AccountError {
    if let Some(limited) = limited {
        return limited.clone();
    }
    match error {
        RequestTokenError::ServerResponse(answer) if *answer.error() == BasicErrorResponseType::InvalidGrant => {
            AccountError::SignedOut
        }
        RequestTokenError::ServerResponse(answer) => AccountError::Refused {
            status: 400,
            code: answer.error().to_string(),
            detail: answer.error_description().cloned().unwrap_or_default(),
        },
        RequestTokenError::Request(HttpClientError::Reqwest(error)) => AccountError::unreachable(*error),
        other => AccountError::Protocol(other.to_string()),
    }
}

fn protocol(error: url::ParseError) -> AccountError {
    AccountError::Protocol(error.to_string())
}
