//! The document conformance suite against a MongoDB replica set, once
//! over a direct route, where the client library dials the server, and
//! once over an SSH-style forward, where the driver's relay carries every
//! read, save and stop.

use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    ConnectOptions, DatabaseDriver, LivenessPolicy, NetworkEndpoint, RunEnd, TlsConfig, Transport, TransportError,
    TransportKind, TransportRoute, TransportStream, Value, WorkspaceSettings,
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

impl MongoEngine {
    fn options(
        &self,
        transport: Arc<dyn Transport>,
        settings: WorkspaceSettings,
        liveness: LivenessPolicy,
    ) -> ConnectOptions {
        options_over(
            transport,
            password(&self.fixture.password_credentials()),
            TlsConfig::disabled(),
            settings,
            liveness,
        )
    }

    fn fault(&self, liveness: &LivenessPolicy) -> Result<Arc<FaultTransport>, ConformanceFailure> {
        let endpoint =
            NetworkEndpoint::new(self.fixture.host(), self.fixture.port()).map_err(ConformanceFailure::setup)?;
        Ok(Arc::new(
            FaultTransport::direct(endpoint, liveness).map_err(ConformanceFailure::setup)?,
        ))
    }
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
        let transport = direct(self.fixture.host(), self.fixture.port(), &liveness);
        self.options(transport, settings, liveness)
    }

    async fn faulty_connect_options(
        &self,
        settings: WorkspaceSettings,
        liveness: LivenessPolicy,
    ) -> Result<(ConnectOptions, Arc<FaultTransport>), ConformanceFailure> {
        let fault = self.fault(&liveness)?;
        Ok((self.options(fault.clone(), settings, liveness), fault))
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

/// An SSH forward as the driver sees one: a socket route, so the driver
/// relays, and streams it opens itself, through a `FaultTransport` a case
/// can drop.
#[derive(Debug)]
struct Forward(Arc<FaultTransport>);

#[async_trait]
impl Transport for Forward {
    fn service_endpoint(&self) -> &NetworkEndpoint {
        self.0.service_endpoint()
    }

    fn kind(&self) -> TransportKind {
        TransportKind::SshForward {
            destination: "bastion.tablepro.test".to_owned(),
        }
    }

    fn route(&self) -> TransportRoute {
        self.0.route()
    }

    async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
        self.0.open().await
    }

    async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
        self.0.reroute(endpoint).await
    }

    async fn explain_closed_stream(&self) -> Option<TransportError> {
        self.0.explain_closed_stream().await
    }
}

/// The same server through a forward, as a connection through an SSH
/// tunnel reaches it. The server's own list of operations is still read
/// over the direct route.
pub struct MongoForwardEngine(MongoEngine);

#[async_trait]
impl DocumentEngine for MongoForwardEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        MongoEngine::driver()
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        MongoEngine::start().await.map(Self)
    }

    fn connect_options(&self, settings: WorkspaceSettings, liveness: LivenessPolicy) -> ConnectOptions {
        let fault = self.0.fault(&liveness).expect("a forward to the fixture");
        self.0.options(Arc::new(Forward(fault)), settings, liveness)
    }

    async fn faulty_connect_options(
        &self,
        settings: WorkspaceSettings,
        liveness: LivenessPolicy,
    ) -> Result<(ConnectOptions, Arc<FaultTransport>), ConformanceFailure> {
        let fault = self.0.fault(&liveness)?;
        let options = self.0.options(Arc::new(Forward(fault.clone())), settings, liveness);
        Ok((options, fault))
    }

    fn database(&self) -> &str {
        self.0.database()
    }

    fn fill_statements(&self, collection: &str, documents: u32) -> String {
        self.0.fill_statements(collection, documents)
    }

    fn unbounded_statement(&self, collection: &str, marker: &str) -> String {
        self.0.unbounded_statement(collection, marker)
    }

    fn writing_read(&self, collection: &str, target: &str) -> String {
        self.0.writing_read(collection, target)
    }

    async fn running_operations(&self, marker: &str) -> Result<u64, ConformanceFailure> {
        self.0.running_operations(marker).await
    }
}

mod suite {
    use super::MongoEngine;

    tablepro_test_support::document_conformance_suite! {
        engine: MongoEngine,
    }
}

mod forwarded {
    use super::MongoForwardEngine;

    tablepro_test_support::document_conformance_suite! {
        engine: MongoForwardEngine,
    }
}
