mod accessible_label;
mod main_loop;
mod memory_settings;
mod signal_log;
mod tests;
mod unlabelled_widget;
mod wait_timed_out;
mod widget_lookup;

pub(crate) use accessible_label::assert_labelled;
pub(crate) use main_loop::{drain_main_context, wait_until};
pub(crate) use memory_settings::MemorySettings;
pub(crate) use signal_log::SignalLog;
pub(crate) use unlabelled_widget::UnlabelledWidget;
pub(crate) use wait_timed_out::WaitTimedOut;
pub(crate) use widget_lookup::{descendants, find_by_action_name, first_descendant_of_type};

/// `Tasks` bound to the current test runtime.
///
/// A test already runs inside `#[tokio::test]`, so taking the ambient
/// handle here is the one place it is correct.
#[expect(
    clippy::disallowed_methods,
    reason = "a test is already inside its own runtime; production code takes the handle from AppRuntime"
)]
pub(crate) fn paused_tasks() -> tablepro_session::runtime::Tasks {
    tablepro_session::runtime::Tasks::new(tokio::runtime::Handle::current())
}

/// A runtime a GTK test can borrow `Tasks` from.
///
/// A `#[gtk4::test]` has no ambient tokio runtime, so it owns one for
/// the length of the test and drops it at the end.
pub(crate) fn test_runtime() -> crate::runtime::AppRuntime {
    crate::runtime::AppRuntime::build().expect("a runtime")
}
