//! Session primitives: what a connection's health is, what wakes the
//! monitor, and what identifies an attempt or a session.
//!
//! Everything here is GTK-free and has no connection of its own, so the
//! rules that decide when to probe, when to back off and when to stop
//! trying are testable without a server.

mod attempt_generation;
mod attempt_ticket;
mod connect_attempts;
mod failure_cause;
mod file_identity;
mod health_policy;
mod link_generation;
mod monitor_action;
mod monitor_mailbox;
mod monitor_signal;
mod pending_signals;
mod probe_outcome;
mod reachability;
mod reconnect_result;
mod session_health;
mod session_key;

pub use attempt_generation::AttemptGeneration;
pub use attempt_ticket::AttemptTicket;
pub use connect_attempts::ConnectAttempts;
pub use failure_cause::FailureCause;
pub use file_identity::FileIdentity;
pub use health_policy::HealthPolicy;
pub use link_generation::LinkGeneration;
pub use monitor_action::MonitorAction;
pub use monitor_mailbox::MonitorMailbox;
pub use monitor_signal::MonitorSignal;
pub use pending_signals::PendingSignals;
pub use probe_outcome::ProbeOutcome;
pub use reachability::Reachability;
pub use reconnect_result::ReconnectResult;
pub use session_health::SessionHealth;
pub use session_key::SessionKey;
