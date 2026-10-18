use std::num::NonZeroU32;

use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};

use crate::container_file::with_files;
use crate::{
    ContainerFile, FixtureCredentials, FixtureError, FixtureImage, HbaMode, PoolMode, PostgresFixture, TestNetwork,
};

const CONTAINER_PORT: u16 = 5432;
const NETWORK_ROLE: &str = "pgbouncer";

pub struct PgBouncerFixture {
    container: ContainerAsync<GenericImage>,
    upstream: PostgresFixture,
    network: TestNetwork,
    pool_mode: PoolMode,
    pool_size: NonZeroU32,
    host: String,
    port: u16,
}

impl PgBouncerFixture {
    /// PgBouncer's own default, so a fixture started without a size
    /// behaves like an unconfigured pooler.
    pub const DEFAULT_POOL_SIZE: NonZeroU32 = NonZeroU32::new(20).expect("20 is not zero");

    pub async fn start(pool_mode: PoolMode) -> Result<Self, FixtureError> {
        Self::start_with_pool_size(pool_mode, Self::DEFAULT_POOL_SIZE).await
    }

    /// A pool of one server connection makes every client share the same
    /// backend, which is how a test proves no session state leaks out.
    pub async fn start_with_pool_size(pool_mode: PoolMode, pool_size: NonZeroU32) -> Result<Self, FixtureError> {
        let network = TestNetwork::new();
        let upstream = PostgresFixture::start_in(HbaMode::Password, &network).await?;
        let upstream_host = network.container_name(PostgresFixture::NETWORK_ROLE);
        let files = Self::files(
            pool_mode,
            pool_size,
            &upstream_host,
            upstream.database(),
            &upstream.password_credentials(),
        );
        let request = FixtureImage::PGBOUNCER
            .generic()
            .with_exposed_port(CONTAINER_PORT.tcp())
            .with_wait_for(WaitFor::message_on_either_std("process up"))
            .with_network(network.name())
            .with_container_name(network.container_name(NETWORK_ROLE));
        let container = with_files(request, files).start().await?;
        let host = container.get_host().await?.to_string();
        let port = container.get_host_port_ipv4(CONTAINER_PORT).await?;
        Ok(Self {
            container,
            upstream,
            network,
            pool_mode,
            pool_size,
            host,
            port,
        })
    }

    pub fn files(
        pool_mode: PoolMode,
        pool_size: NonZeroU32,
        upstream_host: &str,
        database: &str,
        credentials: &FixtureCredentials,
    ) -> Vec<ContainerFile> {
        let mode = pool_mode.as_str();
        let configuration = format!(
            "[databases]\n\
             {database} = host={upstream_host} port={CONTAINER_PORT} dbname={database}\n\
             \n\
             [pgbouncer]\n\
             listen_addr = 0.0.0.0\n\
             listen_port = {CONTAINER_PORT}\n\
             auth_type = scram-sha-256\n\
             auth_file = /etc/pgbouncer/userlist.txt\n\
             pool_mode = {mode}\n\
             default_pool_size = {pool_size}\n\
             max_prepared_statements = 0\n\
             ignore_startup_parameters = extra_float_digits,options\n"
        );
        let userlist = format!("\"{}\" \"{}\"\n", credentials.username, credentials.password);
        vec![
            ContainerFile::readable("/etc/pgbouncer/pgbouncer.ini", configuration),
            ContainerFile::readable("/etc/pgbouncer/userlist.txt", userlist),
        ]
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn pool_mode(&self) -> PoolMode {
        self.pool_mode
    }

    pub fn pool_size(&self) -> NonZeroU32 {
        self.pool_size
    }

    pub fn network(&self) -> &TestNetwork {
        &self.network
    }

    pub fn network_alias(&self) -> String {
        self.network.container_name(NETWORK_ROLE)
    }

    pub fn upstream(&self) -> &PostgresFixture {
        &self.upstream
    }

    pub fn container(&self) -> &ContainerAsync<GenericImage> {
        &self.container
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_configuration_carries_the_mode_and_the_pool_size() {
        let credentials = FixtureCredentials::new("tablepro", "secret");
        let files = PgBouncerFixture::files(
            PoolMode::Transaction,
            NonZeroU32::MIN,
            "upstream",
            "tablepro",
            &credentials,
        );
        let configuration = String::from_utf8(files[0].contents().to_vec()).unwrap();

        assert_eq!(files[0].target(), "/etc/pgbouncer/pgbouncer.ini");
        assert!(configuration.contains("pool_mode = transaction\n"));
        assert!(configuration.contains("default_pool_size = 1\n"));
        assert!(configuration.contains("tablepro = host=upstream port=5432 dbname=tablepro\n"));
    }
}
