use std::process::ExitStatus;

#[derive(Debug, thiserror::Error)]
pub enum FixtureError {
    #[error(transparent)]
    Container(#[from] testcontainers::TestcontainersError),
    #[error(transparent)]
    Certificate(#[from] rcgen::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("{program} exited with {status}: {stderr}")]
    HostCommand {
        program: &'static str,
        status: ExitStatus,
        stderr: String,
    },
    #[error("{variable}={value} names no release a fixture pins; it pins {known}")]
    UnknownRelease {
        variable: &'static str,
        value: String,
        known: String,
    },
    #[error("{service} did not accept connections within {seconds} seconds")]
    NotReady { service: &'static str, seconds: u64 },
    #[error("{service} came back on host port {after}, not {before}")]
    PortMoved {
        service: &'static str,
        before: u16,
        after: u16,
    },
    #[error("{service}'s cqlsh refused {statements:?}: {output}")]
    Cql {
        service: &'static str,
        statements: String,
        output: String,
    },
    #[error("{service} was not ready: {reason}; last reply: {last_reply}; container {state}\n{logs}")]
    ContainerNotReady {
        service: &'static str,
        reason: String,
        last_reply: String,
        state: String,
        logs: String,
    },
}
