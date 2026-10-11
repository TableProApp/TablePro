//! Azure Entra ID authentication support for Redis
//!
//! This module provides token-based authentication using Azure Entra ID (formerly Azure Active Directory),
//! enabling secure, dynamic authentication for Redis connections with automatic token refresh and
//! streaming credentials support.
//!
//! # Overview
//!
//! Token-based authentication allows you to authenticate to Redis using Azure Entra ID tokens instead
//! of static passwords. This provides several benefits:
//!
//! - **Enhanced Security**: Tokens have limited lifetimes and can be automatically refreshed
//! - **Centralized Identity Management**: Leverage Azure Entra ID for user and service authentication
//! - **Audit and Compliance**: Better tracking and auditing of authentication events
//! - **Zero-Trust Architecture**: Support for modern security models
//!
//! # Features
//!
//! - **Automatic Token Refresh & Streaming of Credentials**: Seamlessly handle token expiration and stream updated credentials to prevent connection errors due to token expiration
//! - **Multiple Authentication Flows**: Service principals, managed identities, and custom `TokenCredential` implementations
//! - **Configurable Refresh Policies**: Customizable refresh thresholds and retry behavior via [`RetryConfig`]
//! - **Async-First Design**: Full async/await support for non-blocking operations with seamless integration for multiplexed connections
//!
//! # Architecture
//!
//! ## Streaming Credentials Pattern
//!
//! 1. The [`EntraIdCredentialsProvider`] implements the [`StreamingCredentialsProvider`] trait, which allows clients to subscribe to a stream of credentials.
//! 2. An [`EntraIdCredentialsProvider`] can be created with one of the public constructors. Each of them creates a specific `TokenCredential` implementation from the `azure_identity` crate.
//! 3. The [`EntraIdCredentialsProvider`] must be started by calling its `start()` method, which begins a background task for token refresh.
//! 4. A [`MultiplexedConnection`] can leverage a [`StreamingCredentialsProvider`] both for its initial authentication and for subsequent re-authentications when the provider yields new credentials.
//! 5. A credentials provider is attached to an [`AsyncConnectionConfig`], [`ConnectionManagerConfig`], or [`ClusterClientBuilder`](crate::cluster::ClusterClientBuilder) via their `set_credentials_provider()` methods. This configuration is then passed when establishing a connection using methods like [`Client::get_multiplexed_async_connection_with_config()`]. For cluster connections, each node connection independently subscribes to the provider and re-authenticates when credentials rotate.
//! 6. The [`EntraIdCredentialsProvider`] keeps the current token and provides it to a connection when it gets established. Before the connection is fully established, it creates a background task which subscribes for credential updates.
//! 7. When the token is refreshed, the [`EntraIdCredentialsProvider`] notifies all subscribers with the new credentials.
//! 8. When a subscriber receives the new credentials, it uses them to re-authenticate itself.
//!
//! # Quick Start
//!
//! ## Enable the Feature
//!
//! Add the `entra-id` feature to your `Cargo.toml`.
//!
//! ## Basic Usage with DeveloperToolsCredential
//!
//! ```rust,no_run
//! use redis::{Client, EntraIdCredentialsProvider, RetryConfig, AsyncConnectionConfig};
//!
//! # async fn example() -> redis::RedisResult<()> {
//! // Create the credentials provider using the DeveloperToolsCredential
//! let mut provider = EntraIdCredentialsProvider::new_developer_tools()?;
//! provider.start(RetryConfig::default());
//!
//! // Create Redis client
//! let client = Client::open("redis://your-redis-instance.com:6380")?;
//!
//! // Create a connection configuration with credentials provider
//! let config = AsyncConnectionConfig::new().set_credentials_provider(provider);
//!
//! // Get a multiplexed connection with the configuration
//! let mut con = client.get_multiplexed_async_connection_with_config(&config).await?;
//! redis::cmd("SET")
//!     .arg("my_key")
//!     .arg(42i32)
//!     .exec_async(&mut con)
//!     .await?;
//! let result: Option<String> = redis::cmd("GET")
//!     .arg("my_key")
//!     .query_async(&mut con)
//!     .await?;
//! # Ok(())
//! # }
//! ```
//!
//! # Authentication Flows
//!
//! ## DeveloperToolsCredential (Recommended for Development)
//!
//! The `DeveloperToolsCredential` (from `azure_identity`) tries the following credential types, in this order, stopping when one provides a token:
//! * `AzureCliCredential`
//! * `AzureDeveloperCliCredential`
//!
//! ```rust,no_run
//! # use redis::{EntraIdCredentialsProvider, RetryConfig, RedisResult};
//! # fn example() -> RedisResult<()> {
//! let mut provider = EntraIdCredentialsProvider::new_developer_tools()?;
//! provider.start(RetryConfig::default());
//! # Ok(())
//! # }
//! ```
//!
//! ## Service Principal with Client Secret
//!
//! For production applications:
//!
//! ```rust,no_run
//! # use redis::{EntraIdCredentialsProvider, RetryConfig, RedisResult};
//! # fn example() -> RedisResult<()> {
//! let mut provider = EntraIdCredentialsProvider::new_client_secret(
//!     "your-tenant-id".to_string(),
//!     "your-client-id".to_string(),
//!     "your-client-secret".to_string(),
//! )?;
//! provider.start(RetryConfig::default());
//! # Ok(())
//! # }
//! ```
//!
//! ## Service Principal with Certificate
//!
//! For enhanced security:
//!
//! ```rust,no_run
//! # use redis::{ClientCertificate, EntraIdCredentialsProvider, RetryConfig, RedisResult};
//! # use std::fs;
//! # fn example() -> RedisResult<()> {
//! // Load certificate from file
//! let certificate_base64 = fs::read_to_string("path/to/base64_pkcs12_certificate")
//!     .expect("Base64 PKCS12 certificate not found.")
//!     .trim()
//!     .to_string();
//!
//! // Create the credentials provider using service principal with client certificate
//! let mut provider = EntraIdCredentialsProvider::new_client_certificate(
//!     "your-tenant-id".to_string(),
//!     "your-client-id".to_string(),
//!     ClientCertificate {
//!         base64_pkcs12: certificate_base64, // Base64 encoded PKCS12 data
//!         password: None,
//!     },
//! )?;
//! provider.start(RetryConfig::default());
//! # Ok(())
//! # }
//! ```
//!
//! ## Managed Identity
//!
//! For Azure-hosted applications:
//!
//! ```rust,no_run
//! # use redis::{EntraIdCredentialsProvider, RetryConfig, RedisResult};
//! # fn example() -> RedisResult<()> {
//! // System-assigned managed identity
//! let mut provider = EntraIdCredentialsProvider::new_system_assigned_managed_identity()?;
//! provider.start(RetryConfig::default());
//!
//! // User-assigned managed identity
//! let mut provider = EntraIdCredentialsProvider::new_user_assigned_managed_identity()?;
//! provider.start(RetryConfig::default());
//! # Ok(())
//! # }
//! ```
//!
//! For user-assigned managed identity with custom scopes and identity specification:
//!
//! ```rust,no_run
//! # use redis::{EntraIdCredentialsProvider, RetryConfig, RedisResult};
//! # use azure_identity::{ManagedIdentityCredentialOptions, UserAssignedId};
//! # fn example() -> RedisResult<()> {
//! let mut provider = EntraIdCredentialsProvider::new_user_assigned_managed_identity_with_scopes(
//!     vec!["your-scope".to_string()],
//!     Some(ManagedIdentityCredentialOptions {
//!         // Specify the user-assigned identity using one of:
//!         user_assigned_id: Some(UserAssignedId::ClientId("your-client-id".to_string())),
//!         // or: user_assigned_id: Some(UserAssignedId::ObjectId("your-object-id".to_string())),
//!         // or: user_assigned_id: Some(UserAssignedId::ResourceId("your-resource-id".to_string())),
//!         ..Default::default()
//!     }),
//! )?;
//! provider.start(RetryConfig::default());
//! # Ok(())
//! # }
//! ```
//!
//! # Advanced Configuration
//!
//! ## Token Refresh with Custom Configuration
//!
//! The token refresh behavior can be customized by providing a [`RetryConfig`] when starting the provider:
//!
//! ```rust,no_run
//! # use redis::{EntraIdCredentialsProvider, RetryConfig, RedisResult};
//! # use std::time::Duration;
//! # fn example() -> RedisResult<()> {
//! let mut provider = EntraIdCredentialsProvider::new_developer_tools()?;
//!
//! let retry_config = RetryConfig::default()
//!     .set_number_of_retries(3)
//!     .set_min_delay(Duration::from_millis(100))
//!     .set_max_delay(Duration::from_secs(30))
//!     .set_exponent_base(2.0);
//!
//! provider.start(retry_config);
//! # Ok(())
//! # }
//! ```
//!
//! # Error Handling
//!
//! The library provides comprehensive error handling for authentication and token refresh failures.
//! The background token refresh service will automatically retry failed token refreshes according to the retry configuration.
//! Once the maximum number of attempts is reached, the service will stop retrying and the underlying error will be propagated to the subscribers.
//!
//! # Best Practices
//!
//! ## Use Appropriate Credential Types
//!
//! - **Development**: `DeveloperToolsCredential` (from `azure_identity`)
//! - **Production Services**: Service Principal with certificate
//! - **Azure-hosted Apps**: Managed Identity
//!
//! ## Security Considerations
//!
//! - Store client secrets securely (Azure Key Vault, environment variables)
//! - Use certificates instead of secrets when possible
//!
//! # Compatibility
//!
//! - **Redis Versions**: Compatible with Redis 6.0+ (ACL support required)
//! - **Azure Redis**: Fully compatible with Azure Cache for Redis
//!
//! # Troubleshooting
//!
//! ## Common Issues
//!
//! 1. **"Authentication failed"**: Check your credentials and permissions
//! 2. **"Token expired"**: Ensure automatic refresh is properly configured
//! 3. **"Connection timeout"**: Check network connectivity and Redis endpoint
//!
//! [`Client`]: crate::Client
//! [`Client::get_multiplexed_async_connection_with_config()`]: crate::Client::get_multiplexed_async_connection_with_config
//! [`StreamingCredentialsProvider`]: crate::auth::StreamingCredentialsProvider
//! [`MultiplexedConnection`]: crate::aio::MultiplexedConnection
//! [`AsyncConnectionConfig`]: crate::AsyncConnectionConfig
//! [`ConnectionManagerConfig`]: crate::aio::ConnectionManagerConfig

