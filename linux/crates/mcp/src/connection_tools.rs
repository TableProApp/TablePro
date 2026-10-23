use std::collections::HashMap;
use std::sync::Arc;

use serde::Serialize;
use tablepro_core::{ExternalAccess, SafeModeLevel};
use tablepro_session::Session;
use tablepro_storage::SavedConnection;

use crate::mcp_host::OpenOutcome;
use crate::tool_args::{ConnectionArgs, NoArgs};
use crate::tool_context::ToolContext;
use crate::tool_error::ToolError;

#[derive(Serialize)]
struct ConnectionList {
    connections: Vec<ListedConnection>,
}

#[derive(Serialize)]
struct ListedConnection {
    id: String,
    name: String,
    #[serde(rename = "type")]
    driver: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    host: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    port: Option<u16>,
    #[serde(skip_serializing_if = "String::is_empty")]
    database: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    group: Option<String>,
    is_open: bool,
    external_access: ExternalAccess,
    safe_mode: SafeModeLevel,
}

pub async fn list_connections(context: &ToolContext, _args: NoArgs) -> Result<String, ToolError> {
    let mut saved = context.visible_connections()?;
    saved.sort_by(|left, right| {
        left.name
            .to_lowercase()
            .cmp(&right.name.to_lowercase())
            .then(left.id.cmp(&right.id))
    });
    let open: HashMap<uuid::Uuid, Arc<Session>> = {
        let mut open = HashMap::new();
        for id in context.host.open_connections().await {
            if let Some(session) = context.host.session(id).await {
                open.insert(id, session);
            }
        }
        open
    };
    let connections = saved
        .into_iter()
        .map(|connection| {
            let session = open.get(&connection.id);
            ListedConnection {
                id: connection.id.to_string(),
                port: (!connection.host.is_empty()).then_some(connection.port),
                host: connection.host,
                driver: connection.driver_id,
                database: connection.database,
                group: connection.group.map(|group| group.as_str().to_owned()),
                is_open: session.is_some(),
                external_access: connection.external_access,
                safe_mode: session.map_or(connection.safe_mode, |session| session.safe_mode()),
                name: connection.name,
            }
        })
        .collect();
    to_json(&ConnectionList { connections })
}

#[derive(Serialize)]
struct ConnectAnswer<'a> {
    status: &'static str,
    connection_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    safe_mode: Option<SafeModeLevel>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<&'a str>,
}

pub async fn connect(context: &ToolContext, args: ConnectionArgs) -> Result<String, ToolError> {
    let connection = context.connection(&args.connection_id)?;
    if let Some(session) = context.host.session(connection.id).await
        && !session.is_shut_down()
    {
        return opened(&connection, &session);
    }
    match context.host.open(connection.clone()).await {
        OpenOutcome::Open(session) => opened(&connection, &session),
        OpenOutcome::Connecting => to_json(&ConnectAnswer {
            status: "connecting",
            connection_id: connection.id.to_string(),
            safe_mode: None,
            message: Some(
                "TablePro is still connecting, or waits for the user in its window. Call connect again in a while.",
            ),
        }),
        OpenOutcome::Closed => Err(ToolError::NotConnected(format!(
            "“{}” did not open; TablePro shows why in its window",
            connection.name
        ))),
    }
}

fn opened(connection: &SavedConnection, session: &Session) -> Result<String, ToolError> {
    to_json(&ConnectAnswer {
        status: "open",
        connection_id: connection.id.to_string(),
        safe_mode: Some(session.safe_mode()),
        message: None,
    })
}

pub fn to_json(value: &impl Serialize) -> Result<String, ToolError> {
    serde_json::to_string(value).map_err(|error| ToolError::Internal(error.to_string()))
}
