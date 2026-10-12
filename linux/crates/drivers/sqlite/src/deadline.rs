use tokio::time::Instant;

/// Resolves when `deadline` passes, and never when there is none.
pub(crate) async fn elapsed(deadline: Option<Instant>) {
    match deadline {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

/// The earlier of two deadlines, where either may be absent.
pub(crate) fn earliest(first: Option<Instant>, second: Option<Instant>) -> Option<Instant> {
    match (first, second) {
        (Some(first), Some(second)) => Some(first.min(second)),
        (first, second) => first.or(second),
    }
}