use crate::RetryConfig;
use crate::auth::BasicAuth;
use crate::auth::StreamingCredentialsProvider;
use crate::auth_management::credentials_management_utils;
use crate::errors::{ErrorKind, RedisError};
use crate::types::RedisResult;
use azure_core::credentials::{AccessToken, Secret, TokenCredential};
use azure_core::time::OffsetDateTime;
use azure_identity::{
    ClientCertificateCredential, ClientCertificateCredentialOptions, ClientSecretCredential,
    ClientSecretCredentialOptions, DeveloperToolsCredential, DeveloperToolsCredentialOptions,
    ManagedIdentityCredential, ManagedIdentityCredentialOptions,
};
use backon::{ExponentialBuilder, Retryable};
use futures_util::{Stream, StreamExt};
use log::{debug, error, warn};
use std::pin::Pin;
use std::sync::{Arc, Mutex, RwLock};
use tokio::sync::mpsc::Sender;

/// The default Redis scope for Azure Managed Redis
pub const REDIS_SCOPE_DEFAULT: &str = "https://redis.azure.com/.default";

/// The number of seconds before token expiration to trigger a refresh.
/// This buffer ensures the token is refreshed before it actually expires.
const TOKEN_REFRESH_BUFFER_SECS: u64 = 240;

/// A client certificate in PKCS12 (PFX) that can be used for client certificate authentication.
///
/// The certificate data should be base64-encoded PKCS12 content.
/// If the PKCS12 archive is password-protected, provide the password via `password`.
#[derive(Debug, Clone)]
pub struct ClientCertificate {
    /// Base64-encoded PKCS12 certificate data
    pub base64_pkcs12: String,
    /// The certificate's password if any
    pub password: Option<String>,
}

