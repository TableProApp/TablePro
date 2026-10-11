#[cfg(test)]
mod test;

use std::time::Duration;

use super::{
    description::topology::TopologyType,
    monitor::DEFAULT_HEARTBEAT_FREQUENCY,
    TopologyUpdater,
    TopologyWatcher,
};
use crate::{
    error::{Error, Result},
    options::ClientOptions,
    runtime,
    sdam::topology::TopologyShutdown,
    srv::{LookupHosts, SrvResolver},
};

const MIN_RESCAN_SRV_INTERVAL: Duration = Duration::from_secs(60);

pub(crate) struct SrvPollingMonitor {
    initial_hostname: String,
    resolver: Option<SrvResolver>,
    topology_updater: TopologyUpdater,
    topology_watcher: TopologyWatcher,
    rescan_interval: Duration,
    client_options: ClientOptions,
}

impl SrvPollingMonitor {
    pub(crate) fn new(
        topology_updater: TopologyUpdater,
        topology_watcher: TopologyWatcher,
        mut client_options: ClientOptions,
    ) -> Option<Self> {
        let initial_info = client_options.original_srv_info.take()?;

        Some(Self {
            initial_hostname: initial_info.hostname,
            resolver: None,
            topology_updater,
            topology_watcher,
            rescan_interval: initial_info.min_ttl,
            client_options,
        })
    }

    /// Starts a monitoring task that periodically performs SRV record lookups to determine if the
    /// set of mongos in the cluster have changed. A weak reference is used to ensure that the
    /// monitoring task doesn't keep the topology alive after the client has been dropped.
    pub(super) fn start(
        topology: TopologyUpdater,
        topology_watcher: TopologyWatcher,
        client_options: ClientOptions,
        shutdown: TopologyShutdown,
    ) {
        if let Some(monitor) = Self::new(topology, topology_watcher, client_options) {
            runtime::spawn(shutdown.tasks.track_future(monitor.execute()));
        }
    }

    fn rescan_interval(&self) -> Duration {
        if cfg!(test) {
            self.rescan_interval
        } else {
            std::cmp::max(self.rescan_interval, MIN_RESCAN_SRV_INTERVAL)
        }
    }

    async fn execute(mut self) {
        fn should_poll(tt: TopologyType) -> bool {
            matches!(tt, TopologyType::Sharded | TopologyType::Unknown)
        }

        while self.topology_watcher.is_alive() {
            tokio::time::sleep(self.rescan_interval()).await;

            if should_poll(self.topology_watcher.topology_type()) {
                let hosts = self.lookup_hosts().await;

                // verify we should still update before updating in case the topology changed
                // while the srv lookup was happening.
                if should_poll(self.topology_watcher.topology_type()) {
                    self.update_hosts(hosts).await;
                }
            }
        }
    }

    async fn update_hosts(&mut self, lookup: Result<LookupHosts>) {
        let lookup = match lookup {
            Ok(LookupHosts { hosts, .. }) if hosts.is_empty() => {
                self.no_valid_hosts(None);

                return;
            }
            Ok(lookup) => lookup,
            Err(err) => {
                self.no_valid_hosts(Some(err));

                return;
            }
        };

        self.rescan_interval = lookup.min_ttl;

        // TODO: RUST-230 Log error with host that was returned.
        self.topology_updater
            .sync_hosts(lookup.hosts.into_iter().collect())
            .await;
    }

    async fn lookup_hosts(&mut self) -> Result<LookupHosts> {
        #[cfg(test)]
        if let Some(mock) = self
            .client_options
            .test_options
            .as_ref()
            .and_then(|to| to.mock_lookup_hosts.as_ref())
        {
            return mock.clone();
        }
        let initial_hostname = self.initial_hostname.clone();
        let resolver = self.get_or_create_srv_resolver().await?;
        resolver
            .get_srv_hosts(initial_hostname.as_str(), crate::srv::DomainMismatch::Skip)
            .await
    }

    async fn get_or_create_srv_resolver(&mut self) -> Result<&SrvResolver> {
        if let Some(ref resolver) = self.resolver {
            return Ok(resolver);
        }

        let resolver = SrvResolver::new(
            self.client_options.resolver_config().cloned(),
            self.client_options.srv_service_name.clone(),
        )
        .await?;

        // Since the connection was not `Some` above, this will always insert the new connection and
        // return a reference to it.
        Ok(self.resolver.get_or_insert(resolver))
    }

    fn no_valid_hosts(&mut self, _error: Option<Error>) {
        // TODO RUST-230: Log error/lack of valid results.

        self.rescan_interval = self.heartbeat_freq();
    }

    fn heartbeat_freq(&self) -> Duration {
        self.client_options
            .heartbeat_freq
            .unwrap_or(DEFAULT_HEARTBEAT_FREQUENCY)
    }
}
