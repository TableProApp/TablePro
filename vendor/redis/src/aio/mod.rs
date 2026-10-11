//! Adds async IO support to redis.
use crate::cmd::Cmd;
use crate::connection::{
    AuthResult, ConnectionSetupComponents, RedisConnectionInfo, check_connection_setup,
    connection_setup_pipeline,
};
use crate::io::AsyncDNSResolver;
use crate::types::{RedisFuture, RedisResult, Value};
use crate::{ErrorKind, PushInfo, RedisError, errors::closed_connection_error};
use ::tokio::io::{AsyncRead, AsyncWrite};
use futures_util::{
    future::{Future, FutureExt},
    sink::{Sink, SinkExt},
    stream::{Stream, StreamExt},
};
pub use monitor::Monitor;
use std::net::SocketAddr;
#[cfg(unix)]
use std::path::Path;
use std::pin::Pin;

mod monitor;

#[cfg(any(feature = "tls-rustls", feature = "tls-native-tls"))]
use crate::connection::TlsConnParams;

/// Enables the smol compatibility
#[cfg(feature = "smol-comp")]
#[cfg_attr(docsrs, doc(cfg(feature = "smol-comp")))]
pub mod smol;
/// Enables the tokio compatibility
#[cfg(feature = "tokio-comp")]
#[cfg_attr(docsrs, doc(cfg(feature = "tokio-comp")))]
pub mod tokio;

mod pubsub;
pub use pubsub::{PubSub, PubSubSink, PubSubStream};

/// Represents the ability of connecting via TCP or via Unix socket
pub(crate) trait RedisRuntime: AsyncStream + Send + Sync + Sized + 'static {
    /// Performs a TCP connection
    async fn connect_tcp(
        socket_addr: SocketAddr,
        tcp_settings: &crate::io::tcp::TcpSettings,
    ) -> RedisResult<Self>;

    // Performs a TCP TLS connection
    #[cfg(any(feature = "tls-native-tls", feature = "tls-rustls"))]
    async fn connect_tcp_tls(
        hostname: &str,
        socket_addr: SocketAddr,
        insecure: bool,
        tls_params: &Option<TlsConnParams>,
        tcp_settings: &crate::io::tcp::TcpSettings,
    ) -> RedisResult<Self>;

    /// Performs a UNIX connection
    #[cfg(unix)]
    async fn connect_unix(path: &Path) -> RedisResult<Self>;

    fn spawn(f: impl Future<Output = ()> + Send + 'static) -> TaskHandle;

    fn boxed(self) -> Pin<Box<dyn AsyncStream + Send + Sync>> {
        Box::pin(self)
    }
}

/// Trait for objects that implements `AsyncRead` and `AsyncWrite`
pub trait AsyncStream: AsyncRead + AsyncWrite {}
impl<S> AsyncStream for S where S: AsyncRead + AsyncWrite {}

/// An async abstraction over connections.
pub trait ConnectionLike {
    /// Sends an already encoded (packed) command into the TCP socket and
    /// reads the single response from it.
    fn req_packed_command<'a>(&'a mut self, cmd: &'a Cmd) -> RedisFuture<'a, Value>;

    /// Sends multiple already encoded (packed) command into the TCP socket
    /// and reads `count` responses from it.  This is used to implement
    /// pipelining.
    /// Important - this function is meant for internal usage, since it's
    /// easy to pass incorrect `offset` & `count` parameters, which might
    /// cause the connection to enter an erroneous state. Users shouldn't
    /// call it, instead using the Pipeline::query_async function.
    #[doc(hidden)]
    fn req_packed_commands<'a>(
        &'a mut self,
        pipeline: &'a crate::Pipeline,
        offset: usize,
        count: usize,
    ) -> RedisFuture<'a, Vec<Value>>;

    /// Returns the database this connection is bound to.  Note that this
    /// information might be unreliable because it's initially cached and
    /// also might be incorrect if the connection like object is not
    /// actually connected.
    fn get_db(&self) -> i64;
}

async fn execute_connection_pipeline<T>(
    codec: &mut T,
    (pipeline, instructions): (crate::Pipeline, ConnectionSetupComponents),
) -> RedisResult<AuthResult>
where
    T: Sink<Vec<u8>, Error = RedisError>,
    T: Stream<Item = RedisResult<Value>>,
    T: Unpin + Send + 'static,
{
    let count = pipeline.len();
    if count == 0 {
        return Ok(AuthResult::Succeeded);
    }
    codec.send(pipeline.get_packed_pipeline()).await?;

    let mut results = Vec::with_capacity(count);
    for _ in 0..count {
        let value = codec.next().await.ok_or_else(closed_connection_error)??;
        results.push(value);
    }

    check_connection_setup(results, instructions)
}

