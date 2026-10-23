//! Completion in the SQL editor: the session's schema catalog, the
//! keywords and the snippets.

mod catalog_read;
mod completion_scope;
mod fuzzy;
mod proposal_kind;
mod proposal_list;
mod proposal_list_imp;
mod sql_completion_provider;
mod sql_completion_provider_imp;
mod sql_proposal;
mod sql_proposal_imp;
#[cfg(test)]
mod tests;

#[cfg(test)]
pub(super) use tests::accept_builtin_snippet;

pub(crate) use catalog_read::read as read_catalog;
pub(crate) use completion_scope::{CompletionScope, tables_named};
pub use sql_completion_provider::SqlCompletionProvider;
