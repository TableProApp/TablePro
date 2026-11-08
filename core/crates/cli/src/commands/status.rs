use std::cell::OnceCell;

use crate::client::McpClient;
use crate::command_error::CommandError;
use crate::command_line::FormatArgs;
use crate::console::Console;
use crate::endpoint::endpoint;
use crate::exit::Exit;
use crate::host::{Host, HostError, Terminal};
use crate::output::{Cell, Table};

// Reports what a command would meet, and exits as that command would; it never starts or changes anything.
pub(super) async fn run(
    arguments: &FormatArgs,
    host: &dyn Host,
    console: &mut Console<'_>,
) -> Result<Exit, CommandError> {
    let reading = Reading::of(host);
    let reached = match endpoint(&reading) {
        Ok(reachable) => McpClient::connect_to(&reachable, &reading.version)
            .await
            .map(|client| client.server_version()),
        Err(error) => Err(error),
    };
    let mut table = Table::new(&[
        "version",
        "running",
        "server_enabled",
        "port",
        "token_found",
        "server_version",
        "ready",
    ]);
    table.push(vec![
        Cell::text(reading.version.clone()),
        Cell::literal(reading.running),
        reading
            .enabled
            .as_ref()
            .map_or(Cell::Null, |&enabled| Cell::literal(enabled)),
        reading.port.as_ref().map_or(Cell::Null, |&port| Cell::literal(port)),
        match reading.token.get() {
            Some(Ok(token)) => Cell::literal(token.is_some()),
            _ => Cell::Null,
        },
        Cell::optional(reached.as_ref().ok().cloned().flatten()),
        Cell::literal(reached.is_ok()),
    ]);
    console.tables(&[table], arguments.format)?;
    match reached {
        Ok(_) => Ok(Exit::Success),
        Err(error) => {
            console.note(&error.to_string());
            Ok(error.exit())
        }
    }
}

// Each value is read once. The token is read only where a command would read it, so a stopped app or a server
// turned off never has the keyring ask to unlock.
struct Reading<'a> {
    host: &'a dyn Host,
    version: String,
    running: bool,
    enabled: Result<bool, HostError>,
    port: Result<u16, HostError>,
    token: OnceCell<Result<Option<String>, HostError>>,
    terminal: Terminal,
}

impl<'a> Reading<'a> {
    fn of(host: &'a dyn Host) -> Self {
        Self {
            host,
            version: host.app_version(),
            running: host.app_running(),
            enabled: host.server_enabled(),
            port: host.server_port(),
            token: OnceCell::new(),
            terminal: host.terminal(),
        }
    }
}

impl Host for Reading<'_> {
    fn app_version(&self) -> String {
        self.version.clone()
    }

    fn app_running(&self) -> bool {
        self.running
    }

    fn server_enabled(&self) -> Result<bool, HostError> {
        self.enabled.clone()
    }

    fn server_port(&self) -> Result<u16, HostError> {
        self.port.clone()
    }

    fn verify_server(&self, port: u16) -> Result<(), HostError> {
        self.host.verify_server(port)
    }

    fn token(&self) -> Result<Option<String>, HostError> {
        self.token.get_or_init(|| self.host.token()).clone()
    }

    fn terminal(&self) -> Terminal {
        self.terminal
    }
}
