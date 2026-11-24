use std::fmt::Write as _;

use http::Method;
use serde::Deserialize;
use tablepro_core::AiProvider;

use crate::catalog::{ListSource, ModelCatalog};
use crate::http_client::read_body;
use crate::model_merge::{LiveModel, ModelInfo, merge_models};
use crate::{AiClient, AiError, Endpoint};

const LISTING_LIMIT: usize = 4 * 1024 * 1024;

/// The models the provider offers the key, merged with the catalog
/// (`merge_models`). On an error, `ModelCatalog::offline_models` gives
/// the catalog's list to show beside it.
pub async fn list_models(
    client: &AiClient,
    endpoint: &Endpoint,
    catalog: &ModelCatalog,
) -> Result<Vec<ModelInfo>, AiError> {
    let source = ListSource::of(endpoint.kind());
    if source.key.is_some() {
        catalog.load_cached().await;
        catalog.start_refresh(client);
    }
    let live = read_models(client, endpoint)
        .await
        .map_err(|error| endpoint.scrub(error))?;
    let current = catalog.current();
    let entry = source.key.and_then(|key| current.provider(key));
    Ok(merge_models(entry, source.rules, Some(&live)))
}

async fn read_models(client: &AiClient, endpoint: &Endpoint) -> Result<Vec<LiveModel>, AiError> {
    let path = match endpoint.kind() {
        AiProvider::Anthropic => "/models?limit=1000",
        AiProvider::OpenAi | AiProvider::OpenAiCompatible => "/models",
    };
    let response = client
        .send(endpoint, Method::GET, path, None, "application/json")
        .await?;
    let body = read_body(response, LISTING_LIMIT, endpoint.host()).await?;
    match endpoint.kind() {
        AiProvider::Anthropic => anthropic_models(&body),
        AiProvider::OpenAi => openai_models(&body),
        AiProvider::OpenAiCompatible => compatible_models(&body),
    }
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
    struct Described {
        #[serde(default)]
        max_tokens: Option<u32>,
    }
    let path = format!("/models/{}", path_segment(endpoint.model()));
    let response = client
        .send(endpoint, Method::GET, &path, None, "application/json")
        .await?;
    let body = read_body(response, LISTING_LIMIT, endpoint.host()).await?;
    let info: Described = serde_json::from_slice(&body).map_err(|error| AiError::Protocol(error.to_string()))?;
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

/// Every protocol answers `{"data": [{"id": ...}, ...]}`.
fn listing<T: for<'de> Deserialize<'de>>(body: &[u8]) -> Result<Vec<T>, AiError> {
    #[derive(Deserialize)]
    struct Listing<T> {
        data: Vec<T>,
    }
    let listing: Listing<T> = serde_json::from_slice(body).map_err(|error| AiError::Protocol(error.to_string()))?;
    Ok(listing.data)
}

fn anthropic_models(body: &[u8]) -> Result<Vec<LiveModel>, AiError> {
    #[derive(Deserialize)]
    struct Model {
        id: String,
        #[serde(default)]
        display_name: Option<String>,
        #[serde(default)]
        created_at: Option<String>,
        // active, deprecated or retired; older replies leave it out.
        #[serde(default)]
        lifecycle: Option<String>,
    }
    Ok(listing::<Model>(body)?
        .into_iter()
        .map(|model| LiveModel {
            deprecated: model.lifecycle.is_some_and(|lifecycle| lifecycle != "active"),
            released: model.created_at.as_deref().and_then(day_of_rfc3339),
            name: model.display_name,
            id: model.id,
            default: false,
        })
        .collect())
}

fn openai_models(body: &[u8]) -> Result<Vec<LiveModel>, AiError> {
    #[derive(Deserialize)]
    struct Model {
        id: String,
        #[serde(default)]
        created: Option<i64>,
        // Null until a shutdown is announced.
        #[serde(default)]
        shutdown_date: Option<serde_json::Value>,
    }
    Ok(listing::<Model>(body)?
        .into_iter()
        .map(|model| LiveModel {
            deprecated: model.shutdown_date.is_some_and(|date| !date.is_null()),
            released: model.created.and_then(day_of_unix_time),
            id: model.id,
            ..LiveModel::default()
        })
        .collect())
}

fn compatible_models(body: &[u8]) -> Result<Vec<LiveModel>, AiError> {
    #[derive(Deserialize)]
    struct Model {
        id: String,
        #[serde(default)]
        name: Option<String>,
    }
    Ok(listing::<Model>(body)?
        .into_iter()
        .map(|model| LiveModel {
            name: model.name,
            ..LiveModel::new(model.id)
        })
        .collect())
}

fn day_of_rfc3339(text: &str) -> Option<String> {
    chrono::DateTime::parse_from_rfc3339(text.trim())
        .ok()
        .map(|instant| instant.date_naive().to_string())
}

fn day_of_unix_time(seconds: i64) -> Option<String> {
    chrono::DateTime::from_timestamp(seconds, 0).map(|instant| instant.date_naive().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anthropic_gives_names_dates_and_lifecycles() {
        let body = br#"{"data":[
            {"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-10-20T00:00:00Z","lifecycle":"active"},
            {"type":"model","id":"claude-sonnet-4-5","display_name":"Claude Sonnet 4.5","created_at":"2025-09-29T00:00:00Z","lifecycle":"deprecated"},
            {"type":"model","id":"claude-old"}
        ],"has_more":false}"#;

        let models = anthropic_models(body).unwrap();

        assert_eq!(models[0].name.as_deref(), Some("Claude Opus 5.5"));
        assert_eq!(models[0].released.as_deref(), Some("2026-10-20"));
        assert!(!models[0].deprecated);
        assert!(models[1].deprecated);
        assert_eq!(models[2], LiveModel::new("claude-old"));
    }

    #[test]
    fn openai_gives_a_release_day_and_a_shutdown() {
        let body = br#"{"object":"list","data":[
            {"id":"gpt-5.5","object":"model","created":1776902400,"owned_by":"system","shutdown_date":null},
            {"id":"gpt-4.1","object":"model","created":1744329600,"owned_by":"system","shutdown_date":"2026-12-01"},
            {"id":"whisper-1","object":"model","owned_by":"openai-internal"}
        ]}"#;

        let models = openai_models(body).unwrap();

        assert_eq!(models[0].released.as_deref(), Some("2026-04-23"));
        assert!(!models[0].deprecated);
        assert!(models[1].deprecated);
        assert_eq!(models[2], LiveModel::new("whisper-1"));
    }

    #[test]
    fn a_compatible_server_gives_ids_and_any_name() {
        let ollama = br#"{"object":"list","data":[{"id":"llama3.2:latest","object":"model","created":1730000000},{"id":"qwen3","name":"Qwen 3"}]}"#;

        let models = compatible_models(ollama).unwrap();

        assert_eq!(models[0], LiveModel::new("llama3.2:latest"));
        assert_eq!(models[1].name.as_deref(), Some("Qwen 3"));
        assert!(matches!(compatible_models(b"[]"), Err(AiError::Protocol(_))));
    }

    #[test]
    fn a_model_name_stays_one_path_segment() {
        assert_eq!(path_segment("claude-opus-5-5"), "claude-opus-5-5");
        assert_eq!(path_segment("../keys?x=1 y"), "..%2Fkeys%3Fx%3D1%20y");
    }
}
