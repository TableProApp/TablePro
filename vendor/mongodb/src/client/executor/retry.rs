use std::{collections::HashSet, time::Duration};

#[cfg(test)]
use crate::options::TestOptions;
use crate::{
    error::{Error, Result, NO_WRITES_PERFORMED, RETRYABLE_ERROR, SYSTEM_OVERLOADED_ERROR},
    operation::{Operation, Retryability},
    options::ServerAddress,
    Client,
};

/// The default maximum number of retries that can be performed when the system is overloaded.
const DEFAULT_MAX_ADAPTIVE_RETRIES: u32 = 2;
/// The maximum number of retries that can be performed for retryable reads/writes.
const MAX_RW_RETRIES: u32 = 1;

pub(crate) struct Retry {
    attempt: u32,
    pub(super) deprioritized_servers: HashSet<ServerAddress>,
    last_failure: Failure,
    txn_number: Option<i64>,
    pub(crate) overloaded: bool,
    max_retries: u32,
    base_backoff: Option<Duration>,
}

struct Failure {
    error: Error,
    phase: FailurePhase,
}

#[derive(PartialEq)]
enum FailurePhase {
    ConnectionEstablishment,
    Execution,
}

impl Failure {
    fn indicates_writes_performed(&self) -> bool {
        self.phase != FailurePhase::ConnectionEstablishment
            && !self.error.contains_label(NO_WRITES_PERFORMED)
            && (self.error.is_server_error()
                || self.error.is_read_retryable()
                || self.error.is_write_retryable())
    }
}

impl Retry {
    pub(super) fn for_connection_establishment_failure<T: Operation>(
        retry: Option<Self>,
        error: Error,
        op: &T,
        client: &Client,
        server: ServerAddress,
        is_transaction_op: bool,
    ) -> Result<Retry> {
        let failure = Failure {
            error,
            phase: FailurePhase::ConnectionEstablishment,
        };
        Self::handle_failure(retry, failure, op, client, server, is_transaction_op, None)
    }

    pub(super) fn for_execution_failure<T: Operation>(
        retry: Option<Self>,
        error: Error,
        op: &T,
        client: &Client,
        server: ServerAddress,
        is_transaction_op: bool,
        txn_number: Option<i64>,
    ) -> Result<Self> {
        let failure = Failure {
            error,
            phase: FailurePhase::Execution,
        };
        Self::handle_failure(
            retry,
            failure,
            op,
            client,
            server,
            is_transaction_op,
            txn_number,
        )
    }

    /// Handles a failure by either creating a new `Retry` or updating the existing `Retry` with the
    /// new error. If the error cannot be retried, the appropriate error to return from the
    /// retry loop is returned and no further retries should be performed.
    fn handle_failure<T: Operation>(
        retry: Option<Retry>,
        failure: Failure,
        op: &T,
        client: &Client,
        server: ServerAddress,
        is_transaction_op: bool,
        txn_number: Option<i64>,
    ) -> Result<Self> {
        let error = &failure.error;
        let can_retry = if error.contains_label(SYSTEM_OVERLOADED_ERROR)
            && error.contains_label(RETRYABLE_ERROR)
            && op.is_backpressure_retryable(client.options())
        {
            true
        } else {
            let retryability = op.retryability(client.options());
            // Pool cleared errors should be retried for reads regardless of transaction status.
            retryability == Retryability::Read && error.is_pool_cleared()
                || retryability.can_retry_error(error) && !is_transaction_op
        };
        let overloaded = error.contains_label(SYSTEM_OVERLOADED_ERROR);
        let base_backoff = error.base_backoff().filter(|duration| !duration.is_zero());

        let max_adaptive_retries = overloaded.then_some(
            client
                .options()
                .max_adaptive_retries
                .unwrap_or(DEFAULT_MAX_ADAPTIVE_RETRIES),
        );

        let enable_overload_retargeting = client
            .options()
            .enable_overload_retargeting
            .unwrap_or(false);
        let deprioritized = if client.is_sharded() || overloaded && enable_overload_retargeting {
            Some(server)
        } else {
            None
        };

        match retry {
            Some(mut retry) => {
                let better_failure = match (
                    retry.last_failure.indicates_writes_performed(),
                    failure.indicates_writes_performed(),
                ) {
                    (true, false) => retry.last_failure,
                    _ => failure,
                };
                if !can_retry {
                    return Err(better_failure.error);
                }
                retry.attempt += 1;
                if let Some(server) = deprioritized {
                    retry.deprioritized_servers.insert(server);
                }
                retry.last_failure = better_failure;
                if txn_number.is_some() && retry.txn_number.is_none() {
                    retry.txn_number = txn_number;
                }
                retry.overloaded = overloaded;
                // If we've encountered an overload error, reset the max retries value to max
                // adaptive retries. This should persist for the duration of the retry loop,
                // regardless of whether or not future errors are overload errors.
                if let Some(max_adaptive_retries) = max_adaptive_retries {
                    retry.max_retries = max_adaptive_retries;
                }
                retry.base_backoff = base_backoff;
                Ok(retry)
            }
            None => {
                if !can_retry {
                    return Err(failure.error);
                }
                Ok(Self {
                    attempt: 1,
                    deprioritized_servers: deprioritized
                        .map(|server| HashSet::from([server]))
                        .unwrap_or_default(),
                    last_failure: failure,
                    txn_number,
                    overloaded,
                    max_retries: max_adaptive_retries.unwrap_or(MAX_RW_RETRIES),
                    base_backoff,
                })
            }
        }
    }

    pub(super) fn last_error(self) -> Error {
        self.last_failure.error
    }

    pub(super) fn max_retries_reached(&self) -> bool {
        self.attempt > self.max_retries
    }

    pub(super) fn calculate_backoff(
        &self,
        #[cfg(test)] test_options: Option<&TestOptions>,
    ) -> Duration {
        #[cfg(test)]
        if let Some(backoff) = test_options.and_then(|o| o.backoff) {
            return backoff;
        }

        const DEFAULT_BASE_BACKOFF: Duration = Duration::from_millis(100);
        const MAX_BACKOFF: Duration = Duration::from_millis(10_000);

        let jitter = rand::random::<f32>();
        #[cfg(test)]
        let jitter = test_options.and_then(|o| o.jitter).unwrap_or(jitter);

        let base_backoff = self.base_backoff.unwrap_or(DEFAULT_BASE_BACKOFF);
        let backoff = std::cmp::min(base_backoff * 2u32.pow(self.attempt), MAX_BACKOFF);
        backoff.mul_f32(jitter)
    }
}

pub(super) fn return_last_error(retry: &mut Option<Retry>) -> Result<()> {
    match retry.take() {
        Some(retry) => Err(retry.last_failure.error),
        _ => Ok(()),
    }
}

pub(super) fn txn_number(retry: &Option<Retry>) -> Option<i64> {
    retry.as_ref().and_then(|r| r.txn_number)
}
