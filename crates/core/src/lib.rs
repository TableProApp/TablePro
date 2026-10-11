#[cfg(test)]
extern crate self as tablepro_core;
#[cfg(test)]
#[path = "../tests/support/parser_contract.rs"]
mod parser_contract;

mod activity;
mod catalog;
mod connection;
mod driver;
mod error;
pub mod export;
pub mod filter;
pub mod import;
mod numeric_input;
mod operation;
mod pagination;
mod params;
mod query;
mod registry;
mod session;
mod shortcut_label;
pub mod sql_ddl;
pub mod sql_diagnostics;
pub mod sql_dialect;
pub mod sql_format;
pub mod sql_lex;
pub mod sql_literal;
pub mod sql_syntax;
mod sqlite_any_csv;
pub mod text_file;
mod tls;
mod transaction;

pub use activity::{ActivityQuery, ActivityUnsupported, activity_kinds, activity_sql, parse_session_id};
pub use catalog::{CATALOG_OBJECT_LIMIT, CatalogObject, CatalogObjectKind};
pub use connection::{AuthMode, ConnectOptions, Connection, SocketOrigin, Transport};
pub use driver::{
    ConnectionFormDefaults, DatabaseDriver, DriverMaturity, connection_form_defaults, initial_connection_form_defaults,
};
pub use error::DriverError;
pub use filter::{
    BuildFilterError, Combinator, FilterOp, FilterRule, FilterSet, FilterValue, build_filter_where, equality_rule,
};
pub use numeric_input::{
    FloatInputError, is_numeric_input, parse_float_input, sqlite_affinity_decimal,
    sqlite_declared_type_has_numeric_affinity,
};
pub use operation::{
    CANCELLATION_DISPATCH_TIMEOUT, CANCELLATION_GRACE, CONTROL_SETUP_TIMEOUT, Interruption, OperationControl,
    check_pre_dispatch, run_controlled_setup, run_server_cancellable,
};
pub use pagination::{KEYSET_OFFSET_THRESHOLD, KeysetError, keyset_order_by, keyset_where_clause};
pub use params::{NamedParameters, ParameterKind, extract_named_parameters, parse_parameter_value};
pub use query::{
    ColumnInfo, ExecResult, ForeignKeyInfo, IndexInfo, MAX_QUERY_RESULT_BYTES, MAX_QUERY_RESULT_CELLS, MAX_QUERY_ROWS,
    QualifiedTypeName, QueryResult, QueryResultBatch, QueryResultBudget, TableInfo, Value,
};
pub use registry::DriverRegistry;
pub use session::Session;
pub use shortcut_label::{
    BrowseDrawnShortcuts, BrowseShortcut, browse_drawn_shortcuts, browse_item_accelerator, browse_visible_key,
};
pub use tls::{Environment, TlsConfig, TlsMode, error_chain_text, looks_like_tls_failure};
pub use transaction::Transaction;
