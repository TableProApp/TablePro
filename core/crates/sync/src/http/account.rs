// The app's TablePro account as the transport reads its sign-in.

use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_account::{Account, AccountError};

use super::{SignIn, SignedIn, SignedInAs, errors};
use crate::api::transport::TransportError;

#[async_trait]
impl SignIn for Account {
    async fn signed_in_as(&self) -> Result<SignedInAs, TransportError> {
        let of = Account::signed_in_as(self).await.map_err(transport_error)?;
        Ok(SignedInAs {
            api: of.api,
            origin: of.origin,
            sign_in: of.sign_in,
            account_id: of.account_id,
            device_id: of.device_id,
            session_id: of.session_id,
        })
    }

    async fn signed_in(&self) -> Result<SignedIn, TransportError> {
        let token = self.access_token().await.map_err(transport_error)?;
        Ok(SignedIn {
            token: token.token,
            of: SignedInAs {
                api: token.api,
                origin: token.origin,
                sign_in: token.sign_in,
                account_id: token.account_id,
                device_id: token.device_id,
                session_id: token.session_id,
            },
        })
    }

    async fn rejected(&self, token: &SecretString) {
        self.access_token_rejected(token).await;
    }
}

// A refusal keeps its status, so the scheduler backs off from a 5xx at the token endpoint as from one of `/v2/sync`.
fn transport_error(error: AccountError) -> TransportError {
    match error {
        AccountError::SignedOut => TransportError::SignedOut,
        AccountError::DeviceRevoked => TransportError::DeviceRemoved,
        AccountError::RateLimited { retry_after } => TransportError::RateLimited {
            retry_after_ms: retry_after.map(|wait| u64::try_from(wait.as_millis()).unwrap_or(u64::MAX)),
        },
        AccountError::Unreachable(detail) => TransportError::Network { detail },
        AccountError::StepUpRequired(challenge) => errors::step_up(challenge),
        AccountError::Refused { status, .. } => TransportError::Server {
            status,
            code: error.code().to_owned(),
            retry_after_ms: None,
        },
        other => TransportError::Server {
            status: 0,
            code: other.code().to_owned(),
            retry_after_ms: None,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::retryable;

    fn refused(status: u16) -> AccountError {
        AccountError::Refused {
            status,
            code: "internal".to_owned(),
            detail: String::new(),
        }
    }

    #[test]
    fn the_account_s_failures_back_off_only_where_a_later_try_can_get_past_them() {
        let retried = [
            AccountError::Unreachable("connection refused".to_owned()),
            AccountError::RateLimited { retry_after: None },
            refused(500),
            refused(503),
        ];
        let stopped = [
            AccountError::SignedOut,
            AccountError::DeviceRevoked,
            refused(403),
            AccountError::Protocol("not json".to_owned()),
        ];

        for error in retried {
            let shown = format!("{error:?}");
            assert!(retryable(&transport_error(error).into()), "{shown}");
        }
        for error in stopped {
            let shown = format!("{error:?}");
            assert!(!retryable(&transport_error(error).into()), "{shown}");
        }
    }

    #[test]
    fn a_refusal_keeps_the_account_s_code() {
        let TransportError::Server { status, code, .. } = transport_error(refused(502)) else {
            panic!("a refusal is a server answer");
        };
        assert_eq!((status, code.as_str()), (502, "account.refused"));
    }
}
