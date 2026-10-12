//! The connection conformance suite against ClickHouse.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use drivers_clickhouse::ClickhouseDriver;
use tablepro_core::{
    ConnectOptions, DatabaseDriver, LivenessPolicy, NetworkEndpoint, TableRef, TlsConfig, WorkspaceSettings,
};
use tablepro_test_fixtures::ClickHouseFixture;
use tablepro_test_support::FaultTransport;
use tablepro_test_support::conformance::{
    ConformanceEngine, ConformanceFailure, NetworkConformanceEngine, TypedConformanceEngine, UnsupportedTypeCase,
};

use crate::support::{DATABASE, direct, options_over, password, quoted};

pub struct ClickHouseEngine {
    fixture: ClickHouseFixture,
}

/// A read of `rows` rows that takes a tenth of a second per row. One row
/// per block, so the server notices a KILL between rows.
fn sleeping_rows(marker: &str, rows: u64) -> String {
    format!("SELECT sleepEachRow(0.1), '{marker}' FROM numbers({rows}) SETTINGS max_block_size = 1")
}

#[async_trait]
impl ConformanceEngine for ClickHouseEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(ClickhouseDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let fixture = ClickHouseFixture::start().await.map_err(ConformanceFailure::setup)?;
        Ok(Self { fixture })
    }

    fn connect_options(&self, settings: WorkspaceSettings, liveness: LivenessPolicy) -> ConnectOptions {
        options_over(
            direct(self.fixture.host(), self.fixture.http_port(), &liveness),
            password(&self.fixture.password_credentials()),
            TlsConfig::disabled(),
            settings,
            liveness,
        )
    }

    fn scratch_table(&self, name: &str) -> TableRef {
        TableRef::new(Some(DATABASE.to_owned()), name)
    }

    fn create_scratch_table_sql(&self, table: &TableRef) -> String {
        format!(
            "CREATE TABLE {}.{} (id Int32, label String) ENGINE = MergeTree ORDER BY id",
            quoted(DATABASE),
            quoted(&table.name)
        )
    }

    fn unbounded_statement_sql(&self, marker: &str) -> String {
        sleeping_rows(marker, 100_000_000)
    }

    async fn blocking_statement_sql(&self, marker: &str, hold: Duration) -> Result<String, ConformanceFailure> {
        Ok(sleeping_rows(marker, hold.as_secs() * 10))
    }

    fn row_source_sql(&self, rows: u64) -> String {
        format!("SELECT number FROM numbers({rows})")
    }
}

#[async_trait]
impl NetworkConformanceEngine for ClickHouseEngine {
    async fn faulty_connect_options(
        &self,
        settings: WorkspaceSettings,
        liveness: LivenessPolicy,
    ) -> Result<(ConnectOptions, Arc<FaultTransport>), ConformanceFailure> {
        let endpoint =
            NetworkEndpoint::new(self.fixture.host(), self.fixture.http_port()).map_err(ConformanceFailure::setup)?;
        let fault = Arc::new(FaultTransport::direct(endpoint, &liveness).map_err(ConformanceFailure::setup)?);
        let options = options_over(
            fault.clone(),
            password(&self.fixture.password_credentials()),
            TlsConfig::disabled(),
            settings,
            liveness,
        );
        Ok((options, fault))
    }

    fn running_statement_count_sql(&self, marker: &str) -> String {
        format!(
            "SELECT count() FROM system.processes \
             WHERE query LIKE '%{marker}%' AND query NOT LIKE '%system.processes%'"
        )
    }
}

impl TypedConformanceEngine for ClickHouseEngine {
    fn unsupported_type_cases(&self) -> Vec<UnsupportedTypeCase> {
        let case = |declaration: &str, value: &str| UnsupportedTypeCase {
            setup_sql: Vec::new(),
            declaration: declaration.to_owned(),
            insert_value_sql: value.to_owned(),
        };
        vec![
            case("COLUMN v Map(String, UInt8)", "map('a', 1)"),
            case("COLUMN v Tuple(UInt8, String)", "(1, 'x')"),
            case("COLUMN v Variant(String, UInt64)", "'x'"),
            case("COLUMN v Dynamic", "42"),
            case("COLUMN v JSON", "'{\"a\": 1}'"),
            case("COLUMN v Point", "(1, 2)"),
            case("COLUMN v IPv6", "'::1'"),
        ]
    }
}

mod suite {
    use super::ClickHouseEngine;

    tablepro_test_support::connection_conformance_suite! {
        engine: ClickHouseEngine,
        docker: true,
        endpoint: network,
        pool: unbounded,
        editor_transactions: false,
        unsupported_types: true,
        bounded_ddl: false,
    }
}
