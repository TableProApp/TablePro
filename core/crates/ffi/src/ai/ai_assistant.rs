use std::sync::Arc;

use secrecy::{ExposeSecret, SecretString};
use tablepro_ai::{AiClient, ApiKeyVault, ChatRequest, Endpoint, chat_system_prompt};
use tablepro_core::credentials::SecretItems;
use tablepro_core::{AiPolicy, AiProvider};
use tablepro_session::runtime::Tasks;
use tablepro_storage::ConnectionStore;
use tokio::sync::{OnceCell, mpsc};
use uuid::Uuid;

use super::ai_reply::ReplyState;
use super::{
    AiActionTag, AiChatArg, AiConversationArg, AiConversationStart, AiProviderInfo, AiProviderTag, AiReply,
    AiReplyEvent, AiReplyListener, AiSettingsArg, schema_reader,
};
use crate::cancel_token::{CancelToken, token};
use crate::error::CoreError;
use crate::library::secret_error;
use crate::runtime::on_runtime;
use crate::session::DatabaseSession;

// The providers, their keys in the platform's store, and the replies. The key never crosses back to the app, and a
// saved connection whose AI policy is Never sends nothing; asking under Ask is the app's.
#[derive(uniffi::Object)]
pub struct AiAssistant {
    inner: Arc<Inner>,
}

struct Inner {
    items: Arc<dyn SecretItems>,
    store: Option<ConnectionStore>,
    tasks: Tasks,
    version: String,
    // Built once, off the caller's thread: it reads the system's certificates.
    client: Arc<OnceCell<AiClient>>,
}

impl AiAssistant {
    pub(crate) fn new(
        items: Arc<dyn SecretItems>,
        store: Option<ConnectionStore>,
        tasks: Tasks,
        version: String,
        client: Arc<OnceCell<AiClient>>,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                items,
                store,
                tasks,
                version,
                client,
            }),
        }
    }
}

#[uniffi::export]
impl AiAssistant {
    // Whether a key is kept for the provider; the key itself stays in the store.
    pub async fn has_key(&self, provider: AiProviderTag) -> Result<bool, CoreError> {
        let items = self.inner.items.clone();
        on_runtime(&self.inner.tasks, async move {
            let key = items.load_key(provider.into()).await.map_err(secret_error)?;
            Ok(key.is_some_and(|key| !key.expose_secret().trim().is_empty()))
        })
        .await
    }

    // A blank key removes the one kept. Blanks around a pasted key are dropped, since a header cannot carry a break.
    pub async fn set_key(&self, provider: AiProviderTag, key: SecretString) -> Result<(), CoreError> {
        let items = self.inner.items.clone();
        on_runtime(&self.inner.tasks, async move {
            let trimmed = key.expose_secret().trim();
            let provider = AiProvider::from(provider);
            if trimmed.is_empty() {
                items.delete_key(provider).await
            } else {
                items.store_key(provider, &SecretString::from(trimmed)).await
            }
            .map_err(secret_error)
        })
        .await
    }

