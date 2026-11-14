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

const SCOPES: [&str; 4] = ["openid", "email", "offline_access", "app"];
// The server's access token lifetime, for an answer without expires_in.
const ACCESS_TOKEN_LIFETIME: Duration = Duration::from_secs(15 * 60);

type Client = BasicClient<EndpointSet, EndpointNotSet, EndpointNotSet, EndpointNotSet, EndpointSet>;

pub(crate) struct OAuth {
    client: Client,
    app: AppClient,
    http: reqwest::Client,
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
