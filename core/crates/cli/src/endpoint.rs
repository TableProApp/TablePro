use crate::command_error::CommandError;
use crate::host::{Host, HostError};

pub(crate) struct Endpoint {
    pub(crate) port: u16,
    pub(crate) token: String,
}

// Each check runs before the token goes anywhere: with TablePro stopped or its server off,
// another program may hold the port. The token is read last, so a refusal never asks the keyring to unlock.
pub(crate) fn endpoint(host: &dyn Host) -> Result<Endpoint, CommandError> {
    if !host.app_running() {
        return Err(CommandError::NotRunning);
    }
    if !host.server_enabled()? {
        return Err(CommandError::ServerOff);
    }
    let port = host.server_port()?;
    host.verify_server(port).map_err(|error| match error {
        HostError::NotListening { port } => CommandError::NotAnswering { port },
        other => CommandError::Host(other),
    })?;
    let token = host.token()?.ok_or(CommandError::NoToken)?;
    Ok(Endpoint { port, token })
}
