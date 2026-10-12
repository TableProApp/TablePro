//! What a session's health is and what the monitor does about it.
//!
//! The policy is a pure state machine; the monitor task feeds it what
//! happened and carries out the one action it returns.

mod failure_cause;
mod health_monitor;
mod health_policy;
mod link_generation;
mod monitor_action;
mod monitor_mailbox;
mod monitor_signal;
mod pending_signals;
mod probe_outcome;
mod reachability;
mod reachability_target;
mod reconnect_plan;
mod reconnect_result;
mod session_health;

pub use failure_cause::FailureCause;
pub(crate) use health_monitor::{MonitorContext, run_monitor};
pub use health_policy::HealthPolicy;
pub use link_generation::LinkGeneration;
pub use monitor_action::MonitorAction;
pub use monitor_mailbox::MonitorMailbox;
pub use monitor_signal::MonitorSignal;
pub use pending_signals::PendingSignals;
pub use probe_outcome::ProbeOutcome;
pub use reachability::Reachability;
pub use reachability_target::ReachabilityTarget;
pub use reconnect_plan::ReconnectPlan;
pub use reconnect_result::ReconnectResult;
pub use session_health::SessionHealth;
