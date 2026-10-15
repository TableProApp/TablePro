use std::sync::Arc;

use rmcp::{
    ErrorData, RoleServer, ServerHandler, ServiceExt,
    model::{
        CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, ListToolsResult, PaginatedRequestParams,
        ServerCapabilities, ServerConfig, Tool,
    },
    service::RequestContext,
};
use serde_json::{Map, Value as JsonValue};

use crate::bridge::McpBridge;
use crate::server::{tool_annotations, tool_description, tool_schema};
use crate::tools::{self, TOOL_NAMES};

#[derive(Clone)]
pub struct BridgeHandler {
    bridge: Arc<McpBridge>,
}

impl BridgeHandler {
    pub fn new(bridge: Arc<McpBridge>) -> Self {
        Self { bridge }
    }
}

fn token_from_meta(context: &RequestContext<RoleServer>) -> Option<String> {
    context
        .meta
        .0
        .get("authorization")
        .and_then(JsonValue::as_str)
        .map(str::to_string)
}

fn json_object(value: JsonValue) -> Map<String, JsonValue> {
    match value {
        JsonValue::Object(map) => map,
        _ => Map::new(),
    }
}

fn tool_error_result(error: &crate::errors::McpToolError) -> CallToolResult {
    let mut result = CallToolResult::error(vec![ContentBlock::text(error.message)]);
    result.structured_content = Some(error.structured_content());
    result
}

impl ServerHandler for BridgeHandler {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        let token = token_from_meta(&context)
            .ok_or_else(|| ErrorData::invalid_request("missing token (pass _meta.authorization)", None))?;
        self.bridge
            .authenticate(&token)
            .map_err(|message| ErrorData::invalid_request(message, None))?;
        let tools = TOOL_NAMES
            .iter()
            .map(|name| {
                let tool = Tool::new(*name, tool_description(name), Arc::new(json_object(tool_schema(name))));
                match serde_json::from_value(tool_annotations(name)) {
                    Ok(annotations) => tool.with_annotations(annotations),
                    Err(_) => tool,
                }
            })
            .collect();
        Ok(ListToolsResult::with_all_items(tools))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let mut arguments = JsonValue::Object(request.arguments.unwrap_or_default());
        let token = token_from_meta(&context)
            .or_else(|| arguments.get("token").and_then(JsonValue::as_str).map(str::to_string));
        let outcome = match token {
            None => Err(crate::errors::McpToolError::from("missing token")),
            Some(token) => match self.bridge.authenticate(&token) {
                Err(message) => Err(crate::errors::McpToolError::from(message)),
                Ok(token) => {
                    if let Some(map) = arguments.as_object_mut() {
                        map.remove("token");
                    }
                    tools::dispatch_structured(&self.bridge, &token, &request.name, arguments).await
                }
            },
        };
        let result = match outcome {
            Ok(content) => CallToolResult::success(vec![ContentBlock::text(content.to_string())]),
            Err(error) => tool_error_result(&error),
        };
        Ok(result.into())
    }
}

