use std::{
    net::SocketAddr,
    ops::DerefMut,
    pin::Pin,
    task::{Context, Poll},
    time::Duration,
};

use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::TcpStream,
};

use crate::{
    error::{Error, ErrorKind, Result},
    options::{ServerAddress, Socks5Proxy},
    runtime,
};

use super::{
    tls::{tls_connect, TlsStream},
    TlsConfig,
};

pub(crate) const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
#[cfg(not(target_os = "wasi"))]
const KEEPALIVE_TIME: Duration = Duration::from_secs(120);

/// An async stream possibly using TLS.
#[allow(clippy::large_enum_variant)]
#[derive(Debug)]
pub(crate) enum AsyncStream {
    Null,

    /// A basic TCP connection to the server.
    Tcp(TcpStream),

    /// A TLS connection over TCP.
    Tls(TlsStream<TcpStream>),

    /// A Unix domain socket connection.
    #[cfg(unix)]
    Unix(tokio::net::UnixStream),

    /// A connection to a SOCKS5 proxy.
    #[cfg(feature = "socks5-proxy")]
    Socks5(fast_socks5::client::Socks5Stream<TcpStream>),

    /// A TLS connection to a SOCKS5 proxy.
    #[cfg(feature = "socks5-proxy")]
    Socks5Tls(TlsStream<fast_socks5::client::Socks5Stream<TcpStream>>),
}

#[cfg(feature = "socks5-proxy")]
impl Socks5Proxy {
    async fn connect(
        &self,
        host: String,
        port: Option<u16>,
    ) -> Result<fast_socks5::client::Socks5Stream<TcpStream>> {
        use crate::options::DEFAULT_PORT;
        use fast_socks5::{
            client::{Config, Socks5Stream},
            SocksError,
        };

        let proxy_address = format!("{}:{}", self.host, self.port.unwrap_or(1080));
        let port = port.unwrap_or(DEFAULT_PORT);

        let stream = if let Some((username, password)) = self.authentication.as_ref() {
            Socks5Stream::connect_with_password(
                proxy_address,
                host,
                port,
                username.clone(),
                password.clone(),
                Config::default(),
            )
            .await
        } else {
            Socks5Stream::connect(proxy_address, host, port, Config::default()).await
        }
        .map_err(|error| {
            if let SocksError::Io(io_error) = error {
                ErrorKind::Io(std::sync::Arc::new(io_error))
            } else {
                ErrorKind::ProxyConnect {
                    message: error.to_string(),
                }
            }
        })?;
        Ok(stream)
    }
}
impl AsyncStream {
    pub(crate) async fn connect(
        address: ServerAddress,
        tls_cfg: Option<&TlsConfig>,
        #[allow(unused)] proxy: Option<&Socks5Proxy>,
    ) -> Result<Self> {
        match &address {
            #[allow(unused)] // port is unused when socks5-proxy is not enabled
            ServerAddress::Tcp { host, port } => {
                #[cfg(feature = "socks5-proxy")]
                if let Some(proxy) = proxy {
                    let inner = proxy.connect(host.clone(), *port).await?;
                    return match tls_cfg {
                        Some(cfg) => {
                            Ok(AsyncStream::Socks5Tls(tls_connect(host, inner, cfg).await?))
                        }
                        None => Ok(AsyncStream::Socks5(inner)),
                    };
                }

                let resolved: Vec<_> = runtime::resolve_address(&address).await?.collect();
                if resolved.is_empty() {
                    return Err(ErrorKind::DnsResolve {
                        message: format!(
                            "No DNS results for domain {}",
                            crate::error::Redact(address)
                        ),
                    }
                    .into());
                }
                let tcp_stream = tcp_connect(resolved)
                    .await
                    .map_err(Error::with_backpressure_labels)?;

                // If there are TLS options, wrap the TCP stream in an AsyncTlsStream.
                match tls_cfg {
                    Some(cfg) => {
                        let tls_stream = tls_connect(host, tcp_stream, cfg)
                            .await
                            .map_err(Error::with_backpressure_labels)?;
                        Ok(AsyncStream::Tls(tls_stream))
                    }
                    None => Ok(AsyncStream::Tcp(tcp_stream)),
                }
            }
            #[cfg(unix)]
            ServerAddress::Unix { path } => Ok(AsyncStream::Unix(
                tokio::net::UnixStream::connect(path.as_path()).await?,
            )),
        }
    }
}

