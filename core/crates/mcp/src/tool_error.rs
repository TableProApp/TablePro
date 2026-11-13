use rmcp::model::{CallToolResult, ContentBlock};
use tablepro_core::DriverError;
use tablepro_core::masking::{may_repeat_a_value, server_code};
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

    // On a connection with masking rules a server's message can repeat a value the statement read, so a client gets
    // its code alone.
    pub fn from_driver_masked(error: &DriverError, masks_values: bool) -> Self {
        if !masks_values || !may_repeat_a_value(error) {
            return Self::from_driver(error);
        }
        let reason =
            "TablePro withholds its message because this connection masks values and the message can repeat one";
        Self::QueryFailed(match server_code(error) {
            Some(code) => format!("the server refused the statement with code {code}; {reason}"),
            None => format!("the server refused the statement; {reason}"),
        })
    }

    pub fn from_operation_masked(error: &OperationError, masks_values: bool) -> Self {
        match error {
            OperationError::Driver(driver) => Self::from_driver_masked(driver, masks_values),
            other => Self::from_operation(other),
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
    fn a_server_s_message_is_withheld_only_where_values_are_masked() {
        let refused = DriverError::Server(Box::new(tablepro_core::ServerDiagnostics::new(
            Some(tablepro_core::ServerCode::SqlState("22P02".to_owned())),
            r#"invalid input syntax for type integer: "ann@example.com""#,
        )));

        let masked = ToolError::from_driver_masked(&refused, true);
        let plain = ToolError::from_driver_masked(&refused, false);

        assert_eq!(masked.code(), "query_failed");
        assert!(masked.message().contains("22P02"), "{}", masked.message());
        assert!(!masked.message().contains("ann@example.com"), "{}", masked.message());
        assert!(plain.message().contains("ann@example.com"));
        assert_eq!(
            ToolError::from_driver_masked(&DriverError::Cancelled, true).code(),
            "user_cancelled"
        );
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
