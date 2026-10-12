//! The session's current connection, handed out as generation-stamped
//! leases so a result from a replaced connection is recognised as stale.

mod close_report;
mod connection_lease;
mod connection_link;
mod established_connection;
mod retired_connection;

pub use close_report::CloseReport;
pub use connection_lease::ConnectionLease;
pub use connection_link::ConnectionLink;
pub use established_connection::EstablishedConnection;
pub use retired_connection::RetiredConnection;
