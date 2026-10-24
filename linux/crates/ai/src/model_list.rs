use std::fmt::Write as _;

use http::Method;
use serde::Deserialize;

use crate::http_client::read_body;
use crate::protocol::Protocol;
use crate::{AiClient, AiError, Endpoint};

const LISTING_LIMIT: usize = 4 * 1024 * 1024;

/// The models the provider offers the key, sorted.
pub async fn list_models(client: &AiClient, endpoint: &Endpoint) -> Result<Vec<String>, AiError> {
    let path = match Protocol::of(endpoint.kind()) {
        Protocol::AnthropicMessages => "/models?limit=1000",
        Protocol::ChatCompletions => "/models",
    };
    let response = client
        .send(endpoint, Method::GET, path, None, "application/json")
        .await?;
    let body = read_body(response, LISTING_LIMIT, endpoint.host()).await?;
    let mut ids = model_ids(&body)?;
    ids.sort();
    ids.dedup();
    Ok(ids)
}

/// The most a reply from the endpoint's model may hold, in tokens, as
/// Anthropic's Models API gives it. Read once per model; `None` when the
/// model is unknown there or the lookup fails, which leaves the request
/// as it was.
pub(crate) async fn output_limit(client: &AiClient, endpoint: &Endpoint) -> Option<u32> {
    if let Some(known) = client.known_output_limit(endpoint) {
        return known;
    }
    match read_output_limit(client, endpoint).await {
        Ok(limit) => {
            client.remember_output_limit(endpoint, limit);
            limit
        }
        Err(AiError::Status { status: 404, .. }) => {
            client.remember_output_limit(endpoint, None);
            None
        }
        Err(error) => {
            tracing::debug!(%error, "the model's output limit was not read");
            None
        }
    }
}

async fn read_output_limit(client: &AiClient, endpoint: &Endpoint) -> Result<Option<u32>, AiError> {
    #[derive(Deserialize)]
    struct ModelInfo {
        #[serde(default)]
        max_tokens: Option<u32>,
    }
    let path = format!("/models/{}", path_segment(endpoint.model()));
    let response = client
        .send(endpoint, Method::GET, &path, None, "application/json")
        .await?;
    let body = read_body(response, LISTING_LIMIT, endpoint.host()).await?;
    let info: ModelInfo = serde_json::from_slice(&body).map_err(|error| AiError::Protocol(error.to_string()))?;
    Ok(info.max_tokens.filter(|limit| *limit > 0))
}

/// `text` as one URL path segment: what is not unreserved is
/// percent-encoded, so a model name cannot reach another path.
fn path_segment(text: &str) -> String {
    let mut encoded = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(char::from(byte));
        } else {
            let _ = write!(encoded, "%{byte:02X}");
        }
    }
    encoded
}

/// Both protocols answer `{"data": [{"id": ...}, ...]}`.
fn model_ids(body: &[u8]) -> Result<Vec<String>, AiError> {
    #[derive(Deserialize)]
    struct Listing {
        data: Vec<Model>,
    }
    #[derive(Deserialize)]
    struct Model {
        id: String,
    }
    let listing: Listing = serde_json::from_slice(body).map_err(|error| AiError::Protocol(error.to_string()))?;
    Ok(listing.data.into_iter().map(|model| model.id).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_providers_listing_gives_its_ids() {
        let anthropic =
            br#"{"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5"}],"has_more":false}"#;
        let ollama = br#"{"object":"list","data":[{"id":"llama3.2:latest","object":"model"},{"id":"qwen3"}]}"#;

        assert_eq!(model_ids(anthropic).unwrap(), ["claude-opus-5-5"]);
        assert_eq!(model_ids(ollama).unwrap(), ["llama3.2:latest", "qwen3"]);
        assert!(matches!(model_ids(b"[]"), Err(AiError::Protocol(_))));
    }

    #[test]
    fn a_model_name_stays_one_path_segment() {
        assert_eq!(path_segment("claude-opus-5-5"), "claude-opus-5-5");
        assert_eq!(path_segment("../keys?x=1 y"), "..%2Fkeys%3Fx%3D1%20y");
    }
}
