#[cfg(unix)]
use std::path::Path;
use std::sync::Arc;
use std::{
    future::Future,
    io,
    net::SocketAddr,
    pin::Pin,
    task::{self, Poll},
};

use crate::aio::{AsyncStream, RedisRuntime};
use crate::types::RedisResult;

#[cfg(all(feature = "smol-native-tls-comp", not(feature = "smol-rustls-comp")))]
use async_native_tls::{TlsConnector, TlsStream};

#[cfg(feature = "smol-rustls-comp")]
use crate::connection::create_rustls_config;
#[cfg(feature = "smol-rustls-comp")]
use futures_rustls::{TlsConnector, client::TlsStream};

use super::TaskHandle;
use futures_util::ready;
use smol::net::TcpStream;
#[cfg(unix)]
use smol::net::unix::UnixStream;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

#[inline(always)]
async fn connect_tcp(
    addr: &SocketAddr,
    tcp_settings: &crate::io::tcp::TcpSettings,
) -> io::Result<TcpStream> {
    let socket = TcpStream::connect(addr).await?;
    let socket_inner: Arc<async_io::Async<std::net::TcpStream>> = socket.into();
    let async_socket_inner = Arc::into_inner(socket_inner).unwrap();
    let std_socket = async_socket_inner.into_inner()?;
    let std_socket = crate::io::tcp::stream_with_settings(std_socket, tcp_settings)?;

    std_socket.try_into()
}

#[cfg(any(feature = "smol-rustls-comp", feature = "smol-native-tls-comp"))]
use crate::connection::TlsConnParams;

pin_project_lite::pin_project! {
    /// Wraps the smol `AsyncRead/AsyncWrite` in order to implement the required the tokio traits
    /// for it
    pub struct SmolWrapped<T> {  #[pin] inner: T }
}

impl<T> SmolWrapped<T> {
    pub(super) fn new(inner: T) -> Self {
        Self { inner }
    }
}

impl<T> AsyncWrite for SmolWrapped<T>
where
    T: smol::io::AsyncWrite,
{
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut core::task::Context,
        buf: &[u8],
    ) -> std::task::Poll<Result<usize, tokio::io::Error>> {
        smol::io::AsyncWrite::poll_write(self.project().inner, cx, buf)
    }

    fn poll_flush(
        self: Pin<&mut Self>,
        cx: &mut core::task::Context,
    ) -> std::task::Poll<Result<(), tokio::io::Error>> {
        smol::io::AsyncWrite::poll_flush(self.project().inner, cx)
    }

    fn poll_shutdown(
        self: Pin<&mut Self>,
        cx: &mut core::task::Context,
    ) -> std::task::Poll<Result<(), tokio::io::Error>> {
        smol::io::AsyncWrite::poll_close(self.project().inner, cx)
    }
}

impl<T> AsyncRead for SmolWrapped<T>
where
    T: smol::prelude::AsyncRead,
{
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut core::task::Context,
        buf: &mut ReadBuf<'_>,
    ) -> std::task::Poll<Result<(), tokio::io::Error>> {
        let n = ready!(smol::prelude::AsyncRead::poll_read(
            self.project().inner,
            cx,
            buf.initialize_unfilled()
        ))?;
        buf.advance(n);
        std::task::Poll::Ready(Ok(()))
    }
}

/// Represents an Smol connectable
pub(crate) enum Smol {
    /// Represents aa TCP connection.
    Tcp(SmolWrapped<TcpStream>),
    /// Represents a TLS encrypted TCP connection.
    #[cfg(any(feature = "smol-native-tls-comp", feature = "smol-rustls-comp"))]
    TcpTls(SmolWrapped<Box<TlsStream<TcpStream>>>),
    /// Represents an Unix connection.
    #[cfg(unix)]
    Unix(SmolWrapped<UnixStream>),
}

