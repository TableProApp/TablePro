//! Token-based authentication support for Redis
use crate::types::RedisResult;
use futures_util::Stream;
use std::pin::Pin;

/// Basic authentication credentials for a Redis connection
#[derive(Debug, Clone, Default)]
pub struct BasicAuth {
    /// The username for authentication
    pub(crate) username: String,
    /// The password for authentication
    pub(crate) password: String,
}

impl BasicAuth {
    /// Create new BasicAuth credentials
    pub fn new(username: String, password: String) -> Self {
        Self { username, password }
    }

    /// Get the username
    pub fn username(&self) -> &str {
        &self.username
    }

    /// Get the password
    pub fn password(&self) -> &str {
        &self.password
    }

    /// Set the username
    pub fn set_username(&mut self, username: String) {
        self.username = username;
    }

    /// Set the password
    pub fn set_password(&mut self, password: String) {
        self.password = password;
    }
}

/// Trait for providing credentials in a streaming fashion
///
/// This allows connections to subscribe to credential updates and automatically
/// re-authenticate when tokens are refreshed, preventing connection failures
/// due to token expiration.
pub trait StreamingCredentialsProvider: Send + Sync {
    /// Get an independent stream of credentials.
    fn subscribe(&self) -> Pin<Box<dyn Stream<Item = RedisResult<BasicAuth>> + Send + 'static>>;
}