async fn tcp_try_connect(address: &SocketAddr) -> Result<TcpStream> {
    let stream = TcpStream::connect(address).await?;
    stream.set_nodelay(true)?;

    #[cfg(not(target_os = "wasi"))]
    {
        let sock_ref = socket2::SockRef::from(&stream);
        let conf = socket2::TcpKeepalive::new().with_time(KEEPALIVE_TIME);
        sock_ref.set_tcp_keepalive(&conf)?;
    }

    Ok(stream)
}

pub(crate) async fn tcp_connect(resolved: Vec<SocketAddr>) -> Result<TcpStream> {
    // "Happy Eyeballs": try addresses in parallel, interleaving IPv6 and IPv4, preferring IPv6.
    // Based on the implementation in https://codeberg.org/KMK/happy-eyeballs.
    let (addrs_v6, addrs_v4): (Vec<_>, Vec<_>) = resolved
        .into_iter()
        .partition(|a| matches!(a, SocketAddr::V6(_)));
    let socket_addrs = interleave(addrs_v6, addrs_v4);

    fn handle_join(
        result: std::result::Result<Result<TcpStream>, tokio::task::JoinError>,
    ) -> Result<TcpStream> {
        match result {
            Ok(r) => r,
            // JoinError indicates the task was cancelled or paniced, which should never happen
            // here.
            Err(e) => Err(Error::internal(format!("TCP connect task failure: {e}"))),
        }
    }

    static CONNECTION_ATTEMPT_DELAY: Duration = Duration::from_millis(250);

    // Race connections
    let mut attempts = tokio::task::JoinSet::new();
    let mut connect_error = None;
    'spawn: for a in socket_addrs {
        attempts.spawn(async move { tcp_try_connect(&a).await });
        let sleep = tokio::time::sleep(CONNECTION_ATTEMPT_DELAY);
        tokio::pin!(sleep); // required for select!
        while !attempts.is_empty() {
            tokio::select! {
                biased;
                connect_res = attempts.join_next() => {
                    match connect_res.map(handle_join) {
                        // The gating `while !attempts.is_empty()` should mean this never happens.
                        None => return Err(Error::internal("empty TCP connect task set")),
                        // A connection succeeded, return it. The JoinSet will cancel remaining tasks on drop.
                        Some(Ok(cnx)) => return Ok(cnx),
                        // A connection failed. Remember the error and wait for any other remaining attempts.
                        Some(Err(e)) => {
                            connect_error.get_or_insert(e);
                        },
                    }
                }
                // CONNECTION_ATTEMPT_DELAY expired, spawn a new connection attempt.
                _ = &mut sleep => continue 'spawn
            }
        }
    }

    // No more address to try. Drain the attempts until one succeeds.
    while let Some(result) = attempts.join_next().await {
        match handle_join(result) {
            Ok(cnx) => return Ok(cnx),
            Err(e) => {
                connect_error.get_or_insert(e);
            }
        }
    }

    // All attempts failed.  Return the first error.
    Err(connect_error.unwrap_or_else(|| {
        ErrorKind::Internal {
            message: "connecting to all DNS results failed but no error reported".to_string(),
        }
        .into()
    }))
}

fn interleave<T>(left: Vec<T>, right: Vec<T>) -> Vec<T> {
    let mut out = Vec::with_capacity(left.len() + right.len());
    let (mut left, mut right) = (left.into_iter(), right.into_iter());
    while let Some(a) = left.next() {
        out.push(a);
        std::mem::swap(&mut left, &mut right);
    }
    out.extend(right);
    out
}

impl AsyncRead for AsyncStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        match self.deref_mut() {
            Self::Null => Poll::Ready(Ok(())),
            Self::Tcp(ref mut inner) => AsyncRead::poll_read(Pin::new(inner), cx, buf),
            Self::Tls(ref mut inner) => AsyncRead::poll_read(Pin::new(inner), cx, buf),
            #[cfg(unix)]
            Self::Unix(ref mut inner) => AsyncRead::poll_read(Pin::new(inner), cx, buf),
            #[cfg(feature = "socks5-proxy")]
            Self::Socks5(ref mut inner) => AsyncRead::poll_read(Pin::new(inner), cx, buf),
            #[cfg(feature = "socks5-proxy")]
            Self::Socks5Tls(ref mut inner) => AsyncRead::poll_read(Pin::new(inner), cx, buf),
        }
    }
}

