//! The per-table WHERE clause the browse filter builds.
//!
//! The filter strip hands over a `FilterSet` and `build_filter` turns it
//! into SQL through the connection's own dialect. Every value the user
//! typed is parsed against the column's type and bound, so a filter is
//! a comparison rather than a string spliced into the query.

mod build_filter;
mod build_filter_error;
mod filter_op;
mod filter_rule;
mod filter_set;
mod operators_for;
mod validate_raw_predicate;

pub use build_filter::build_filter;
pub use build_filter_error::BuildFilterError;
pub use filter_op::FilterOp;
pub use filter_rule::{FilterRule, FilterValue};
pub use filter_set::{Combinator, FilterSet};
pub use operators_for::operators_for;
pub use validate_raw_predicate::validate_raw_predicate;
