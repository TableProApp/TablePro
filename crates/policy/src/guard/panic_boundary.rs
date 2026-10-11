use std::any::Any;
use std::future::Future;
use std::panic::AssertUnwindSafe;

use futures::FutureExt;
use tablepro_core::DriverError;

use super::PolicyGuard;

impl PolicyGuard {
    pub(crate) async fn caught_read<T, F>(&self, operation: &'static str, execute: F) -> Result<T, DriverError>
    where
        F: Future<Output = Result<T, DriverError>>,
    {
        match AssertUnwindSafe(execute).catch_unwind().await {
            Ok(result) => {
                self.report_if_disconnected(operation, &result);
                result
            }
            Err(payload) => Err(DriverError::Internal(self.report(operation, &payload))),
        }
    }

    pub(crate) async fn caught_write<T, F>(&self, operation: &'static str, execute: F) -> Result<T, DriverError>
    where
        F: Future<Output = Result<T, DriverError>>,
    {
        match AssertUnwindSafe(execute).catch_unwind().await {
            Ok(result) => {
                self.report_if_disconnected(operation, &result);
                result
            }
            Err(payload) => Err(DriverError::OperationOutcomeUnknown {
                source: Box::new(DriverError::Internal(self.report(operation, &payload))),
            }),
        }
    }

    fn report_if_disconnected<T>(&self, operation: &'static str, result: &Result<T, DriverError>) {
        if !matches!(result, Err(DriverError::Disconnected)) {
            return;
        }
        if let Some(fault) = &self.fault {
            fault.connection_became_unusable(operation);
        }
    }

    fn report(&self, operation: &'static str, payload: &Box<dyn Any + Send>) -> String {
        let message_bytes = payload
            .downcast_ref::<&str>()
            .map(|text| text.len())
            .or_else(|| payload.downcast_ref::<String>().map(String::len))
            .unwrap_or(0);
        tracing::error!(
            operation,
            message_bytes,
            "driver panicked; the message is withheld because it may hold query text or credentials"
        );
        if let Some(fault) = &self.fault {
            fault.connection_became_unusable(operation);
        }
        format!("the driver stopped unexpectedly during {operation}")
    }
}
