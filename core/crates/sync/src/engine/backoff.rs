use uuid::Uuid;

use crate::api::cloudkit::CloudKitFailure;
use crate::api::error::{StateError, SyncError};
use crate::api::transport::TransportError;

// Exponential backoff with jitter after a failed pass, never sooner than the server's `Retry-After` (0051, Rate
// limits; 0054, Scheduling). The delay doubles from `base_ms` to `max_ms`, and each wait draws from its upper half.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Backoff {
    base_ms: u64,
    max_ms: u64,
    failures: u32,
}

impl Backoff {
    pub const STANDARD: Self = Self::new(2_000, 15 * 60 * 1_000);

    pub const fn new(base_ms: u64, max_ms: u64) -> Self {
        Self {
            base_ms,
            max_ms,
            failures: 0,
        }
    }

    pub const fn failures(&self) -> u32 {
        self.failures
    }

    // The wait after one more failure.
    pub fn failed(&mut self, retry_after_ms: Option<u64>) -> u64 {
        let wait = self.delay(retry_after_ms, Uuid::new_v4().as_u64_pair().0);
        self.failures = self.failures.saturating_add(1);
        wait
    }

    pub fn succeeded(&mut self) {
        self.failures = 0;
    }

    // `jitter` is a uniform draw over all of `u64`.
    pub fn delay(&self, retry_after_ms: Option<u64>, jitter: u64) -> u64 {
        let ceiling = self
            .base_ms
            .checked_shl(self.failures.min(63))
            .filter(|delay| *delay >= self.base_ms)
            .unwrap_or(self.max_ms)
            .min(self.max_ms);
        let half = ceiling / 2;
        let spread = ceiling - half;
        let drawn = if spread == 0 { 0 } else { jitter % (spread + 1) };
        (half + drawn).max(retry_after_ms.unwrap_or(0))
    }
}

// The wait a refusal names: `Retry-After` on a 429 or 503, CloudKit's retry-after on a throttle.
pub fn retry_after_ms(error: &SyncError) -> Option<u64> {
    match error {
        SyncError::Transport(
            TransportError::RateLimited { retry_after_ms }
            | TransportError::RestoreCheckUnavailable { retry_after_ms }
            | TransportError::Server { retry_after_ms, .. },
        )
        | SyncError::CloudKit(CloudKitFailure::Throttled { retry_after_ms }) => *retry_after_ms,
        _ => None,
    }
}

// A failure a later pass can get past by itself; any other waits for the person, the account or a new trigger.
pub fn retryable(error: &SyncError) -> bool {
    match error {
        SyncError::Transport(error) => {
            matches!(
                error,
                TransportError::RateLimited { .. }
                    | TransportError::RestoreCheckUnavailable { .. }
                    | TransportError::Network { .. }
                    | TransportError::IdempotencyInProgress
                    | TransportError::UseDpopNonce
            ) || matches!(error, TransportError::Server { status, .. } if *status >= 500)
        }
        SyncError::CloudKit(failure) => matches!(
            failure,
            CloudKitFailure::Network
                | CloudKitFailure::Throttled { .. }
                | CloudKitFailure::AccountTemporarilyUnavailable
        ),
        SyncError::State(StateError::Busy) => true,
        _ => false,
    }
}
