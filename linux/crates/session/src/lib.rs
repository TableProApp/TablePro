//! Generation-leased sessions over driver contract v2, free of GTK.
//!
//! A window holds one `Session`. Every use of its connection goes
//! through the `OperationRunner`, a monitor reconnects it on a backoff,
//! and the `SessionRegistry` keeps one database to one window. The app
//! adopts these on the GTK thread; nothing here needs an entered
//! runtime to be created.

pub mod connect;
#[cfg(any(test, feature = "fakes"))]
pub mod fakes;
pub mod health;
pub mod link;
pub mod operation;
pub mod registry;
pub mod runtime;
pub mod session;
#[cfg(test)]
mod test_support;

pub use connect::{
    AttemptOutcome, ConnectAttempts, ConnectError, ConnectIntent, ConnectRequest, ConnectServices, ConnectSource,
    ConnectionMetadata, Connector, CredentialSource, DriverConnector, NoStoredCredentials, PendingSave, PendingSession,
    PersistReport, RefreshedRequest, RequestTarget, persist_pending_save, resolve_saved,
};
pub use health::{FailureCause, LinkGeneration, MonitorSignal, ReachabilityTarget, SessionHealth};
pub use link::{CloseReport, ConnectionLease, EstablishedConnection};
pub use operation::{DeadlinePolicy, DefaultDeadlines, OperationError, OperationKind, OperationRunner};
pub use registry::{ClaimError, RegistryEvent, SessionClaim, SessionKey, SessionRegistry};
pub use session::{CatalogSnapshot, Session, SessionDeps, close_editor_sessions};
