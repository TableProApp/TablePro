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
    #[error("{service} did not accept connections within {seconds} seconds")]
    NotReady { service: &'static str, seconds: u64 },
}