pub async fn serve_stdio_with_rmcp(bridge: Arc<McpBridge>) -> Result<(), String> {
    let running = BridgeHandler::new(bridge)
        .serve(rmcp::transport::stdio())
        .await
        .map_err(|error| error.to_string())?;
    running.waiting().await.map_err(|error| error.to_string()).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    struct NoProvider;

    #[async_trait::async_trait]
    impl crate::bridge::ConnectionProvider for NoProvider {
        async fn list_saved_connections(&self) -> Result<Vec<tablepro_storage::SavedConnection>, String> {
            Ok(Vec::new())
        }
        async fn connection(
            &self,
            _connection_id: uuid::Uuid,
            _principal: tablepro_policy::Principal,
        ) -> Result<Arc<dyn tablepro_core::Connection>, String> {
            Err("no connections in this test".into())
        }
    }

    struct Client {
        writer: tokio::io::WriteHalf<tokio::io::DuplexStream>,
        lines: tokio::io::Lines<BufReader<tokio::io::ReadHalf<tokio::io::DuplexStream>>>,
        next_id: u64,
        _dir: tempfile::TempDir,
        pub token: String,
    }

    impl Client {
        async fn start() -> Self {
            let dir = tempfile::tempdir().unwrap();
            let store = Arc::new(crate::tokens::TokenStore::open(dir.path().join("tokens.json")).unwrap());
            let (_metadata, token) = store
                .issue("test".into(), crate::TokenPermissions::ReadOnly, vec![], None)
                .unwrap();
            let bridge = Arc::new(McpBridge::new(Arc::new(NoProvider), store));
            let (client_io, server_io) = tokio::io::duplex(64 * 1024);
            tokio::spawn(async move {
                let running = BridgeHandler::new(bridge).serve(server_io).await.unwrap();
                let _ = running.waiting().await;
            });
            let (read, writer) = tokio::io::split(client_io);
            let mut client = Self {
                writer,
                lines: BufReader::new(read).lines(),
                next_id: 1,
                _dir: dir,
                token,
            };
            let initialized = client
                .request(
                    "initialize",
                    json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}),
                )
                .await;
            assert!(initialized.get("result").is_some(), "{initialized}");
            client
                .send(json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))
                .await;
            client
        }

        async fn send(&mut self, message: JsonValue) {
            self.writer.write_all(format!("{message}\n").as_bytes()).await.unwrap();
        }

        async fn request(&mut self, method: &str, params: JsonValue) -> JsonValue {
            let id = self.next_id;
            self.next_id += 1;
            self.send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}))
                .await;
            let line = self.lines.next_line().await.unwrap().expect("a response");
            serde_json::from_str(&line).unwrap()
        }
    }

    #[tokio::test]
    async fn tools_list_is_refused_without_a_token() {
        let mut client = Client::start().await;
        let response = client.request("tools/list", json!({})).await;
        assert!(response.get("error").is_some(), "{response}");
    }

    #[tokio::test]
    async fn tools_list_is_refused_with_a_bad_token() {
        let mut client = Client::start().await;
        let response = client
            .request("tools/list", json!({"_meta": {"authorization": "not-a-token"}}))
            .await;
        assert!(response.get("error").is_some(), "{response}");
    }

    #[tokio::test]
    async fn tools_list_names_every_tool_for_a_valid_token_with_generated_schemas() {
        let mut client = Client::start().await;
        let token = client.token.clone();
        let response = client
            .request("tools/list", json!({"_meta": {"authorization": token}}))
            .await;
        let tools = response["result"]["tools"].as_array().expect("tools");
        let names: Vec<&str> = tools.iter().filter_map(|tool| tool["name"].as_str()).collect();
        assert_eq!(names, TOOL_NAMES);
        assert!(
            tools.iter().all(|tool| tool["inputSchema"]["type"] == "object"),
            "{response}"
        );
        let hint =
            |name: &str, key: &str| tools.iter().find(|tool| tool["name"] == name).unwrap()["annotations"][key].clone();
        assert_eq!(hint("list_tables", "readOnlyHint"), true, "{response}");
        assert_eq!(hint("execute_write", "readOnlyHint"), false, "{response}");
        assert_eq!(hint("execute_write", "destructiveHint"), true, "{response}");
    }

    #[tokio::test]
    async fn a_tool_call_accepts_the_token_in_the_arguments_like_today() {
        let mut client = Client::start().await;
        let token = client.token.clone();
        let response = client
            .request(
                "tools/call",
                json!({"name": "list_connections", "arguments": {"token": token}}),
            )
            .await;
        assert_eq!(response["result"]["isError"], false, "{response}");
        assert_eq!(response["result"]["content"][0]["text"], "[]");
    }

    #[tokio::test]
    async fn a_tool_call_without_a_token_is_an_error_result_and_runs_nothing() {
        let mut client = Client::start().await;
        let response = client
            .request("tools/call", json!({"name": "list_connections", "arguments": {}}))
            .await;
        assert_eq!(response["result"]["isError"], true, "{response}");
        assert_eq!(response["result"]["structuredContent"]["code"], "request_failed");
        assert_eq!(
            response["result"]["structuredContent"]["operation_outcome"],
            "not_started"
        );
    }

    #[test]
    fn rmcp_transport_serializes_the_same_structured_outcome() {
        let error =
            crate::errors::McpToolError::from_write_error(&tablepro_core::DriverError::OperationOutcomeUnknown {
                source: Box::new(tablepro_core::DriverError::Disconnected),
            });
        let result = serde_json::to_value(tool_error_result(&error)).unwrap();

        assert_eq!(result["isError"], true);
        assert_eq!(result["structuredContent"], error.structured_content());
    }

    #[tokio::test]
    async fn a_tool_call_with_a_bad_token_is_an_error_result() {
        let mut client = Client::start().await;
        let response = client
            .request(
                "tools/call",
                json!({"name": "list_connections", "arguments": {"token": "nope"}}),
            )
            .await;
        assert_eq!(response["result"]["isError"], true, "{response}");
    }

    #[tokio::test]
    async fn a_top_level_params_token_is_not_seen_by_the_sdk_layer() {
        let mut client = Client::start().await;
        let token = client.token.clone();
        let response = client
            .request(
                "tools/call",
                json!({"name": "list_connections", "arguments": {}, "token": token}),
            )
            .await;
        assert_eq!(
            response["result"]["isError"], true,
            "documents the compatibility gap: params.token needs a transport shim"
        );
    }
}
