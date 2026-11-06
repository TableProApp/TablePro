use std::time::Duration;

use crate::entitlement::EntitlementError;
use crate::profile::Device;

#[derive(Debug, Clone, thiserror::Error)]
pub enum AccountError {
    #[error("TablePro's account service could not be reached: {0}")]
    Unreachable(String),
    #[error("the browser did not open the sign-in page: {0}")]
    Browser(String),
    #[error("the sign-in was not finished in the browser in time")]
    SignInTimedOut,
    #[error("the sign-in was canceled before the browser came back")]
    SignInCanceled,
    #[error("the sign-in was refused: {error}")]
    SignInRefused { error: String, description: Option<String> },
    #[error("not signed in")]
    SignedOut,
    #[error("this device was removed from the account")]
    DeviceRevoked,
    #[error("the license is in use on {} other devices", devices.len())]
    DeviceLimitReached { devices: Vec<Device> },
    #[error("the offline file is for another account than the one signed in")]
    OtherAccount,
    #[error("the server refused the request ({status} {code}): {detail}")]
    Refused { status: u16, code: String, detail: String },
    #[error("the account service asked for fewer requests (retry after {retry_after:?})")]
    RateLimited { retry_after: Option<Duration> },
    #[error(transparent)]
    Entitlement(#[from] EntitlementError),
    #[error("cannot keep the account's state in {path}: {detail}")]
    Storage { path: String, detail: String },
    #[error("unexpected answer from the account service: {0}")]
    Protocol(String),
}

impl AccountError {
    // A stable code an app outside Rust words the error from.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Unreachable(_) => "account.unreachable",
            Self::Browser(_) => "account.browser",
            Self::SignInTimedOut => "account.sign_in_timed_out",
            Self::SignInCanceled => "account.sign_in_canceled",
            Self::SignInRefused { .. } => "account.sign_in_refused",
            Self::SignedOut => "account.signed_out",
            Self::DeviceRevoked => "account.device_revoked",
            Self::DeviceLimitReached { .. } => "account.device_limit_reached",
            Self::OtherAccount => "account.other_account",
            Self::Refused { .. } => "account.refused",
            Self::RateLimited { .. } => "account.rate_limited",
            Self::Entitlement(_) => "account.entitlement",
            Self::Storage { .. } => "account.storage",
            Self::Protocol(_) => "account.protocol",
        }
    }

    // reqwest keeps the cause, such as a refused connection, a level down.
    pub(crate) fn unreachable(error: &dyn std::error::Error) -> Self {
        let mut detail = error.to_string();
        let mut source = error.source();
        while let Some(cause) = source {
            detail.push_str(": ");
            detail.push_str(&cause.to_string());
            source = cause.source();
        }
        Self::Unreachable(detail)
    }
}
