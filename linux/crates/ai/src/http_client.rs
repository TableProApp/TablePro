use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use http::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HeaderName, HeaderValue, USER_AGENT};
use http::{Method, Request, Response, StatusCode};
use http_body_util::{BodyExt, Full, Limited};
use hyper::body::Incoming;
use hyper_rustls::{HttpsConnector, HttpsConnectorBuilder};
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::TokioExecutor;
use secrecy::ExposeSecret;

use crate::protocol::Protocol;
use crate::{AiError, Endpoint};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
/// A busy provider can queue a request for a while before it answers.
const HEADERS_TIMEOUT: Duration = Duration::from_secs(120);
const ERROR_BODY_LIMIT: usize = 64 * 1024;
const ERROR_MESSAGE_CHARS: usize = 500;

const API_KEY: HeaderName = HeaderName::from_static("x-api-key");
const ANTHROPIC_VERSION: HeaderName = HeaderName::from_static("anthropic-version");

/// The one HTTP client every request goes through. TLS is rustls on
/// aws-lc-rs with the system's trust store, as for the database drivers.
/// Redirects are not followed, so a key never leaves the host it was
/// given for.
#[derive(Clone)]
pub struct AiClient {
    http: Client<HttpsConnector<HttpConnector>, Full<Bytes>>,
    user_agent: HeaderValue,
    output_limits: Arc<Mutex<OutputLimits>>,
}

/// Each model's output limit once read, by base URL and model.
type OutputLimits = HashMap<(String, String), Option<u32>>;

impl AiClient {
    pub fn new(version: &str) -> Result<Self, AiError> {
        let tls = tablepro_net::tls::build_client_config(&tablepro_core::TlsConfig::verify_full())
            .map_err(|error| AiError::Tls(error.to_string()))?
            .ok_or_else(|| AiError::Tls("verification is off".to_owned()))?;
        let mut connector = HttpConnector::new();
        connector.enforce_http(false);
        connector.set_connect_timeout(Some(CONNECT_TIMEOUT));
        let https = HttpsConnectorBuilder::new()
            .with_tls_config((*tls).clone())
            .https_or_http()
            .enable_http1()
            .wrap_connector(connector);
        let user_agent =
            HeaderValue::from_str(&format!("TablePro/{version}")).unwrap_or(HeaderValue::from_static("TablePro"));
        Ok(Self {
            http: Client::builder(TokioExecutor::new()).build(https),
            user_agent,
            output_limits: Arc::default(),
        })
    }

    pub(crate) fn known_output_limit(&self, endpoint: &Endpoint) -> Option<Option<u32>> {
        let limits = self.output_limits.lock().ok()?;
        limits
            .get(&(endpoint.base_url().to_owned(), endpoint.model().to_owned()))
            .copied()
    }

    pub(crate) fn remember_output_limit(&self, endpoint: &Endpoint, limit: Option<u32>) {
        if let Ok(mut limits) = self.output_limits.lock() {
            limits.insert((endpoint.base_url().to_owned(), endpoint.model().to_owned()), limit);
        }
    }

    /// Send a request and hand back a successful response; any other
    /// status is read into an error.
    pub(crate) async fn send(
        &self,
        endpoint: &Endpoint,
        method: Method,
        path: &str,
        body: Option<Vec<u8>>,
        accept: &'static str,
    ) -> Result<Response<Incoming>, AiError> {
        let request = self.request(endpoint, method, path, body, accept)?;
        let response = tokio::time::timeout(HEADERS_TIMEOUT, self.http.request(request))
            .await
            .map_err(|_| AiError::TimedOut {
                host: endpoint.host().to_owned(),
            })?
            .map_err(|error| AiError::Unreachable {
                host: endpoint.host().to_owned(),
                detail: error_chain(&error),
            })?;
        if response.status().is_success() {
            return Ok(response);
        }
        let status = response.status();
        let message = read_error_message(response).await;
        Err(status_error(endpoint, status, message))
    }

    fn request(
        &self,
        endpoint: &Endpoint,
        method: Method,
        path: &str,
        body: Option<Vec<u8>>,
        accept: &'static str,
    ) -> Result<Request<Full<Bytes>>, AiError> {
        let mut builder = Request::builder()
            .method(method)
            .uri(endpoint.url(path))
            .header(USER_AGENT, self.user_agent.clone())
            .header(ACCEPT, accept);
        if body.is_some() {
            builder = builder.header(CONTENT_TYPE, "application/json");
        }
        if let Some(key) = endpoint.key() {
            let mut value = match Protocol::of(endpoint.kind()) {
                Protocol::AnthropicMessages => HeaderValue::from_str(key.expose_secret()),
                Protocol::ChatCompletions => HeaderValue::from_str(&format!("Bearer {}", key.expose_secret())),
            }
            .map_err(|_| AiError::InvalidKey)?;
            value.set_sensitive(true);
            let name = match Protocol::of(endpoint.kind()) {
                Protocol::AnthropicMessages => API_KEY,
                Protocol::ChatCompletions => AUTHORIZATION,
            };
            builder = builder.header(name, value);
        }
        if Protocol::of(endpoint.kind()) == Protocol::AnthropicMessages {
            builder = builder.header(ANTHROPIC_VERSION, crate::anthropic::API_VERSION);
        }
        let bytes = body.map_or_else(Bytes::new, Bytes::from);
        builder.body(Full::new(bytes)).map_err(|_| AiError::InvalidAddress)
    }
}

