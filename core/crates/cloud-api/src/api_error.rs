use std::time::Duration;

use crate::challenge::StepUpChallenge;
use crate::v2::types::LicensedDevice;

// How a /v2 call failed, as its answer says. The caller words it: the account as an `AccountError`.
#[derive(Debug, Clone, thiserror::Error)]
pub enum ApiError {
    #[error("the server could not be reached: {0}")]
    Unreachable(String),
    #[error("this device was removed from the account")]
    DeviceRevoked,
    #[error("the license is in use on {} other devices", devices.len())]
    DeviceLimitReached { devices: Vec<LicensedDevice> },
    #[error("the server refused the request ({status} {code}): {detail}")]
    Refused { status: u16, code: String, detail: String },
    // A 401 whose challenge names RFC 9470's `insufficient_user_authentication`: the token is valid, but its sign-in is
    // too old or too weak for the call.
    #[error("the call needs a fresh step-up")]
    StepUpRequired(StepUpChallenge),
    // RFC 9449 section 9: a 401 asking for a DPoP proof that carries this nonce, which a retry signs.
    #[error("the server wants a DPoP proof with its nonce")]
    UseDpopNonce { nonce: String },
    // A 413 from the framework or a proxy, which carries no problem code of the server's.
    #[error("the request is larger than the server takes")]
    TooLarge,
    #[error("the server asked for fewer requests (retry after {retry_after:?})")]
    RateLimited { retry_after: Option<Duration> },
    #[error("unexpected answer from the server: {0}")]
    Protocol(String),
}

impl ApiError {
    pub fn unreachable(error: reqwest::Error) -> Self {
        Self::Unreachable(http_text(error))
    }
}

// Without the URL, whose path can hold a share token. reqwest keeps the cause, such as a refused connection, below.
pub fn http_text(error: reqwest::Error) -> String {
    let error = error.without_url();
    let mut detail = error.to_string();
    let mut source = std::error::Error::source(&error);
    while let Some(cause) = source {
        detail.push_str(": ");
        detail.push_str(&cause.to_string());
        source = cause.source();
    }
    detail
}
