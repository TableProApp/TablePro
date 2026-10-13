//! The connection conformance suite against SQL Server.
//!
//! tiberius 0.13 decodes sql_variant and CLR values, so the unsupported
//! types case runs. A stop that may leave a response half read discards
//! its connection, which the cancellation cases allow.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use drivers_mssql::{MssqlDriver, WORKSPACE_POOL_MAX_SIZE};
use tablepro_core::{ConnectOptions, DatabaseDriver, LivenessPolicy, NetworkEndpoint, TableRef, WorkspaceSettings};
use tablepro_test_fixtures::MssqlFixture;
use tablepro_test_support::FaultTransport;
use tablepro_test_support::conformance::{
    BoundedDdlEngine, ConformanceEngine, ConformanceFailure, EditorTransactionEngine, NetworkConformanceEngine,
    PooledConformanceEngine, TypedConformanceEngine, UnsupportedTypeCase,
};

use crate::support::{dbo, delay, direct, options_over, password, quoted, require};

pub struct MssqlEngine {
    fixture: MssqlFixture,
}

#[async_trait]
impl ConformanceEngine for MssqlEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(MssqlDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let fixture = MssqlFixture::start().await.map_err(ConformanceFailure::setup)?;
        Ok(Self { fixture })
    }

    fn connect_options(&self, settings: WorkspaceSettings, liveness: LivenessPolicy) -> ConnectOptions {
        options_over(
            direct(self.fixture.host(), self.fixture.port(), &liveness),
            password(&self.fixture.password_credentials()),
            require(),
            settings,
            liveness,
        )
    }

    fn scratch_table(&self, name: &str) -> TableRef {
        dbo(name)
    }

    fn create_scratch_table_sql(&self, table: &TableRef) -> String {
        format!(
            "CREATE TABLE [dbo].{} (id int PRIMARY KEY, label nvarchar(200) NOT NULL)",
            quoted(&table.name)
        )
    }

    fn unbounded_statement_sql(&self, marker: &str) -> String {
        format!("WAITFOR /* {marker} */ DELAY '23:59:59'")
    }

    async fn blocking_statement_sql(&self, marker: &str, hold: Duration) -> Result<String, ConformanceFailure> {
        Ok(format!(
            "/* {marker} */ WAITFOR DELAY '{}'; SELECT 1 AS done",
            delay(hold)
        ))
    }

    fn row_source_sql(&self, rows: u64) -> String {
        format!(
            "SELECT TOP ({rows}) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n \
             FROM sys.all_objects a CROSS JOIN sys.all_objects b"
        )
    }
}

#[async_trait]
impl NetworkConformanceEngine for MssqlEngine {
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
            require(),
            settings,
            liveness,
        );
        Ok((options, fault))
    }

    fn running_statement_count_sql(&self, marker: &str) -> String {
        format!(
            "SELECT COUNT(*) FROM sys.dm_exec_requests r \
             CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t \
             WHERE t.text LIKE N'%{marker}%' AND r.session_id <> @@SPID"
        )
    }
}

impl PooledConformanceEngine for MssqlEngine {
    const WORKSPACE_POOL_MAX_SIZE: usize = WORKSPACE_POOL_MAX_SIZE;
}

impl EditorTransactionEngine for MssqlEngine {
    fn begin_sql(&self) -> String {
        "BEGIN TRANSACTION".to_owned()
    }

    fn commit_sql(&self) -> String {
        "COMMIT TRANSACTION".to_owned()
    }
}

impl TypedConformanceEngine for MssqlEngine {
    fn unsupported_type_cases(&self) -> Vec<UnsupportedTypeCase> {
        let case = |declaration: &str, value: &str| UnsupportedTypeCase {
            setup_sql: Vec::new(),
            declaration: declaration.to_owned(),
            insert_value_sql: value.to_owned(),
        };
        vec![
            case("v geography", "geography::Point(47.65, -122.34, 4326)"),
            case("v hierarchyid", "hierarchyid::Parse('/1/2/')"),
            case("v sql_variant", "CAST(42 AS sql_variant)"),
        ]
    }
}

impl BoundedDdlEngine for MssqlEngine {
    fn schema_change_exceeding_sql(&self, table: &TableRef, duration: Duration) -> String {
        format!(
            "WAITFOR DELAY '{}'; CREATE TABLE [dbo].{} (id int)",
            delay(duration),
            quoted(&table.name)
        )
    }
}

mod suite {
    use super::MssqlEngine;

    tablepro_test_support::connection_conformance_suite! {
        engine: MssqlEngine,
        docker: true,
        endpoint: network,
        pool: pooled,
        editor_transactions: true,
        unsupported_types: true,
        bounded_ddl: true,
    }
}
