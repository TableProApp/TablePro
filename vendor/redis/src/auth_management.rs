//! This module contains utilities for managing token-based authentication
use std::time::{Duration, SystemTime};

/// Configuration for token refresh behavior
#[derive(Debug, Clone)]
#[non_exhaustive]
pub struct TokenRefreshConfig {
    /// Fraction of token lifetime after which refresh should be triggered (0.0 to 1.0).
    /// For example, 0.8 means refresh when 80% of the token's lifetime has elapsed.
    pub expiration_refresh_ratio: f64,
    /// Retry configuration for failed refresh attempts
    pub retry_config: RetryConfig,
}

impl TokenRefreshConfig {
    /// Set the expiration refresh ratio
    pub fn set_expiration_refresh_ratio(mut self, ratio: f64) -> Self {
        self.expiration_refresh_ratio = ratio;
        self
    }

    /// Set the retry configuration
    pub fn set_retry_config(mut self, retry_config: RetryConfig) -> Self {
        self.retry_config = retry_config;
        self
    }
}

impl Default for TokenRefreshConfig {
    fn default() -> Self {
        Self {
            expiration_refresh_ratio: 0.8,
            retry_config: RetryConfig::default(),
        }
    }
}

/// Configuration for handling failed token refresh attempts
#[derive(Debug, Clone)]
#[non_exhaustive]
pub struct RetryConfig {
    /// The resulting duration is calculated by taking the base to the `n`-th power,
    /// where `n` denotes the number of past attempts.
    pub(crate) exponent_base: f32,
    /// The minimal delay for reconnection attempts
    pub(crate) min_delay: Duration,
    /// Apply a maximum delay between connection attempts. The delay between attempts won't be longer than max_delay milliseconds.
    pub(crate) max_delay: Option<Duration>,
    /// number_of_retries times, with an exponentially increasing delay
    pub(crate) number_of_retries: usize,
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            number_of_retries: 3,
            min_delay: Duration::from_millis(100),
            max_delay: Some(Duration::from_secs(30)),
            exponent_base: 2.0,
        }
    }
}

impl RetryConfig {
    /// Sets the maximum number of retry attempts for token refresh
    pub fn set_number_of_retries(mut self, number_of_retries: usize) -> Self {
        self.number_of_retries = number_of_retries;
        self
    }

    /// Sets the minimal delay before attempting to refresh the token after a failure
    pub fn set_min_delay(mut self, min_delay: Duration) -> Self {
        self.min_delay = min_delay;
        self
    }

    /// Sets the upper bound for retry delays
    pub fn set_max_delay(mut self, max_delay: Duration) -> Self {
        self.max_delay = Some(max_delay);
        self
    }

    /// Sets the base for exponential backoff
    pub fn set_exponent_base(mut self, exponent_base: f32) -> Self {
        self.exponent_base = exponent_base;
        self
    }
}

/// Common logic for credentials management
pub(crate) mod credentials_management_utils {
    use super::*;

    /// Calculate the refresh threshold based on the token's lifetime and the refresh ratio
    #[allow(dead_code)] // Reserved for future use with TokenRefreshConfig
    pub(crate) fn calculate_refresh_threshold(
        received_at: SystemTime,
        expires_at: SystemTime,
        refresh_ratio: f64,
    ) -> Option<Duration> {
        if let Ok(total_lifetime) = expires_at.duration_since(received_at) {
            Some(Duration::from_secs_f64(
                total_lifetime.as_secs_f64() * refresh_ratio,
            ))
        } else {
            None
        }
    }

    /// Extract the OID claim from a JWT
    #[cfg(all(feature = "token-based-authentication", feature = "entra-id"))]
    pub(crate) fn extract_oid_from_jwt(jwt: &str) -> Result<String, String> {
        use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};

        let parts: Vec<&str> = jwt.split('.').collect();
        if parts.len() != 3 {
            return Err("Invalid JWT: must have 3 parts".to_string());
        }

        let payload_bytes = URL_SAFE_NO_PAD
            .decode(parts[1])
            .map_err(|e| format!("Failed to decode payload: {e}"))?;
        let payload_str = String::from_utf8(payload_bytes)
            .map_err(|e| format!("Payload is not valid UTF-8: {e}"))?;

