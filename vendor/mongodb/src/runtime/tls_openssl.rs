use std::pin::Pin;

use openssl::{
    error::ErrorStack,
    ssl::{SslConnector, SslFiletype, SslMethod, SslVerifyMode},
};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_openssl::SslStream;

use crate::{
    client::options::TlsOptions,
    error::{Error, ErrorKind, Result},
};

pub(crate) type TlsStream<T> = SslStream<T>;

/// Configuration required to use TLS. Creating this is expensive, so its best to cache this value
/// and reuse it for multiple connections.
#[derive(Clone)]
pub(crate) struct TlsConfig {
    connector: SslConnector,
    verify_hostname: bool,
}

impl TlsConfig {
    /// Create a new `TlsConfig` from the provided options from the user.
    /// This operation is expensive, so the resultant `TlsConfig` should be cached.
    pub(crate) fn new(options: TlsOptions) -> Result<TlsConfig> {
        let verify_hostname = match options.allow_invalid_hostnames {
            Some(b) => !b,
            None => true,
        };

        let connector = make_openssl_connector(options)?;

        Ok(TlsConfig {
            connector,
            verify_hostname,
        })
    }
}

pub(crate) async fn tls_connect<T: AsyncRead + AsyncWrite + Unpin>(
    host: &str,
    tcp_stream: T,
    cfg: &TlsConfig,
) -> Result<TlsStream<T>> {
    let mut stream = make_ssl_stream(host, tcp_stream, cfg).map_err(|err| {
        Error::from(ErrorKind::InvalidTlsConfig {
            message: err.to_string(),
        })
    })?;
    Pin::new(&mut stream).connect().await.map_err(|err| {
        use std::io;
        match err.into_io_error() {
            Ok(err) => err,
            Err(err) => io::Error::other(err),
        }
    })?;
    Ok(stream)
}

fn make_openssl_connector(cfg: TlsOptions) -> Result<SslConnector> {
    let openssl_err = |e: ErrorStack| {
        Error::from(ErrorKind::InvalidTlsConfig {
            message: e.to_string(),
        })
    };

    let mut builder = SslConnector::builder(SslMethod::tls_client()).map_err(openssl_err)?;

    let probe = openssl_probe::probe();
    builder
        .load_verify_locations(probe.cert_file.as_deref(), probe.cert_dir.as_deref())
        .map_err(openssl_err)?;

    let TlsOptions {
        allow_invalid_certificates,
        ca_file_path,
        cert_key_file_path,
        allow_invalid_hostnames: _,
        #[cfg(feature = "cert-key-password")]
        tls_certificate_key_file_password,
        verify_hostname: _,
    } = cfg;

    if let Some(true) = allow_invalid_certificates {
        builder.set_verify(SslVerifyMode::NONE);
    }
    if let Some(path) = ca_file_path {
        builder.set_ca_file(path).map_err(openssl_err)?;
    }
    if let Some(path) = cert_key_file_path {
        builder
            .set_certificate_file(path.clone(), SslFiletype::PEM)
            .map_err(openssl_err)?;
        // Inner fn so the cert-key-password path can early return
        let handle_private_key = || -> Result<()> {
            #[cfg(feature = "cert-key-password")]
            if let Some(key_pw) = tls_certificate_key_file_password {
                let contents = std::fs::read(&path)?;

                /*
                let key_bytes = super::pem::decrypt_private_key(&contents, &key_pw)?;
                let key =
                    openssl::pkey::PKey::private_key_from_der(&key_bytes).map_err(openssl_err)?;
                    */

                let key = openssl::pkey::PKey::private_key_from_pem_passphrase(&contents, &key_pw)
                    .map_err(openssl_err)?;
                builder.set_private_key(&key).map_err(openssl_err)?;
                return Ok(());
            }
            builder
                .set_private_key_file(path, SslFiletype::PEM)
                .map_err(openssl_err)
        };
        handle_private_key()?;
    }

    Ok(builder.build())
}

fn make_ssl_stream<T: AsyncRead + AsyncWrite>(
    host: &str,
    tcp_stream: T,
    cfg: &TlsConfig,
) -> std::result::Result<SslStream<T>, ErrorStack> {
    let ssl = cfg
        .connector
        .configure()?
        .use_server_name_indication(true)
        .verify_hostname(cfg.verify_hostname)
        .into_ssl(host)?;
    SslStream::new(ssl, tcp_stream)
}
