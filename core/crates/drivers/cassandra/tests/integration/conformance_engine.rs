//! The connection, DDL and large-table suites against Apache Cassandra
//! and ScyllaDB.

use std::marker::PhantomData;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    ConnectOptions, DatabaseDriver, LivenessPolicy, NetworkEndpoint, TableRef, TlsConfig, WorkspaceSettings,
};
use tablepro_driver_cassandra::CassandraDriver;
use tablepro_test_fixtures::{CassandraFixture, CassandraFlavour};
use tablepro_test_support::FaultTransport;
use tablepro_test_support::conformance::{
    ConformanceDdlEngine, ConformanceEngine, ConformanceFailure, LargeTableEngine, NetworkConformanceEngine,
    TypedConformanceEngine, UnsupportedTypeCase,
};

use crate::support::{
    CassandraServer, KEYSPACE, ScyllaServer, Server, direct, load_series, options_over, password, qualified,
};

/// The row source the suites read: a million rows, the most a case asks
/// for, since CQL has no generator.
const SERIES: &str = "series";
const SERIES_ROWS: u64 = 1_000_000;
/// Rows a fill batch writes. Each row is its own partition, so the batch
/// is only one round trip, not one write.
const FILL_BATCH: u64 = 2_000;

pub struct CqlEngine<S: Server> {
    pub fixture: CassandraFixture,
    server: PhantomData<S>,
}

impl<S: Server> CqlEngine<S> {
    pub async fn started() -> Result<Self, ConformanceFailure> {
        let fixture = CassandraFixture::start(S::FLAVOUR)
            .await
            .map_err(ConformanceFailure::setup)?;
        fixture
            .cql(&spin_function(S::FLAVOUR))
            .await
            .map_err(ConformanceFailure::setup)?;
        Ok(Self {
            fixture,
            server: PhantomData,
        })
    }
}

/// `spin(n)` counts to `n` and returns. Each server runs it where its
/// caller leaving cannot stop it: Cassandra in the request thread, with
/// no timeout once the fixture moves functions there, and ScyllaDB under
/// the hour the fixture allows a Lua function. A literal cannot be an
/// argument on ScyllaDB, so `n` comes from `spin_source`.
fn spin_function(flavour: CassandraFlavour) -> String {
    let body = match flavour {
        CassandraFlavour::Cassandra => {
            "LANGUAGE java AS 'long x = 0; for (long i = 0; i < n; i++) { x += i ^ (x >>> 3); } return x;'"
        }
        CassandraFlavour::Scylla => "LANGUAGE lua AS 'local x = 0; for i = 1, n do x = x + i % 7 end; return x'",
    };
    format!(
        "CREATE FUNCTION {KEYSPACE}.spin(n bigint) RETURNS NULL ON NULL INPUT RETURNS bigint {body};\n\
         CREATE TABLE {KEYSPACE}.spin_source (id int PRIMARY KEY, n bigint);\n\
         INSERT INTO {KEYSPACE}.spin_source (id, n) VALUES (1, 9223372036854775807);\n"
    )
}

#[async_trait]
impl<S: Server> ConformanceEngine for CqlEngine<S> {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(CassandraDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let engine = Self::started().await?;
        load_series(&engine.fixture, SERIES, SERIES_ROWS).await;
        Ok(engine)
    }

    fn connect_options(&self, settings: WorkspaceSettings, liveness: LivenessPolicy) -> ConnectOptions {
        options_over(
            direct(self.fixture.host(), self.fixture.port(), &liveness),
            password(&self.fixture.password_credentials()),
            TlsConfig::disabled(),
            settings,
            liveness,
        )
    }

    fn scratch_table(&self, name: &str) -> TableRef {
        TableRef::new(Some(KEYSPACE.to_owned()), name)
    }

    fn create_scratch_table_sql(&self, table: &TableRef) -> String {
        format!(
            "CREATE TABLE {} (id int PRIMARY KEY, label text)",
            qualified(&table.name)
        )
    }

    fn unbounded_statement_sql(&self, marker: &str) -> String {
        format!("SELECT {KEYSPACE}.spin(n) AS \"{marker}\" FROM {KEYSPACE}.spin_source WHERE id = 1")
    }

