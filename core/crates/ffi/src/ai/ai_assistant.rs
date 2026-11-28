use std::sync::Arc;
use std::sync::atomic::AtomicU64;

use secrecy::{ExposeSecret, SecretString};
use tablepro_ai::{
    AiClient, ApiKeyVault, ChatMessage, ChatRequest, ContentBlock, Endpoint, ModelCatalog, ReplyEnd, ReplyEvent, Role,
    StopReason, ToolSpec, chat_system_prompt, stream_reply,
};
use tablepro_core::credentials::SecretItems;
use tablepro_core::{AiPolicy, AiProvider};
use tablepro_mcp::{ToolContext, dispatch_tool};
use tablepro_session::runtime::Tasks;
use tablepro_storage::ConnectionStore;
use tokio::sync::{OnceCell, mpsc};
use uuid::Uuid;

use super::agent_host::{AgentHost, AiApprover};
use super::ai_reply::ReplyState;
use super::{
    AiActionTag, AiChatArg, AiConversationArg, AiConversationStart, AiModelInfo, AiProviderInfo, AiProviderTag,
    AiReply, AiReplyEvent, AiReplyListener, AiSettingsArg, schema_reader,
};
use crate::cancel_token::{CancelToken, token};
use crate::error::CoreError;
use crate::library::{optional_id, secret_error};
use crate::mcp::open_sessions::OpenSessions;
use crate::mcp::{ActiveProject, AppBridge, HistoryAccess, McpAppHost};
use crate::runtime::on_runtime;
use crate::session::DatabaseSession;

// A cap so a model that keeps calling tools without answering cannot loop forever.
const MAX_ROUNDS: u32 = 24;

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
    catalog: ModelCatalog,
    // Agent mode reaches the open sessions and records history as the MCP server does.
    open_sessions: Arc<OpenSessions>,
    history: HistoryAccess,
}

