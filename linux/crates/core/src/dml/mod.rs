//! Turning a row change into SQL.
//!
//! Every value the user typed is bound, never written into the text,
//! and every statement carries the guard that proves it touched the
//! row the user was looking at.

mod build_sql_error;
mod key_component;

pub use build_sql_error::BuildSqlError;
pub use key_component::{KeyComponent, key_components};
