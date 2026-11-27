//! The client of tablepro-cloud's `/v2` API, generated from the vendored document, and how its answers read. Holds no
//! account state: the caller brings the bearer.

mod api_error;
mod bearer;
mod challenge;
mod http;
mod problem;
mod snapshot;
mod sync_scopes;

pub use api_error::{ApiError, http_text};
pub use bearer::Bearer;
pub use challenge::{StepUpChallenge, dpop_nonce, dpop_nonce_challenge};
pub use http::{CONNECT_TIMEOUT, REQUEST_TIMEOUT, http_client, read_capped};
pub use problem::{answer_error, rate_limited, refusal, schema_mismatch};
pub use snapshot::{PublicSnapshot, SnapshotBody, SnapshotColumnBody};
pub use sync_scopes::{SyncScopesPoll, poll_sync_scopes};

#[expect(
    clippy::unwrap_used,
    reason = "progenitor's client unwraps its own reqwest builder and the document's fixed patterns"
)]
pub mod v2 {
    include!(concat!(env!("OUT_DIR"), "/v2.rs"));
}