impl AsyncWrite for Smol {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut task::Context,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        match &mut *self {
            Self::Tcp(r) => Pin::new(r).poll_write(cx, buf),
            #[cfg(any(feature = "smol-native-tls-comp", feature = "smol-rustls-comp"))]
            Self::TcpTls(r) => Pin::new(r).poll_write(cx, buf),
            #[cfg(unix)]
            Self::Unix(r) => Pin::new(r).poll_write(cx, buf),
        }
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut task::Context) -> Poll<io::Result<()>> {
        match &mut *self {
            Self::Tcp(r) => Pin::new(r).poll_flush(cx),
            #[cfg(any(feature = "smol-native-tls-comp", feature = "smol-rustls-comp"))]
            Self::TcpTls(r) => Pin::new(r).poll_flush(cx),
            #[cfg(unix)]
            Self::Unix(r) => Pin::new(r).poll_flush(cx),
        }
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut task::Context) -> Poll<io::Result<()>> {
        match &mut *self {
            Self::Tcp(r) => Pin::new(r).poll_shutdown(cx),
            #[cfg(any(feature = "smol-native-tls-comp", feature = "smol-rustls-comp"))]
            Self::TcpTls(r) => Pin::new(r).poll_shutdown(cx),
            #[cfg(unix)]
            Self::Unix(r) => Pin::new(r).poll_shutdown(cx),
        }
    }
}

impl AsyncRead for Smol {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut task::Context,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        match &mut *self {
            Self::Tcp(r) => Pin::new(r).poll_read(cx, buf),
            #[cfg(any(feature = "smol-native-tls-comp", feature = "smol-rustls-comp"))]
            Self::TcpTls(r) => Pin::new(r).poll_read(cx, buf),
            #[cfg(unix)]
            Self::Unix(r) => Pin::new(r).poll_read(cx, buf),
        }
    }
}

impl RedisRuntime for Smol {
    async fn connect_tcp(
        socket_addr: SocketAddr,
        tcp_settings: &crate::io::tcp::TcpSettings,
    ) -> RedisResult<Self> {
        Ok(connect_tcp(&socket_addr, tcp_settings)
            .await
            .map(|con| Self::Tcp(SmolWrapped::new(con)))?)
    }

    #[cfg(all(feature = "smol-native-tls-comp", not(feature = "smol-rustls-comp")))]
    async fn connect_tcp_tls(
        hostname: &str,
        socket_addr: SocketAddr,
        insecure: bool,
        tls_params: &Option<TlsConnParams>,
        tcp_settings: &crate::io::tcp::TcpSettings,
    ) -> RedisResult<Self> {
        let tcp_stream = connect_tcp(&socket_addr, tcp_settings).await?;
        let tls_connector = if insecure {
            TlsConnector::new()
                .danger_accept_invalid_certs(true)
                .danger_accept_invalid_hostnames(true)
                .use_sni(false)
        } else if let Some(params) = tls_params {
            TlsConnector::new()
                .danger_accept_invalid_hostnames(params.danger_accept_invalid_hostnames)
        } else {
            TlsConnector::new()
        };
        Ok(tls_connector
            .connect(hostname, tcp_stream)
            .await
            .map(|con| Self::TcpTls(SmolWrapped::new(Box::new(con))))?)
    }

    #[cfg(feature = "smol-rustls-comp")]
    async fn connect_tcp_tls(
        hostname: &str,
        socket_addr: SocketAddr,
        insecure: bool,
        tls_params: &Option<TlsConnParams>,
        tcp_settings: &crate::io::tcp::TcpSettings,
    ) -> RedisResult<Self> {
        let tcp_stream = connect_tcp(&socket_addr, tcp_settings).await?;

        let verify_host = tls_params
            .as_ref()
            .and_then(|params| params.verify_host.as_deref())
            .unwrap_or(hostname);
        let config = create_rustls_config(insecure, tls_params.clone())?;
        let tls_connector = TlsConnector::from(Arc::new(config));

        Ok(tls_connector
            .connect(
                rustls::pki_types::ServerName::try_from(verify_host)?.to_owned(),
                tcp_stream,
            )
            .await
            .map(|con| Self::TcpTls(SmolWrapped::new(Box::new(con))))?)
    }

    #[cfg(unix)]
    async fn connect_unix(path: &Path) -> RedisResult<Self> {
        Ok(UnixStream::connect(path)
            .await
            .map(|con| Self::Unix(SmolWrapped::new(con)))?)
    }

    fn spawn(f: impl Future<Output = ()> + Send + 'static) -> TaskHandle {
        TaskHandle::Smol(smol::spawn(f))
    }

    fn boxed(self) -> Pin<Box<dyn AsyncStream + Send + Sync>> {
        match self {
            Self::Tcp(x) => Box::pin(x),
            #[cfg(any(feature = "smol-native-tls-comp", feature = "smol-rustls-comp"))]
            Self::TcpTls(x) => Box::pin(x),
            #[cfg(unix)]
            Self::Unix(x) => Box::pin(x),
        }
    }
}
