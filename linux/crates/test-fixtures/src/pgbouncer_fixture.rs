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
    host: String,
    port: u16,
}

impl PgBouncerFixture {
    pub async fn start(pool_mode: PoolMode) -> Result<Self, FixtureError> {
        let network = TestNetwork::new();
        let upstream = PostgresFixture::start_in(HbaMode::Password, &network).await?;
        let upstream_host = network.container_name(PostgresFixture::NETWORK_ROLE);
        let files = Self::files(
            pool_mode,
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
            host,
            port,
        })
    }

    pub fn files(
        pool_mode: PoolMode,
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
