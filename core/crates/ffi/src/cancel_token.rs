use std::sync::Arc;

use tokio_util::sync::CancellationToken;

/// A cancel the foreign side passes into an async call, since UniFFI
/// itself never cancels a call. C# fires it from a `CancellationToken`,
/// Swift from a task's cancellation handler.
#[derive(Debug, Default, uniffi::Object)]
pub struct CancelToken(CancellationToken);

#[uniffi::export]
impl CancelToken {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn cancel(&self) {
        self.0.cancel();
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.is_cancelled()
    }
}

/// The token an optional foreign cancel stands for, or one nobody fires.
pub(crate) fn token(cancel: Option<Arc<CancelToken>>) -> CancellationToken {
    cancel.map(|cancel| cancel.0.clone()).unwrap_or_default()
}
