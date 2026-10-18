use crate::runtime::Tasks;

/// `Tasks` bound to the current test runtime.
///
/// A test already runs inside `#[tokio::test]`, so taking the ambient
/// handle here is the one place it is correct.
#[expect(
    clippy::disallowed_methods,
    reason = "a test is already inside its own runtime; production code takes the handle from AppRuntime"
)]
pub(crate) fn paused_tasks() -> Tasks {
    Tasks::new(tokio::runtime::Handle::current())
}
