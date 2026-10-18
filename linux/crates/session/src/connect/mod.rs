//! Turning a saved connection or a dialog's request into a connected,
//! not yet adopted, session; and saving the connection once it works.

mod attempt_generation;
mod attempt_outcome;
mod attempt_ticket;
mod connect_attempts;
mod connect_error;
mod connect_intent;
mod connect_request;
mod connect_services;
mod connect_source;
mod connection_metadata;
mod connection_writes;
mod connector;
mod credential_source;
mod driver_connector;
mod keyring_source;
mod no_stored_credentials;
mod pending_save;
mod pending_session;
mod persist_pending_save;
mod request_target;
mod resolve_saved;

pub use attempt_generation::AttemptGeneration;
pub use attempt_outcome::AttemptOutcome;
pub use attempt_ticket::AttemptTicket;
pub use connect_attempts::ConnectAttempts;
pub use connect_error::ConnectError;
pub use connect_intent::ConnectIntent;
pub use connect_request::ConnectRequest;
pub use connect_services::ConnectServices;
pub use connect_source::ConnectSource;
pub use connection_metadata::ConnectionMetadata;
pub use connection_writes::{ConnectionWrites, StoreConnectionWrites};
pub use connector::Connector;
pub use credential_source::{CredentialSource, RefreshedRequest};
pub use driver_connector::DriverConnector;
pub use no_stored_credentials::NoStoredCredentials;
pub use pending_save::PendingSave;
pub use pending_session::PendingSession;
pub use persist_pending_save::{PersistReport, persist_pending_save};
pub use request_target::RequestTarget;
pub use resolve_saved::{resolve_saved, ssh_config};
