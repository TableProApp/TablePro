//! SQL and its parameters, built together.
//!
//! Every value the user supplied travels as a parameter. Nothing in
//! here writes one into the statement text, which is what keeps a cell
//! edit or a filter from becoming an injection.

mod bound_param;
mod param_type;
mod row_guard;
mod sql_build_error;
#[expect(clippy::module_inception, reason = "the module is the type it exports")]
mod statement;
mod statement_builder;

pub use bound_param::BoundParam;
pub use param_type::ParamType;
pub use row_guard::{GuardedStatement, RowGuard};
pub use sql_build_error::SqlBuildError;
pub use statement::Statement;
pub use statement_builder::{PlaceholderStyle, StatementBuilder};
