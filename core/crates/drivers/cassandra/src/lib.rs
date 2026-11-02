//! The Cassandra and ScyllaDB driver: the scylla crate, reached through
//! the target's transport by a loopback relay and kept on the one node
//! that transport reaches.

mod bind;
mod call;
mod capabilities;
mod catalog;
mod connection;
mod cql_type;
mod ddl;
mod decode;
mod dialect;
mod driver;
mod editor;
mod errors;
mod peer_owner;
mod pin;
mod relay;
mod rows;
mod session;
mod stream_read;
mod write_batch;

pub use dialect::CqlDialect;
pub use driver::CassandraDriver;