/// The whole body of a successful response, up to `limit` bytes.
pub(crate) async fn read_body(response: Response<Incoming>, limit: usize, host: &str) -> Result<Bytes, AiError> {
    let body = Limited::new(response.into_body(), limit);
    match tokio::time::timeout(HEADERS_TIMEOUT, body.collect()).await {
        Err(_) => Err(AiError::TimedOut { host: host.to_owned() }),
        Ok(Err(error)) if error.is::<http_body_util::LengthLimitError>() => Err(AiError::TooLong),
        Ok(Err(error)) => Err(AiError::Unreachable {
            host: host.to_owned(),
            detail: error.to_string(),
        }),
        Ok(Ok(collected)) => Ok(collected.to_bytes()),
    }
}

async fn read_error_message(response: Response<Incoming>) -> Option<String> {
    let body = Limited::new(response.into_body(), ERROR_BODY_LIMIT);
    let bytes = tokio::time::timeout(Duration::from_secs(10), body.collect())
        .await
        .ok()?
        .ok()?
        .to_bytes();
    error_message(&bytes)
}

/// The sentence a provider puts in an error body: `{"error":{"message"}}`
/// from Anthropic and OpenAI, `{"error":"..."}` from Ollama, or the text.
pub(crate) fn error_message(body: &[u8]) -> Option<String> {
    #[derive(serde::Deserialize)]
    struct Body {
        #[serde(default)]
        error: Option<crate::openai::WireError>,
        #[serde(default)]
        message: Option<String>,
    }
    let message = match serde_json::from_slice::<Body>(body) {
        Ok(parsed) => parsed
            .error
            .and_then(crate::openai::WireError::into_message)
            .or(parsed.message),
        Err(_) => Some(String::from_utf8_lossy(body).into_owned()),
    }?;
    let message = message.trim();
    if message.is_empty() {
        return None;
    }
    Some(message.chars().take(ERROR_MESSAGE_CHARS).collect())
}

fn status_error(endpoint: &Endpoint, status: StatusCode, message: Option<String>) -> AiError {
    let host = endpoint.host().to_owned();
    match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => AiError::Unauthorized { host, message },
        StatusCode::TOO_MANY_REQUESTS => AiError::RateLimited { host, message },
        _ => AiError::Status {
            host,
            status: status.as_u16(),
            message,
        },
    }
}

/// hyper's error says only that the connect failed; the cause, such as
/// a refused connection or a certificate rustls rejected, is underneath.
pub(crate) fn error_chain(error: &(dyn std::error::Error + 'static)) -> String {
    let mut parts = vec![error.to_string()];
    let mut source = error.source();
    while let Some(cause) = source {
        let text = cause.to_string();
        if !parts.contains(&text) {
            parts.push(text);
        }
        source = cause.source();
    }
    parts.join(": ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_error_message_is_read_in_each_providers_shape() {
        assert_eq!(
            error_message(br#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
                .as_deref(),
            Some("invalid x-api-key")
        );
        assert_eq!(
            error_message(br#"{"error":"model 'x' not found"}"#).as_deref(),
            Some("model 'x' not found")
        );
        assert_eq!(error_message(b"Bad Gateway").as_deref(), Some("Bad Gateway"));
        assert_eq!(error_message(b"  ").as_deref(), None);
    }

    #[test]
    fn a_long_error_body_is_cut() {
        let body = format!("{{\"error\":\"{}\"}}", "x".repeat(10_000));

        assert_eq!(
            error_message(body.as_bytes()).map(|text| text.len()),
            Some(ERROR_MESSAGE_CHARS)
        );
    }

    #[test]
    fn statuses_map_to_what_the_user_can_do_about_them() {
        let endpoint = Endpoint::new(
            tablepro_core::AiProvider::OpenAiCompatible,
            "http://localhost:11434/v1",
            "m",
            None,
        )
        .unwrap();

        assert!(matches!(
            status_error(&endpoint, StatusCode::UNAUTHORIZED, None),
            AiError::Unauthorized { .. }
        ));
        assert!(matches!(
            status_error(&endpoint, StatusCode::TOO_MANY_REQUESTS, None),
            AiError::RateLimited { .. }
        ));
        assert!(matches!(
            status_error(&endpoint, StatusCode::NOT_FOUND, None),
            AiError::Status { status: 404, .. }
        ));
    }
}
