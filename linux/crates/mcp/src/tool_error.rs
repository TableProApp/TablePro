use rmcp::model::{CallToolResult, ContentBlock};
use tablepro_core::DriverError;
use tablepro_session::OperationError;

/// Why a tool did not do what it was asked. It reaches the client as a
/// tool result with `isError` set, text first with a code a client can
/// match on, because a client renders a protocol error without its
/// message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolError {
    InvalidArgument(String),
    NotFound(String),
    NotConnected(String),
    /// The user's settings refuse it; asking again gets the same answer.
    Denied(String),
    /// The user said no in the app.
    UserCancelled(String),
    Timeout(String),
    QueryFailed(String),
    Unsupported(String),
    Internal(String),
}

impl ToolError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::InvalidArgument(_) => "invalid_argument",
            Self::NotFound(_) => "not_found",
            Self::NotConnected(_) => "not_connected",
            Self::Denied(_) => "denied",
            Self::UserCancelled(_) => "user_cancelled",
            Self::Timeout(_) => "timeout",
            Self::QueryFailed(_) => "query_failed",
            Self::Unsupported(_) => "unsupported",
            Self::Internal(_) => "internal_failure",
        }
    }

    pub fn message(&self) -> &str {
        match self {
            Self::InvalidArgument(message)
            | Self::NotFound(message)
            | Self::NotConnected(message)
            | Self::Denied(message)
            | Self::UserCancelled(message)
            | Self::Timeout(message)
            | Self::QueryFailed(message)
            | Self::Unsupported(message)
            | Self::Internal(message) => message,
        }
    }

    pub fn into_result(self) -> CallToolResult {
        CallToolResult::error(vec![ContentBlock::text(format!("{}: {}", self.code(), self.message()))])
    }

    pub fn from_driver(error: &DriverError) -> Self {
        match error {
            DriverError::Timeout { .. } => Self::Timeout(error.to_string()),
            DriverError::Cancelled => Self::UserCancelled("the request was cancelled".to_owned()),
            DriverError::ConnectionLost { .. } | DriverError::Transport(_) => Self::NotConnected(error.to_string()),
            _ => Self::QueryFailed(error.to_string()),
        }
    }

    pub fn from_operation(error: &OperationError) -> Self {
        match error {
            OperationError::Driver(driver) => Self::from_driver(driver),
            OperationError::Cancelled => Self::UserCancelled("the request was cancelled".to_owned()),
            OperationError::Closed => Self::NotConnected("the connection was closed in TablePro".to_owned()),
            OperationError::Panicked(_) => Self::Internal("TablePro failed while running the request".to_owned()),
            OperationError::Sql(_) | OperationError::Browse(_) | OperationError::Build(_) => {
                Self::InvalidArgument(error.to_string())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_text_starts_with_the_code() {
        let result = ToolError::Denied("read only".to_owned()).into_result();

        assert_eq!(result.is_error, Some(true));
        let text = serde_json::to_string(&result.content).expect("JSON");
        assert!(text.contains("denied: read only"), "{text}");
    }

    #[test]
    fn a_closed_session_reads_as_not_connected() {
        assert_eq!(
            ToolError::from_operation(&OperationError::Closed).code(),
            "not_connected"
        );
        assert_eq!(
            ToolError::from_operation(&OperationError::Driver(DriverError::Cancelled)).code(),
            "user_cancelled"
        );
    }
}
