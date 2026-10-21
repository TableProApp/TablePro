//! Completion in the SQL editor from the session's schema catalog.

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

pub use sql_completion_provider::SqlCompletionProvider;
