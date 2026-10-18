//! The ClickHouse driver: the official `clickhouse` crate over hyper,
//! with every connection dialled through the target's transport.
//!
//! Reads stream `JSONCompactEachRowWithNamesAndTypes` and read each cell
//! by the type the server named for it. Values go to the server as typed
//! `{pN:Type}` parameters. A write is a sequence of statements, each
//! under a query id of its own, so one whose answer never arrived can
//! be looked up in the server's query log afterwards.

mod call_client;
mod cancel;
mod capabilities;
mod catalog;
mod cell_seed;
mod clickhouse_type;
mod client_factory;
mod commit_resolution;
mod connection;
mod ddl;
mod dialect;
mod driver;
mod editor_run;
mod editor_session;
mod endpoint;
mod errors;
mod http_call;
mod key_expression;
mod line_reader;
mod lingering_query;
mod metadata;
mod param_value;
mod result_reader;
mod row_seed;
mod session_status;
mod stream_read;
mod transport_connector;
mod transport_io;
mod write_batch;
mod write_error_class;

pub use dialect::ClickHouseDialect;
pub use driver::ClickhouseDriver;
