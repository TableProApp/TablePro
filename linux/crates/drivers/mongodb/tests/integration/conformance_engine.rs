//! The document conformance suite against a MongoDB replica set.

use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    ConnectOptions, DatabaseDriver, LivenessPolicy, NetworkEndpoint, RunEnd, TlsConfig, Value, WorkspaceSettings,
};
use tablepro_driver_mongodb::MongoDriver;
use tablepro_test_fixtures::MongoFixture;
use tablepro_test_support::FaultTransport;
use tablepro_test_support::conformance::{ConformanceFailure, DocumentEngine, test_liveness};
use tokio_util::sync::CancellationToken;

use crate::support::{DATABASE, direct, editor, options_over, password, rows, run};

/// How many documents one filling statement inserts.
const CHUNK: u32 = 500;

pub struct MongoEngine {
    fixture: MongoFixture,
}

#[async_trait]
impl DocumentEngine for MongoEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(MongoDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let fixture = MongoFixture::start().await.map_err(ConformanceFailure::setup)?;
        Ok(Self { fixture })
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

    fn database(&self) -> &str {
        DATABASE
    }

    fn fill_statements(&self, collection: &str, documents: u32) -> String {
        (1..=documents)
            .collect::<Vec<_>>()
            .chunks(CHUNK as usize)
            .map(|chunk| {
                let documents: Vec<String> = chunk
                    .iter()
                    .map(|n| format!("{{_id: {n}, label: 'row {n}', nested: {{n: {n}}}}}"))
                    .collect();
                format!(
                    "db.getCollection('{collection}').insertMany([{}])",
                    documents.join(", ")
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// Server-side JavaScript that sleeps a second for each document, so
    /// the read outlasts any case.
    fn unbounded_statement(&self, collection: &str, marker: &str) -> String {
        format!("db.getCollection('{collection}').find({{$where: 'sleep(1000) || true'}}).comment('{marker}')")
    }

    fn writing_read(&self, collection: &str, target: &str) -> String {
        format!("db.getCollection('{collection}').aggregate([{{$match: {{}}}}, {{$out: '{target}'}}])")
    }

    /// Counted by `$currentOp` on a connection of its own.
    async fn running_operations(&self, marker: &str) -> Result<u64, ConformanceFailure> {
        let options = self.connect_options(WorkspaceSettings::workspace(false), test_liveness());
        let connection = MongoDriver.connect(options, CancellationToken::new()).await?;
        let session = editor(connection.as_ref()).await;
        let (summary, events) = run(
            session.as_ref(),
            &format!(
                "db.getSiblingDB('admin').aggregate([{{$currentOp: {{allUsers: true}}}}, \
                 {{$match: {{'command.comment': '{marker}'}}}}, {{$count: 'n'}}])"
            ),
        )
        .await;
        session.close().await;
        connection.close().await?;
        if summary.end != RunEnd::Completed {
            return Err(ConformanceFailure::setup(format!("$currentOp ended {:?}", summary.end)));
        }
        match rows(&events).first().and_then(|row| row.first()) {
            None => Ok(0),
            Some(Value::Int(count)) => u64::try_from(*count).map_err(ConformanceFailure::setup),
            Some(other) => Err(ConformanceFailure::setup(format!("$currentOp counted {other:?}"))),
        }
    }
}

mod suite {
    use super::MongoEngine;

    tablepro_test_support::document_conformance_suite! {
        engine: MongoEngine,
    }
}
