//! The connection conformance suite against PostgreSQL.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use drivers_postgres::{PgDriver, WORKSPACE_POOL_MAX_SIZE};
use tablepro_core::{
    ConnectOptions, DatabaseDriver, LivenessPolicy, NetworkEndpoint, TableRef, TlsConfig, WorkspaceSettings,
};
use tablepro_test_fixtures::{HbaMode, PostgresFixture};
use tablepro_test_support::FaultTransport;
use tablepro_test_support::conformance::{
    BoundedDdlEngine, ConformanceEngine, ConformanceFailure, EditorTransactionEngine, NetworkConformanceEngine,
    PooledConformanceEngine, TypedConformanceEngine, UnsupportedTypeCase,
};

use crate::support::{direct, options_over, password};

pub struct PgEngine {
    fixture: PostgresFixture,
}

fn quoted(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

#[async_trait]
impl ConformanceEngine for PgEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(PgDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let fixture = PostgresFixture::start(HbaMode::Password)
            .await
            .map_err(ConformanceFailure::setup)?;
        Ok(Self { fixture })
    }

    fn connect_options(&self, settings: WorkspaceSettings, liveness: LivenessPolicy) -> ConnectOptions {
        options_over(
            direct(self.fixture.host(), self.fixture.port(), &liveness),
            password(&self.fixture.password_credentials()),
            self.fixture.database(),
            TlsConfig::disabled(),
            settings,
            liveness,
        )
    }

    fn scratch_table(&self, name: &str) -> TableRef {
        TableRef::new(Some("public".to_owned()), name)
    }

    fn create_scratch_table_sql(&self, table: &TableRef) -> String {
        format!(
            "CREATE TABLE public.{} (id integer PRIMARY KEY, label text NOT NULL)",
            quoted(&table.name)
        )
    }

    fn unbounded_statement_sql(&self, marker: &str) -> String {
        format!("SELECT pg_sleep(3600) /* {marker} */")
    }

    async fn blocking_statement_sql(&self, marker: &str, hold: Duration) -> Result<String, ConformanceFailure> {
        Ok(format!("SELECT pg_sleep({}) /* {marker} */", hold.as_secs_f64()))
    }

    fn row_source_sql(&self, rows: u64) -> String {
        format!("SELECT generate_series(1, {rows})")
    }
}

#[async_trait]
impl NetworkConformanceEngine for PgEngine {
    async fn faulty_connect_options(
        &self,
        settings: WorkspaceSettings,
        liveness: LivenessPolicy,
    ) -> Result<(ConnectOptions, Arc<FaultTransport>), ConformanceFailure> {
        let endpoint =
            NetworkEndpoint::new(self.fixture.host(), self.fixture.port()).map_err(ConformanceFailure::setup)?;
        let fault = Arc::new(FaultTransport::direct(endpoint, &liveness).map_err(ConformanceFailure::setup)?);
        let options = options_over(
            fault.clone(),
            password(&self.fixture.password_credentials()),
            self.fixture.database(),
            TlsConfig::disabled(),
            settings,
            liveness,
        );
        Ok((options, fault))
    }

    fn running_statement_count_sql(&self, marker: &str) -> String {
        format!(
            "SELECT count(*) FROM pg_stat_activity \
             WHERE state = 'active' AND query LIKE '%{marker}%' AND pid <> pg_backend_pid()"
        )
    }
}

impl PooledConformanceEngine for PgEngine {
    const WORKSPACE_POOL_MAX_SIZE: usize = WORKSPACE_POOL_MAX_SIZE;
}

impl EditorTransactionEngine for PgEngine {
    fn begin_sql(&self) -> String {
        "BEGIN".to_owned()
    }

    fn commit_sql(&self) -> String {
        "COMMIT".to_owned()
    }
}

impl TypedConformanceEngine for PgEngine {
    fn unsupported_type_cases(&self) -> Vec<UnsupportedTypeCase> {
        let case = |setup: &[&str], declaration: &str, value: &str| UnsupportedTypeCase {
            setup_sql: setup.iter().map(|sql| (*sql).to_owned()).collect(),
            declaration: declaration.to_owned(),
            insert_value_sql: value.to_owned(),
        };
        vec![
            case(&[], "v point", "'(1,2)'::point"),
            case(&[], "v int4range", "'[1,5)'::int4range"),
            case(
                &["CREATE TYPE tp_pair AS (a integer, b text)"],
                "v tp_pair",
                "ROW(1, 'x')::tp_pair",
            ),
            case(
                &["CREATE TYPE tp_mood AS ENUM ('happy', 'sad')"],
                "v tp_mood",
                "'happy'::tp_mood",
            ),
        ]
    }
}

impl BoundedDdlEngine for PgEngine {
    fn schema_change_exceeding_sql(&self, table: &TableRef, duration: Duration) -> String {
        format!(
            "CREATE TABLE public.{} AS SELECT 1 AS id FROM pg_sleep({})",
            quoted(&table.name),
            duration.as_secs_f64()
        )
    }
}

mod suite {
    use super::PgEngine;

    tablepro_test_support::connection_conformance_suite! {
        engine: PgEngine,
        docker: true,
        endpoint: network,
        pool: pooled,
        editor_transactions: true,
        unsupported_types: true,
        bounded_ddl: true,
    }
}