type Subscriptions = Vec<Sender<RedisResult<BasicAuth>>>;
type SharedSubscriptions = Arc<Mutex<Subscriptions>>;

struct TaskAborter {
    handle: tokio::task::JoinHandle<()>,
}

impl Drop for TaskAborter {
    fn drop(&mut self) {
        self.handle.abort();
    }
}
/// Entra ID credentials provider that uses Azure Identity for authentication
#[derive(Clone)]
pub struct EntraIdCredentialsProvider {
    credential_provider: Arc<dyn TokenCredential + Send + Sync>,
    scopes: Vec<String>,
    background_handle: Arc<Mutex<Option<TaskAborter>>>,
    subscribers: SharedSubscriptions,
    current_credentials: Arc<RwLock<Option<BasicAuth>>>,
}

impl EntraIdCredentialsProvider {
    /// Validate that scopes are not empty
    fn validate_scopes(scopes: &[String]) -> RedisResult<()> {
        if scopes.is_empty() {
            return Err(RedisError::from((
                ErrorKind::InvalidClientConfig,
                "Scopes cannot be empty for Entra ID authentication",
            )));
        }

        for scope in scopes {
            if scope.trim().is_empty() {
                return Err(RedisError::from((
                    ErrorKind::InvalidClientConfig,
                    "Scope cannot be empty or whitespace-only",
                )));
            }
        }

        Ok(())
    }

    /// Convert Azure AccessToken to Redis BasicAuth
    fn convert_credentials(username: String, access_token: &AccessToken) -> BasicAuth {
        BasicAuth {
            username,
            password: access_token.token.secret().to_string(),
        }
    }

    /// Convert Azure Core error to Redis error
    fn convert_error(err: azure_core::Error) -> RedisError {
        RedisError::from((
            ErrorKind::AuthenticationFailed,
            "Entra ID authentication failed",
            format!("{err}"),
        ))
    }

    /// Convert Azure Core error to Redis error
    fn convert_error_ref(err: &azure_core::Error) -> RedisError {
        RedisError::from((
            ErrorKind::AuthenticationFailed,
            "Entra ID authentication failed",
            format!("{err}"),
        ))
    }

    /// Unwrap a credentials provider from its `Arc` wrapper.
    ///
    /// The azure_identity crate returns credentials wrapped in an `Arc`, while sole ownership is expected at construction time.
    /// Failure to unwrap indicates unexpected shared ownership within the azure_identity crate internals.
    fn unwrap_credential<T: TokenCredential>(credential: std::sync::Arc<T>) -> RedisResult<T> {
        std::sync::Arc::try_unwrap(credential).map_err(|_| {
            RedisError::from((
                ErrorKind::AuthenticationFailed,
                "[azure_identity]: Unexpected shared ownership of credentials provider.",
            ))
        })
    }

    async fn notify_subscribers(
        subscribers_arc: &SharedSubscriptions,
        username: &str,
        token_response: Result<AccessToken, azure_core::Error>,
    ) {
        let subscribers = {
            let mut guard = subscribers_arc
                .lock()
                .expect("could not acquire lock for subscribers");
            guard.retain(|sender| !sender.is_closed());
            guard.clone()
        };

        futures_util::future::join_all(subscribers.iter().map(|sender| {
            let token_response = token_response.as_ref();
            let response = match token_response {
                Ok(access_token) => {
                    Ok(Self::convert_credentials(username.to_owned(), access_token))
                }
                Err(error) => Err(Self::convert_error_ref(error)),
            };

            sender.send(response)
        }))
        .await;
    }

