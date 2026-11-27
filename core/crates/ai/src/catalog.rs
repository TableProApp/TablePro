use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use chrono::{DateTime, FixedOffset};
use http::StatusCode;
use serde::Deserialize;
use tablepro_core::AiProvider;

use crate::AiClient;
use crate::model_merge::{MergeRules, ModelInfo, merge_models};

const BUNDLED: &str = include_str!("../ai-models.json");

/// The catalog layout this build reads; a file with another is ignored.
pub const SCHEMA_VERSION: u32 = 1;

/// Where a newer catalog is published. It is not a provider: no key and
/// no account go with the request.
pub const REFRESH_URL: &str = "https://updates.tablepro.app/ai/models-v1.json";

const REFRESH_EVERY: Duration = Duration::from_secs(60 * 60);
const REFRESH_TIMEOUT: Duration = Duration::from_secs(15);
const CATALOG_LIMIT: usize = 2 * 1024 * 1024;
const CACHED_FILE: &str = "models-v1.json";
const ETAG_FILE: &str = "models-v1.etag";

const PROVIDER_KEYS: [&str; 6] = ["anthropic", "openai", "openai-codex", "google", "xai", "meta"];

/// A protocol a model is reached through, as the catalog names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Api {
    Responses,
    ChatCompletions,
    Messages,
    GenerateContent,
}

