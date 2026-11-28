use std::sync::atomic::Ordering;

use secrecy::ExposeSecret as _;
use tablepro_cloud_api::StepUpChallenge;

use super::{Account, Server, server_calls};
use crate::account_error::AccountError;
use crate::account_settings::Redirect;
use crate::oauth::Tokens;

// The sign-in a step-up was started for, which its tokens may replace only while it still holds the session.
struct SteppingUp {
    attempt: u64,
    session_id: Option<String>,
    account_id: String,
}

impl Account {
    // RFC 9470 section 4, for the challenge a call was answered with: the server's authorization endpoint in the
    // browser, as the sign-in opens it (core ADR 0047), with the challenge's `acr_values` and `max_age` and PKCE. The
    // tokens replace this sign-in's only when they are for the same account. They start a new refresh token family, so
    // the device registers again, which answers 200 for this machine, and the access token is refreshed, which keeps
    // the step-up (core ADR 0051, Step-up). The caller then retries its call. `cancelled` ends only the wait for the
    // browser, as for a sign-in.
    pub async fn step_up(
        &self,
        challenge: &StepUpChallenge,
        cancelled: impl Future<Output = ()> + Send,
    ) -> Result<(), AccountError> {
        let attempt = self.inner.attempts.load(Ordering::SeqCst);
        let mut cancelled = std::pin::pin!(cancelled);
        // A slow company server's discovery holds the session, so a cancel ends it too, as at a sign-in.
        let discovering = async {
            let mut session = self.inner.session.lock().await;
            if session.refresh.is_none() {
                return Err(AccountError::SignedOut);
            }
            let server = self.connection(&mut session, true).await?;
            server_calls::same_issuer(&session, &server)?;
            Ok(server)
        };
        let server = tokio::select! {
            discovered = discovering => discovered?,
            () = &mut cancelled => return Err(AccountError::SignInCanceled),
        };
        // The sign-in the tokens must come back for, before any page opens. Not cancelled: finding its account can
        // refresh the token, and a rotated refresh token dropped before it is kept would end the sign-in at its next use.
        let stepping = {
            let mut session = self.inner.session.lock().await;
            let account_id = self.account_id(&mut session).await?;
            SteppingUp {
                attempt,
                session_id: session.id.clone(),
                account_id,
            }
        };
        let oauth = &server.connection()?.oauth;
        let issuer = server.expected_issuer()?;
        let tokens = match self.inner.settings.client.redirect {
            Redirect::Loopback => {
                self.browser_sign_in(oauth, &issuer, Some(challenge), &mut cancelled)
                    .await?
            }
            Redirect::Scheme(scheme) => {
                self.web_sign_in(oauth, &issuer, scheme, Some(challenge), &mut cancelled)
                    .await?
            }
        };
        self.commit_step_up(&stepping, &server, tokens).await
    }

    // RFC 9470 section 4 for one call: when the server answers it with a step-up challenge, the step-up runs and the
    // call runs once more on the new tokens. A second challenge is the caller's, so a server that never takes the
    // step-up cannot keep reopening the browser.
    pub async fn stepped_up<T>(
        &self,
        cancelled: impl Future<Output = ()> + Send,
        mut call: impl AsyncFnMut() -> Result<T, AccountError>,
    ) -> Result<T, AccountError> {
        match call().await {
            Err(AccountError::StepUpRequired(challenge)) => {
                self.step_up(&challenge, cancelled).await?;
                call().await
            }
            answered => answered,
        }
    }

    async fn commit_step_up(&self, stepping: &SteppingUp, server: &Server, tokens: Tokens) -> Result<(), AccountError> {
        self.reachable()?;
        let Some(refresh) = tokens.refresh.clone().filter(|token| !token.expose_secret().is_empty()) else {
            return Err(AccountError::Protocol("the step-up gave no refresh token".to_owned()));
        };
        let oauth = &server.connection()?.oauth;
        let mut session = self.inner.session.lock().await;
        // The values may have stopped the server while the browser was open.
        self.reachable()?;
        let refused = if session.refresh.is_none() {
            Err(AccountError::SignedOut)
        } else if self.inner.attempts.load(Ordering::SeqCst) != stepping.attempt || session.id != stepping.session_id {
            // A sign-in that committed, or a sign-out or server change, since the step-up started owns the session
            // now. A sign-in started before the step-up moves no attempt when it commits, but it gives a new session.
            Err(AccountError::SignInCanceled)
        } else {
            server_calls::audience_check(server, &tokens.access)
                .and_then(|()| server_calls::subject_check(&tokens.access, &stepping.account_id))
        };
        if let Err(error) = refused {
            if let Err(revoked) = oauth.revoke(&refresh).await {
                tracing::warn!(code = revoked.code(), error = %revoked, "a step-up the account did not take was not revoked");
            }
            return Err(error);
        }
        let previous = session.refresh.take();
        // The new family is bound to no device until the device registers with it.
        session.device_id = None;
        self.adopt(&mut session, tokens).await;
        let held = self.held_entitlement();
        self.write_file(&session, held).await;
        if let Some(previous) = previous
            && let Err(error) = oauth.revoke(&previous).await
        {
            tracing::warn!(code = error.code(), %error, "the sign-in the step-up replaced was not revoked");
        }
        tracing::info!("stepped up the TablePro account's sign-in");
        let registered = self.register(&mut session).await.map(drop);
        self.ended_by(&mut session, registered).await
    }
}
