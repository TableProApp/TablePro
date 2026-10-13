//! The SQLite driver against real database files. No server is needed,
//! so these run in the fast CI job.
//!
//! Every module is test-only code: `cfg(test)` is what lets the shared
//! helpers fail a case with `unwrap`, as the case bodies do.

#[cfg(test)]
mod catalog;
#[cfg(test)]
mod conformance_engine;
#[cfg(test)]
mod decode;
#[cfg(test)]
mod dialect;
#[cfg(test)]
mod lock_wait;
#[cfg(test)]
mod metadata;
#[cfg(test)]
mod open_semantics;
#[cfg(test)]
mod sessions;
#[cfg(test)]
mod support;
#[cfg(test)]
mod write_batch_foreign_keys;
