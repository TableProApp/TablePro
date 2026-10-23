//! The DuckDB driver against real database files. No server is needed,
//! so these run in the fast CI job.
//!
//! Every module is test-only code: `cfg(test)` is what lets the shared
//! helpers fail a case with `unwrap`, as the case bodies do.

#[cfg(test)]
mod catalog;
#[cfg(test)]
mod conformance_engine;
#[cfg(test)]
mod ddl;
#[cfg(test)]
mod decode;
#[cfg(test)]
mod duckdb_engine;
#[cfg(test)]
mod open_semantics;
#[cfg(test)]
mod round_trip;
#[cfg(test)]
mod sessions;
#[cfg(test)]
mod support;
#[cfg(test)]
mod value_corpus;
