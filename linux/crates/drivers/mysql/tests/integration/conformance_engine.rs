//! The connection conformance suite against MySQL 8.4 and MariaDB 11.4.

use std::marker::PhantomData;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use drivers_mysql::{MysqlDriver, WORKSPACE_POOL_MAX_SIZE};
use tablepro_core::{
    ConnectOptions, DatabaseDriver, LivenessPolicy, NetworkEndpoint, TableRef, TlsConfig, WorkspaceSettings,
};
use tablepro_test_fixtures::{MysqlFixture, MysqlFlavour, MysqlOptions};
use tablepro_test_support::FaultTransport;
use tablepro_test_support::conformance::{
    BoundedDdlEngine, ConformanceDdlEngine, ConformanceEngine, ConformanceFailure, EditorTransactionEngine,
    NetworkConformanceEngine, PooledConformanceEngine, TypedConformanceEngine, UnsupportedTypeCase,
};

use crate::support::{direct, options_over, password};

/// Which server an engine starts.
pub trait Server: Send + Sync + 'static {
    const FLAVOUR: MysqlFlavour;
}

pub struct Mysql84;

impl Server for Mysql84 {
    const FLAVOUR: MysqlFlavour = MysqlFlavour::Mysql;
}

pub struct Mariadb114;

impl Server for Mariadb114 {
    const FLAVOUR: MysqlFlavour = MysqlFlavour::Mariadb;
}

pub struct MySqlEngine<S> {
    fixture: MysqlFixture,
    server: PhantomData<S>,
}

fn quoted(name: &str) -> String {
    format!("`{}`", name.replace('`', "``"))
}

fn qualified(table: &TableRef) -> String {
    match &table.schema {
        Some(schema) => format!("{}.{}", quoted(schema), quoted(&table.name)),
        None => quoted(&table.name),
    }
}

#[async_trait]
impl<S: Server> ConformanceEngine for MySqlEngine<S> {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(MysqlDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let options = MysqlOptions::new(S::FLAVOUR).allowing_plaintext();
        let fixture = MysqlFixture::start_with(options, None)
            .await
            .map_err(ConformanceFailure::setup)?;
        Ok(Self {
            fixture,
            server: PhantomData,
        })
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
        TableRef::new(Some(self.fixture.database().to_owned()), name)
    }

    fn create_scratch_table_sql(&self, table: &TableRef) -> String {
        format!(
            "CREATE TABLE {} (id integer PRIMARY KEY, label text NOT NULL)",
            qualified(table)
        )
    }

    /// SLEEP alone in a SELECT returns 1 when killed, with no error, so
    /// it sits in a WHERE clause, where a KILL fails the statement.
    fn unbounded_statement_sql(&self, marker: &str) -> String {
        format!("SELECT /* {marker} */ 1 FROM DUAL WHERE SLEEP(3600) = 0")
    }

    async fn blocking_statement_sql(&self, marker: &str, hold: Duration) -> Result<String, ConformanceFailure> {
        Ok(format!("SELECT SLEEP({}) /* {marker} */", hold.as_secs_f64()))
    }

    /// A LIMIT of its own, so `sql_select_limit` does not cut it and the
    /// editor reads past its row limit. Both servers stop a recursive CTE
    /// after 1,000 rounds by default, so MySQL raises the bound for the
    /// statement and MariaDB reads its sequence engine instead.
    fn row_source_sql(&self, rows: u64) -> String {
        match S::FLAVOUR {
            MysqlFlavour::Mysql => format!(
                "WITH RECURSIVE source (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM source WHERE n < {rows}) \
                 SELECT /*+ SET_VAR(cte_max_recursion_depth = {rows}) */ n FROM source LIMIT {rows}"
            ),
            MysqlFlavour::Mariadb => format!("SELECT seq AS n FROM seq_1_to_{rows} LIMIT {rows}"),
        }
    }
}

#[async_trait]
impl<S: Server> NetworkConformanceEngine for MySqlEngine<S> {
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
            "SELECT COUNT(*) FROM information_schema.PROCESSLIST \
             WHERE INFO LIKE '%{marker}%' AND ID <> CONNECTION_ID()"
        )
    }
}

impl<S: Server> PooledConformanceEngine for MySqlEngine<S> {
    const WORKSPACE_POOL_MAX_SIZE: usize = WORKSPACE_POOL_MAX_SIZE;
}

impl<S: Server> EditorTransactionEngine for MySqlEngine<S> {
    fn begin_sql(&self) -> String {
        "BEGIN".to_owned()
    }

    fn commit_sql(&self) -> String {
        "COMMIT".to_owned()
    }
}

impl<S: Server> TypedConformanceEngine for MySqlEngine<S> {
    fn unsupported_type_cases(&self) -> Vec<UnsupportedTypeCase> {
        let case = |declaration: &str, value: &str| UnsupportedTypeCase {
            setup_sql: Vec::new(),
            declaration: declaration.to_owned(),
            insert_value_sql: value.to_owned(),
        };
        let mut cases = vec![
            case("v geometry", "ST_GeomFromText('POINT(1 2)')"),
            case("v set('a', 'b')", "'a,b'"),
            case("v bit(10)", "b'1010101010'"),
            case("v year", "2024"),
        ];
        if S::FLAVOUR == MysqlFlavour::Mariadb {
            cases.push(case("v inet6", "'::1'"));
            cases.push(case("v uuid", "'123e4567-e89b-12d3-a456-426614174000'"));
        }
        cases
    }
}

impl<S: Server> ConformanceDdlEngine for MySqlEngine<S> {
    fn integer_type(&self) -> &'static str {
        "int"
    }

    fn text_type(&self) -> &'static str {
        "varchar(255)"
    }

    fn timestamp_type(&self) -> &'static str {
        "datetime"
    }

    fn current_timestamp_expression(&self) -> &'static str {
        "CURRENT_TIMESTAMP"
    }
}

/// MariaDB's `max_statement_time` stops a CREATE ... SELECT as it stops a
/// SELECT. MySQL's `max_execution_time` bounds only read-only SELECTs, so
/// it has no bounded DDL to lift and runs without this case.
impl BoundedDdlEngine for MySqlEngine<Mariadb114> {
    fn schema_change_exceeding_sql(&self, table: &TableRef, duration: Duration) -> String {
        format!(
            "CREATE TABLE {} AS SELECT SLEEP({}) AS id",
            qualified(table),
            duration.as_secs_f64()
        )
    }
}

mod mysql_suite {
    use super::{MySqlEngine, Mysql84};

    tablepro_test_support::connection_conformance_suite! {
        engine: MySqlEngine<Mysql84>,
        docker: true,
        endpoint: network,
        pool: pooled,
        editor_transactions: true,
        unsupported_types: true,
        bounded_ddl: false,
    }

    tablepro_test_support::ddl_conformance_suite! {
        engine: MySqlEngine<Mysql84>,
        docker: true,
    }
}

mod mariadb_suite {
    use super::{Mariadb114, MySqlEngine};

    tablepro_test_support::connection_conformance_suite! {
        engine: MySqlEngine<Mariadb114>,
        docker: true,
        endpoint: network,
        pool: pooled,
        editor_transactions: true,
        unsupported_types: true,
        bounded_ddl: true,
    }

    tablepro_test_support::ddl_conformance_suite! {
        engine: MySqlEngine<Mariadb114>,
        docker: true,
    }
}
