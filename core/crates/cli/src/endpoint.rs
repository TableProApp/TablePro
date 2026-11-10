use crate::command_error::CommandError;
use crate::host::Host;

pub(crate) struct Endpoint {
    pub(crate) port: u16,
    pub(crate) token: String,
}

// A stopped app or disabled server must not ask the keyring to unlock.
pub(crate) fn endpoint(host: &dyn Host) -> Result<Endpoint, CommandError> {
    if !host.app_running() {
        return Err(CommandError::NotRunning);
    }
    if !host.server_enabled()? {
        return Err(CommandError::ServerOff);
    }
    let port = host.server_port()?;
    let token = host.token()?.ok_or(CommandError::NoToken)?;
    Ok(Endpoint { port, token })
}