    /// Start the background refresh service
    fn start_refresh_service<F>(
        &mut self,
        retry_config: RetryConfig,
        compute_sleep_duration_on_success: F,
    ) where
        F: Fn(&AccessToken) -> std::time::Duration + Send + Sync + 'static,
    {
        // Prevent multiple calls to start
        if self.background_handle.lock().unwrap().is_some() {
            return;
        }

        let subscribers_arc = Arc::clone(&self.subscribers);
        let current_credentials_arc = Arc::clone(&self.current_credentials);

        let credential_provider_arc = Arc::clone(&self.credential_provider);
        let scopes = self.scopes.clone();

        let handle = tokio::spawn(async move {
            let scopes: Vec<&str> = scopes.iter().map(|s| s.as_str()).collect();
            let mut next_sleep_duration;
            let mut username = "default".to_string();
            let RetryConfig {
                exponent_base,
                min_delay,
                max_delay,
                number_of_retries,
            } = retry_config;
            let mut strategy = ExponentialBuilder::default()
                .with_factor(exponent_base)
                .with_min_delay(min_delay)
                .with_max_times(number_of_retries)
                .with_jitter();

            if let Some(mex_delay) = max_delay {
                strategy = strategy.with_max_delay(mex_delay);
            }

            loop {
                debug!("Refreshing token.");
                let get_auth = || async { credential_provider_arc.get_token(&scopes, None).await };

                let token_response = get_auth
                    .retry(strategy)
                    .sleep(|duration| async move { tokio::time::sleep(duration).await })
                    .notify(|err, duration| warn!("An error `{err}` occurred while refreshing the token. Sleeping for {duration:?}"))
                    .await;

                if let Ok(ref access_token) = token_response {
                    username = match credentials_management_utils::extract_oid_from_jwt(
                        access_token.token.secret(),
                    ) {
                        Ok(object_id) => object_id,
                        Err(error) => {
                            warn!("Failed to extract OID: {error}");
                            "default".to_string()
                        }
                    };

                    *current_credentials_arc.write().unwrap() =
                        Some(Self::convert_credentials(username.clone(), access_token));

                    next_sleep_duration = compute_sleep_duration_on_success(access_token);
                } else {
                    error!("Maximum token refresh attempts reached. Stopping token refresh.");
                    Self::notify_subscribers(&subscribers_arc, &username, token_response).await;
                    break;
                }

                Self::notify_subscribers(&subscribers_arc, &username, token_response).await;

                tokio::time::sleep(std::time::Duration::from_millis(
                    next_sleep_duration.as_millis() as u64,
                ))
                .await;
            }
        });

        *self.background_handle.lock().unwrap() = Some(TaskAborter { handle });
    }

    /// Create a new provider using the DeveloperToolsCredential
    /// This is recommended for development and will try multiple credential types
    pub fn new_developer_tools() -> RedisResult<Self> {
        Self::new_developer_tools_with_scopes(vec![REDIS_SCOPE_DEFAULT.to_string()], None)
    }

    /// Create a new provider using the DeveloperToolsCredential with custom scopes
    pub fn new_developer_tools_with_scopes(
        scopes: Vec<String>,
        options: Option<DeveloperToolsCredentialOptions>,
    ) -> RedisResult<Self> {
        Self::validate_scopes(&scopes)?;
        let credential_provider =
            DeveloperToolsCredential::new(options).map_err(Self::convert_error)?;
        Ok(Self {
            credential_provider: Arc::new(Self::unwrap_credential(credential_provider)?),
            scopes,
            background_handle: Default::default(),
            subscribers: Default::default(),
            current_credentials: Default::default(),
        })
    }

    /// Create a new provider using client secret authentication (service principal)
    pub fn new_client_secret(
        tenant_id: String,
        client_id: String,
        client_secret: String,
    ) -> RedisResult<Self> {
        Self::new_client_secret_with_scopes(
            tenant_id,
            client_id,
            client_secret,
            vec![REDIS_SCOPE_DEFAULT.to_string()],
            None,
        )
    }

    /// Create a new provider using client secret authentication with custom scopes
    pub fn new_client_secret_with_scopes(
        tenant_id: String,
        client_id: String,
        client_secret: String,
        scopes: Vec<String>,
        options: Option<ClientSecretCredentialOptions>,
    ) -> RedisResult<Self> {
        Self::validate_scopes(&scopes)?;
        let credential_provider =
            ClientSecretCredential::new(&tenant_id, client_id, client_secret.into(), options)
                .map_err(Self::convert_error)?;
        Ok(Self {
            credential_provider: Arc::new(Self::unwrap_credential(credential_provider)?),
            scopes,
            background_handle: Default::default(),
            subscribers: Default::default(),
            current_credentials: Default::default(),
        })
    }

    /// Create a new provider using client certificate authentication (service principal)
    pub fn new_client_certificate(
        tenant_id: String,
        client_id: String,
        client_certificate: ClientCertificate,
    ) -> RedisResult<Self> {
        Self::new_client_certificate_with_scopes(
            tenant_id,
            client_id,
            client_certificate,
            vec![REDIS_SCOPE_DEFAULT.to_string()],
            None,
        )
    }

    /// Create a new provider using client certificate authentication with custom scopes
    pub fn new_client_certificate_with_scopes(
        tenant_id: String,
        client_id: String,
        client_certificate: ClientCertificate,
        scopes: Vec<String>,
        mut options: Option<ClientCertificateCredentialOptions>,
    ) -> RedisResult<Self> {
        Self::validate_scopes(&scopes)?;
        if let Some(password) = client_certificate.password {
            if let Some(ref mut opts) = options {
                opts.password = Some(Secret::new(password));
            } else {
                options = Some(ClientCertificateCredentialOptions {
                    password: Some(Secret::new(password)),
                    ..Default::default()
                });
            }
        }
        let credential_provider = ClientCertificateCredential::new(
            tenant_id,
            client_id,
            client_certificate.base64_pkcs12.into(),
            options,
        )
        .map_err(Self::convert_error)?;
        Ok(Self {
            credential_provider: Arc::new(Self::unwrap_credential(credential_provider)?),
            scopes,
            background_handle: Default::default(),
            subscribers: Default::default(),
            current_credentials: Default::default(),
        })
    }

