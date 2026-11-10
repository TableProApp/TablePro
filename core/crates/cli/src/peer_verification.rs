use std::error::Error;
use std::time::Duration;

use hyper_util::client::legacy::connect::{Connection, HttpInfo};

use crate::host::{Host, HostError};

type ConnectError = Box<dyn Error + Send + Sync>;

pub(crate) fn http_client(
    host: &(impl Host + Clone + Send + Sync + 'static),
    port: u16,
) -> Result<reqwest::Client, reqwest::Error> {
    let host = host.clone();
    // A proxy or redirect could carry the token to a different server.
    reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .connector_layer(tower::util::MapResultLayer::new(move |connection| {
            verify_connection(connection, &host, port)
        }))
        .build()
}

fn verify_connection<C: Connection>(
    connection: Result<C, ConnectError>,
    host: &dyn Host,
    port: u16,
) -> Result<C, ConnectError> {
    let connection = connection?;
    let mut extras = http::Extensions::new();
    connection.connected().get_extras(&mut extras);
    let addresses = extras.get::<HttpInfo>().ok_or_else(|| HostError::Unverified {
        port,
        reason: "the connection did not report its addresses".to_owned(),
    })?;
    // Returning the stream lets HTTP write the token, so refusal must drop this same stream first.
    host.verify_peer(addresses.remote_addr(), addresses.local_addr())?;
    Ok(connection)
}
