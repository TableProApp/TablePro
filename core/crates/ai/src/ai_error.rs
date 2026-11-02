use tablepro_core::AiProvider;

/// Why a request got no answer. The app words each one itself.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AiError {
    #[error("no API key is stored for {0}")]
    MissingKey(AiProvider),
    #[error("no model is chosen")]
    MissingModel,
    #[error("the server address is not an http or https URL")]
    InvalidAddress,
    /// Anyone on the path could read it.
    #[error("an API key is sent to another computer over https only")]
    KeyOverPlainHttp,
    #[error("the API key holds characters an HTTP header cannot carry")]
    InvalidKey,
    #[error("the TLS setup failed: {0}")]
    Tls(String),
    #[error("could not reach {host}: {detail}")]
    Unreachable { host: String, detail: String },
    #[error("{host} did not answer in time")]
    TimedOut { host: String },
    #[error("{host} refused the API key")]
    Unauthorized { host: String, message: Option<String> },
    #[error("{host} is limiting requests")]
    RateLimited { host: String, message: Option<String> },
    #[error("{host} answered {status}")]
    Status {
        host: String,
        status: u16,
        message: Option<String>,
    },
    /// An error the server sent in the middle of a reply.
    #[error("the provider stopped the reply: {0}")]
    Provider(String),
    #[error("the reply could not be read: {0}")]
    Protocol(String),
    #[error("the reply is longer than TablePro keeps")]
    TooLong,
}

impl AiError {
    /// A name for the variant that stays the same across releases, for
    /// a caller outside Rust, such as another platform's UI, that words the error itself. The variant's fields are its parameters.
    pub fn code(&self) -> &'static str {
        match self {
            Self::MissingKey(..) => "ai.missing_key",
            Self::MissingModel => "ai.missing_model",
            Self::InvalidAddress => "ai.invalid_address",
            Self::KeyOverPlainHttp => "ai.key_over_plain_http",
            Self::InvalidKey => "ai.invalid_key",
            Self::Tls(..) => "ai.tls",
            Self::Unreachable { .. } => "ai.unreachable",
            Self::TimedOut { .. } => "ai.timed_out",
            Self::Unauthorized { .. } => "ai.unauthorized",
            Self::RateLimited { .. } => "ai.rate_limited",
            Self::Status { .. } => "ai.status",
            Self::Provider(..) => "ai.provider",
            Self::Protocol(..) => "ai.protocol",
            Self::TooLong => "ai.too_long",
        }
    }
}

impl AiError {
    /// What the server said, when it said anything.
    pub fn server_message(&self) -> Option<&str> {
        match self {
            Self::Unauthorized { message, .. } | Self::RateLimited { message, .. } | Self::Status { message, .. } => {
                message.as_deref()
            }
            Self::Provider(message) => Some(message),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_error_names_its_variant_with_a_code_that_does_not_change() {
        assert_eq!(AiError::MissingModel.code(), "ai.missing_model");
        assert_eq!(
            AiError::TimedOut {
                host: "api.example.com".to_owned()
            }
            .code(),
            "ai.timed_out"
        );
    }
}