impl Api {
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "responses" => Some(Self::Responses),
            "chat-completions" => Some(Self::ChatCompletions),
            "messages" => Some(Self::Messages),
            "generate-content" => Some(Self::GenerateContent),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogModel {
    pub id: String,
    pub name: Option<String>,
    /// `YYYY-MM-DD`.
    pub released: Option<String>,
    pub deprecated: bool,
    /// An API name this build does not know is left out.
    pub apis: Vec<Api>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(from = "RawProvider")]
pub struct ProviderCatalog {
    pub default: Option<String>,
    pub models: Vec<CatalogModel>,
}

impl ProviderCatalog {
    pub fn model(&self, id: &str) -> Option<&CatalogModel> {
        self.models.iter().find(|model| model.id == id)
    }
}

#[derive(Deserialize)]
struct RawProvider {
    #[serde(default)]
    default: Option<String>,
    #[serde(default)]
    models: Vec<RawModel>,
}

#[derive(Deserialize)]
struct RawModel {
    id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    released: Option<String>,
    #[serde(default)]
    deprecated: bool,
    #[serde(default)]
    apis: Vec<String>,
}

impl From<RawProvider> for ProviderCatalog {
    fn from(raw: RawProvider) -> Self {
        Self {
            default: raw.default.filter(|id| !id.trim().is_empty()),
            models: raw
                .models
                .into_iter()
                .map(|model| CatalogModel {
                    id: model.id,
                    name: model.name.filter(|name| !name.trim().is_empty()),
                    released: model.released,
                    deprecated: model.deprecated,
                    apis: model.apis.iter().filter_map(|name| Api::from_name(name)).collect(),
                })
                .collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Catalog {
    generated: String,
    providers: HashMap<String, ProviderCatalog>,
}

impl Catalog {
    /// Fails on another schema or a known provider whose entry does not
    /// read; a provider this build does not know is skipped.
    pub fn parse(text: &[u8]) -> Result<Self, CatalogError> {
        #[derive(Deserialize)]
        struct Schema {
            schema: u32,
        }
        #[derive(Deserialize)]
        struct File {
            generated: String,
            #[serde(default)]
            providers: HashMap<String, serde_json::Value>,
        }
        let schema: Schema = serde_json::from_slice(text).map_err(CatalogError::malformed)?;
        if schema.schema != SCHEMA_VERSION {
            return Err(CatalogError::UnsupportedSchema(schema.schema));
        }
        let file: File = serde_json::from_slice(text).map_err(CatalogError::malformed)?;
        let mut providers = HashMap::new();
        for (key, entry) in file.providers {
            if PROVIDER_KEYS.contains(&key.as_str()) {
                let entry: ProviderCatalog = serde_json::from_value(entry).map_err(CatalogError::malformed)?;
                providers.insert(key, entry);
            }
        }
        Ok(Self {
            generated: file.generated,
            providers,
        })
    }

    pub fn provider(&self, key: &str) -> Option<&ProviderCatalog> {
        self.providers.get(key)
    }

    /// When the file was written, as RFC 3339.
    pub fn generated(&self) -> &str {
        &self.generated
    }

    fn newer_than(&self, other: &Self) -> bool {
        match (instant(&self.generated), instant(&other.generated)) {
            (Some(mine), Some(theirs)) => mine > theirs,
            (Some(_), None) => true,
            _ => false,
        }
    }
}

fn instant(text: &str) -> Option<DateTime<FixedOffset>> {
    DateTime::parse_from_rfc3339(text.trim()).ok()
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CatalogError {
    #[error("the model catalog has schema version {0}")]
    UnsupportedSchema(u32),
    #[error("the model catalog is not valid: {0}")]
    Malformed(String),
}

impl CatalogError {
    fn malformed(error: serde_json::Error) -> Self {
        Self::Malformed(error.to_string())
    }
}

fn bundled() -> Arc<Catalog> {
    static BUNDLED_CATALOG: OnceLock<Arc<Catalog>> = OnceLock::new();
    BUNDLED_CATALOG
        .get_or_init(|| match Catalog::parse(BUNDLED.as_bytes()) {
            Ok(catalog) => Arc::new(catalog),
            Err(error) => {
                tracing::warn!(%error, "the bundled model catalog does not read");
                Arc::new(Catalog {
                    generated: String::new(),
                    providers: HashMap::new(),
                })
            }
        })
        .clone()
}

/// Where a provider's models are looked up in the catalog, and how its
/// own list is merged with it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ListSource {
    pub key: Option<&'static str>,
    pub rules: MergeRules,
}

impl ListSource {
    pub(crate) fn of(provider: AiProvider) -> Self {
        match provider {
            AiProvider::Anthropic => Self {
                key: Some("anthropic"),
                rules: MergeRules {
                    api: Api::Messages,
                    hides_unknown: false,
                    live_ordered: true,
                },
            },
            // The core speaks Chat Completions to OpenAI, so a Responses-only model is left out.
            AiProvider::OpenAi => Self {
                key: Some("openai"),
                rules: MergeRules {
                    api: Api::ChatCompletions,
                    hides_unknown: true,
                    live_ordered: false,
                },
            },
            AiProvider::OpenAiCompatible => Self {
                key: None,
                rules: MergeRules {
                    api: Api::ChatCompletions,
                    hides_unknown: false,
                    live_ordered: false,
                },
            },
        }
    }
}

/// The model catalog an app keeps: the bundled copy, and a newer one
/// fetched into a folder of the app's. Clones share one state.
#[derive(Clone)]
pub struct ModelCatalog {
    inner: Arc<Inner>,
}

struct Inner {
    source: Option<Source>,
    state: Mutex<State>,
}

struct Source {
    dir: PathBuf,
    url: String,
}

struct State {
    current: Arc<Catalog>,
    cache_read: bool,
    etag: Option<String>,
    last_refresh: Option<Instant>,
    // Off while the organization holds the app to its own account server (core ADR 0055).
    refresh_allowed: bool,
}

impl ModelCatalog {
    /// The bundled copy only, never refreshed.
    pub fn bundled() -> Self {
        Self::build(None, bundled())
    }

    /// `catalog` only, never refreshed.
    pub fn fixed(catalog: Catalog) -> Self {
        Self::build(None, Arc::new(catalog))
    }

    /// Refreshed from [`REFRESH_URL`] into `dir`.
    pub fn new(dir: PathBuf) -> Self {
        Self::refreshed_from(dir, REFRESH_URL)
    }

    /// Refreshed from another address, such as a test's server.
    pub fn refreshed_from(dir: PathBuf, url: &str) -> Self {
        let source = Source {
            dir,
            url: url.to_owned(),
        };
        Self::build(Some(source), bundled())
    }

    fn build(source: Option<Source>, current: Arc<Catalog>) -> Self {
        Self {
            inner: Arc::new(Inner {
                source,
                state: Mutex::new(State {
                    current,
                    cache_read: false,
                    etag: None,
                    last_refresh: None,
                    refresh_allowed: true,
                }),
            }),
        }
    }

    /// The newer of the bundled copy and the one fetched.
    pub fn current(&self) -> Arc<Catalog> {
        match self.inner.state.lock() {
            Ok(state) => state.current.clone(),
            Err(_) => bundled(),
        }
    }

    /// The catalog's models for `provider` that this client can reach,
    /// each offline: what a list shows when the provider's own failed.
    pub fn offline_models(&self, provider: AiProvider) -> Vec<ModelInfo> {
        let source = ListSource::of(provider);
        let Some(key) = source.key else {
            return Vec::new();
        };
        self.load_cached_now();
        merge_models(self.current().provider(key), source.rules, None)
    }

    /// The model a new setup of `provider` starts on: the catalog's
    /// default when this client can reach it, else the newest it can.
    pub fn default_model(&self, provider: AiProvider) -> Option<String> {
        let models = self.offline_models(provider);
        models
            .iter()
            .find(|model| model.default)
            .or_else(|| models.first())
            .map(|model| model.id.clone())
    }

    /// Read the copy fetched by an earlier run, once, off the async runtime.
    pub(crate) async fn load_cached(&self) {
        let catalog = self.clone();
        let _ = tokio::task::spawn_blocking(move || catalog.load_cached_now()).await;
    }

    /// Read the copy fetched by an earlier run, once. The file is small,
    /// and a default resolved before it was read would be saved for good.
    fn load_cached_now(&self) {
        let Some(source) = &self.inner.source else {
            return;
        };
        let first = self
            .inner
            .state
            .lock()
            .is_ok_and(|mut state| !std::mem::replace(&mut state.cache_read, true));
        if !first {
            return;
        }
        let Some((catalog, etag)) = read_cache(&source.dir) else {
            return;
        };
        if let Ok(mut state) = self.inner.state.lock() {
            state.etag = etag;
            if catalog.newer_than(&state.current) {
                state.current = Arc::new(catalog);
            }
        }
    }

    /// Whether [`Self::refresh`] may fetch. Without it, the newer of the
    /// bundled copy and the one an earlier run kept serves.
    pub fn allow_refresh(&self, allowed: bool) {
        if let Ok(mut state) = self.inner.state.lock() {
            state.refresh_allowed = allowed;
        }
    }

    /// Fetch a newer copy, at most once an hour. A failure leaves the
    /// catalog as it was and is only logged.
    pub async fn refresh(&self, client: &AiClient) {
        let Some(source) = &self.inner.source else {
            return;
        };
        self.load_cached().await;
        let Some(etag) = self.claim_refresh() else {
            return;
        };
        match tokio::time::timeout(REFRESH_TIMEOUT, self.fetch(client, source, etag)).await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => tracing::debug!(%error, "the model catalog was not refreshed"),
            Err(_) => tracing::debug!("the model catalog did not arrive in time"),
        }
    }

    /// Start [`Self::refresh`] beside the work that asked for it, so a
    /// slow or failed fetch never holds a model list up.
    pub(crate) fn start_refresh(&self, client: &AiClient) {
        if self.inner.source.is_none() {
            return;
        }
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return;
        };
        let (catalog, client) = (self.clone(), client.clone());
        drop(runtime.spawn(async move { catalog.refresh(&client).await }));
    }

    /// The ETag to send, or `None` when a refresh ran within the hour or
    /// may not run.
    fn claim_refresh(&self) -> Option<Option<String>> {
        let mut state = self.inner.state.lock().ok()?;
        if !state.refresh_allowed {
            return None;
        }
        if state.last_refresh.is_some_and(|last| last.elapsed() < REFRESH_EVERY) {
            return None;
        }
        state.last_refresh = Some(Instant::now());
        Some(state.etag.clone())
    }

    async fn fetch(&self, client: &AiClient, source: &Source, etag: Option<String>) -> Result<(), String> {
        let (status, etag, body) = client
            .fetch_published(&source.url, etag.as_deref(), CATALOG_LIMIT)
            .await
            .map_err(|error| error.to_string())?;
        if status == StatusCode::NOT_MODIFIED {
            return Ok(());
        }
        if status != StatusCode::OK {
            return Err(format!("the catalog host answered {status}"));
        }
        let catalog = Catalog::parse(&body).map_err(|error| error.to_string())?;
        // A cache can hand back an older copy than the one held; writing it would lose models after a restart.
        if self.current().newer_than(&catalog) {
            return Ok(());
        }
        let dir = source.dir.clone();
        let stored_etag = etag.clone();
        tokio::task::spawn_blocking(move || write_cache(&dir, &body, stored_etag.as_deref()))
            .await
            .map_err(|error| error.to_string())?
            .map_err(|error| error.to_string())?;
        if let Ok(mut state) = self.inner.state.lock() {
            state.etag = etag;
            if catalog.newer_than(&state.current) {
                state.current = Arc::new(catalog);
            }
        }
        Ok(())
    }
}

impl std::fmt::Debug for ModelCatalog {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ModelCatalog")
            .field("dir", &self.inner.source.as_ref().map(|source| &source.dir))
            .finish_non_exhaustive()
    }
}

/// The copy an earlier run fetched and its ETag; `None` when there is
/// none or it does not read, so no ETag is sent for a copy not kept.
fn read_cache(dir: &Path) -> Option<(Catalog, Option<String>)> {
    let text = std::fs::read(dir.join(CACHED_FILE)).ok()?;
    let catalog = match Catalog::parse(&text) {
        Ok(catalog) => catalog,
        Err(error) => {
            tracing::debug!(%error, "the cached model catalog is ignored");
            return None;
        }
    };
    let etag = std::fs::read_to_string(dir.join(ETAG_FILE))
        .ok()
        .map(|etag| etag.trim().to_owned())
        .filter(|etag| !etag.is_empty());
    Some((catalog, etag))
}

fn write_cache(dir: &Path, body: &[u8], etag: Option<&str>) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let staged = dir.join(format!("{CACHED_FILE}.partial"));
    std::fs::write(&staged, body)?;
    std::fs::rename(&staged, dir.join(CACHED_FILE))?;
    match etag {
        Some(etag) => std::fs::write(dir.join(ETAG_FILE), etag),
        None => match std::fs::remove_file(dir.join(ETAG_FILE)) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINIMAL: &str = r#"{"schema":1,"generated":"2026-11-24T00:00:00Z","providers":{
        "openai":{"default":"gpt-5.5","models":[{"id":"gpt-5.5","name":"GPT-5.5","apis":["responses","chat-completions","telepathy"]}]},
        "someone-new":{"models":"not a list"}}}"#;

    #[test]
    fn the_bundled_catalog_reads_and_names_a_default_for_each_hosted_provider() {
        let catalog = Catalog::parse(BUNDLED.as_bytes()).unwrap();

        for key in ["anthropic", "openai"] {
            let provider = catalog.provider(key).unwrap();
            let default = provider.default.as_deref().unwrap();
            assert!(provider.model(default).is_some(), "{key} default {default}");
        }
        assert!(instant(catalog.generated()).is_some(), "{}", catalog.generated());
    }

    #[test]
    fn unknown_providers_and_apis_are_skipped() {
        let catalog = Catalog::parse(MINIMAL.as_bytes()).unwrap();

        assert!(catalog.provider("someone-new").is_none());
        let model = catalog.provider("openai").unwrap().model("gpt-5.5").unwrap();
        assert_eq!(model.apis, [Api::Responses, Api::ChatCompletions]);
        assert_eq!(model.name.as_deref(), Some("GPT-5.5"));
    }

    #[test]
    fn another_schema_is_refused() {
        let error = Catalog::parse(br#"{"schema":2,"generated":"2026-11-24T00:00:00Z","providers":{}}"#);

        assert_eq!(error, Err(CatalogError::UnsupportedSchema(2)));
        assert!(matches!(Catalog::parse(b"[]"), Err(CatalogError::Malformed(_))));
    }

    #[test]
    fn the_newer_generated_wins() {
        let older = Catalog::parse(MINIMAL.as_bytes()).unwrap();
        let newer = Catalog::parse(MINIMAL.replace("2026-11-24T00", "2026-11-25T00").as_bytes()).unwrap();

        assert!(newer.newer_than(&older));
        assert!(!older.newer_than(&newer));
        assert!(!older.newer_than(&older));
    }

    #[test]
    fn a_cached_copy_is_read_with_its_etag_and_a_broken_one_is_ignored() {
        let dir = tempfile::tempdir().unwrap();
        write_cache(dir.path(), MINIMAL.as_bytes(), Some("\"abc\"")).unwrap();

        let (catalog, etag) = read_cache(dir.path()).unwrap();
        assert!(catalog.provider("openai").is_some());
        assert_eq!(etag.as_deref(), Some("\"abc\""));

        std::fs::write(dir.path().join(CACHED_FILE), b"{").unwrap();
        assert!(read_cache(dir.path()).is_none());
    }

    #[test]
    fn the_compatible_server_has_no_catalog() {
        let catalog = ModelCatalog::bundled();

        assert!(catalog.offline_models(AiProvider::OpenAiCompatible).is_empty());
        assert_eq!(catalog.default_model(AiProvider::OpenAiCompatible), None);
    }

    #[test]
    fn the_default_model_is_one_the_offline_list_offers() {
        let catalog = ModelCatalog::bundled();

        for provider in [AiProvider::Anthropic, AiProvider::OpenAi] {
            let default = catalog.default_model(provider).unwrap();
            let offline = catalog.offline_models(provider);
            assert!(offline.iter().all(|model| model.offline));
            assert!(offline.iter().any(|model| model.id == default), "{provider} {default}");
        }
    }
}
