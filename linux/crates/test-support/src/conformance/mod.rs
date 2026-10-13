//! The suites every driver runs against a real server.
//!
//! A driver's integration target implements an engine adapter and
//! invokes `connection_conformance_suite!` and `tls_conformance_suite!`
//! with flags for what the engine supports. A flag that is off emits no
//! test, and the flags themselves are checked against the driver's
//! capability table, so a case cannot be skipped by declaring less.

mod bounded_ddl_engine;
pub mod cases;
mod client_identity_engine;
mod conformance_engine;
mod conformance_failure;
mod connection_suite_flags;
mod connection_suite_macro;
mod editor_transaction_engine;
#[cfg(test)]
mod fake_engine;
mod network_conformance_engine;
mod pooled_conformance_engine;
mod run_case;
mod suite_endpoint;
mod support;
mod test_liveness;
mod tls_conformance_engine;
mod tls_suite_macro;
mod typed_conformance_engine;
mod unsupported_type_case;

pub use bounded_ddl_engine::BoundedDdlEngine;
pub use client_identity_engine::ClientIdentityEngine;
pub use conformance_engine::ConformanceEngine;
pub use conformance_failure::ConformanceFailure;
pub use connection_suite_flags::ConnectionSuiteFlags;
pub use editor_transaction_engine::EditorTransactionEngine;
pub use network_conformance_engine::NetworkConformanceEngine;
pub use pooled_conformance_engine::PooledConformanceEngine;
pub use run_case::{CASE_LIMIT, run_case};
pub use suite_endpoint::SuiteEndpoint;
pub use test_liveness::test_liveness;
pub use tls_conformance_engine::TlsConformanceEngine;
pub use typed_conformance_engine::TypedConformanceEngine;
pub use unsupported_type_case::UnsupportedTypeCase;
