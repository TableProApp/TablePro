//! One file per area of the contract. Every case gets an engine started
//! for it alone and returns a `ConformanceFailure` rather than panicking.

pub mod cancellation;
pub mod close;
pub mod commit_resolution;
pub mod deadlines;
pub mod liveness;
pub mod metadata;
pub mod pool;
pub mod read_only;
pub mod row_guards;
pub mod row_limit;
pub mod statement_timeout;
pub mod streaming;
pub mod suite_flags;
pub mod tls;
pub mod type_fallback;
pub mod writes;
