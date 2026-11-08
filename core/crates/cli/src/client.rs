use std::error::Error;
use std::time::Duration;

use rmcp::model::{
    CallToolRequest, CallToolRequestParams, ClientCapabilities, ClientConfig, ClientRequest, ContentBlock,
    Implementation, ServerResult,
};
use rmcp::service::{ClientInitializeError, PeerRequestOptions, RunningService};
use rmcp::transport::StreamableHttpClientTransport;
use rmcp::transport::streamable_http_client::{
    AuthRequiredError, StreamableHttpClientTransportConfig, StreamableHttpError,
};
use rmcp::{RoleClient, ServiceError, ServiceExt};
use serde::Serialize;

use crate::command_error::CommandError;
use crate::endpoint::{Endpoint, endpoint};
use crate::host::{Host, HostError};
use crate::peer_verification::http_client;

const CLIENT_NAME: &str = "tablepro-cli";
const CLIENT_TITLE: &str = "Command Line";
const SERVER_NAME: &str = "tablepro";
// core/crates/mcp/src/query_tools.rs, DEFAULT_TIMEOUT_SECONDS.
const SERVER_STATEMENT_SECONDS: u32 = 30;
// Past a deadline rmcp tells the server to drop the call; this bounds a server too stalled to take that.
const CANCEL_GRACE: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy)]
pub(crate) struct Deadlines {
    pub(crate) handshake: Duration,
    pub(crate) tool: Duration,
    pub(crate) statement_margin: Duration,
}

impl Deadlines {
    // The handshake waits on no window and no database. Other tools wait on the app's windows and on reads
    // the server stops at 15 s, connect at 10 s. A statement may first wait on the user's answer to a write.
    pub(crate) const TABLEPRO: Self = Self {
        handshake: Duration::from_secs(15),
        tool: Duration::from_secs(60),
        statement_margin: Duration::from_secs(120),
    };

    pub(crate) fn statement(&self, timeout_seconds: Option<u32>) -> Duration {
        Duration::from_secs(u64::from(timeout_seconds.unwrap_or(SERVER_STATEMENT_SECONDS)))
            .saturating_add(self.statement_margin)
    }

    // The server reads each table on its own, under the bound one tool call has.
    pub(crate) fn tables(&self, tables: usize) -> Duration {
        self.tool
            .saturating_mul(u32::try_from(tables.max(1)).unwrap_or(u32::MAX))
    }
}

pub(crate) struct McpClient {
    service: RunningService<RoleClient, ClientConfig>,
    port: u16,
    deadlines: Deadlines,
}

