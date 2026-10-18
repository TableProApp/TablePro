//! The one way to use a session's connection: lease it, bound the call,
//! observe what the outcome says about the link, and replay a read once
//! when the connection was replaced under it.

mod deadline_policy;
mod default_deadlines;
mod operation_error;
mod operation_kind;
mod operation_runner;
mod replay_rule;

pub use deadline_policy::DeadlinePolicy;
pub use default_deadlines::DefaultDeadlines;
pub use operation_error::OperationError;
pub use operation_kind::OperationKind;
pub use operation_runner::OperationRunner;
pub use replay_rule::ReplayRule;