    /// Create a new provider using system-assigned managed identity
    pub fn new_system_assigned_managed_identity() -> RedisResult<Self> {
        Self::new_system_assigned_managed_identity_with_scopes(
            vec![REDIS_SCOPE_DEFAULT.to_string()],
            None,
        )
    }

    /// Create a new provider using system-assigned managed identity with custom scopes
    pub fn new_system_assigned_managed_identity_with_scopes(
        scopes: Vec<String>,
        options: Option<ManagedIdentityCredentialOptions>,
    ) -> RedisResult<Self> {
        Self::validate_scopes(&scopes)?;
        let credential_provider =
            ManagedIdentityCredential::new(options).map_err(Self::convert_error)?;
        Ok(Self {
            credential_provider: Arc::new(Self::unwrap_credential(credential_provider)?),
            scopes,
            background_handle: Default::default(),
            subscribers: Default::default(),
            current_credentials: Default::default(),
        })
    }

    /// Create a new provider using user-assigned managed identity
    pub fn new_user_assigned_managed_identity() -> RedisResult<Self> {
        Self::new_user_assigned_managed_identity_with_scopes(
            vec![REDIS_SCOPE_DEFAULT.to_string()],
            None,
        )
    }

    /// Create a new provider using user-assigned managed identity with custom scopes
    pub fn new_user_assigned_managed_identity_with_scopes(
        scopes: Vec<String>,
        options: Option<ManagedIdentityCredentialOptions>,
    ) -> RedisResult<Self> {
        Self::validate_scopes(&scopes)?;
        let credential_provider =
            ManagedIdentityCredential::new(options).map_err(Self::convert_error)?;
        Ok(Self {
            credential_provider: Arc::new(Self::unwrap_credential(credential_provider)?),
            scopes,
            background_handle: Default::default(),
            subscribers: Default::default(),
            current_credentials: Default::default(),
        })
    }

    /// Create a new provider with a custom credential implementation
    pub fn new_with_credential(
        credential_provider: Arc<dyn TokenCredential + Send + Sync>,
        scopes: Vec<String>,
    ) -> RedisResult<Self> {
        Self::validate_scopes(&scopes)?;
        Ok(Self {
            credential_provider,
            scopes,
            background_handle: Default::default(),
            subscribers: Default::default(),
            current_credentials: Default::default(),
        })
    }

    /// Start the background refresh service
    pub fn start(&mut self, retry_config: RetryConfig) {
        self.start_refresh_service(retry_config, |access_token| {
            let remaining = access_token.expires_on - OffsetDateTime::now_utc();
            let remaining_duration = match remaining.try_into() {
                Ok(duration) => duration,
                Err(_) => std::time::Duration::from_secs(0),
            };
            remaining_duration
                .checked_sub(std::time::Duration::from_secs(TOKEN_REFRESH_BUFFER_SECS))
                .unwrap_or_else(|| {
                    warn!("The token is about to expire! Refreshing...");
                    std::time::Duration::from_secs(0)
                })
        });
    }
}

impl StreamingCredentialsProvider for EntraIdCredentialsProvider {
    fn subscribe(&self) -> Pin<Box<dyn Stream<Item = RedisResult<BasicAuth>> + Send + 'static>> {
        let (tx, rx) = tokio::sync::mpsc::channel::<RedisResult<BasicAuth>>(1);

        self.subscribers
            .lock()
            .expect("could not acquire lock for subscribers")
            .push(tx);

        let stream = futures_util::stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|item| (item, rx))
        });

        if let Some(creds) = self.current_credentials.read().unwrap().clone() {
            futures_util::stream::once(async move { Ok(creds) })
                .chain(stream)
                .boxed()
        } else {
            stream.boxed()
        }
    }
}

impl std::fmt::Debug for EntraIdCredentialsProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EntraIdCredentialsProvider")
            .field("scopes", &self.scopes)
            .field("credential", &"<TokenCredential>")
            .finish()
    }
}

#[cfg(all(feature = "entra-id", test))]
mod tests {
    use super::*;

    #[test]
    fn test_entra_id_provider_creation() {
        // Test that credentials providers can be created without panicking
        let _default_provider = EntraIdCredentialsProvider::new_developer_tools();
        _default_provider.unwrap();

        let _client_secret_provider = EntraIdCredentialsProvider::new_client_secret(
            "tenant".to_string(),
            "client".to_string(),
            "secret".to_string(),
        );
        _client_secret_provider.unwrap();

        let _managed_identity_provider =
            EntraIdCredentialsProvider::new_system_assigned_managed_identity();
        _managed_identity_provider.unwrap();
    }

    #[test]
    fn test_scope_validation() {
        // Test empty scopes
        let result = EntraIdCredentialsProvider::new_developer_tools_with_scopes(vec![], None);
        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("Scopes cannot be empty")
        );

        // Test empty string scope
        let result =
            EntraIdCredentialsProvider::new_developer_tools_with_scopes(vec!["".to_string()], None);
        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("Scope cannot be empty")
        );

        // Test whitespace-only scope
        let result = EntraIdCredentialsProvider::new_developer_tools_with_scopes(
            vec!["   ".to_string()],
            None,
        );
        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("Scope cannot be empty")
        );
    }

    #[test]
    fn test_custom_scopes() {
        let custom_scopes = vec!["https://custom.scope/.default".to_string()];
        let provider = EntraIdCredentialsProvider::new_developer_tools_with_scopes(
            custom_scopes.clone(),
            None,
        )
        .unwrap();
        assert_eq!(provider.scopes, custom_scopes);
    }
}