    // The models the provider offers the key, sorted.
    pub async fn list_models(
        &self,
        settings: AiSettingsArg,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Vec<String>, CoreError> {
        let inner = self.inner.clone();
        let cancel = token(cancel);
        on_runtime(&self.inner.tasks, async move {
            let (client, endpoint) = inner.connect(&settings).await?;
            tokio::select! {
                biased;
                () = cancel.cancelled() => Err(CoreError::Cancelled),
                listed = tablepro_ai::list_models(&client, &endpoint) => Ok(listed?),
            }
        })
        .await
    }

    // Reads the catalog for the tables `asked` names and writes the system prompt the conversation keeps.
    pub async fn start_conversation(
        &self,
        session: Arc<DatabaseSession>,
        conversation: AiConversationArg,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<AiConversationStart, CoreError> {
        let inner = self.inner.clone();
        let cancel = token(cancel);
        on_runtime(&self.inner.tasks, async move {
            inner.refuse_if_never(&session).await?;
            let editor = conversation.editor.filter(|text| !text.trim().is_empty());
            let named_in = match &editor {
                Some(editor) => format!("{editor}\n{}", conversation.asked),
                None => conversation.asked,
            };
            let read = schema_reader::read(
                session.session().clone(),
                conversation.engine,
                &named_in,
                conversation.database,
            );
            let context = tokio::select! {
                biased;
                () = cancel.cancelled() => return Err(CoreError::Cancelled),
                context = read => context,
            };
            Ok(AiConversationStart {
                system: chat_system_prompt(&context, editor.as_deref()),
                described: context.described_names().into_iter().map(str::to_owned).collect(),
            })
        })
        .await
    }

    // Returns at once; a refusal, a missing key and a failed request arrive as the reply's Failed event.
    pub fn reply(
        &self,
        session: Arc<DatabaseSession>,
        settings: AiSettingsArg,
        chat: AiChatArg,
        listener: Box<dyn AiReplyListener>,
    ) -> Arc<AiReply> {
        let reply = Arc::new(AiReply::new(listener));
        let state = reply.state();
        let inner = self.inner.clone();
        drop(
            self.inner
                .tasks
                .spawn_task(async move { inner.stream(&session, &settings, chat, &state).await }),
        );
        reply
    }
}

impl Inner {
    // A reply stops with its session, as an editor does, and one asked of a closed session never starts.
    async fn stream(&self, session: &DatabaseSession, settings: &AiSettingsArg, chat: AiChatArg, state: &ReplyState) {
        let cancel = state.cancel.clone();
        let shutdown = session.session().shutdown_signal();
        let stopped = async {
            tokio::select! {
                () = cancel.cancelled() => {}
                () = shutdown.cancelled() => {}
            }
        };
        tokio::pin!(stopped);
        let ready = tokio::select! {
            biased;
            () = &mut stopped => None,
            ready = self.ready_to_send(session, settings) => Some(ready),
        };
        let (client, endpoint) = match ready {
            None => return state.post(AiReplyEvent::Stopped),
            Some(Err(error)) => return state.post(AiReplyEvent::failed(error)),
            Some(Ok(ready)) => ready,
        };
        let request = ChatRequest::from(chat);
        let (sender, mut receiver) = mpsc::unbounded_channel();
        let streaming = tablepro_ai::stream_reply(&client, &endpoint, &request, cancel.clone(), sender);
        let forwarding = async {
            while let Some(event) = receiver.recv().await {
                state.post(event.into());
            }
        };
        // Dropping the stream on a stop ends its request.
        tokio::select! {
            biased;
            () = &mut stopped => {}
            _ = async { tokio::join!(streaming, forwarding) } => {}
        }
        // A stop ends the stream with neither Finished nor Failed; after either, this is not posted.
        state.post(AiReplyEvent::Stopped);
    }

    async fn ready_to_send(
        &self,
        session: &DatabaseSession,
        settings: &AiSettingsArg,
    ) -> Result<(AiClient, Endpoint), CoreError> {
        self.refuse_if_never(session).await?;
        self.connect(settings).await
    }

    async fn connect(&self, settings: &AiSettingsArg) -> Result<(AiClient, Endpoint), CoreError> {
        let endpoint = self.endpoint(settings).await?;
        Ok((self.client().await?, endpoint))
    }

    async fn endpoint(&self, settings: &AiSettingsArg) -> Result<Endpoint, CoreError> {
        let provider = AiProvider::from(settings.provider);
        let key = match self.items.load_key(provider).await {
            Ok(key) => key,
            // A local server usually takes no key, so a store that cannot be read does not stop it.
            Err(error) if !provider.requires_key() => {
                tracing::debug!(%error, "no key read for the compatible server");
                None
            }
            Err(error) => return Err(secret_error(error)),
        };
        Ok(Endpoint::new(provider, &settings.base_url(), &settings.model, key)?)
    }

    async fn client(&self) -> Result<AiClient, CoreError> {
        let tasks = self.tasks.clone();
        let version = self.version.clone();
        self.client
            .get_or_try_init(|| async move {
                tasks
                    .spawn_blocking_task(move || AiClient::new(&version))
                    .await
                    .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))?
                    .map_err(CoreError::from)
            })
            .await
            .cloned()
    }

