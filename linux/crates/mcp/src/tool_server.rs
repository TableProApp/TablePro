use std::sync::Arc;

use rmcp::handler::server::common::schema_for_type;
use rmcp::model::{
    CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, Implementation, ListToolsResult,
    PaginatedRequestParams, ServerCapabilities, ServerConfig, Tool, ToolAnnotations,
};
use rmcp::service::RequestContext;
use rmcp::{ErrorData, RoleServer, ServerHandler};
use schemars::JsonSchema;
use serde::de::DeserializeOwned;

use crate::tool_args::{BrowseArgs, ConnectionArgs, CountArgs, NoArgs, QueryArgs, SchemaArgs, TableArgs};
use crate::tool_context::ToolContext;
use crate::tool_error::ToolError;
use crate::{connection_tools, query_tools, schema_tools};

const INSTRUCTIONS: &str = "TablePro reaches the database connections the user saved in it. \
Start with list_connections. A connection has to be open in a TablePro window: call connect for one whose \
is_open is false, and the user may have to answer TablePro first. Call describe_table before writing SQL \
against a table. execute_query runs one statement: a read runs read-only, and a write runs only where the \
connection's External Clients level allows it and after the user approves it in TablePro. A refusal is the \
user's setting, not a passing failure, so do not retry it.";

/// The tools, as a stateless handler: every call reads the saved
/// connections and the windows again.
#[derive(Clone)]
pub struct ToolServer {
    context: ToolContext,
    version: Arc<str>,
}

impl ToolServer {
    pub fn new(context: ToolContext, version: &str) -> Self {
        Self {
            context,
            version: Arc::from(version),
        }
    }

    async fn dispatch(
        &self,
        request: CallToolRequestParams,
        context: &RequestContext<RoleServer>,
    ) -> Result<String, ToolError> {
        let arguments = serde_json::Value::Object(request.arguments.unwrap_or_default());
        let tools = &self.context;
        let cancel = context.ct.clone();
        match request.name.as_ref() {
            "list_connections" => connection_tools::list_connections(tools, parse(arguments)?).await,
            "connect" => connection_tools::connect(tools, parse(arguments)?).await,
            "list_schemas" => schema_tools::list_schemas(tools, parse(arguments)?).await,
            "list_tables" => schema_tools::list_tables(tools, parse(arguments)?).await,
            "describe_table" => schema_tools::describe_table(tools, parse(arguments)?).await,
            "get_table_ddl" => schema_tools::get_table_ddl(tools, parse(arguments)?).await,
            "browse_table" => query_tools::browse_table(tools, parse(arguments)?, cancel).await,
            "count_rows" => query_tools::count_rows(tools, parse(arguments)?).await,
            "execute_query" => query_tools::execute_query(tools, parse(arguments)?, cancel).await,
            other => Err(ToolError::NotFound(format!("there is no tool named {other}"))),
        }
    }
}

fn parse<T: DeserializeOwned>(arguments: serde_json::Value) -> Result<T, ToolError> {
    serde_json::from_value(arguments).map_err(|error| ToolError::InvalidArgument(error.to_string()))
}

impl ServerHandler for ToolServer {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("tablepro", self.version.as_ref()).with_title("TablePro"))
            .with_instructions(INSTRUCTIONS)
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        Ok(ListToolsResult::with_all_items(catalog()))
    }

    fn get_tool(&self, name: &str) -> Option<Tool> {
        catalog().into_iter().find(|tool| tool.name == name)
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let name = request.name.clone();
        let result = match self.dispatch(request, &context).await {
            Ok(text) => CallToolResult::success(vec![ContentBlock::text(text)]),
            Err(error) => {
                tracing::debug!(tool = %name, code = error.code(), "an MCP tool call failed");
                error.into_result()
            }
        };
        Ok(result.into())
    }
}

fn tool<T: JsonSchema + 'static>(name: &'static str, title: &str, description: &'static str, reads: bool) -> Tool {
    let annotations = ToolAnnotations::with_title(title)
        .read_only(reads)
        .destructive(!reads)
        .open_world(false);
    Tool::new(name, description, schema_for_type::<T>())
        .with_title(title)
        .with_annotations(annotations)
}

pub fn catalog() -> Vec<Tool> {
    vec![
        tool::<NoArgs>(
            "list_connections",
            "List Connections",
            "The saved connections a client may use, with whether each is open in TablePro, its External Clients \
level (read_only or read_write) and its Safe Mode level.",
            true,
        ),
        tool::<ConnectionArgs>(
            "connect",
            "Open a Connection",
            "Open a saved connection in a TablePro window, as the user would. The user may have to answer TablePro \
first, such as for a password; then the status is connecting, and calling connect again tells when it is open.",
            true,
        ),
        tool::<ConnectionArgs>(
            "list_schemas",
            "List Schemas",
            "The schemas of an open connection, with the default one marked.",
            true,
        ),
        tool::<SchemaArgs>(
            "list_tables",
            "List Tables",
            "The tables and views of one schema, read again from the server.",
            true,
        ),
        tool::<TableArgs>(
            "describe_table",
            "Describe a Table",
            "A table's columns with their types, nullability, keys and defaults, its indexes and foreign keys, \
and its row count where the engine keeps one.",
            true,
        ),
        tool::<TableArgs>(
            "get_table_ddl",
            "Show CREATE TABLE",
            "The statements that create the table as it is defined now, in the connection's own dialect.",
            true,
        ),
        tool::<BrowseArgs>(
            "browse_table",
            "Browse a Table",
            "Rows of a table or view, filtered and sorted without writing SQL. Identifiers and values are quoted \
for the engine.",
            true,
        ),
        tool::<CountArgs>(
            "count_rows",
            "Count Rows",
            "The exact number of rows in a table, under optional filters.",
            true,
        ),
        tool::<QueryArgs>(
            "execute_query",
            "Run a Statement",
            "Run one SQL statement, or one batch on SQL Server. A read runs read-only. A write runs only on a \
connection whose External Clients level is Read & Write and whose Safe Mode is not Read-Only, and only after the \
user approves it in TablePro.",
            false,
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_tool_has_an_object_schema_and_only_execute_query_writes() {
        let tools = catalog();

        let names: Vec<&str> = tools.iter().map(|tool| tool.name.as_ref()).collect();
        assert_eq!(names.len(), 9);
        for tool in &tools {
            assert_eq!(
                tool.input_schema.get("type").and_then(serde_json::Value::as_str),
                Some("object"),
                "{}",
                tool.name
            );
            let read_only = tool
                .annotations
                .as_ref()
                .and_then(|annotations| annotations.read_only_hint);
            assert_eq!(read_only, Some(tool.name != "execute_query"), "{}", tool.name);
        }
    }

    #[test]
    fn an_unknown_argument_is_refused() {
        let arguments: serde_json::Value =
            serde_json::from_str(r#"{"connection_id": "x", "query": "SELECT 1", "database": "other"}"#).expect("JSON");

        let refused = parse::<QueryArgs>(arguments);

        assert!(matches!(refused, Err(ToolError::InvalidArgument(_))));
    }
}