#[cfg(all(feature = "entra-id", test))]
mod entra_id_mock_tests {
    use crate::{
        EntraIdCredentialsProvider, REDIS_SCOPE_DEFAULT, RetryConfig, StreamingCredentialsProvider,
    };
    use azure_core::Error as AzureError;
    use azure_core::credentials::{AccessToken, Secret, TokenCredential};
    use azure_core::time::{Duration, OffsetDateTime};
    use futures_util::StreamExt;
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, LazyLock, Once};
    use tokio::sync::Mutex;

    static INIT_LOGGER: Once = Once::new();

    /// Initialize the logger for tests. Only initializes once even if called multiple times.
    /// Respects RUST_LOG environment variable if set, otherwise defaults to Debug level.
    fn init_logger() {
        INIT_LOGGER.call_once(|| {
            let mut builder = env_logger::builder();
            builder.is_test(true);
            if std::env::var("RUST_LOG").is_err() {
                builder.filter_level(log::LevelFilter::Debug);
            }
            builder.init();
        });
    }

    const TOKEN_PAYLOAD: &str = "eyJvaWQiOiIxMjM0NTY3OC05YWJjLWRlZi0xMjM0LTU2Nzg5YWJjZGVmMCJ9"; // Payload with "oid" claim
    const TOKEN_SIGNATURE: &str = "signature";

    const OID_CLAIM_VALUE: &str = "12345678-9abc-def-1234-56789abcdef0";

    static MOCKED_TOKEN: LazyLock<String> =
        LazyLock::new(|| format!("mock_jwt_token.{TOKEN_PAYLOAD}.{TOKEN_SIGNATURE}"));

    static MOCKED_TOKEN_1: LazyLock<String> =
        LazyLock::new(|| format!("mock_jwt_token1.{TOKEN_PAYLOAD}.{TOKEN_SIGNATURE}"));
    static MOCKED_TOKEN_2: LazyLock<String> =
        LazyLock::new(|| format!("mock_jwt_token2.{TOKEN_PAYLOAD}.{TOKEN_SIGNATURE}"));
    static MOCKED_TOKEN_3: LazyLock<String> =
        LazyLock::new(|| format!("mock_jwt_token3.{TOKEN_PAYLOAD}.{TOKEN_SIGNATURE}"));

    /// Mock TokenCredential that simulates Azure Identity behavior
    #[derive(Debug)]
    struct MockTokenCredential {
        /// Counter to track how many times get_token was called
        call_count: Arc<AtomicUsize>,
        /// Predefined responses to return
        responses: Arc<Mutex<VecDeque<Result<AccessToken, AzureError>>>>,
    }

    impl MockTokenCredential {
        /// Create a mock that always succeeds
        fn success() -> Self {
            let token = AccessToken {
                token: Secret::new(MOCKED_TOKEN.as_str()),
                expires_on: OffsetDateTime::now_utc() + Duration::hours(1),
            };

            Self {
                call_count: Arc::new(AtomicUsize::new(0)),
                responses: Arc::new(Mutex::new(VecDeque::from(vec![Ok(token)]))),
            }
        }

        /// Create a mock that always fails with an authentication error
        fn failure() -> Self {
            let error = AzureError::new(
                azure_core::error::ErrorKind::Credential,
                "Authentication failed due to invalid credentials".to_string(),
            );

            Self {
                call_count: Arc::new(AtomicUsize::new(0)),
                responses: Arc::new(Mutex::new(VecDeque::from(vec![Err(error)]))),
            }
        }

        /// Creates a mock that simulates alternating token refresh responses. (first call fails, second succeeds)
        fn alternating_fail_success() -> Self {
            let error = AzureError::new(
                azure_core::error::ErrorKind::Credential,
                "Temporary failure".to_string(),
            );

            let token = AccessToken {
                token: Secret::new(MOCKED_TOKEN.as_str()),
                expires_on: OffsetDateTime::now_utc() + Duration::hours(1),
            };

            Self {
                call_count: Arc::new(AtomicUsize::new(0)),
                responses: Arc::new(Mutex::new(VecDeque::from(vec![Err(error), Ok(token)]))),
            }
        }

        /// Create a mock that simulates multiple token refreshes
        fn multiple_tokens() -> Self {
            let time_now = OffsetDateTime::now_utc();
            let tokens = vec![
                Ok(AccessToken {
                    token: Secret::new(MOCKED_TOKEN_1.as_str()),
                    expires_on: time_now + Duration::seconds(1),
                }),
                Ok(AccessToken {
                    token: Secret::new(MOCKED_TOKEN_2.as_str()),
                    expires_on: time_now + Duration::seconds(2),
                }),
                Ok(AccessToken {
                    token: Secret::new(MOCKED_TOKEN_3.as_str()),
                    expires_on: time_now + Duration::seconds(3),
                }),
            ];

            Self {
                call_count: Arc::new(AtomicUsize::new(0)),
                responses: Arc::new(Mutex::new(VecDeque::from(tokens))),
            }
        }
    }

    #[async_trait::async_trait]
    impl TokenCredential for MockTokenCredential {
        async fn get_token(
            &self,
            _scopes: &[&str],
            _options: Option<azure_core::credentials::TokenRequestOptions<'_>>,
        ) -> azure_core::Result<AccessToken> {
            self.call_count.fetch_add(1, Ordering::SeqCst);

            let mut responses = self.responses.lock().await;

            // After popping the response, queue it back to simulate a cyclic behavior.
            match responses.pop_front() {
                Some(Ok(token)) => {
                    responses.push_back(Ok(token.clone()));
                    Ok(token)
                }
                Some(Err(err)) => {
                    responses.push_back(Err(AzureError::new(
                        azure_core::error::ErrorKind::Credential,
                        "Mock authentication failed",
                    )));
                    Err(err)
                }
                None => {
                    unreachable!("No more responses");
                }
            }
        }
    }

    /// Helper to create a mock EntraIdCredentialsProvider
    fn create_mock_entra_id_credentials_provider(
        mock_credential: MockTokenCredential,
        scopes: Vec<String>,
    ) -> EntraIdCredentialsProvider {
        create_arc_mock_entra_id_credentials_provider(Arc::new(mock_credential), scopes)
    }

    /// Helper to create a mock EntraIdCredentialsProvider from an Arc-wrapped MockTokenCredential
    fn create_arc_mock_entra_id_credentials_provider(
        mock_credential: Arc<MockTokenCredential>,
        scopes: Vec<String>,
    ) -> EntraIdCredentialsProvider {
        EntraIdCredentialsProvider::new_with_credential(mock_credential, scopes).unwrap()
    }

    #[tokio::test]
    async fn test_mock_successful_authentication() {
        init_logger();
        let mock_credential = MockTokenCredential::success();
        let call_count_ref = mock_credential.call_count.clone();

        let mut provider = create_mock_entra_id_credentials_provider(
            mock_credential,
            vec![REDIS_SCOPE_DEFAULT.to_string()],
        );
        provider.start(RetryConfig::default());

        // Wait a bit for the background task to run
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        // Verify that get_token was called
        assert!(call_count_ref.load(Ordering::SeqCst) > 0);

        // Test that the subscription stream yields the correct credentials
        let mut stream = provider.subscribe();
        let credentials = stream.next().await.unwrap().unwrap();

        assert!(!credentials.username.is_empty());
        assert!(!credentials.password.is_empty());
        assert_eq!(credentials.username, OID_CLAIM_VALUE);
        assert_eq!(credentials.password, MOCKED_TOKEN.as_str());
    }

    #[tokio::test]
    async fn test_mock_authentication_failure() {
        init_logger();
        let mock_credential = MockTokenCredential::failure();
        let call_count_ref = mock_credential.call_count.clone();

        let mut provider = create_mock_entra_id_credentials_provider(
            mock_credential,
            vec![REDIS_SCOPE_DEFAULT.to_string()],
        );
        provider.start(
            RetryConfig::default()
                .set_number_of_retries(1) // It's really important to set the max_attempt to one, otherwise the refresh loop will cycle through the error.
                .set_min_delay(std::time::Duration::from_millis(10))
                .set_max_delay(std::time::Duration::from_millis(100))
                .set_exponent_base(2.0),
        );

        // Test that the stream returns an error once the maximum number of retries is reached
        let mut stream = provider.subscribe();
        if let Some(result) = stream.next().await {
            assert!(call_count_ref.load(Ordering::SeqCst) > 0);
            assert!(result.is_err());
            assert!(
                result
                    .unwrap_err()
                    .to_string()
                    .contains("authentication failed")
            );
        }
    }

    #[tokio::test]
    async fn test_mock_retry_mechanism() {
        init_logger();
        let mock_credential = MockTokenCredential::alternating_fail_success();
        let call_count_ref = mock_credential.call_count.clone();

        let mut provider = create_mock_entra_id_credentials_provider(
            mock_credential,
            vec![REDIS_SCOPE_DEFAULT.to_string()],
        );
        provider.start(RetryConfig::default());

        // Wait for the retries to complete
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        // get_token should have been called multiple times (initial failure + retry)
        assert!(call_count_ref.load(Ordering::SeqCst) >= 2);

        // Eventually should get successful credentials
        let mut stream = provider.subscribe();
        let credentials = stream.next().await.unwrap().unwrap();
        assert_eq!(credentials.username, OID_CLAIM_VALUE);
        assert_eq!(credentials.password, MOCKED_TOKEN.as_str());
    }

    #[tokio::test]
    async fn test_mock_multiple_subscribers() {
        init_logger();
        let mock_credential = MockTokenCredential::multiple_tokens();
        let call_count_ref = mock_credential.call_count.clone();

        let mut provider = create_mock_entra_id_credentials_provider(
            mock_credential,
            vec![REDIS_SCOPE_DEFAULT.to_string()],
        );
        provider.start(RetryConfig::default());

        // Create multiple subscribers
        let mut stream1 = provider.subscribe();
        let mut stream2 = provider.subscribe();
        let mut stream3 = provider.subscribe();

        // All subscribers should receive the same initial credentials
        let credentials1 = stream1.next().await.unwrap().unwrap();
        let credentials2 = stream2.next().await.unwrap().unwrap();
        let credentials3 = stream3.next().await.unwrap().unwrap();

        assert_eq!(credentials1.password, credentials2.password);
        assert_eq!(credentials2.password, credentials3.password);

        assert_eq!(credentials1.password, MOCKED_TOKEN_1.as_str());

        // Verify that get_token was called only once
        assert_eq!(call_count_ref.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn test_mock_multiple_tokens_over_time() {
        init_logger();
        let mock_credential = MockTokenCredential::multiple_tokens();
        let call_count_ref = mock_credential.call_count.clone();
        let mut provider = create_mock_entra_id_credentials_provider(
            mock_credential,
            vec![REDIS_SCOPE_DEFAULT.to_string()],
        );
        provider.start(RetryConfig::default());

        let mut stream = provider.subscribe();
        // Wait for the first token to be received
        let credentials = stream.next().await.unwrap().unwrap();
        assert!(call_count_ref.load(Ordering::SeqCst) >= 1);
        assert_eq!(credentials.username, OID_CLAIM_VALUE);
        assert_eq!(credentials.password, MOCKED_TOKEN_1.as_str());

        // Wait for the next token to be received
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        let credentials = stream.next().await.unwrap().unwrap();
        assert!(call_count_ref.load(Ordering::SeqCst) >= 2);
        assert_eq!(credentials.username, OID_CLAIM_VALUE);
        assert_eq!(credentials.password, MOCKED_TOKEN_2.as_str());

        // Wait for the next token to be received
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        let credentials = stream.next().await.unwrap().unwrap();
        assert!(call_count_ref.load(Ordering::SeqCst) >= 3);
        assert_eq!(credentials.username, OID_CLAIM_VALUE);
        assert_eq!(credentials.password, MOCKED_TOKEN_3.as_str());
    }

    #[test]
    fn test_mock_scope_validation() {
        use std::panic;

        let result = panic::catch_unwind(|| {
            create_mock_entra_id_credentials_provider(MockTokenCredential::success(), Vec::new());
        });

        assert!(
            result.is_err(),
            "Expected `create_mock_entra_id_credentials_provider` to panic, but it did not."
        );
        assert!(
            result
                .unwrap_err()
                .downcast_ref::<String>()
                .unwrap()
                .contains("Scopes cannot be empty")
        );
    }

    #[tokio::test]
    async fn test_mock_subscriber_cleanup() {
        init_logger();
        let mock_credential = MockTokenCredential::multiple_tokens();

        let mut provider = create_mock_entra_id_credentials_provider(
            mock_credential,
            vec![REDIS_SCOPE_DEFAULT.to_string()],
        );
        provider.start(RetryConfig::default());

        let mut stream1 = provider.subscribe();
        let mut stream2 = provider.subscribe();
        let mut stream3 = provider.subscribe();

        assert_eq!(provider.subscribers.lock().unwrap().len(), 3);

        let credentials1 = stream1.next().await.unwrap().unwrap();
        let credentials2 = stream2.next().await.unwrap().unwrap();
        let credentials3 = stream3.next().await.unwrap().unwrap();

        assert_eq!(credentials1.password, MOCKED_TOKEN_1.as_str());
        assert_eq!(credentials1.password, credentials2.password);
        assert_eq!(credentials2.password, credentials3.password);

        // Drop one subscriber (this closes the receiver, which should close the sender)
        drop(stream3);

        let credentials1 = stream1.next().await.unwrap().unwrap();
        let credentials2 = stream2.next().await.unwrap().unwrap();

        assert_eq!(credentials1.password, MOCKED_TOKEN_2.as_str());
        assert_eq!(credentials1.password, credentials2.password);

        assert_eq!(
            provider.subscribers.lock().unwrap().len(),
            2,
            "Dropped subscriber should be removed"
        );

        drop(stream2);

        assert_eq!(
            stream1.next().await.unwrap().unwrap().password,
            MOCKED_TOKEN_3.as_str()
        );

        assert_eq!(
            provider.subscribers.lock().unwrap().len(),
            1,
            "Only one subscriber should remain"
        );
    }

    /// This test asserts that the EntraIdCredentialsProvider can be cloned and
    /// dropped without stopping the background task until all instances are dropped.
    #[tokio::test]
    async fn test_mock_provider_with_running_background_task_cleanup() {
        init_logger();
        let mock_credential = MockTokenCredential::success();

        let mut provider = create_mock_entra_id_credentials_provider(
            mock_credential,
            vec![REDIS_SCOPE_DEFAULT.to_string()],
        );

        assert!(
            provider.background_handle.lock().unwrap().is_none(),
            "Background task should not be running before start() is called"
        );

        provider.start(RetryConfig::default());
        // Wait for the background task to start
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        // Because the credential_provider is copied into the background task,
        // it can be used to track if the background task is still running.
        let credential_provider_ref = Arc::downgrade(&provider.credential_provider);

        let _cloned_provider = provider.clone();
        assert_eq!(
            credential_provider_ref.strong_count(),
            3,
            "There should be three strong references to the credential provider after cloning (original EntraIdCredentialsProvider + background task + cloned EntraIdCredentialsProvider)"
        );

        // After dropping the original EntraIdCredentialsProvider, there should still have two instances:
        // One for the cloned EntraIdCredentialsProvider and one for the background task.
        // This asserts that dropping a single EntraIdCredentialsProvider does not stop the background task.
        drop(provider);
        assert_eq!(
            credential_provider_ref.strong_count(),
            2,
            "There should be two strong references to the credential provider after dropping the original EntraIdCredentialsProvider"
        );

        // By dropping the last EntraIdCredentialsProvider, it should trigger the background task to stop,
        // causing the remaining 2 instances of the credential_provider to be dropped.
        drop(_cloned_provider);
        // Wait for the background task to stop
        tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        assert_eq!(
            credential_provider_ref.strong_count(),
            0,
            "There should be no strong references to the credential provider after the last EntraIdCredentialsProvider is dropped"
        );
    }
}
