#[cfg(feature = "aio")]
use std::net::SocketAddr;

/// An async DNS resovler for resolving redis domain.
#[cfg(feature = "aio")]
pub trait AsyncDNSResolver: Send + Sync + 'static {
    /// Resolves the host and port to a list of `SocketAddr`.
    fn resolve<'a, 'b: 'a>(
        &'a self,
        host: &'b str,
        port: u16,
    ) -> crate::RedisFuture<'a, Box<dyn Iterator<Item = SocketAddr> + Send + 'a>>;
}
