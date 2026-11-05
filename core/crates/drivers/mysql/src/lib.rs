//! The MySQL and MariaDB driver: sqlx connections dialled over the
//! target's route, a deadpool workspace pool, KILL QUERY for stops, and
//! editor sessions on the server's own defaults.
//!
//! sqlx dials the route itself, so a direct route is a TCP endpoint and
//! an SSH forward is the Unix socket OpenSSH listens on. A route only
//! `Transport::open` reaches is dialled through a relay of the driver's.

mod cancel;
mod capabilities;
mod catalog;
mod column_origins;
mod connection;
mod ddl;
mod decode;
mod dialect;
mod driver;
mod editor_run;
mod editor_session;
mod encode;
mod errors;
mod flavour;
mod metadata;
mod mysql_call;
mod mysql_manager;
mod mysql_temporal;
mod mysql_timestamp_mode;
mod mysql_wire_format;
mod physical;
mod relay;
mod script_split;
mod server_zone;
mod session_statements;
mod standalone;
mod stream_read;
mod table_engine;
mod transaction_probe;
mod workspace_call;
mod workspace_session;
mod write_batch;

pub use dialect::MySqlDialect;
pub use driver::MysqlDriver;
pub use flavour::MySqlFlavour;
pub use mysql_manager::WORKSPACE_POOL_MAX_SIZE;