    // Read again before every request, so a policy changed in the connection form applies to the next one.
    async fn refuse_if_never(&self, session: &DatabaseSession) -> Result<(), CoreError> {
        let Some(store) = self.store.clone() else {
            return Ok(());
        };
        let Ok(id) = Uuid::parse_str(&session.id()) else {
            return Ok(());
        };
        let connections = self
            .tasks
            .spawn_blocking_task(move || store.load_blocking())
            .await
            .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))??;
        let never = connections
            .iter()
            .any(|connection| connection.id == id && connection.ai_policy == AiPolicy::Never);
        if never {
            return Err(CoreError::failed(
                "ai.blocked",
                "the connection's AI policy sends nothing from it",
            ));
        }
        Ok(())
    }
}

impl std::fmt::Debug for AiAssistant {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AiAssistant").finish_non_exhaustive()
    }
}

// In the order a settings page lists them.
#[uniffi::export]
pub fn ai_providers() -> Vec<AiProviderInfo> {
    AiProvider::ALL
        .into_iter()
        .map(|provider| AiProviderInfo {
            provider: provider.into(),
            default_base_url: provider.default_base_url().to_owned(),
            requires_key: provider.requires_key(),
            takes_address: provider == AiProvider::OpenAiCompatible,
        })
        .collect()
}

// The user's message for an editor action on `statement`; `error` is the server's, for Fix.
#[uniffi::export]
pub fn ai_action_message(action: AiActionTag, statement: String, error: Option<String>) -> String {
    tablepro_ai::action_message(action.into(), &statement, error.as_deref())
}

// The host the settings send requests to, for naming where the data goes before anything is sent.
#[uniffi::export]
pub fn ai_host_of(settings: AiSettingsArg) -> Option<String> {
    Endpoint::host_of(&settings.base_url())
}

// Whether a compatible server's address is an http or https URL with a host and no query.
#[uniffi::export]
pub fn ai_address_is_valid(address: String) -> bool {
    Endpoint::new(AiProvider::OpenAiCompatible, &address, "", None).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_provider_says_where_it_goes_and_whether_it_needs_a_key() {
        let providers = ai_providers();

        assert_eq!(
            providers.iter().map(|info| info.provider).collect::<Vec<_>>(),
            [
                AiProviderTag::Anthropic,
                AiProviderTag::OpenAi,
                AiProviderTag::OpenAiCompatible
            ]
        );
        assert!(providers[0].requires_key && !providers[0].takes_address);
        assert!(!providers[2].requires_key && providers[2].takes_address);
    }

    #[test]
    fn the_host_named_is_the_one_the_settings_reach() {
        let settings = |provider, address: &str| AiSettingsArg {
            provider,
            model: String::new(),
            address: Some(address.to_owned()),
        };

        assert_eq!(
            ai_host_of(settings(AiProviderTag::OpenAi, "http://elsewhere/v1")).as_deref(),
            Some("api.openai.com")
        );
        assert_eq!(
            ai_host_of(settings(AiProviderTag::OpenAiCompatible, "http://gpu-box:11434/v1")).as_deref(),
            Some("gpu-box")
        );
    }

    #[test]
    fn an_address_is_checked_as_a_request_would_take_it() {
        assert!(ai_address_is_valid("http://localhost:11434/v1".to_owned()));
        assert!(!ai_address_is_valid("localhost:11434/v1".to_owned()));
        assert!(!ai_address_is_valid("http://host/v1?x=1".to_owned()));
    }

    #[test]
    fn an_action_message_carries_the_statement_and_the_error() {
        let message = ai_action_message(AiActionTag::Fix, "SELEC 1".to_owned(), Some("syntax error".to_owned()));

        assert!(message.contains("SELEC 1"), "{message}");
        assert!(message.contains("syntax error"), "{message}");
    }
}