pub(super) async fn setup_connection<T>(
    codec: &mut T,
    connection_info: &RedisConnectionInfo,
    #[cfg(feature = "cache-aio")] cache_config: Option<crate::caching::CacheConfig>,
) -> RedisResult<()>
where
    T: Sink<Vec<u8>, Error = RedisError>,
    T: Stream<Item = RedisResult<Value>>,
    T: Unpin + Send + 'static,
{
    if execute_connection_pipeline(
        codec,
        connection_setup_pipeline(
            connection_info,
            true,
            #[cfg(feature = "cache-aio")]
            cache_config,
        ),
    )
    .await?
        == AuthResult::ShouldRetryWithoutUsername
    {
        execute_connection_pipeline(
            codec,
            connection_setup_pipeline(
                connection_info,
                false,
                #[cfg(feature = "cache-aio")]
                cache_config,
            ),
        )
        .await?;
    }

    Ok(())
}

mod connection;
pub(crate) use connection::connect_simple;
pub use connection::transaction_async;
mod multiplexed_connection;
pub use multiplexed_connection::*;
#[cfg(feature = "connection-manager")]
mod connection_manager;
#[cfg(feature = "connection-manager")]
#[cfg_attr(docsrs, doc(cfg(feature = "connection-manager")))]
pub use connection_manager::*;
mod runtime;
#[cfg(all(feature = "smol-comp", feature = "tokio-comp"))]
pub use runtime::prefer_smol;
#[cfg(all(feature = "tokio-comp", feature = "smol-comp"))]
pub use runtime::prefer_tokio;
pub(super) use runtime::*;

/// An error showing that the receiver
pub struct SendError;

/// A trait for sender parts of a channel that can be used for sending push messages from async
/// connection.
pub trait AsyncPushSender: Send + Sync + 'static {
    /// The sender must send without blocking, otherwise it will block the sending connection.
    fn send(&self, info: PushInfo) -> Result<(), SendError>;
}

impl AsyncPushSender for ::tokio::sync::mpsc::UnboundedSender<PushInfo> {
    fn send(&self, info: PushInfo) -> Result<(), SendError> {
        match self.send(info) {
            Ok(_) => Ok(()),
            Err(_) => Err(SendError),
        }
    }
}

impl AsyncPushSender for ::tokio::sync::broadcast::Sender<PushInfo> {
    fn send(&self, info: PushInfo) -> Result<(), SendError> {
        match self.send(info) {
            Ok(_) => Ok(()),
            Err(_) => Err(SendError),
        }
    }
}

impl<T, Func: Fn(PushInfo) -> Result<(), T> + Send + Sync + 'static> AsyncPushSender for Func {
    fn send(&self, info: PushInfo) -> Result<(), SendError> {
        match self(info) {
            Ok(_) => Ok(()),
            Err(_) => Err(SendError),
        }
    }
}

impl AsyncPushSender for std::sync::mpsc::Sender<PushInfo> {
    fn send(&self, info: PushInfo) -> Result<(), SendError> {
        match self.send(info) {
            Ok(_) => Ok(()),
            Err(_) => Err(SendError),
        }
    }
}

#[cfg(feature = "cluster-async")]
impl AsyncPushSender for futures_channel::mpsc::UnboundedSender<PushInfo> {
    fn send(&self, info: PushInfo) -> Result<(), SendError> {
        match self.unbounded_send(info) {
            Ok(_) => Ok(()),
            Err(_) => Err(SendError),
        }
    }
}

impl<T> AsyncPushSender for std::sync::Arc<T>
where
    T: AsyncPushSender + ?Sized,
{
    fn send(&self, info: PushInfo) -> Result<(), SendError> {
        self.as_ref().send(info)
    }
}

/// Default DNS resolver which uses the system's DNS resolver.
#[derive(Clone)]
pub(crate) struct DefaultAsyncDNSResolver;

impl AsyncDNSResolver for DefaultAsyncDNSResolver {
    fn resolve<'a, 'b: 'a>(
        &'a self,
        host: &'b str,
        port: u16,
    ) -> RedisFuture<'a, Box<dyn Iterator<Item = SocketAddr> + Send + 'a>> {
        Box::pin(get_socket_addrs(host, port).map(|vec| {
            Ok(Box::new(vec?.into_iter()) as Box<dyn Iterator<Item = SocketAddr> + Send>)
        }))
    }
}

async fn get_socket_addrs(host: &str, port: u16) -> RedisResult<Vec<SocketAddr>> {
    let socket_addrs: Vec<_> = match Runtime::locate() {
        #[cfg(feature = "tokio-comp")]
        Runtime::Tokio => ::tokio::net::lookup_host((host, port))
            .await
            .map_err(RedisError::from)
            .map(|iter| iter.collect()),

        #[cfg(feature = "smol-comp")]
        Runtime::Smol => ::smol::net::resolve((host, port))
            .await
            .map_err(RedisError::from),
    }?;

    if socket_addrs.is_empty() {
        Err(RedisError::from((
            ErrorKind::InvalidClientConfig,
            "No address found for host",
        )))
    } else {
        Ok(socket_addrs)
    }
}
