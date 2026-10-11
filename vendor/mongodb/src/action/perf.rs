use crate::Client;

impl Client {
    /// Add connections to the connection pool up to `min_pool_size`.  This is normally not needed -
    /// the connection pool will be filled in the background, and new connections created as needed
    /// up to `max_pool_size`.  However, it can sometimes be preferable to pay the (larger) cost of
    /// creating new connections up-front so that individual operations execute as quickly as
    /// possible.
    ///
    /// Note that topology changes require rebuilding the connection pool, so this method cannot
    /// guarantee that the pool will always be filled for the lifetime of the `Client`.
    ///
    /// Does nothing if `min_pool_size` is unset or zero.
    ///
    /// `await` will return `()`.
    pub fn warm_connection_pool(&self) -> WarmConnectionPool<'_> {
        WarmConnectionPool { client: self }
    }
}

#[cfg(feature = "sync")]
impl crate::sync::Client {
    /// Add connections to the connection pool up to `min_pool_size`.  This is normally not needed -
    /// the connection pool will be filled in the background, and new connections created as needed
    /// up to `max_pool_size`.  However, it can sometimes be preferable to pay the (larger) cost of
    /// creating new connections up-front so that individual operations execute as quickly as
    /// possible.
    ///
    /// Note that topology changes require rebuilding the connection pool, so this method cannot
    /// guarantee that the pool will always be filled for the lifetime of the `Client`.
    ///
    /// Does nothing if `min_pool_size` is unset or zero.
    ///
    /// [`run`](WarmConnectionPool::run) will return `()`.
    pub fn warm_connection_pool(&self) -> WarmConnectionPool<'_> {
        self.async_client.warm_connection_pool()
    }
}

/// Add connections to the connection pool up to `min_pool_size`.  Construct with
/// [`Client::warm_connection_pool`].
#[must_use]
pub struct WarmConnectionPool<'a> {
    pub(crate) client: &'a Client,
}

// Action impl in src/client/action/perf.rs
