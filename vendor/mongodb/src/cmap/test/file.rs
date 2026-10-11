use std::{sync::Arc, time::Duration};

use serde::Deserialize;

use super::State;
use crate::{
    cmap::options::ConnectionPoolOptions,
    error::Result,
    event::cmap::CmapEvent,
    serde_util,
    test::{
        get_topology,
        log_uncaptured,
        server_version_matches,
        util::fail_point::FailPoint,
        Serverless,
        Topology,
    },
};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TestFile {
    #[serde(rename = "version")]
    _version: u8, // can ignore this field as there's only one version
    #[serde(rename = "style")]
    _style: TestStyle, // we use the presence of fail_point / run_on to determine this
    pub(super) description: String,
    pub(super) pool_options: Option<ConnectionPoolOptions>,
    pub(super) operations: Vec<ThreadedOperation>,
    pub(super) error: Option<Error>,
    pub(super) events: Vec<CmapEvent>,
    #[serde(default)]
    pub(super) ignore: Vec<String>,
    pub(super) fail_point: Option<FailPoint>,
    pub(super) run_on: Option<Vec<RunOn>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct RunOn {
    pub(super) min_server_version: Option<String>,
    pub(super) max_server_version: Option<String>,
    pub(super) topology: Option<Vec<Topology>>,
    pub(super) serverless: Option<Serverless>,
}

impl RunOn {
    pub(super) async fn can_run_on(&self) -> bool {
        if let Some(ref min_version) = self.min_server_version {
            if !server_version_matches(&format!(">= {min_version}")).await {
                log_uncaptured(format!(
                    "runOn mismatch: required server version >= {min_version}",
                ));
                return false;
            }
        }
        if let Some(ref max_version) = self.max_server_version {
            if !server_version_matches(&format!("<= {max_version}")).await {
                log_uncaptured(format!(
                    "runOn mismatch: required server version <= {max_version}",
                ));
                return false;
            }
        }
        if let Some(ref topology) = self.topology {
            let actual_topology = get_topology().await;
            if !topology.contains(actual_topology) {
                log_uncaptured(format!(
                    "runOn mismatch: required topology in {topology:?}, got {actual_topology:?}"
                ));
                return false;
            }
        }
        if let Some(ref serverless) = self.serverless {
            if !serverless.can_run() {
                log_uncaptured(format!(
                    "runOn mismatch: required serverless {serverless:?}"
                ));
                return false;
            }
        }
        true
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
enum TestStyle {
    Unit,
    Integration,
}

#[derive(Debug, Deserialize)]
pub struct ThreadedOperation {
    #[serde(flatten)]
    type_: Operation,

    thread: Option<String>,
}

impl ThreadedOperation {
    pub(super) async fn execute(self, state: Arc<State>) -> Result<()> {
        match self.thread {
            Some(thread_name) => {
                let threads = state.threads.read().await;
                let thread = threads.get(&thread_name).unwrap();
                thread.dispatcher.send(self.type_).unwrap();
                Ok(())
            }
            None => self.type_.execute(state).await,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "name")]
#[serde(rename_all = "camelCase")]
pub enum Operation {
    Start {
        target: String,
    },
    Wait {
        ms: u64,
    },
    WaitForThread {
        target: String,
    },
    WaitForEvent {
        event: String,
        count: usize,
        #[serde(deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis")]
        #[serde(default)]
        timeout: Option<Duration>,
    },
    CheckOut {
        label: Option<String>,
    },
    CheckIn {
        connection: String,
    },
    #[serde(rename_all = "camelCase")]
    Clear {
        #[serde(default)]
        interrupt_in_use_connections: Option<bool>,
    },
    Close,
    Ready,
}

#[derive(Debug, Deserialize)]
// TODO RUST-1077: remove the #[allow(dead_code)] tag and add #[serde(deny_unknown_fields)] to
// ensure these tests are being fully run
#[allow(dead_code)]
pub struct Error {
    #[serde(rename = "type")]
    pub type_: String,
    message: String,
    address: Option<String>,
}