impl AsyncWrite for AsyncStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        match self.deref_mut() {
            Self::Null => Poll::Ready(Ok(0)),
            Self::Tcp(ref mut inner) => AsyncWrite::poll_write(Pin::new(inner), cx, buf),
            Self::Tls(ref mut inner) => Pin::new(inner).poll_write(cx, buf),
            #[cfg(unix)]
            Self::Unix(ref mut inner) => AsyncWrite::poll_write(Pin::new(inner), cx, buf),
            #[cfg(feature = "socks5-proxy")]
            Self::Socks5(ref mut inner) => AsyncWrite::poll_write(Pin::new(inner), cx, buf),
            #[cfg(feature = "socks5-proxy")]
            Self::Socks5Tls(ref mut inner) => AsyncWrite::poll_write(Pin::new(inner), cx, buf),
        }
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        match self.deref_mut() {
            Self::Null => Poll::Ready(Ok(())),
            Self::Tcp(ref mut inner) => AsyncWrite::poll_flush(Pin::new(inner), cx),
            Self::Tls(ref mut inner) => Pin::new(inner).poll_flush(cx),
            #[cfg(unix)]
            Self::Unix(ref mut inner) => AsyncWrite::poll_flush(Pin::new(inner), cx),
            #[cfg(feature = "socks5-proxy")]
            Self::Socks5(ref mut inner) => AsyncWrite::poll_flush(Pin::new(inner), cx),
            #[cfg(feature = "socks5-proxy")]
            Self::Socks5Tls(ref mut inner) => AsyncWrite::poll_flush(Pin::new(inner), cx),
        }
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        match self.deref_mut() {
            Self::Null => Poll::Ready(Ok(())),
            Self::Tcp(ref mut inner) => Pin::new(inner).poll_shutdown(cx),
            Self::Tls(ref mut inner) => Pin::new(inner).poll_shutdown(cx),
            #[cfg(unix)]
            Self::Unix(ref mut inner) => Pin::new(inner).poll_shutdown(cx),
            #[cfg(feature = "socks5-proxy")]
            Self::Socks5(ref mut inner) => Pin::new(inner).poll_shutdown(cx),
            #[cfg(feature = "socks5-proxy")]
            Self::Socks5Tls(ref mut inner) => Pin::new(inner).poll_shutdown(cx),
        }
    }

    fn poll_write_vectored(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bufs: &[futures_io::IoSlice<'_>],
    ) -> Poll<std::result::Result<usize, std::io::Error>> {
        match self.get_mut() {
            Self::Null => Poll::Ready(Ok(0)),
            Self::Tcp(ref mut inner) => Pin::new(inner).poll_write_vectored(cx, bufs),
            Self::Tls(ref mut inner) => Pin::new(inner).poll_write_vectored(cx, bufs),
            #[cfg(unix)]
            Self::Unix(ref mut inner) => Pin::new(inner).poll_write_vectored(cx, bufs),
            #[cfg(feature = "socks5-proxy")]
            Self::Socks5(ref mut inner) => Pin::new(inner).poll_write_vectored(cx, bufs),
            #[cfg(feature = "socks5-proxy")]
            Self::Socks5Tls(ref mut inner) => Pin::new(inner).poll_write_vectored(cx, bufs),
        }
    }

    fn is_write_vectored(&self) -> bool {
        match self {
            Self::Null => false,
            Self::Tcp(ref inner) => inner.is_write_vectored(),
            Self::Tls(ref inner) => inner.is_write_vectored(),
            #[cfg(unix)]
            Self::Unix(ref inner) => inner.is_write_vectored(),
            #[cfg(feature = "socks5-proxy")]
            Self::Socks5(ref inner) => inner.is_write_vectored(),
            #[cfg(feature = "socks5-proxy")]
            Self::Socks5Tls(ref inner) => inner.is_write_vectored(),
        }
    }
}