    /// Only the busy-pool case asks for one, and a CQL connection has no
    /// pool slots to fill.
    async fn blocking_statement_sql(&self, _marker: &str, _hold: Duration) -> Result<String, ConformanceFailure> {
        Err(ConformanceFailure::setup(
            "a CQL connection has no pool slots for a blocking statement to hold",
        ))
    }

    fn row_source_sql(&self, rows: u64) -> String {
        format!("SELECT n FROM {} LIMIT {rows}", qualified(SERIES))
    }

    fn trivial_read_sql(&self) -> String {
        "SELECT release_version FROM system.local".to_owned()
    }
}

#[async_trait]
impl<S: Server> NetworkConformanceEngine for CqlEngine<S> {
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
            TlsConfig::disabled(),
            settings,
            liveness,
        );
        Ok((options, fault))
    }
}

impl<S: Server> TypedConformanceEngine for CqlEngine<S> {
    fn unsupported_type_cases(&self) -> Vec<UnsupportedTypeCase> {
        let case = |setup: &[&str], declaration: &str, value: &str| UnsupportedTypeCase {
            setup_sql: setup.iter().map(|sql| (*sql).to_owned()).collect(),
            declaration: declaration.to_owned(),
            insert_value_sql: value.to_owned(),
        };
        let point = format!("CREATE TYPE IF NOT EXISTS {KEYSPACE}.tp_point (x int, y int)");
        vec![
            case(&[], "v map<text, int>", "{'a': 1}"),
            case(&[], "v set<int>", "{3, 1}"),
            case(&[], "v list<text>", "['x', 'y']"),
            case(&[], "v frozen<tuple<int, text>>", "(1, 'x')"),
            case(&[&point], "v frozen<tp_point>", "{x: 1, y: 2}"),
        ]
    }
}

impl<S: Server> ConformanceDdlEngine for CqlEngine<S> {
    fn integer_type(&self) -> &'static str {
        "bigint"
    }

    fn text_type(&self) -> &'static str {
        "text"
    }

    fn timestamp_type(&self) -> &'static str {
        "timestamp"
    }

    fn current_timestamp_expression(&self) -> &'static str {
        "toTimestamp(now())"
    }
}

impl<S: Server> LargeTableEngine for CqlEngine<S> {
    fn fill_scratch_table_sql(&self, table: &TableRef, rows: u64, label_width: usize) -> Vec<String> {
        let name = qualified(&table.name);
        (0..rows.div_ceil(FILL_BATCH))
            .map(|chunk| {
                let inserts: String = (chunk * FILL_BATCH + 1..=rows.min((chunk + 1) * FILL_BATCH))
                    .map(|id| format!("INSERT INTO {name} (id, label) VALUES ({id}, '{id:0label_width$}');\n"))
                    .collect();
                format!("BEGIN UNLOGGED BATCH\n{inserts}APPLY BATCH")
            })
            .collect()
    }
}

mod cassandra_suite {
    use super::{CassandraServer, CqlEngine};

    tablepro_test_support::connection_conformance_suite! {
        engine: CqlEngine<CassandraServer>,
        docker: true,
        endpoint: network,
        server_stop: false,
        pool: unbounded,
        editor_transactions: false,
        unsupported_types: true,
        bounded_ddl: false,
    }

    tablepro_test_support::ddl_conformance_suite! {
        engine: CqlEngine<CassandraServer>,
        docker: true,
    }

    tablepro_test_support::large_table_conformance_suite! {
        engine: CqlEngine<CassandraServer>,
        docker: true,
    }
}

mod scylla_suite {
    use super::{CqlEngine, ScyllaServer};

    tablepro_test_support::connection_conformance_suite! {
        engine: CqlEngine<ScyllaServer>,
        docker: true,
        endpoint: network,
        server_stop: false,
        pool: unbounded,
        editor_transactions: false,
        unsupported_types: true,
        bounded_ddl: false,
    }

    tablepro_test_support::ddl_conformance_suite! {
        engine: CqlEngine<ScyllaServer>,
        docker: true,
    }

    tablepro_test_support::large_table_conformance_suite! {
        engine: CqlEngine<ScyllaServer>,
        docker: true,
    }
}
