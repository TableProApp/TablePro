use std::num::NonZeroUsize;
use std::time::Duration;

/// Defines the behavior of the cache regarding which commands should be cached.
#[derive(Clone, PartialEq, Debug, Copy)]
#[non_exhaustive]
pub enum CacheMode {
    /// Try to cache every command. This is equivalent to calling [crate::Cmd::set_cache_config]/[crate::Pipeline::set_cache_config] on every command using OptIn mode.
    /// In this mode cache usage can't be disabled using [crate::Cmd::set_cache_config]/[crate::Pipeline::set_cache_config].
    All,
    /// Only try to cache commands which explicitly enabled caching.
    /// If OptIn is used [crate::Cmd::set_cache_config]/[crate::Pipeline::set_cache_config]
    /// must be used for caching to be tried for the command.
    OptIn,
}

/// Configuration for client side caching.
#[derive(Clone, Debug, Copy)]
pub struct CacheConfig {
    pub(crate) mode: CacheMode,
    pub(crate) size: NonZeroUsize,
    pub(crate) default_client_ttl: Duration,
}

impl CacheConfig {
    /// Creates new CacheConfig with default values (10_000 LRU size and 30 minutes of client ttl)
    pub fn new() -> Self {
        Self {
            mode: CacheMode::All,
            size: NonZeroUsize::new(10_000).unwrap(),
            default_client_ttl: Duration::from_secs(60 * 30),
        }
    }

    /// Sets how client side caching should work, default is [`CacheMode::All`].
    pub fn set_mode(mut self, mode: CacheMode) -> Self {
        self.mode = mode;
        self
    }

    /// Sets maximum key count for the cache.
    pub fn set_size(mut self, size: NonZeroUsize) -> Self {
        self.size = size;
        self
    }

    ///  Sets the default client side time to live (TTL) for cached values, this value will be used when a TTL isn't explicitly passed with [crate::Cmd::set_cache_config]/[crate::Pipeline::set_cache_config].
    ///  Client side caching mechanism will compare client side TTL with server side TTL and pick minimum to retain in the cache.
    ///  Client side TTL is the maximum time for a key to stay in cache.
    ///  Server side TTL is the maximum time for a key to stay in server, it's requested using `PTTL` command for each key.
    ///
    /// # Examples
    ///
    /// ```rust,no_run
    /// # use std::time::Duration;
    /// # use redis::caching::CacheConfig;
    /// # use redis::{AsyncConnectionConfig,CommandCacheConfig};
    /// # #[tokio::main]
    /// # async fn main() {
    /// let client = redis::Client::open("redis://127.0.0.1/?protocol=resp3").unwrap();
    /// // Set default client side time to live as 60 seconds instead of 30 minutes default.
    /// let cache_config = CacheConfig::new().set_default_client_ttl(Duration::from_secs(60));
    /// let async_config = AsyncConnectionConfig::new().set_cache_config(cache_config);
    /// let mut connection = client.get_multiplexed_async_connection_with_config(&async_config).await.unwrap();
    /// // Command below will use client side time to live of 60 seconds from cache configuration.
    /// let key_1: Option<String> = redis::cmd("GET").arg("KEY_1").query_async(&mut connection).await.unwrap();
    /// // Command below will have client side time to live of 5 seconds;
    /// let command_cache_config = CommandCacheConfig::new().set_client_side_ttl(Duration::from_secs(5));
    /// let key_2: Option<String> = redis::cmd("GET").arg("KEY_2").set_cache_config(command_cache_config).query_async(&mut connection).await.unwrap();
    /// # }
    /// ```
    pub fn set_default_client_ttl(mut self, ttl: Duration) -> Self {
        self.default_client_ttl = ttl;
        self
    }
}

impl Default for CacheConfig {
    /// Creates new CacheConfig with default values (10_000 LRU size and 30 minutes of client ttl)
    fn default() -> Self {
        Self::new()
    }
}
