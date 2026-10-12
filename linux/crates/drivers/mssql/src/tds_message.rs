use tablepro_core::{ServerCode, ServerDiagnostics};
use tiberius::error::TokenError;

/// An ERROR token as the server sent it.
///
/// tiberius gives `TokenError` no public constructor, so the mapping is
/// written against this copy and can be tested without a server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TdsMessage {
    pub(crate) number: u32,
    pub(crate) state: u8,
    pub(crate) class: u8,
    pub(crate) message: String,
    pub(crate) procedure: String,
    pub(crate) line: u32,
}

impl TdsMessage {
    pub(crate) fn diagnostics(&self) -> ServerDiagnostics {
        ServerDiagnostics {
            code: Some(ServerCode::Tds {
                number: self.number,
                state: self.state,
                class: self.class,
            }),
            severity: Some(self.class.to_string()),
            message: self.message.clone(),
            detail: (self.line > 0).then(|| format!("line {}", self.line)),
            where_context: (!self.procedure.is_empty()).then(|| self.procedure.clone()),
            ..ServerDiagnostics::default()
        }
    }
}

impl From<&TokenError> for TdsMessage {
    fn from(token: &TokenError) -> Self {
        Self {
            number: token.code(),
            state: token.state(),
            class: token.class(),
            message: token.message().to_owned(),
            procedure: token.procedure().to_owned(),
            line: token.line(),
        }
    }
}
