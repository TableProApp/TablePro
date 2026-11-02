//! The keyspace conformance suite against Redis.

use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::meta::KeyKind;
use tablepro_core::{
    ConnectOptions, DatabaseDriver, LivenessPolicy, NetworkEndpoint, TlsConfig, Value, WorkspaceSettings,
};
use tablepro_driver_redis::RedisDriver;
use tablepro_test_fixtures::RedisFixture;
use tablepro_test_support::FaultTransport;
use tablepro_test_support::conformance::{ConformanceFailure, KeyspaceEngine, test_liveness};
use tokio_util::sync::CancellationToken;

use crate::support::{direct, editor, options_over, password, rows, run};

/// How many arguments one filling command carries.
const CHUNK: u32 = 100;

pub struct RedisEngine {
    fixture: RedisFixture,
}

#[async_trait]
impl KeyspaceEngine for RedisEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(RedisDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let fixture = RedisFixture::start().await.map_err(ConformanceFailure::setup)?;
        Ok(Self { fixture })
    }

    fn connect_options(&self, settings: WorkspaceSettings, liveness: LivenessPolicy) -> ConnectOptions {
        options_over(
            direct(self.fixture.host(), self.fixture.port(), &liveness),
            password(&self.fixture.password_credentials()),
            None,
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
            None,
            TlsConfig::disabled(),
            settings,
            liveness,
        );
        Ok((options, fault))
    }

    fn fill_commands(&self, key: &str, kind: KeyKind, entries: u32) -> String {
        if kind == KeyKind::String {
            return format!("SET {key} {}", "x".repeat(entries as usize));
        }
        if kind == KeyKind::Stream {
            return (0..entries)
                .map(|entry| format!("XADD {key} * field {entry}"))
                .collect::<Vec<_>>()
                .join("\n");
        }
        let (command, entry): (&str, fn(u32) -> String) = match kind {
            KeyKind::Hash => ("HSET", |n| format!("field{n} value{n}")),
            KeyKind::List => ("RPUSH", |n| format!("element{n}")),
            KeyKind::Set => ("SADD", |n| format!("member{n}")),
            _ => ("ZADD", |n| format!("{n} member{n}")),
        };
        (0..entries)
            .collect::<Vec<_>>()
            .chunks(CHUNK as usize)
            .map(|chunk| {
                let arguments: Vec<String> = chunk.iter().map(|&n| entry(n)).collect();
                format!("{command} {key} {}", arguments.join(" "))
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn blocking_command(&self, key: &str) -> String {
        format!("BLPOP {key} 0")
    }

    fn write_command(&self, key: &str) -> String {
        format!("SET {key} written")
    }

    fn read_all_command(&self, key: &str) -> String {
        format!("LRANGE {key} 0 -1")
    }

    /// Asked on a connection of its own, which `INFO clients` answers
    /// with the count of clients waiting on a key.
    async fn blocked_commands(&self) -> Result<u64, ConformanceFailure> {
        let options = self.connect_options(WorkspaceSettings::workspace(false), test_liveness());
        let connection = RedisDriver.connect(options, CancellationToken::new()).await?;
        let session = editor(connection.as_ref()).await;
        let (_, events) = run(session.as_ref(), "INFO clients").await;
        session.close().await;
        connection.close().await?;
        let info = match rows(&events).first().and_then(|row| row.first()) {
            Some(Value::Text(info)) => info.clone(),
            other => return Err(ConformanceFailure::setup(format!("INFO clients gave {other:?}"))),
        };
        info.lines()
            .find_map(|line| line.trim().strip_prefix("blocked_clients:"))
            .and_then(|count| count.trim().parse().ok())
            .ok_or_else(|| ConformanceFailure::setup(format!("INFO clients gave no blocked_clients: {info}")))
    }
}

mod suite {
    use super::RedisEngine;

    tablepro_test_support::keyspace_conformance_suite! {
        engine: RedisEngine,
    }
}
