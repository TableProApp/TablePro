// The app's TablePro account as the transport reads its sign-in.

use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_account::{Account, AccountError};

use super::{SignIn, SignedIn, errors};
use crate::api::transport::TransportError;

#[async_trait]
impl SignIn for Account {
    async fn signed_in(&self) -> Result<SignedIn, TransportError> {
        let token = self.access_token().await.map_err(transport_error)?;
        Ok(SignedIn {
            token: token.token,
            api: token.api,
            origin: token.origin,
            sign_in: token.sign_in,
            account_id: token.account_id,
            device_id: token.device_id,
            session_id: token.session_id,
        })
    }

    async fn rejected(&self, token: &SecretString) {
        self.access_token_rejected(token).await;
    }
}

fn transport_error(error: AccountError) -> TransportError {
    match error {
        AccountError::SignedOut => TransportError::SignedOut,
        AccountError::DeviceRevoked => TransportError::DeviceRemoved,
        AccountError::RateLimited { retry_after } => TransportError::RateLimited {
            retry_after_ms: retry_after.map(|wait| u64::try_from(wait.as_millis()).unwrap_or(u64::MAX)),
        },
        AccountError::Unreachable(detail) => TransportError::Network { detail },
        AccountError::StepUpRequired(challenge) => errors::step_up(challenge),
        other => TransportError::Server {
            status: 0,
            code: other.code().to_owned(),
            retry_after_ms: None,
        },
    }
}
