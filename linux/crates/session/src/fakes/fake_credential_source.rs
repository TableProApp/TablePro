use std::collections::VecDeque;
use std::sync::{Arc, Mutex, PoisonError};

use futures::future::BoxFuture;
use tablepro_core::credentials::{CredentialInteraction, SecretError, SecretKind, SecretSave};
use tablepro_storage::CredentialDemand;

use crate::connect::{ConnectError, ConnectRequest, CredentialSource, RefreshedRequest};

#[derive(Default)]
struct State {
    failures: VecDeque<ConnectError>,
    refreshes: Vec<bool>,
    remembered: Vec<SecretSave>,
}

/// Passes the request through unchanged unless a failure is queued, and
/// records whether each refresh could have prompted.
#[derive(Clone, Default)]
pub struct FakeCredentialSource {
    state: Arc<Mutex<State>>,
}

impl FakeCredentialSource {
    pub fn new() -> Self {
        Self::default()
    }

    /// Fail the next refresh with `error`.
    pub fn fail_next(&self, error: ConnectError) {
        self.lock().failures.push_back(error);
    }

    /// Whether each refresh so far was attended, in order.
    pub fn refreshes(&self) -> Vec<bool> {
        self.lock().refreshes.clone()
    }

    pub fn remembered(&self) -> Vec<SecretSave> {
        self.lock().remembered.clone()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl CredentialSource for FakeCredentialSource {
    fn refresh(
        &self,
        request: ConnectRequest,
        interaction: CredentialInteraction,
        _demand: CredentialDemand,
    ) -> BoxFuture<'static, Result<RefreshedRequest, ConnectError>> {
        let failure = {
            let mut state = self.lock();
            state
                .refreshes
                .push(matches!(interaction, CredentialInteraction::Attended(_)));
            state.failures.pop_front()
        };
        Box::pin(async move {
            match failure {
                Some(error) => Err(error),
                None => Ok(RefreshedRequest {
                    request,
                    remember: Vec::new(),
                }),
            }
        })
    }

    fn remember(&self, saves: Vec<SecretSave>) -> BoxFuture<'static, Vec<(SecretKind, SecretError)>> {
        self.lock().remembered.extend(saves);
        Box::pin(async { Vec::new() })
    }
}

impl std::fmt::Debug for FakeCredentialSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FakeCredentialSource")
            .field("refreshes", &self.lock().refreshes.len())
            .finish_non_exhaustive()
    }
}