impl McpClient {
    pub(crate) async fn connect(host: &(impl Host + Clone + Send + Sync + 'static)) -> Result<Self, CommandError> {
        Self::connect_to(&endpoint(host)?, &host.app_version(), host).await
    }

    pub(crate) async fn connect_to(
        endpoint: &Endpoint,
        version: &str,
        host: &(impl Host + Clone + Send + Sync + 'static),
    ) -> Result<Self, CommandError> {
        Self::connect_within(endpoint, version, Deadlines::TABLEPRO, host).await
    }

    pub(crate) async fn connect_within(
        endpoint: &Endpoint,
        version: &str,
        deadlines: Deadlines,
        host: &(impl Host + Clone + Send + Sync + 'static),
    ) -> Result<Self, CommandError> {
        let port = endpoint.port;
        let http = http_client(host, port).map_err(|error| CommandError::Transport(error.to_string()))?;
        let config = StreamableHttpClientTransportConfig::with_uri(format!("http://127.0.0.1:{port}/mcp"))
            .auth_header(endpoint.token.clone());
        let transport = StreamableHttpClientTransport::with_client(http, config);
        let identity = ClientConfig::new(
            ClientCapabilities::default(),
            Implementation::new(CLIENT_NAME, version).with_title(CLIENT_TITLE),
        );
        let service = tokio::time::timeout(deadlines.handshake, identity.serve(transport))
            .await
            .map_err(|_| no_answer(deadlines.handshake))?
            .map_err(|error| initialize_failure(&error, port))?;
        let client = Self {
            service,
            port,
            deadlines,
        };
        if client.server_name().as_deref() != Some(SERVER_NAME) {
            return Err(CommandError::NotTablePro { port });
        }
        Ok(client)
    }

    pub(crate) fn server_version(&self) -> Option<String> {
        self.service
            .peer_info()
            .and_then(|info| info.server_info.as_ref().map(|server| server.version.clone()))
    }

    fn server_name(&self) -> Option<String> {
        self.service
            .peer_info()
            .and_then(|info| info.server_info.as_ref().map(|server| server.name.clone()))
    }

    pub(crate) fn deadlines(&self) -> Deadlines {
        self.deadlines
    }

    pub(crate) async fn call(&self, tool: &'static str, arguments: &impl Serialize) -> Result<String, CommandError> {
        self.call_within(tool, arguments, self.deadlines.tool).await
    }

    // The text of a tool's answer, or its failure with the tool's code.
    pub(crate) async fn call_within(
        &self,
        tool: &'static str,
        arguments: &impl Serialize,
        deadline: Duration,
    ) -> Result<String, CommandError> {
        let arguments = serde_json::to_value(arguments).map_err(|error| CommandError::Answer(error.to_string()))?;
        let params = match arguments {
            serde_json::Value::Object(arguments) => CallToolRequestParams::new(tool).with_arguments(arguments),
            _ => CallToolRequestParams::new(tool),
        };
        tracing::debug!(tool, ?deadline, "calling a TablePro tool");
        let request = ClientRequest::from(CallToolRequest::new(params));
        let peer = self.service.peer();
        let answered = tokio::time::timeout(deadline.saturating_add(CANCEL_GRACE), async {
            peer.send_request_with_option(request, PeerRequestOptions::with_timeout(deadline))
                .await?
                .await_response()
                .await
        })
        .await;
        let result = match answered {
            Err(_) | Ok(Err(ServiceError::Timeout { .. })) => return Err(no_answer(deadline)),
            Ok(Err(error)) => return Err(service_failure(error, self.port)),
            Ok(Ok(ServerResult::CallToolResult(result))) => result,
            Ok(Ok(_)) => return Err(service_failure(ServiceError::UnexpectedResponse, self.port)),
        };
        let text: String = result
            .content
            .iter()
            .filter_map(ContentBlock::as_text)
            .map(|content| content.text.as_str())
            .collect();
        match result.is_error {
            Some(true) => Err(CommandError::from_tool_text(&text)),
            _ => Ok(text),
        }
    }
}

fn no_answer(deadline: Duration) -> CommandError {
    CommandError::NoAnswer {
        seconds: deadline.as_secs(),
    }
}

fn initialize_failure(error: &ClientInitializeError, port: u16) -> CommandError {
    match error {
        ClientInitializeError::TransportError { error, .. } => transport_failure(error, port),
        other => CommandError::Transport(other.to_string()),
    }
}

fn service_failure(error: ServiceError, port: u16) -> CommandError {
    match error {
        ServiceError::McpError(data) => CommandError::Transport(data.message.into_owned()),
        ServiceError::TransportSend(error) => transport_failure(&error, port),
        other => CommandError::Transport(other.to_string()),
    }
}

// rmcp nests the HTTP failure inside its own errors; the layer that knows what went wrong is found by type.
fn transport_failure(error: &(dyn Error + 'static), port: u16) -> CommandError {
    let mut layer = Some(error);
    while let Some(current) = layer {
        if current.is::<AuthRequiredError>() {
            return CommandError::TokenRefused { port };
        }
        if let Some(host) = current.downcast_ref::<HostError>() {
            return CommandError::Host(host.clone());
        }
        if let Some(StreamableHttpError::Client(http)) = current.downcast_ref::<StreamableHttpError<reqwest::Error>>()
            && let Some(failure) = http_failure(http, port)
        {
            return failure;
        }
        if let Some(http) = current.downcast_ref::<reqwest::Error>()
            && let Some(failure) = http_failure(http, port)
        {
            return failure;
        }
        layer = current.source();
    }
    CommandError::Transport(error.to_string())
}

fn http_failure(error: &reqwest::Error, port: u16) -> Option<CommandError> {
    let mut layer = error.source();
    while let Some(current) = layer {
        if let Some(host) = current.downcast_ref::<HostError>() {
            return Some(CommandError::Host(host.clone()));
        }
        layer = current.source();
    }
    if error.is_connect() {
        return Some(CommandError::NotAnswering { port });
    }
    match error.status() {
        Some(reqwest::StatusCode::UNAUTHORIZED) => Some(CommandError::TokenRefused { port }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use async_trait::async_trait;
    use secrecy::SecretString;
    use tablepro_core::dialect::SqlDialect;
    use tablepro_mcp::{AccessToken, McpHost, McpServer, OpenOutcome, ToolContext, WriteApproval};
    use tablepro_session::Session;
    use tablepro_session::runtime::Tasks;
    use tablepro_storage::query_history::NewEntry;
    use tablepro_storage::{ConnectionStore, SavedConnection, StoragePaths};
    use uuid::Uuid;

    use super::*;
    use crate::exit::Exit;
    use crate::tool_arguments::NoArguments;

    const TOKEN: &str = "tp_test_token";

    // Real time: the deadlines are short, and a paused clock could fire one before a loopback connect lands.
    const SHORT: Deadlines = Deadlines {
        handshake: Duration::from_millis(300),
        tool: Duration::from_millis(300),
        statement_margin: Duration::from_millis(300),
    };

    // An app whose GTK thread never answers.
    struct Stalled;

    #[async_trait]
    impl McpHost for Stalled {
        async fn session(&self, _id: Uuid) -> Option<Arc<Session>> {
            std::future::pending().await
        }

        async fn open_connections(&self) -> Vec<Uuid> {
            std::future::pending().await
        }

        async fn open(&self, _connection: SavedConnection) -> OpenOutcome {
            std::future::pending().await
        }

        async fn approve(&self, _approval: WriteApproval) -> bool {
            std::future::pending().await
        }

        async fn record(&self, _entry: NewEntry, _dialect: Arc<dyn SqlDialect>) {}
    }

    fn endpoint_at(port: u16) -> Endpoint {
        Endpoint {
            port,
            token: TOKEN.to_owned(),
        }
    }

    #[tokio::test]
    async fn a_listener_that_never_answers_the_handshake_stops_at_its_deadline() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("a port");
        let port = listener.local_addr().expect("an address").port();
        let silent = tokio::spawn(async move {
            let mut held = Vec::new();
            while let Ok((stream, _)) = listener.accept().await {
                held.push(stream);
            }
        });

        let refused = McpClient::connect_within(&endpoint_at(port), "1.0.0", SHORT, &crate::runner::tests::STOPPED)
            .await
            .err();

        assert!(matches!(refused, Some(CommandError::NoAnswer { .. })), "{refused:?}");
        assert_eq!(refused.map(|error| error.exit()), Some(Exit::TimedOut));
        silent.abort();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_tool_call_the_app_never_answers_stops_at_its_deadline() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let paths = StoragePaths::under(dir.path(), "tablepro-test", "app.tablepro.TablePro.Test");
        let store = ConnectionStore::new(&paths);
        store.load_blocking().expect("an empty library");
        let token = AccessToken::from_secret(SecretString::from(TOKEN.to_owned())).expect("a token");
        let context = ToolContext {
            host: Arc::new(Stalled),
            connections: store,
        };
        let tasks = Tasks::new(tokio::runtime::Handle::current());
        let server = McpServer::start(0, token, context, "0.0.0-test", &tasks)
            .await
            .expect("a listening server");
        let client = McpClient::connect_within(
            &endpoint_at(server.address().port()),
            "1.0.0",
            SHORT,
            &crate::runner::tests::STOPPED,
        )
        .await
        .expect("a handshake the server answers itself");

        let refused = tokio::time::timeout(
            Duration::from_secs(10),
            client.call("list_connections", &NoArguments {}),
        )
        .await
        .expect("the call returns on its own");

        assert!(matches!(refused, Err(CommandError::NoAnswer { .. })), "{refused:?}");
    }

    #[test]
    fn a_statement_waits_for_its_own_timeout_and_an_export_for_each_table() {
        let deadlines = Deadlines::TABLEPRO;

        assert_eq!(deadlines.statement(None), Duration::from_secs(150));
        assert_eq!(deadlines.statement(Some(300)), Duration::from_secs(420));
        assert_eq!(deadlines.tables(0), Duration::from_secs(60));
        assert_eq!(deadlines.tables(3), Duration::from_secs(180));
    }
}
