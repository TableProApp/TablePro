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
use tablepro_cloud_api::{ANSWER_TIMEOUT, StepUpChallenge, rate_limited, read_capped, schema_mismatch};
use url::Url;

use crate::account_error::AccountError;
use crate::account_settings::{AppClient, DeviceDescription, Endpoints};
use crate::machine_id::MachineId;

const SCOPES: [&str; 4] = ["openid", "email", "offline_access", "app"];
// The server's access token lifetime, for an answer without expires_in.
const ACCESS_TOKEN_LIFETIME: Duration = Duration::from_secs(15 * 60);
// RFC 8693, with tablepro-cloud's own subject token type (api.md, Legacy key exchange).
const TOKEN_EXCHANGE: &str = "urn:ietf:params:oauth:grant-type:token-exchange";
const LICENSE_KEY_TOKEN_TYPE: &str = "https://account.tablepro.app/token-types/license-key";
// A token answer is a few kilobytes, as is a refused revocation's OAuth error.
const TOKEN_ANSWER_LIMIT: usize = 64 * 1024;
const REVOKE_DETAIL_LIMIT: usize = 4 * 1024;
// RFC 6749 section 5.2 and RFC 7009 section 2.2.1: the codes a refused revocation can name.
const REVOCATION_ERRORS: [&str; 7] = [
    "invalid_request",
    "invalid_client",
    "invalid_grant",
    "unauthorized_client",
    "unsupported_token_type",
    "server_error",
    "temporarily_unavailable",
];

type Client = BasicClient<EndpointSet, EndpointNotSet, EndpointNotSet, EndpointNotSet, EndpointSet>;

pub(crate) struct OAuth {
    client: Client,
    app: AppClient,
    http: reqwest::Client,
    token: String,
    revoke: String,
    // How long a token call waits for the server's answer to start.
    answer_within: Duration,
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
            answer_within: ANSWER_TIMEOUT,
        })
    }

    #[cfg(test)]
    pub(crate) fn answering_within(mut self, within: Duration) -> Self {
        self.answer_within = within;
        self
    }

    // The machine's fields name it on the confirmation screen. A step-up asks for what its challenge named (RFC 9470
    // section 4).
    pub(crate) fn authorization(
        &self,
        redirect_uri: String,
        device: &DeviceDescription,
        step_up: Option<&StepUpChallenge>,
    ) -> Result<Authorization, AccountError> {
        let redirect_uri = RedirectUrl::new(redirect_uri).map_err(protocol)?;
        let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
        let mut request = self
            .client
            .authorize_url(CsrfToken::new_random)
            .set_redirect_uri(Cow::Borrowed(&redirect_uri))
            .add_scopes(SCOPES.map(|scope| Scope::new(scope.to_owned())))
            .set_pkce_challenge(challenge)
            .add_extra_param("machine_name", device.name.clone())
            .add_extra_param("app_version", device.app_version.clone())
            .add_extra_param("os_version", device.os_version.clone());
        if let Some(step_up) = step_up {
            if !step_up.acr_values.is_empty() {
                request = request.add_extra_param("acr_values", step_up.acr_values.join(" "));
            }
            if let Some(max_age) = step_up.max_age_secs {
                request = request.add_extra_param("max_age", max_age.to_string());
            }
        }
        let (url, state) = request.url();
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
        let noted = Arc::new(OnceLock::new());
        let http = |request| execute(self.http.clone(), request, self.answer_within, noted.clone());
        let answer = self
            .client
            .exchange_code(AuthorizationCode::new(code))
            .set_pkce_verifier(authorization.verifier)
            .set_redirect_uri(Cow::Owned(authorization.redirect_uri))
            .request_async(&http)
            .await;
        answer.map(tokens).map_err(|error| grant_error(error, noted.get()))
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
            return Err(rate_limited(response.headers()).into());
        }
        let body = read_capped(response, TOKEN_ANSWER_LIMIT).await?;
        match status.is_success() {
            true => exchanged(&body),
            false => Err(exchange_refused(status.as_u16(), &body)),
        }
    }

    pub(crate) async fn refresh(&self, refresh: &SecretString) -> Result<Tokens, AccountError> {
        let noted = Arc::new(OnceLock::new());
        let http = |request| execute(self.http.clone(), request, self.answer_within, noted.clone());
        let token = RefreshToken::new(refresh.expose_secret().to_owned());
        let answer = self.client.exchange_refresh_token(&token).request_async(&http).await;
        answer.map(tokens).map_err(|error| grant_error(error, noted.get()))
    }

    // RFC 7009 by hand: oauth2 refuses a revocation URL that is not https. A refusal keeps only a standard error code:
    // its body may echo the token, and callers log the error.
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
            false => {
                let status = response.status().as_u16();
                let detail = read_capped(response, REVOKE_DETAIL_LIMIT)
                    .await
                    .ok()
                    .and_then(|body| serde_json::from_slice::<ExchangeRefusal>(&body).ok())
                    .and_then(|refusal| REVOCATION_ERRORS.into_iter().find(|code| *code == refusal.error))
                    .unwrap_or_default()
                    .to_owned();
                Err(AccountError::Refused {
                    status,
                    code: "revoke".to_owned(),
                    detail,
                })
            }
        }
    }
}