        if let Some(oid_claim_start_idx) = payload_str.find("\"oid\"")
            && let Some(colon_idx) = payload_str[oid_claim_start_idx..].find(':')
        {
            let oid_value_str = payload_str[oid_claim_start_idx + colon_idx + 1..].trim_start();

            if let Some(stripped_oid_value) = oid_value_str.strip_prefix('"')
                && let Some(end_quote) = stripped_oid_value.find('"')
            {
                return Ok(stripped_oid_value[..end_quote].to_string());
            }
        }

        Err("OID claim not found".to_string())
    }
}

#[cfg(all(feature = "token-based-authentication", test))]
mod auth_management_tests {
    use super::{TokenRefreshConfig, credentials_management_utils};
    use std::sync::LazyLock;

    const TOKEN_HEADER: &str = "header";
    const TOKEN_PAYLOAD: &str = "eyJvaWQiOiIxMjM0NTY3OC05YWJjLWRlZi0xMjM0LTU2Nzg5YWJjZGVmMCJ9"; // Payload with "oid" claim
    const TOKEN_PAYLOAD_NO_OID: &str =
        "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNzM1Njg5NjAwfQ"; // Payload with no "oid" claim
    const TOKEN_SIGNATURE: &str = "signature";

    const OID_CLAIM_VALUE: &str = "12345678-9abc-def-1234-56789abcdef0";

    static TOKEN: LazyLock<String> =
        LazyLock::new(|| format!("{TOKEN_HEADER}.{TOKEN_PAYLOAD}.{TOKEN_SIGNATURE}"));
    static TOKEN_WITH_NO_OID: LazyLock<String> =
        LazyLock::new(|| format!("{TOKEN_HEADER}.{TOKEN_PAYLOAD_NO_OID}.{TOKEN_SIGNATURE}"));
    static INVALID_TOKEN: LazyLock<String> =
        LazyLock::new(|| format!("{TOKEN_HEADER}.{TOKEN_PAYLOAD}"));

    #[test]
    fn test_token_refresh_config() {
        let config = TokenRefreshConfig::default();
        assert_eq!(config.expiration_refresh_ratio, 0.8);

        let custom_config = TokenRefreshConfig::default().set_expiration_refresh_ratio(0.9);
        assert_eq!(custom_config.expiration_refresh_ratio, 0.9);
    }

    #[test]
    fn test_refresh_threshold_calculation() {
        use std::time::{Duration, SystemTime};
        let config = TokenRefreshConfig::default(); // Default refresh ratio is 0.8

        let received_at = SystemTime::now();
        let expires_at = received_at + Duration::from_secs(3600); // 1 hour

        let threshold = credentials_management_utils::calculate_refresh_threshold(
            received_at,
            expires_at,
            config.expiration_refresh_ratio,
        );
        assert!(threshold.is_some());
        assert_eq!(threshold.unwrap(), Duration::from_secs(2880)); // 80% of 3600
    }

    #[cfg(all(feature = "token-based-authentication", feature = "entra-id"))]
    #[test]
    fn test_extract_oid_from_jwt() {
        let result = credentials_management_utils::extract_oid_from_jwt(TOKEN.as_str());
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), OID_CLAIM_VALUE);
    }

    #[cfg(all(feature = "token-based-authentication", feature = "entra-id"))]
    #[test]
    fn test_extract_oid_from_jwt_with_invalid_token() {
        let result = credentials_management_utils::extract_oid_from_jwt(INVALID_TOKEN.as_str());
        assert!(result.is_err());
        assert_eq!(result.err().unwrap(), "Invalid JWT: must have 3 parts");
    }

    #[cfg(all(feature = "token-based-authentication", feature = "entra-id"))]
    #[test]
    fn test_extract_oid_from_jwt_with_no_oid_claim() {
        let result = credentials_management_utils::extract_oid_from_jwt(TOKEN_WITH_NO_OID.as_str());
        assert!(result.is_err());
        assert_eq!(result.err().unwrap(), "OID claim not found");
    }
}
