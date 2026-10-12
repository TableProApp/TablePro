//! Scripted connectors and credential sources for tests of code that
//! starts sessions: the app's window and dialog tests use them through
//! the `fakes` feature.

mod fake_connector;
mod fake_credential_source;

pub use fake_connector::{EstablishCall, FakeConnector, FakeEstablish};
pub use fake_credential_source::FakeCredentialSource;