// oauth2 keeps neither the status nor the headers of an error answer, so a 429 is noted here, and a 5xx, whose body
// may be a proxy's page, keeps its status for the caller's backoff. A server that sends no answer within `within` is
// noted as out of reach.
async fn execute(
    client: reqwest::Client,
    request: HttpRequest,
    within: Duration,
    noted: Arc<OnceLock<AccountError>>,
) -> Result<HttpResponse, HttpClientError<reqwest::Error>> {
    let (parts, body) = request.into_parts();
    let sent = client
        .request(parts.method, parts.uri.to_string())
        .headers(parts.headers)
        .body(body)
        .send();
    let Ok(sent) = tokio::time::timeout(within, sent).await else {
        let detail = format!("no answer within {within:?}");
        drop(noted.set(AccountError::Unreachable(detail.clone())));
        return Err(HttpClientError::Other(detail));
    };
    let mut response = sent.map_err(Box::new)?;
    let status = response.status();
    if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
        drop(noted.set(rate_limited(response.headers()).into()));
    } else if status.is_server_error() {
        drop(noted.set(AccountError::Refused {
            status: status.as_u16(),
            code: format!("http_{}", status.as_u16()),
            detail: String::new(),
        }));
    }
    let mut answer = http::Response::builder().status(response.status());
    if let Some(headers) = answer.headers_mut() {
        headers.extend(response.headers().clone());
    }
    // A server the person typed in answers here before anything vouches for it, so its answer is cut off at the cap.
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(Box::new)? {
        if body.len() + chunk.len() > TOKEN_ANSWER_LIMIT {
            return Err(HttpClientError::Other(format!(
                "the answer is larger than {TOKEN_ANSWER_LIMIT} bytes"
            )));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(answer.body(body)?)
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
    let answer: ExchangeAnswer =
        serde_json::from_slice(body).map_err(|error| AccountError::Protocol(schema_mismatch(&error)))?;
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
    noted: Option<&AccountError>,
) -> AccountError {
    if let Some(noted) = noted {
        return noted.clone();
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
        RequestTokenError::Request(HttpClientError::Other(detail)) => AccountError::Protocol(detail),
        other => AccountError::Protocol(other.to_string()),
    }
}

fn protocol(error: url::ParseError) -> AccountError {
    AccountError::Protocol(error.to_string())
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead as _, BufReader, Read as _, Write as _};

    use super::*;

    // A revocation endpoint that refuses with `body`.
    fn refusing(body: &'static str) -> Endpoints {
        answering(500, body)
    }

    // Every endpoint answers `status` with `body`.
    fn answering(status: u16, body: &'static str) -> Endpoints {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
        let base = format!("http://{}", listener.local_addr().expect("its address"));
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let mut reader = BufReader::new(stream.try_clone().expect("a second handle"));
                let mut length = 0;
                loop {
                    let mut line = String::new();
                    reader.read_line(&mut line).expect("a line");
                    if line.trim().is_empty() {
                        break;
                    }
                    if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                        length = value.trim().parse().expect("a length");
                    }
                }
                let mut request = vec![0; length];
                reader.read_exact(&mut request).expect("the body");
                let mut stream = stream;
                write!(
                    stream,
                    "HTTP/1.1 {status} Stub\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                )
                .expect("the answer");
            }
        });
        Endpoints::new(&base, &format!("{base}/v2")).expect("the endpoints")
    }

    async fn refusal(body: &'static str) -> AccountError {
        let oauth = OAuth::new(AppClient::LINUX, &refusing(body), reqwest::Client::new()).expect("a client");
        oauth
            .revoke(&SecretString::from("live-refresh-token"))
            .await
            .expect_err("refused")
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_refused_revocation_keeps_a_standard_code_and_never_the_body() {
        let echoed = refusal(r#"{"error":"server_error","error_description":"bad token live-refresh-token"}"#).await;
        let named = refusal(r#"{"error":"live-refresh-token"}"#).await;
        let page = refusal("<html>live-refresh-token</html>").await;

        assert!(
            matches!(&echoed, AccountError::Refused { status: 500, code, detail } if code == "revoke" && detail == "server_error"),
            "{echoed:?}"
        );
        for error in [&echoed, &named, &page] {
            assert!(
                !format!("{error} {error:?}").contains("live-refresh-token"),
                "{error:?}"
            );
        }
    }

    // E2E F21: a paused server held the launch refresh for the client's whole request timeout.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_refresh_a_server_never_answers_is_out_of_reach_within_the_answer_window() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
        let base = format!("http://{}", listener.local_addr().expect("its address"));
        std::thread::spawn(move || {
            let mut held = Vec::new();
            for stream in listener.incoming().flatten() {
                held.push(stream);
            }
        });
        let endpoints = Endpoints::new(&base, &format!("{base}/v2")).expect("the endpoints");
        let oauth = OAuth::new(AppClient::LINUX, &endpoints, reqwest::Client::new())
            .expect("a client")
            .answering_within(Duration::from_millis(300));
        let started = std::time::Instant::now();

        let Err(refused) = oauth.refresh(&SecretString::from("refresh")).await else {
            panic!("a server that never answered gave tokens");
        };

        assert!(matches!(&refused, AccountError::Unreachable(_)), "{refused:?}");
        assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_refresh_a_proxy_answers_with_a_5xx_page_keeps_the_status() {
        let oauth = OAuth::new(
            AppClient::LINUX,
            &answering(502, "<html>Bad Gateway</html>"),
            reqwest::Client::new(),
        )
        .expect("a client");

        let Err(refused) = oauth.refresh(&SecretString::from("refresh")).await else {
            panic!("a 502 gave tokens");
        };

        assert!(
            matches!(&refused, AccountError::Refused { status: 502, code, .. } if code == "http_502"),
            "{refused:?}"
        );
    }
}
