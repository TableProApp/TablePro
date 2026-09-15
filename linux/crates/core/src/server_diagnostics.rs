use std::fmt;

/// What the server said about a statement, in the shape that server
/// says it.
///
/// Every engine numbers its own errors, and the number is what tells a
/// missing password apart from a missing table. Flattening them into
/// one string loses that, so each engine's own form is kept.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ServerCode {
    SqlState(String),
    MySql { number: u16, sqlstate: Option<String> },
    Tds { number: u32, state: u8, class: u8 },
    ClickHouse { code: i32 },
    Sqlite { primary: i32, extended: i32 },
}

impl ServerCode {
    /// The five-character SQLSTATE, where the engine has one.
    pub fn sqlstate(&self) -> Option<&str> {
        match self {
            Self::SqlState(state) => Some(state),
            Self::MySql { sqlstate, .. } => sqlstate.as_deref(),
            _ => None,
        }
    }
}

impl fmt::Display for ServerCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::SqlState(state) => f.write_str(state),
            Self::MySql { number, .. } => write!(f, "{number}"),
            Self::Tds { number, .. } => write!(f, "{number}"),
            Self::ClickHouse { code } => write!(f, "{code}"),
            Self::Sqlite { extended, .. } => write!(f, "{extended}"),
        }
    }
}

/// A server's own report of what went wrong.
///
/// The fields past `message` are the ones PostgreSQL sends and the
/// other engines mostly leave empty. They are what turns "syntax error"
/// into a caret under the word that caused it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ServerDiagnostics {
    pub code: Option<ServerCode>,
    pub severity: Option<String>,
    pub message: String,
    pub detail: Option<String>,
    pub hint: Option<String>,
    pub position: Option<u32>,
    pub where_context: Option<String>,
    pub schema: Option<String>,
    pub table: Option<String>,
    pub column: Option<String>,
    pub constraint: Option<String>,
}

impl ServerDiagnostics {
    pub fn new(code: Option<ServerCode>, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            ..Self::default()
        }
    }

    pub fn sqlstate(&self) -> Option<&str> {
        self.code.as_ref().and_then(ServerCode::sqlstate)
    }
}

impl fmt::Display for ServerDiagnostics {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.code {
            Some(code) => write!(f, "{} ({code})", self.message),
            None => f.write_str(&self.message),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mysql_code_carries_both_numbers() {
        let code = ServerCode::MySql {
            number: 1045,
            sqlstate: Some("28000".to_owned()),
        };

        assert_eq!(code.to_string(), "1045");
        assert_eq!(code.sqlstate(), Some("28000"));
    }

    #[test]
    fn a_code_without_a_sqlstate_reports_none() {
        assert_eq!(ServerCode::ClickHouse { code: 192 }.sqlstate(), None);
        assert_eq!(
            ServerCode::Sqlite {
                primary: 1,
                extended: 1
            }
            .sqlstate(),
            None
        );
    }

    #[test]
    fn diagnostics_read_as_the_message_and_the_code() {
        let diagnostics = ServerDiagnostics::new(Some(ServerCode::SqlState("42P01".to_owned())), "no such table");

        assert_eq!(diagnostics.to_string(), "no such table (42P01)");
        assert_eq!(diagnostics.sqlstate(), Some("42P01"));
    }
}
