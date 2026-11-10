use std::time::Duration;

use serde::Serialize;

use crate::answers::{ConnectAnswer, ConnectionList, ListedConnection, parse};
use crate::client::McpClient;
use crate::command_error::CommandError;
use crate::console::Console;
use crate::tool_arguments::{ConnectionArguments, NoArguments};

const OPEN_DEADLINE: Duration = Duration::from_secs(300);
const POLL_INTERVAL: Duration = Duration::from_secs(1);

pub(super) async fn list(client: &McpClient) -> Result<Vec<ListedConnection>, CommandError> {
    let answer: ConnectionList = parse(&client.call("list_connections", &NoArguments {}).await?)?;
    Ok(answer.connections)
}

pub(super) struct Resolved {
    connection: ListedConnection,
    opened: bool,
}

// Ids and names go through the one listing, so a connection hidden from clients reads as unknown either way.
pub(super) async fn resolve(
    client: &McpClient,
    wanted: &str,
    console: &mut Console<'_>,
) -> Result<Resolved, CommandError> {
    let connections = list(client).await?;
    let connection = find(&connections, wanted)?.clone();
    let opened = !connection.is_open;
    if opened {
        open(client, &connection, console).await?;
    }
    Ok(Resolved { connection, opened })
}

impl Resolved {
    pub(super) fn id(&self) -> &str {
        &self.connection.id
    }

    pub(super) async fn call(
        &self,
        client: &McpClient,
        console: &mut Console<'_>,
        tool: &'static str,
        arguments: &impl Serialize,
    ) -> Result<String, CommandError> {
        self.call_within(client, console, tool, arguments, client.deadlines().tool)
            .await
    }

    // The listing can call a connection open that closed since, so a tool that finds it closed gets one open and
    // one retry. Once open, a not_connected answer is final: a database the window does not hold gives it too.
    pub(super) async fn call_within(
        &self,
        client: &McpClient,
        console: &mut Console<'_>,
        tool: &'static str,
        arguments: &impl Serialize,
        deadline: Duration,
    ) -> Result<String, CommandError> {
        match client.call_within(tool, arguments, deadline).await {
            Err(error) if error.code() == "not_connected" && !self.opened && console.terminal().stderr => {
                open(client, &self.connection, console).await?;
                client.call_within(tool, arguments, deadline).await
            }
            answer => answer,
        }
    }
}

fn find<'a>(connections: &'a [ListedConnection], wanted: &str) -> Result<&'a ListedConnection, CommandError> {
    let by_id: Vec<&ListedConnection> = connections
        .iter()
        .filter(|connection| connection.id.eq_ignore_ascii_case(wanted))
        .collect();
    let by_name: Vec<&ListedConnection> = connections
        .iter()
        .filter(|connection| connection.name == wanted)
        .collect();
    let lowered = wanted.to_lowercase();
    let by_folded_name: Vec<&ListedConnection> = connections
        .iter()
        .filter(|connection| connection.name.to_lowercase() == lowered)
        .collect();
    let matches = [by_id, by_name, by_folded_name]
        .into_iter()
        .find(|matches| !matches.is_empty())
        .unwrap_or_default();
    match matches.as_slice() {
        [] => Err(CommandError::UnknownConnection(wanted.to_owned())),
        [only] => Ok(*only),
        many => Err(CommandError::AmbiguousConnection {
            name: wanted.to_owned(),
            ids: many.iter().map(|connection| connection.id.clone()).collect(),
        }),
    }
}

// connect opens a window in TablePro, which a script running unattended must not do behind the user.
async fn open(
    client: &McpClient,
    connection: &ListedConnection,
    console: &mut Console<'_>,
) -> Result<(), CommandError> {
    if !console.terminal().stderr {
        return Err(CommandError::NotOpen(connection.name.clone()));
    }
    console.note(&format!(
        "Opening “{}” in TablePro. Answer TablePro there if it asks.",
        connection.name
    ));
    // Bounded as a whole, so a connect call still running at the deadline does not stretch it.
    tokio::time::timeout(OPEN_DEADLINE, wait_open(client, connection))
        .await
        .unwrap_or_else(|_| Err(CommandError::OpenTimedOut(connection.name.clone())))
}

async fn wait_open(client: &McpClient, connection: &ListedConnection) -> Result<(), CommandError> {
    let arguments = ConnectionArguments {
        connection_id: &connection.id,
    };
    loop {
        let answer: ConnectAnswer = parse(&client.call("connect", &arguments).await?)?;
        if answer.status == "open" {
            return Ok(());
        }
        tokio::time::sleep(POLL_INTERVAL).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn listed(id: &str, name: &str) -> ListedConnection {
        ListedConnection {
            id: id.to_owned(),
            name: name.to_owned(),
            kind: "postgresql".to_owned(),
            is_open: true,
        }
    }

    fn found(connections: &[ListedConnection], wanted: &str) -> Result<String, CommandError> {
        find(connections, wanted).map(|connection| connection.id.clone())
    }

    #[test]
    fn an_id_wins_then_the_exact_name_then_the_name_in_any_case() {
        let connections = [
            listed("8b1f0c2e-0000-4000-8000-000000000001", "Staging"),
            listed("8b1f0c2e-0000-4000-8000-000000000002", "staging"),
            listed("8b1f0c2e-0000-4000-8000-000000000003", "Prod"),
        ];

        assert_eq!(
            found(&connections, "8B1F0C2E-0000-4000-8000-000000000003")
                .ok()
                .as_deref(),
            Some("8b1f0c2e-0000-4000-8000-000000000003")
        );
        assert_eq!(
            found(&connections, "staging").ok().as_deref(),
            Some("8b1f0c2e-0000-4000-8000-000000000002")
        );
        assert_eq!(
            found(&connections, "prod").ok().as_deref(),
            Some("8b1f0c2e-0000-4000-8000-000000000003")
        );
    }

    #[test]
    fn a_name_no_listed_connection_has_is_unknown() {
        let connections = [listed("a", "Staging")];

        assert!(matches!(
            found(&connections, "Blocked"),
            Err(CommandError::UnknownConnection(_))
        ));
    }

    #[test]
    fn two_names_alike_in_any_case_are_ambiguous() {
        let connections = [listed("a", "Staging"), listed("b", "STAGING")];

        let refused = found(&connections, "staging");

        assert!(matches!(
            refused,
            Err(CommandError::AmbiguousConnection { ref ids, .. }) if ids == &["a", "b"]
        ));
    }
}
