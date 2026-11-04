use std::panic::AssertUnwindSafe;

use futures::FutureExt;

use super::TaskPanic;

/// Run a future and turn a panic inside it into a value.
///
/// For work that is already on the right thread and must not take the
/// whole process down, such as a callback the app cannot vet.
pub async fn catch_panic<F, T>(future: F) -> Result<T, TaskPanic>
where
    F: Future<Output = T>,
{
    AssertUnwindSafe(future)
        .catch_unwind()
        .await
        .map_err(TaskPanic::from_payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn catch_panic_returns_err() {
        let caught = catch_panic(async { panic!("inside") }).await;

        assert_eq!(caught.map(|_: ()| ()).unwrap_err().message(), "inside");
    }

    #[tokio::test]
    async fn catch_panic_passes_a_value_through() {
        let value = catch_panic(async { 3 }).await.expect("no panic");

        assert_eq!(value, 3);
    }
}
