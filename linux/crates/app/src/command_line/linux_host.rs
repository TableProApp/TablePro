use std::net::SocketAddr;

use gio::prelude::*;
use secrecy::ExposeSecret;
use tablepro_cli::{Host, HostError, Terminal};
use tablepro_core::credentials::{SecretItem, SecretItems};
use tablepro_linux_platform::{AppSettings, SecretStore};

use crate::config;

// NameHasOwner is answered by the bus itself, so this only bounds a bus that hangs.
const BUS_TIMEOUT_MS: i32 = 5_000;

// Inside Flatpak this runs in the app's own sandbox, with its keyfile settings and portal-keyed keyring.
#[derive(Clone)]
pub struct LinuxHost;

impl Host for LinuxHost {
    fn app_version(&self) -> String {
        config::VERSION.to_owned()
    }

    // Asked of the bus: a call to TablePro's own name would D-Bus-activate it.
    fn app_running(&self) -> bool {
        let Ok(bus) = gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE) else {
            return false;
        };
        bus.call_sync(
            Some("org.freedesktop.DBus"),
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameHasOwner",
            Some(&(config::APP_ID,).to_variant()),
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            BUS_TIMEOUT_MS,
            gio::Cancellable::NONE,
        )
        .ok()
        .and_then(|reply| reply.get::<(bool,)>())
        .is_some_and(|(owned,)| owned)
    }

    fn server_enabled(&self) -> Result<bool, HostError> {
        Ok(settings()?.mcp_server_enabled())
    }

    fn server_port(&self) -> Result<u16, HostError> {
        Ok(settings()?.mcp_server_port())
    }

    // This user's is enough: the same user can already read the token from the keyring.
    fn verify_peer(&self, peer: SocketAddr, local: SocketAddr) -> Result<(), HostError> {
        let port = peer.port();
        let ours = tablepro_net::loopback_peer_is_ours(peer, local).map_err(|error| HostError::Unverified {
            port,
            reason: error.to_string(),
        })?;
        match ours {
            true => Ok(()),
            false => Err(HostError::ForeignServer { port }),
        }
    }

    // Only read: a token made here would be one the running server never accepts.
    fn token(&self) -> Result<Option<String>, HostError> {
        // A thread of its own, so the read never runs inside a runtime the caller may be blocking on.
        std::thread::scope(|scope| scope.spawn(read_token).join()).unwrap_or_else(|_| {
            Err(HostError::Keyring {
                reason: "the keyring read stopped unexpectedly".to_owned(),
            })
        })
    }

    fn terminal(&self) -> Terminal {
        Terminal::detect()
    }
}

fn settings() -> Result<AppSettings, HostError> {
    AppSettings::open(config::APP_ID).map_err(|error| HostError::Settings {
        reason: error.to_string(),
    })
}

fn read_token() -> Result<Option<String>, HostError> {
    let keyring = |reason: String| HostError::Keyring { reason };
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| keyring(error.to_string()))?;
    let store = SecretStore::new(config::secret_schema());
    let token = runtime
        .block_on(store.load_item(SecretItem::McpToken))
        .map_err(|error| keyring(error.to_string()))?;
    Ok(token.map(|token| token.expose_secret().to_owned()))
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, TcpListener, TcpStream};

    use super::*;

    #[test]
    fn a_listener_this_process_owns_is_verified() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("a free port");
        let stream = TcpStream::connect(listener.local_addr().expect("an address")).expect("a connection");

        assert_eq!(
            LinuxHost.verify_peer(
                stream.peer_addr().expect("the peer"),
                stream.local_addr().expect("the local address")
            ),
            Ok(())
        );
    }
}
