//! DDL string builders for CREATE / ALTER / DROP TABLE, CREATE / DROP
//! INDEX, ADD / DROP FOREIGN KEY across MySQL + Postgres + SQLite.
//!
//! Pure SQL-string construction; no async, no I/O. Mirrors the
//! parameterised-by-`driver_id` style of `sql_dialect.rs`. All
//! identifier quoting goes through `sql_dialect::quote_ident`; type
//! names interpolate raw because they're a syntax category, not a
//! string-literal category — the worst case is a driver syntax error,
//! never injection.
//!
//! Statement ordering for a multi-op materialize() is handled by the
//! caller (the StructureChangeTracker). Each builder produces one
//! statement at a time; the caller composes them.

mod column;
mod diff;
mod index_fk;
mod table;
mod types;

#[cfg(test)]
mod collation_tests;
#[cfg(test)]
mod comment_tests;
#[cfg(test)]
mod default_tests;
#[cfg(test)]
mod tests;

pub use column::{build_add_column, build_alter_column, build_drop_column, build_rename_column, build_reorder_column};
pub use diff::{diff_to_ops, materialize_ops};
pub use index_fk::{build_add_foreign_key, build_create_index, build_drop_foreign_key, build_drop_index};
pub use table::{build_create_table, build_drop_table, build_rename_table};
pub use types::{
    BuildDdlError, CommentPlacement, DraftColumn, StructureOp, column_comment_placement, supported_fk_actions,
};
