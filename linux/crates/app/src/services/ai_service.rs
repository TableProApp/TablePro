//! The AI provider the settings name: its key in the keyring, the one
//! HTTP client, and the replies, which run on the app's runtime.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ai::{
    AiClient, AiError, ApiKeyVault, ChatRequest, Endpoint, ModelCatalog, ModelInfo, ReplyEnd, ReplyEvent,
};
use tablepro_core::AiProvider;
use tablepro_core::credentials::SecretError;
use tablepro_linux_platform::AppSettings;
use tablepro_session::runtime::Tasks;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

/// Why no request could start.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum AiSetupError {
    #[error("no provider is chosen")]
    Off,
    #[error(transparent)]
    Keyring(#[from] SecretError),
    #[error(transparent)]
    Ai(#[from] AiError),
    #[error("the background work stopped")]
    Stopped,
}

/// A reply on its way: its events, and the switch that stops it.
pub(crate) struct ReplyHandle {
    pub events: mpsc::UnboundedReceiver<ReplyEvent>,
    pub cancel: CancellationToken,
}

impl Drop for ReplyHandle {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

/// A provider's models, or the catalog's beside why the provider's were
/// not read.
pub(crate) struct ModelListing {
    pub models: Vec<ModelInfo>,
    pub error: Option<AiSetupError>,
}

#[derive(Clone)]
pub(crate) struct AiService {
    inner: Rc<Inner>,
}

struct Inner {
    settings: Rc<AppSettings>,
    tasks: Tasks,
    /// `None` in a test that brings no keyring.
    keys: Option<Arc<dyn ApiKeyVault>>,
    /// Built on first use, off the GTK thread: it reads the system's
    /// certificates.
    client: RefCell<Option<AiClient>>,
    catalog: ModelCatalog,
}

impl AiService {
    /// On the bundled model catalog, as tests use it.
    pub(crate) fn new(settings: Rc<AppSettings>, tasks: Tasks, keys: Option<Arc<dyn ApiKeyVault>>) -> Self {
        Self::with_catalog(settings, tasks, keys, ModelCatalog::bundled())
    }

    pub(crate) fn with_catalog(
        settings: Rc<AppSettings>,
        tasks: Tasks,
        keys: Option<Arc<dyn ApiKeyVault>>,
        catalog: ModelCatalog,
    ) -> Self {
        Self {
            inner: Rc::new(Inner {
                settings,
                tasks,
                keys,
                client: RefCell::new(None),
                catalog,
            }),
        }
    }

    /// The provider that answers, or `None` while the assistant is off.
    pub(crate) fn provider(&self) -> Option<AiProvider> {
        self.inner.settings.ai_provider()
    }

    pub(crate) fn settings(&self) -> &Rc<AppSettings> {
        &self.inner.settings
    }

    pub(crate) fn tasks(&self) -> &Tasks {
        &self.inner.tasks
    }

    /// Where the requests go and with which model, its key read from the
    /// keyring, which may ask the user to unlock it.
    pub(crate) async fn endpoint(&self) -> Result<Endpoint, AiSetupError> {
        let provider = self.provider().ok_or(AiSetupError::Off)?;
        self.endpoint_for(provider).await
    }

    pub(crate) async fn endpoint_for(&self, provider: AiProvider) -> Result<Endpoint, AiSetupError> {
        let settings = &self.inner.settings;
        let (base, model) = (settings.ai_base_url(provider), self.settle_model(provider));
        let key = match self.load_key(provider).await {
            Ok(key) => key,
            // A local server usually takes no key, so a keyring that is
            // missing or locked does not stop it.
            Err(error) if !provider.requires_key() => {
                tracing::debug!(%error, "no key read for the compatible server");
                None
            }
            Err(error) => return Err(error),
        };
        Ok(Endpoint::new(provider, &base, &model, key)?)
    }

    pub(crate) async fn load_key(&self, provider: AiProvider) -> Result<Option<SecretString>, AiSetupError> {
        let Some(keys) = self.inner.keys.clone() else {
            return Ok(None);
        };
        let loaded = self
            .inner
            .tasks
            .spawn_task(async move { keys.load_key(provider).await })
            .await
            .map_err(|_| AiSetupError::Stopped)?;
        Ok(loaded?)
    }

    /// Keep `key` for `provider`; an empty one removes the key kept.
    pub(crate) async fn store_key(&self, provider: AiProvider, key: SecretString) -> Result<(), AiSetupError> {
        let Some(keys) = self.inner.keys.clone() else {
            return Err(AiSetupError::Keyring(SecretError::ServiceUnavailable {
                detail: "no keyring in this build".to_owned(),
            }));
        };
        let empty = secrecy::ExposeSecret::expose_secret(&key).trim().is_empty();
        let stored = self
            .inner
            .tasks
            .spawn_task(async move {
                if empty {
                    keys.delete_key(provider).await
                } else {
                    keys.store_key(provider, &key).await
                }
            })
            .await
            .map_err(|_| AiSetupError::Stopped)?;
        Ok(stored?)
    }

    async fn client(&self) -> Result<AiClient, AiError> {
        if let Some(client) = self.inner.client.borrow().clone() {
            return Ok(client);
        }
        let client = self
            .inner
            .tasks
            .spawn_blocking_task(|| AiClient::new(crate::config::VERSION))
            .await
            .map_err(|_| AiError::Tls("the setup stopped".to_owned()))??;
        self.inner.client.replace(Some(client.clone()));
        Ok(client)
    }

    /// Have the HTTP client ready, so the check made just before a send
    /// is not separated from it by its setup.
    pub(crate) async fn prepare(&self) -> Result<(), AiError> {
        self.client().await.map(drop)
    }

    /// Start a reply on the runtime. Dropping the handle stops it.
    pub(crate) async fn stream(&self, endpoint: Endpoint, request: ChatRequest) -> Result<ReplyHandle, AiError> {
        let client = self.client().await?;
        let (sender, events) = mpsc::unbounded_channel();
        let cancel = CancellationToken::new();
        let stop = cancel.clone();
        drop(self.inner.tasks.spawn_task(async move {
            tablepro_ai::stream_reply(&client, &endpoint, &request, stop, sender).await;
        }));
        Ok(ReplyHandle { events, cancel })
    }

    /// A whole reply, for a suggestion.
    pub(crate) async fn complete(
        &self,
        endpoint: Endpoint,
        request: ChatRequest,
    ) -> Result<(String, ReplyEnd), AiError> {
        let client = self.client().await?;
        let reply = self
            .inner
            .tasks
            .spawn_owned(async move { tablepro_ai::collect_reply(&client, &endpoint, &request).await });
        reply
            .await
            .map_err(|_| AiError::Protocol("the request stopped".to_owned()))?
    }

    /// The model saved for `provider`, else the one an empty setting
    /// takes on first use.
    pub(crate) fn model(&self, provider: AiProvider) -> String {
        let saved = self.inner.settings.ai_model(provider);
        if !saved.is_empty() {
            return saved;
        }
        self.inner.catalog.default_model(provider).unwrap_or_default()
    }

    /// Save the catalog's default for `provider` when no model is saved,
    /// so a later catalog never changes a model the user started on.
    pub(crate) fn settle_model(&self, provider: AiProvider) -> String {
        let model = self.model(provider);
        if self.inner.settings.ai_model(provider).is_empty()
            && !model.is_empty()
            && let Err(error) = self.inner.settings.set_ai_model(provider, &model)
        {
            tracing::warn!(%error, "the default model could not be saved");
        }
        model
    }

    pub(crate) async fn models(&self, provider: AiProvider) -> ModelListing {
        match self.read_models(provider).await {
            Ok(models) => ModelListing { models, error: None },
            Err(error) => ModelListing {
                models: self.inner.catalog.offline_models(provider),
                error: Some(error),
            },
        }
    }

    async fn read_models(&self, provider: AiProvider) -> Result<Vec<ModelInfo>, AiSetupError> {
        let endpoint = self.endpoint_for(provider).await?;
        let client = self.client().await?;
        let catalog = self.inner.catalog.clone();
        let listed = self
            .inner
            .tasks
            .spawn_task(async move { tablepro_ai::list_models(&client, &endpoint, &catalog).await })
            .await
            .map_err(|_| AiSetupError::Stopped)?;
        Ok(listed?)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::collections::HashMap;
    use std::sync::Mutex;

    use async_trait::async_trait;
    use secrecy::ExposeSecret;

    use super::*;

    /// A keyring in memory, for tests that must not touch the user's.
    #[derive(Default)]
    pub(crate) struct MemoryKeys(pub(crate) Mutex<HashMap<AiProvider, String>>);

    #[async_trait]
    impl ApiKeyVault for MemoryKeys {
        async fn load_key(&self, provider: AiProvider) -> Result<Option<SecretString>, SecretError> {
            Ok(self.0.lock().unwrap().get(&provider).cloned().map(SecretString::from))
        }

        async fn store_key(&self, provider: AiProvider, key: &SecretString) -> Result<(), SecretError> {
            self.0.lock().unwrap().insert(provider, key.expose_secret().to_owned());
            Ok(())
        }

        async fn delete_key(&self, provider: AiProvider) -> Result<(), SecretError> {
            self.0.lock().unwrap().remove(&provider);
            Ok(())
        }
    }

    const WAIT: std::time::Duration = std::time::Duration::from_secs(10);

    fn endpoint(service: &AiService) -> Result<Endpoint, AiSetupError> {
        let service = service.clone();
        crate::test_support::finish_on_main(WAIT, async move { service.endpoint().await }).expect("an answer")
    }

    fn store(service: &AiService, provider: AiProvider, key: &str) {
        let (service, key) = (service.clone(), SecretString::from(key.to_owned()));
        crate::test_support::finish_on_main(WAIT, async move { service.store_key(provider, key).await })
            .expect("an answer")
            .expect("the key kept");
    }

    #[gtk4::test]
    fn an_off_assistant_has_no_endpoint() {
        let settings = crate::test_support::MemorySettings::new();
        let runtime = crate::test_support::test_runtime();
        let service = AiService::new(
            settings.get().clone(),
            runtime.tasks(),
            Some(Arc::new(MemoryKeys::default())),
        );

        assert_eq!(endpoint(&service).unwrap_err(), AiSetupError::Off);
    }

    #[gtk4::test]
    fn a_hosted_provider_without_a_key_says_so_and_one_with_a_key_is_ready() {
        let settings = crate::test_support::MemorySettings::new();
        let runtime = crate::test_support::test_runtime();
        let keys = Arc::new(MemoryKeys::default());
        let service = AiService::new(settings.get().clone(), runtime.tasks(), Some(keys.clone()));
        settings.get().set_ai_provider(Some(AiProvider::Anthropic)).unwrap();

        let missing = endpoint(&service);
        store(&service, AiProvider::Anthropic, "sk-ant");
        let ready = endpoint(&service).unwrap();
        store(&service, AiProvider::Anthropic, " ");

        assert_eq!(
            missing.unwrap_err(),
            AiSetupError::Ai(AiError::MissingKey(AiProvider::Anthropic))
        );
        let default = ModelCatalog::bundled().default_model(AiProvider::Anthropic).unwrap();
        assert_eq!(ready.host(), "api.anthropic.com");
        assert_eq!(ready.model(), default);
        assert_eq!(
            settings.get().ai_model(AiProvider::Anthropic),
            default,
            "saved on first use"
        );
        assert!(keys.0.lock().unwrap().is_empty(), "an empty key removes the one kept");
    }

    #[gtk4::test]
    fn a_saved_model_is_never_replaced_and_the_compatible_server_has_no_default() {
        let settings = crate::test_support::MemorySettings::new();
        let runtime = crate::test_support::test_runtime();
        let service = AiService::new(settings.get().clone(), runtime.tasks(), None);
        settings
            .get()
            .set_ai_model(AiProvider::Anthropic, "claude-haiku-4-5")
            .unwrap();

        assert_eq!(service.settle_model(AiProvider::Anthropic), "claude-haiku-4-5");
        assert_eq!(service.settle_model(AiProvider::OpenAiCompatible), "");
        assert_eq!(settings.get().ai_model(AiProvider::OpenAiCompatible), "");
    }

    #[gtk4::test]
    fn a_failed_listing_gives_the_catalogs_models_beside_the_error() {
        let settings = crate::test_support::MemorySettings::new();
        let runtime = crate::test_support::test_runtime();
        let service = AiService::new(
            settings.get().clone(),
            runtime.tasks(),
            Some(Arc::new(MemoryKeys::default())),
        );

        let listing = crate::test_support::finish_on_main(WAIT, {
            let service = service.clone();
            async move { service.models(AiProvider::Anthropic).await }
        })
        .expect("an answer");

        assert_eq!(
            listing.error,
            Some(AiSetupError::Ai(AiError::MissingKey(AiProvider::Anthropic)))
        );
        assert!(!listing.models.is_empty());
        assert!(listing.models.iter().all(|model| model.offline));
    }
}
