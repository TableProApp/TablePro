use super::{AsyncStream, RedisResult, RedisRuntime, SocketAddr, TaskHandle};
use std::{
    future::Future,
    io,
    pin::Pin,
    task::{self, Poll},
};
#[cfg(unix)]
use tokio::net::UnixStream as UnixStreamTokio;
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::TcpStream as TcpStreamTokio,
};

#[cfg(all(feature = "tokio-native-tls-comp", not(feature = "tokio-rustls-comp")))]
use native_tls::TlsConnector;

#[cfg(feature = "tokio-rustls-comp")]
use crate::connection::create_rustls_config;
#[cfg(feature = "tokio-rustls-comp")]
use std::sync::Arc;
#[cfg(feature = "tokio-rustls-comp")]
use tokio_rustls::{TlsConnector, client::TlsStream};

#[cfg(all(feature = "tokio-native-tls-comp", not(feature = "tokio-rustls-comp")))]
use tokio_native_tls::TlsStream;

#[cfg(any(feature = "tokio-rustls-comp", feature = "tokio-native-tls-comp"))]
use crate::connection::TlsConnParams;

#[cfg(unix)]
use super::Path;

#[inline(always)]
async fn connect_tcp(
    addr: &SocketAddr,
    tcp_settings: &crate::io::tcp::TcpSettings,
) -> io::Result<TcpStreamTokio> {
    let socket = TcpStreamTokio::connect(addr).await?;
    let std_socket = socket.into_std()?;
    let std_socket = crate::io::tcp::stream_with_settings(std_socket, tcp_settings)?;

    TcpStreamTokio::from_std(std_socket)
}

pub(crate) enum Tokio {
    /// Represents a Tokio TCP connection.
    Tcp(TcpStreamTokio),
    /// Represents a Tokio TLS encrypted TCP connection
    #[cfg(any(feature = "tokio-native-tls-comp", feature = "tokio-rustls-comp"))]
    TcpTls(Box<TlsStream<TcpStreamTokio>>),
    /// Represents a Tokio Unix connection.
    #[cfg(unix)]
    Unix(UnixStreamTokio),
}

impl AsyncWrite for Tokio {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut task::Context,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        match &mut *self {
            Self::Tcp(r) => Pin::new(r).poll_write(cx, buf),
            #[cfg(any(feature = "tokio-native-tls-comp", feature = "tokio-rustls-comp"))]
            Self::TcpTls(r) => Pin::new(r).poll_write(cx, buf),
            #[cfg(unix)]
            Self::Unix(r) => Pin::new(r).poll_write(cx, buf),
        }
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut task::Context) -> Poll<io::Result<()>> {
        match &mut *self {
            Self::Tcp(r) => Pin::new(r).poll_flush(cx),
            #[cfg(any(feature = "tokio-native-tls-comp", feature = "tokio-rustls-comp"))]
            Self::TcpTls(r) => Pin::new(r).poll_flush(cx),
            #[cfg(unix)]
            Self::Unix(r) => Pin::new(r).poll_flush(cx),
        }
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut task::Context) -> Poll<io::Result<()>> {
        match &mut *self {
            Self::Tcp(r) => Pin::new(r).poll_shutdown(cx),
            #[cfg(any(feature = "tokio-native-tls-comp", feature = "tokio-rustls-comp"))]
            Self::TcpTls(r) => Pin::new(r).poll_shutdown(cx),
            #[cfg(unix)]
            Self::Unix(r) => Pin::new(r).poll_shutdown(cx),
        }
    }
}

impl AsyncRead for Tokio {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut task::Context,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        match &mut *self {
            Self::Tcp(r) => Pin::new(r).poll_read(cx, buf),
            #[cfg(any(feature = "tokio-native-tls-comp", feature = "tokio-rustls-comp"))]
            Self::TcpTls(r) => Pin::new(r).poll_read(cx, buf),
            #[cfg(unix)]
            Self::Unix(r) => Pin::new(r).poll_read(cx, buf),
        }
    }
}

impl RedisRuntime for Tokio {
    async fn connect_tcp(
        socket_addr: SocketAddr,
        tcp_settings: &crate::io::tcp::TcpSettings,
    ) -> RedisResult<Self> {
        Ok(connect_tcp(&socket_addr, tcp_settings)
            .await
            .map(Tokio::Tcp)?)
    }

    #[cfg(all(feature = "tokio-native-tls-comp", not(feature = "tokio-rustls-comp")))]
    async fn connect_tcp_tls(
        hostname: &str,
        socket_addr: SocketAddr,
        insecure: bool,
        params: &Option<TlsConnParams>,
        tcp_settings: &crate::io::tcp::TcpSettings,
    ) -> RedisResult<Self> {
        let tls_connector: tokio_native_tls::TlsConnector = if insecure {
            TlsConnector::builder()
                .danger_accept_invalid_certs(true)
                .danger_accept_invalid_hostnames(true)
                .use_sni(false)
                .build()?
        } else if let Some(params) = params {
            TlsConnector::builder()
                .danger_accept_invalid_hostnames(params.danger_accept_invalid_hostnames)
                .build()?
        } else {
            TlsConnector::new()?
        }
        .into();
        Ok(tls_connector
            .connect(hostname, connect_tcp(&socket_addr, tcp_settings).await?)
            .await
            .map(|con| Tokio::TcpTls(Box::new(con)))?)
    }

    #[cfg(feature = "tokio-rustls-comp")]
    async fn connect_tcp_tls(
        hostname: &str,
        socket_addr: SocketAddr,
        insecure: bool,
        tls_params: &Option<TlsConnParams>,
        tcp_settings: &crate::io::tcp::TcpSettings,
    ) -> RedisResult<Self> {
        let verify_host = tls_params
            .as_ref()
            .and_then(|params| params.verify_host.as_deref())
            .unwrap_or(hostname);
        let config = create_rustls_config(insecure, tls_params.clone())?;
        let tls_connector = TlsConnector::from(Arc::new(config));

        Ok(tls_connector
            .connect(
                rustls::pki_types::ServerName::try_from(verify_host)?.to_owned(),
                connect_tcp(&socket_addr, tcp_settings).await?,
            )
            .await
            .map(|con| Self::TcpTls(Box::new(con)))?)
    }

    #[cfg(unix)]
    async fn connect_unix(path: &Path) -> RedisResult<Self> {
        Ok(UnixStreamTokio::connect(path).await.map(Tokio::Unix)?)
    }

    fn spawn(f: impl Future<Output = ()> + Send + 'static) -> TaskHandle {
        TaskHandle::Tokio(tokio::spawn(f))
    }

    fn boxed(self) -> Pin<Box<dyn AsyncStream + Send + Sync>> {
        match self {
            Self::Tcp(x) => Box::pin(x),
            #[cfg(any(feature = "tokio-native-tls-comp", feature = "tokio-rustls-comp"))]
            Self::TcpTls(x) => Box::pin(x),
            #[cfg(unix)]
            Self::Unix(x) => Box::pin(x),
        }
    }
}
