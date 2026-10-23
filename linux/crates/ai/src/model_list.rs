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
}