impl AiAssistant {
    #[expect(
        clippy::too_many_arguments,
        reason = "the core hands its shared handles in; grouping them would only move the list"
    )]
    pub(crate) fn new(
        items: Arc<dyn SecretItems>,
        store: Option<ConnectionStore>,
        tasks: Tasks,
        version: String,
        client: Arc<OnceCell<AiClient>>,
        catalog: ModelCatalog,
        open_sessions: Arc<OpenSessions>,
        history: HistoryAccess,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                items,
                store,
                tasks,
                version,
                client,
                catalog,
                open_sessions,
                history,
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

    // The models the provider offers the key, merged with the catalog. On a failure, `offline_models` gives the
    // catalog's to show beside the error.
    pub async fn list_models(
        &self,
        settings: AiSettingsArg,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Vec<AiModelInfo>, CoreError> {
        let inner = self.inner.clone();
        let cancel = token(cancel);
        on_runtime(&self.inner.tasks, async move {
            let (client, endpoint) = inner.connect(&settings).await?;
            tokio::select! {
                biased;
                () = cancel.cancelled() => Err(CoreError::Cancelled),
                listed = tablepro_ai::list_models(&client, &endpoint, &inner.catalog) => {
                    Ok(listed?.into_iter().map(AiModelInfo::from).collect())
                }
            }
        })
        .await
    }

    // The catalog's models for the provider, each offline; none for the compatible server.
    pub fn offline_models(&self, provider: AiProviderTag) -> Vec<AiModelInfo> {
        self.inner
            .catalog
            .offline_models(provider.into())
            .into_iter()
            .map(AiModelInfo::from)
            .collect()
    }

    // The model an empty setting resolves to, which the app saves on first use; None for the compatible server.
    pub fn default_model(&self, provider: AiProviderTag) -> Option<String> {
        self.inner.catalog.default_model(provider.into())
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

    // Agent mode: the model runs the 11 MCP tools in rounds until a final answer. `host` opens connections as
    // the picker does; `approver` answers writes in the assistant pane (ADR 0014). `project_id` scopes the
    // connections the tools see to the one the app shows, None for all. Returns at once, like `reply`.
    #[expect(
        clippy::too_many_arguments,
        reason = "host and approver are callback interfaces, so neither folds into a record with the rest"
    )]
    pub fn reply_agentic(
        &self,
        session: Arc<DatabaseSession>,
        settings: AiSettingsArg,
        chat: AiChatArg,
        project_id: Option<String>,
        host: Box<dyn McpAppHost>,
        approver: Box<dyn AiApprover>,
        listener: Box<dyn AiReplyListener>,
    ) -> Result<Arc<AiReply>, CoreError> {
        let connections = self.inner.store.clone().ok_or_else(|| {
            CoreError::failed(
                "ffi.no_storage",
                "agent mode needs the saved connections, which this core has no folder for",
            )
        })?;
        let project = ActiveProject::default();
        project.set(optional_id(project_id.as_deref())?);
        let reply = Arc::new(AiReply::new(listener));
        let state = reply.state();
        let inner = self.inner.clone();
        let bridge = AppBridge {
            app: Arc::from(host),
            sessions: inner.open_sessions.clone(),
            tasks: inner.tasks.clone(),
            history: inner.history.clone(),
            requests: AtomicU64::new(1),
            project,
        };
        let agent_host = AgentHost::new(Arc::new(bridge), Arc::from(approver), inner.tasks.clone());
        let context = ToolContext {
            host: Arc::new(agent_host),
            connections,
        };
        drop(
            self.inner
                .tasks
                .spawn_task(async move { inner.run_agent(&session, &settings, chat, context, &state).await }),
        );
        Ok(reply)
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
                if let Some(event) = AiReplyEvent::from_reply(event) {
                    state.post(event);
                }
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

    // The agent loop: send the turn with the tools, run every tool the model asks for, send the results,
    // and go again until it answers without a tool. Stops with its session, as `stream` does.
    async fn run_agent(
        &self,
        session: &DatabaseSession,
        settings: &AiSettingsArg,
        chat: AiChatArg,
        context: ToolContext,
        state: &ReplyState,
    ) {
        // One token for the user's Stop and the session's end, so a tool's dispatch and a write's approval both end
        // on either. The guard follows the session, and the handle aborts it when this returns.
        let work = state.cancel.child_token();
        let shutdown = session.session().shutdown_signal();
        let _guard = {
            let work = work.clone();
            self.tasks.spawn_owned(async move {
                shutdown.cancelled().await;
                work.cancel();
            })
        };
        let stopped = work.cancelled();
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
        let mut request = ChatRequest::from(chat);
        request.tools = tool_specs();
        for _ in 0..MAX_ROUNDS {
            let round = tokio::select! {
                biased;
                () = &mut stopped => return state.post(AiReplyEvent::Stopped),
                round = self.run_round(&client, &endpoint, &request, &work, state) => round,
            };
            let end = match round.end {
                Ok(end) => end,
                Err(error) => return state.post(AiReplyEvent::failed(error.into())),
            };
            if end.stop != StopReason::ToolUse || round.calls.is_empty() {
                return state.post(end.into());
            }
            let mut assistant = Vec::new();
            if !round.text.is_empty() {
                assistant.push(ContentBlock::Text(round.text));
            }
            for call in &round.calls {
                assistant.push(ContentBlock::ToolUse {
                    id: call.id.clone(),
                    name: call.name.clone(),
                    input: call.input.clone(),
                });
            }
            request.messages.push(ChatMessage {
                role: Role::Assistant,
                content: assistant,
            });
            let mut results = Vec::new();
            for call in round.calls {
                state.post(AiReplyEvent::ToolCall {
                    id: call.id.clone(),
                    name: call.name.clone(),
                    input: call.input.to_string(),
                });
                state.post(AiReplyEvent::ToolStarted { id: call.id.clone() });
                // Awaited, not raced against the stop: a write waits on the approver, and a stop fires `work`, which
                // lets execute_query withdraw the question and return rather than leaving the dialog up.
                let ran = dispatch_tool(&context, &call.name, call.input, work.clone()).await;
                if work.is_cancelled() {
                    return state.post(AiReplyEvent::Stopped);
                }

                let (output, is_error) = match ran {
                    Ok(text) => (text, false),
                    Err(error) => (format!("{}: {}", error.code(), error.message()), true),
                };
                state.post(AiReplyEvent::ToolFinished {
                    id: call.id.clone(),
                    output: output.clone(),
                    is_error,
                });
                results.push(ContentBlock::ToolResult {
                    id: call.id,
                    content: output,
                    is_error,
                });
            }
            request.messages.push(ChatMessage {
                role: Role::User,
                content: results,
            });
        }
        state.post(AiReplyEvent::failed(CoreError::failed(
            "ai.agent_rounds",
            "the agent ran its tool limit without a final answer",
        )));
    }

    // One model turn: forward its text as it streams, collect the tool calls and the end.
    async fn run_round(
        &self,
        client: &AiClient,
        endpoint: &Endpoint,
        request: &ChatRequest,
        cancel: &tokio_util::sync::CancellationToken,
        state: &ReplyState,
    ) -> Round {
        let (sender, mut receiver) = mpsc::unbounded_channel();
        let streaming = stream_reply(client, endpoint, request, cancel.clone(), sender);
        let collecting = async {
            let mut round = Round::default();
            while let Some(event) = receiver.recv().await {
                match event {
                    ReplyEvent::Text(part) => {
                        round.text.push_str(&part);
                        state.post(AiReplyEvent::Text { part });
                    }
                    ReplyEvent::ToolCall { id, name, input } => round.calls.push(ToolCallData { id, name, input }),
                    ReplyEvent::Finished(end) => round.end = Ok(end),
                    ReplyEvent::Failed(error) => round.end = Err(error),
                }
            }
            round
        };
        let ((), round) = tokio::join!(streaming, collecting);
        round
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

struct ToolCallData {
    id: String,
    name: String,
    input: serde_json::Value,
}

struct Round {
    text: String,
    calls: Vec<ToolCallData>,
    end: Result<ReplyEnd, tablepro_ai::AiError>,
}

impl Default for Round {
    fn default() -> Self {
        Self {
            text: String::new(),
            calls: Vec::new(),
            // Overwritten by the stream's Finished or Failed. It stands only when the stream sent neither,
            // which a cancel does, and the loop then posts Stopped rather than reading this.
            end: Err(tablepro_ai::AiError::Protocol(
                "the reply ended before it was complete".to_owned(),
            )),
        }
    }
}

// The 11 MCP tools as the model sees them, read from the one catalog the HTTP server also serves.
fn tool_specs() -> Vec<ToolSpec> {
    tablepro_mcp::catalog()
        .into_iter()
        .map(|tool| ToolSpec {
            name: tool.name.into_owned(),
            description: tool.description.map(|text| text.into_owned()).unwrap_or_default(),
            input_schema: serde_json::Value::Object((*tool.input_schema).clone()),
        })
        .collect()
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
