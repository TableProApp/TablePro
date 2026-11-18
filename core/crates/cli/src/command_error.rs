use std::io;

use crate::exit::Exit;
use crate::host::{HostError, Places};

// core/crates/mcp/src/tool_error.rs: a failed tool answers "<code>: <message>".
const TOOL_CODES: [&str; 9] = [
    "invalid_argument",
    "not_found",
    "not_connected",
    "denied",
    "user_cancelled",
    "timeout",
    "query_failed",
    "unsupported",
    "internal_failure",
];

#[derive(Debug, thiserror::Error)]
pub(crate) enum CommandError {
    #[error("{0}")]
    Usage(String),
    #[error("Files and links open in TablePro itself: run tablepro with them and no command.")]
    OpensInApp,
    #[error("TablePro is not running. Start it, then run the command again.")]
    NotRunning,
    #[error("{}", server_off(Places::PREFERENCES))]
    ServerOff,
    #[error("{}", no_token(Places::PREFERENCES))]
    NoToken,
    #[error("{}", not_answering(*.port, Places::PREFERENCES))]
    NotAnswering { port: u16 },
    #[error(
        "The MCP token changed while the command ran. Run it again; if it keeps failing, another program answers on port {port}."
    )]
    TokenRefused { port: u16 },
    #[error("Port {port} is answered by a program that is not TablePro.")]
    NotTablePro { port: u16 },
    #[error("The request to TablePro failed: {0}")]
    Transport(String),
    #[error("TablePro did not answer within {seconds} seconds.")]
    NoAnswer { seconds: u64 },
    #[error(
        "TablePro's answer is larger than the {mebibytes} MiB this command reads. Ask for fewer rows with --limit."
    )]
    AnswerTooLarge { mebibytes: usize },
    #[error("{message}")]
    Tool { code: String, message: String },
    #[error("No connection named “{0}” is open to the tablepro command. Run tablepro connections to list them.")]
    UnknownConnection(String),
    #[error("{} connections are named “{name}”. Pass one of their ids: {}.", .ids.len(), .ids.join(", "))]
    AmbiguousConnection { name: String, ids: Vec<String> },
    #[error("“{0}” is not open in TablePro. Open it there, or run the command in a terminal to have it opened.")]
    NotOpen(String),
    #[error("“{0}” did not open in TablePro within 5 minutes.")]
    OpenTimedOut(String),
    #[error("TablePro sent an answer this command cannot read: {0}")]
    Answer(String),
    #[error(transparent)]
    Host(#[from] HostError),
    #[error("Could not start: {0}")]
    Runtime(String),
    #[error("Could not write the output: {0}")]
    Output(#[source] io::Error),
}

impl CommandError {
    pub(crate) fn from_tool_text(text: &str) -> Self {
        match text.split_once(": ") {
            Some((code, message)) if TOOL_CODES.contains(&code) => Self::Tool {
                code: code.to_owned(),
                message: message.to_owned(),
            },
            _ => Self::Tool {
                code: "unknown".to_owned(),
                message: text.to_owned(),
            },
        }
    }

    // As the app the command came with names its settings and its secret store.
    pub(crate) fn message(&self, places: Places) -> String {
        match self {
            Self::ServerOff => server_off(places),
            Self::NoToken => no_token(places),
            Self::NotAnswering { port } => not_answering(*port, places),
            Self::Host(error) => error.message(places),
            other => other.to_string(),
        }
    }

    pub(crate) fn code(&self) -> &str {
        match self {
            Self::Usage(_) => "cli.usage",
            Self::OpensInApp => "cli.opens_in_app",
            Self::NotRunning => "cli.not_running",
            Self::ServerOff => "cli.server_off",
            Self::NoToken => "cli.no_token",
            Self::NotAnswering { .. } => "cli.not_answering",
            Self::TokenRefused { .. } => "cli.token_refused",
            Self::NotTablePro { .. } => "cli.not_tablepro",
            Self::Transport(_) => "cli.transport",
            Self::NoAnswer { .. } => "cli.no_answer",
            Self::AnswerTooLarge { .. } => "cli.answer_too_large",
            Self::Tool { code, .. } => code,
            Self::UnknownConnection(_) => "cli.unknown_connection",
            Self::AmbiguousConnection { .. } => "cli.ambiguous_connection",
            Self::NotOpen(_) => "cli.not_open",
            Self::OpenTimedOut(_) => "cli.open_timed_out",
            Self::Answer(_) => "cli.unreadable_answer",
            Self::Host(error) => error.code(),
            Self::Runtime(_) => "cli.runtime",
            Self::Output(_) => "cli.output",
        }
    }

    pub(crate) fn exit(&self) -> Exit {
        match self {
            Self::Usage(_) | Self::OpensInApp | Self::UnknownConnection(_) | Self::AmbiguousConnection { .. } => {
                Exit::Usage
            }
            Self::ServerOff | Self::TokenRefused { .. } => Exit::Refused,
            Self::NoAnswer { .. } => Exit::TimedOut,
            Self::Tool { code, .. } => match code.as_str() {
                "invalid_argument" => Exit::Usage,
                "denied" | "user_cancelled" => Exit::Refused,
                "timeout" => Exit::TimedOut,
                _ => Exit::Failure,
            },
            Self::NotRunning
            | Self::NoToken
            | Self::NotAnswering { .. }
            | Self::NotTablePro { .. }
            | Self::Transport(_)
            | Self::AnswerTooLarge { .. }
            | Self::NotOpen(_)
            | Self::OpenTimedOut(_)
            | Self::Answer(_)
            | Self::Host(_)
            | Self::Runtime(_)
            | Self::Output(_) => Exit::Failure,
        }
    }
}

fn server_off(places: Places) -> String {
    format!(
        "TablePro's MCP server is off. Turn on {} > Enable MCP Server, then run the command again.",
        places.mcp_settings
    )
}

fn no_token(places: Places) -> String {
    format!(
        "TablePro's MCP server has not started. {} shows why.",
        places.mcp_settings
    )
}

fn not_answering(port: u16, places: Places) -> String {
    format!(
        "TablePro's MCP server does not answer on port {port}. {} shows why.",
        places.mcp_settings
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const SETTINGS: Places = Places {
        mcp_settings: "Settings > MCP",
        token_store: "Credential Manager",
    };

    #[test]
    fn a_message_names_the_places_of_the_app_it_came_with() {
        let cases = [
            (
                CommandError::ServerOff,
                "TablePro's MCP server is off. Turn on Preferences > MCP > Enable MCP Server, then run the command \
again.",
                "TablePro's MCP server is off. Turn on Settings > MCP > Enable MCP Server, then run the command again.",
            ),
            (
                CommandError::NoToken,
                "TablePro's MCP server has not started. Preferences > MCP shows why.",
                "TablePro's MCP server has not started. Settings > MCP shows why.",
            ),
            (
                CommandError::NotAnswering { port: 7 },
                "TablePro's MCP server does not answer on port 7. Preferences > MCP shows why.",
                "TablePro's MCP server does not answer on port 7. Settings > MCP shows why.",
            ),
            (
                CommandError::Host(HostError::Keyring {
                    reason: "locked".to_owned(),
                }),
                "Could not read the MCP token from the keyring: locked",
                "Could not read the MCP token from Credential Manager: locked",
            ),
            (
                CommandError::Host(HostError::ForeignServer { port: 7 }),
                "Another program holds port 7, so the command did not send it TablePro's token. Quit that program, \
or pick another port in Preferences > MCP.",
                "Another program holds port 7, so the command did not send it TablePro's token. Quit that program, \
or pick another port in Settings > MCP.",
            ),
        ];

        for (error, preferences, settings) in cases {
            assert_eq!(error.to_string(), preferences);
            assert_eq!(error.message(Places::PREFERENCES), preferences);
            assert_eq!(error.message(SETTINGS), settings);
        }
        assert_eq!(
            CommandError::NoAnswer { seconds: 1 }.message(SETTINGS),
            "TablePro did not answer within 1 seconds."
        );
    }

    #[test]
    fn a_tool_code_maps_to_its_exit_status() {
        let cases = [
            ("invalid_argument: send one statement per call", Exit::Usage),
            ("denied: “Staging” lets MCP clients read only", Exit::Refused),
            (
                "user_cancelled: the user declined the statement in TablePro",
                Exit::Refused,
            ),
            (
                "timeout: the statement ran past 30 seconds and was stopped",
                Exit::TimedOut,
            ),
            ("not_found: no table or view named x", Exit::Failure),
            ("not_connected: “Staging” is not open in TablePro", Exit::Failure),
            ("query_failed: syntax error", Exit::Failure),
            ("unsupported: this engine cannot", Exit::Failure),
            ("internal_failure: TablePro failed", Exit::Failure),
            ("something without a code", Exit::Failure),
        ];

        for (text, exit) in cases {
            assert_eq!(CommandError::from_tool_text(text).exit(), exit, "{text}");
        }
    }

    #[test]
    fn the_message_drops_a_known_code_and_keeps_an_unknown_one() {
        assert_eq!(
            CommandError::from_tool_text("denied: read only").to_string(),
            "read only"
        );
        assert_eq!(CommandError::from_tool_text("odd: text").to_string(), "odd: text");
    }

    #[test]
    fn an_ambiguous_name_lists_every_id() {
        let error = CommandError::AmbiguousConnection {
            name: "Staging".to_owned(),
            ids: vec!["a".to_owned(), "b".to_owned()],
        };

        assert_eq!(error.exit(), Exit::Usage);
        assert_eq!(
            error.to_string(),
            "2 connections are named “Staging”. Pass one of their ids: a, b."
        );
    }

    #[test]
    fn settings_off_and_a_refused_token_are_refusals() {
        assert_eq!(CommandError::ServerOff.exit(), Exit::Refused);
        assert_eq!(CommandError::TokenRefused { port: 1 }.exit(), Exit::Refused);
        assert_eq!(CommandError::NotRunning.exit(), Exit::Failure);
        assert_eq!(CommandError::NotAnswering { port: 1 }.exit(), Exit::Failure);
    }

    #[test]
    fn a_server_that_stops_answering_times_out_and_a_foreign_one_fails() {
        assert_eq!(CommandError::NoAnswer { seconds: 60 }.exit(), Exit::TimedOut);
        assert_eq!(
            CommandError::NoAnswer { seconds: 60 }.to_string(),
            "TablePro did not answer within 60 seconds."
        );
        assert_eq!(
            CommandError::Host(HostError::ForeignServer { port: 1 }).exit(),
            Exit::Failure
        );
    }
}
