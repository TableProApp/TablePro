mod description;
mod monitor;
pub mod public;
mod server;
mod srv_polling;
#[cfg(test)]
mod test;
pub(crate) mod topology;

pub use self::public::{ServerInfo, ServerType, TopologyType};

pub(crate) use self::{
    description::{
        server::{ServerDescription, TopologyVersion},
        topology::{
            choose_n,
            server_selection::{self, SelectedServer},
            verify_max_staleness,
            TopologyDescription,
            TransactionSupportStatus,
        },
    },
    monitor::{Monitor, DEFAULT_HEARTBEAT_FREQUENCY, MIN_HEARTBEAT_FREQUENCY},
    server::Server,
    topology::{BroadcastMessage, HandshakePhase, Topology, TopologyUpdater, TopologyWatcher},
};

#[cfg(test)]
pub(crate) use topology::UpdateMessage;
