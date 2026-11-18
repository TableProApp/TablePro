mod dial;
mod direct_tcp;
#[cfg(unix)]
mod local_socket;
mod loopback_listener;
mod loopback_owner;
mod private_dir;
mod private_listener;
mod socket_options;
pub mod tls;

pub use direct_tcp::DirectTcpTransport;
#[cfg(unix)]
pub use local_socket::LocalSocketTransport;
pub use loopback_listener::LoopbackListener;
pub use loopback_owner::{loopback_peer_is_ours, loopback_peer_is_this_user};
#[cfg(windows)]
pub use loopback_owner::{loopback_peer_process, process_runs_as_this_user};
pub use private_dir::private_dir;
pub use private_listener::{PrivateAddress, PrivateListener};
