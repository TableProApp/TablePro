//! A document engine's collection, paged, counted, exported and changed
//! through its shell language in place of SQL. A collection opens in the
//! same table tab as a table, so every builder that writes SQL for a
//! table hands a collection here when the dialect's grammar is
//! `SqlGrammar::Mongo`. Each builder writes one mongosh call, and every
//! value the user gave is bound as `$n`, never written into the text.

mod document_filter;
mod document_read;
mod document_write;
mod json_cells;
mod shell_literal;
mod shell_params;
#[cfg(test)]
mod tests;
mod value_order;

pub(crate) use document_filter::{filter_document, typed_document};
pub(crate) use document_read::{count, export, page};
pub(crate) use document_write::{delete, insert, insert_many, key_probe, update};
pub(crate) use json_cells::json_cells;
pub use shell_literal::shell_literal;
pub(crate) use shell_literal::{insert_document, insert_start};
pub(crate) use shell_params::ShellParams;
pub use shell_params::bind_param;

use crate::dialect::SqlDialect;
use crate::sql_syntax::SqlGrammar;

/// Whether the dialect's statements are shell calls rather than SQL.
pub(crate) fn speaks_shell(dialect: &dyn SqlDialect) -> bool {
    dialect.grammar() == SqlGrammar::Mongo
}
