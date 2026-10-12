//! A conformance engine over the fakes, so the cases themselves can be
//! tested: each scenario scripts one way a driver can break a rule.

use std::marker::PhantomData;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{
    ConnectEnvironment, ConnectOptions, ConnectTarget, DatabaseDriver, DriverCapabilities, FileEndpoint,
    LivenessPolicy, TableRef, WorkspaceSettings, WriteReport,
};

use crate::conformance::{ConformanceEngine, ConformanceFailure, PooledConformanceEngine};
use crate::{ConnectionScript, FakeDriver, FakeReply};

pub(crate) trait FakeScenario: Send + Sync + 'static {
    fn capabilities() -> &'static DriverCapabilities {
        &FakeDriver::NETWORK_CAPABILITIES
    }

    fn script() -> ConnectionScript;
}

pub(crate) struct FakeEngine<S>(PhantomData<fn() -> S>);

impl<S> FakeEngine<S> {
    /// Answers the setup every case does, so a scenario scripts only the
    /// call it is about.
    pub(crate) fn base_script() -> ConnectionScript {
        let mut script = ConnectionScript::default();
        script.probe.always(FakeReply::ok(()));
        script
            .write_batch
            .when_sql_contains("CREATE TABLE", FakeReply::ok(WriteReport::new(vec![None])));
        script
    }
}

#[async_trait]
impl<S: FakeScenario> ConformanceEngine for FakeEngine<S> {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(FakeDriver::connecting(S::capabilities(), S::script()))
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        Ok(Self(PhantomData))
    }

    fn connect_options(&self, settings: WorkspaceSettings, liveness: LivenessPolicy) -> ConnectOptions {
        ConnectOptions {
            target: ConnectTarget::File(FileEndpoint::open_existing(PathBuf::from("/fake.db")).unwrap()),
            workspace_settings: settings,
            liveness,
            environment: ConnectEnvironment::new("test"),
        }
    }

    fn scratch_table(&self, name: &str) -> TableRef {
        TableRef::unqualified(name)
    }

    fn create_scratch_table_sql(&self, table: &TableRef) -> String {
        format!(
            "CREATE TABLE {} (id integer primary key, label text not null)",
            table.name
        )
    }

    fn unbounded_statement_sql(&self, marker: &str) -> String {
        format!("UNBOUNDED {marker}")
    }

    async fn blocking_statement_sql(&self, marker: &str, hold: Duration) -> Result<String, ConformanceFailure> {
        Ok(format!("BLOCK {marker} {}", hold.as_secs()))
    }

    fn row_source_sql(&self, rows: u64) -> String {
        format!("ROWS {rows}")
    }
}

impl<S: FakeScenario> PooledConformanceEngine for FakeEngine<S> {
    const WORKSPACE_POOL_MAX_SIZE: usize = 2;
}
