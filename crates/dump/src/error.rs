#[derive(Debug, thiserror::Error)]
pub enum DumpError {
    #[error("{tool} was not found; install it or choose its location")]
    ToolMissing { tool: String },
    #[error("{tool} reported a version BookiE cannot read")]
    ToolVersionUnknown { tool: String },
    #[error("{tool} {tool_major} is older than the server ({server_major}); install a newer client")]
    ToolTooOld {
        tool: String,
        tool_major: u32,
        server_major: u32,
    },
    #[error("{tool} {tool_major} is newer than the server ({server_major}); install the matching client")]
    ToolTooNew {
        tool: String,
        tool_major: u32,
        server_major: u32,
    },
    #[error("this connection cannot be used for a backup or restore: {0}")]
    Unsupported(&'static str),
    #[error("the backup file location must be an absolute path")]
    PathNotAbsolute,
    #[error("the operation was cancelled")]
    Cancelled,
    #[error("{tool} failed{}: {stderr}", status.map(|code| format!(" with exit code {code}")).unwrap_or_default())]
    Failed {
        tool: String,
        status: Option<i32>,
        stderr: String,
    },
    #[error("backup file error: {0}")]
    Io(#[from] std::io::Error),
}
