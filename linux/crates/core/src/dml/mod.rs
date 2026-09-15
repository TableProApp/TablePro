//! Turning a row change into SQL.
//!
//! Every value the user typed is bound, never written into the text,
//! and every statement names the row through the same key ordering the
//! page laid out.

mod build_delete;
mod build_insert;
mod build_sql_error;
mod build_update;
mod key_component;
mod predicate;
#[cfg(test)]
mod tests;

pub use build_delete::{build_delete, build_key_probe};
pub use build_insert::build_insert;
pub use build_sql_error::BuildSqlError;
pub use build_update::build_update;
pub use key_component::{KeyComponent, key_components};
