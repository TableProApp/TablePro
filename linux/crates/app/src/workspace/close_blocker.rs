use futures::future::LocalBoxFuture;

/// Work a window's close would cut short that is not a tab's, such as a
/// running export. A close asks about it first, and either keeps the
/// window or stops the work and goes on.
pub trait CloseBlocker {
    /// What to ask, while the work runs.
    fn blocking(&self) -> Option<CloseBlockPrompt>;

    /// Stop the work. Resolves once it has stopped.
    fn stop(&self) -> LocalBoxFuture<'static, ()>;
}

/// The alert a blocker asks with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloseBlockPrompt {
    pub heading: String,
    pub body: String,
    pub keep_label: String,
    pub stop_label: String,
}
