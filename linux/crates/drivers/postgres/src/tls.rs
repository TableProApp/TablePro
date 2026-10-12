use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use tablepro_core::{DriverError, TlsConfig, TlsFailure};
use tablepro_net::tls::{TlsSetupError, build_client_config};
use tokio_postgres::config::SslMode;
use tokio_postgres::tls::{MakeTlsConnect, TlsConnect};
use tokio_postgres_rustls::MakeRustlsConnect;

use crate::transport_io::TransportIo;

/// The stream tokio-postgres-rustls wraps a transport stream in. Its
/// type is private to that crate and reachable only through the trait.
pub(crate) type PgTlsStream = <MakeRustlsConnect as MakeTlsConnect<TransportIo>>::Stream;

type RustlsConnect = <MakeRustlsConnect as MakeTlsConnect<TransportIo>>::TlsConnect;

/// How every physical connection of one target negotiates TLS.
#[derive(Clone)]
pub(crate) struct PgTlsSetup {
    connector: Option<MakeRustlsConnect>,
    server_name: String,
}

impl PgTlsSetup {
    pub(crate) fn new(tls: &TlsConfig, server_name: &str) -> Result<Self, DriverError> {
        let config = build_client_config(tls).map_err(setup_error)?;
        Ok(Self {
            connector: config.map(|config| MakeRustlsConnect::new((*config).clone())),
            server_name: server_name.to_owned(),
        })
    }

    pub(crate) fn ssl_mode(&self) -> SslMode {
        match self.connector {
            Some(_) => SslMode::Require,
            None => SslMode::Disable,
        }
    }

    pub(crate) fn requested(&self) -> bool {
        self.connector.is_some()
    }

    /// A connector for one physical connection, and the flag it raises
    /// once the server has agreed to TLS.
    pub(crate) fn connector(&self) -> (PgTls, Arc<AtomicBool>) {
        let handshake_started = Arc::new(AtomicBool::new(false));
        let connect = self.connector.clone().map(|mut make| {
            match <MakeRustlsConnect as MakeTlsConnect<TransportIo>>::make_tls_connect(&mut make, &self.server_name) {
                Ok(connect) => connect,
                Err(never) => match never {},
            }
        });
        (
            PgTls {
                connect,
                handshake_started: handshake_started.clone(),
            },
            handshake_started,
        )
    }
}

/// tokio-postgres-rustls's connector, wrapped to record that the server
/// answered the SSLRequest with 'S'. tokio-postgres reports a server
/// that refused TLS with a TLS error of its own, and only this flag
/// tells it apart from a handshake that failed.
pub(crate) struct PgTls {
    connect: Option<RustlsConnect>,
    handshake_started: Arc<AtomicBool>,
}

type HandshakeFuture = Pin<Box<dyn Future<Output = io::Result<PgTlsStream>> + Send>>;

impl TlsConnect<TransportIo> for PgTls {
    type Stream = PgTlsStream;
    type Error = io::Error;
    type Future = HandshakeFuture;

    fn connect(self, stream: TransportIo) -> Self::Future {
        self.handshake_started.store(true, Ordering::SeqCst);
        match self.connect {
            Some(connect) => Box::pin(connect.connect(stream)),
            // SslMode::Disable never reaches here, so a connector without
            // TLS is a configuration this module did not build.
            None => Box::pin(std::future::ready(Err(io::Error::other("TLS is not configured")))),
        }
    }
}

fn setup_error(error: TlsSetupError) -> DriverError {
    match error {
        TlsSetupError::Config(error) => DriverError::Config(error),
        TlsSetupError::Rustls(error) => DriverError::Tls {
            failure: TlsFailure::ClientIdentityInvalid,
            detail: error.to_string(),
        },
        other => DriverError::Tls {
            failure: TlsFailure::Other,
            detail: other.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_disabled_setup_asks_for_no_tls() {
        let setup = PgTlsSetup::new(&TlsConfig::disabled(), "db.example.com").expect("a setup");

        assert!(matches!(setup.ssl_mode(), SslMode::Disable));
        assert!(!setup.requested());
    }

    #[test]
    fn a_required_setup_asks_for_tls_and_records_nothing_until_used() {
        let tls = TlsConfig {
            mode: tablepro_core::TlsMode::Require,
            ..TlsConfig::disabled()
        };
        let setup = PgTlsSetup::new(&tls, "db.example.com").expect("a setup");

        let (_connector, started) = setup.connector();

        assert!(matches!(setup.ssl_mode(), SslMode::Require));
        assert!(!started.load(Ordering::SeqCst));
    }
}
