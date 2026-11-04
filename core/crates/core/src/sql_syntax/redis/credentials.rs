use super::command_lexer::split_commands;
use crate::sql_syntax::{HistoryRecording, WithholdReason};

/// `CONFIG SET` parameters that hold a password.
const SECRET_PARAMETERS: &[&str] = &[
    "requirepass",
    "masterauth",
    "primaryauth",
    "tls-key-file-pass",
    "tls-client-key-file-pass",
];

/// Words in a script body that reach a password through `redis.call`,
/// besides the password parameters themselves.
const SCRIPT_MARKERS: &[&str] = &["auth", "setuser"];

/// Whether Redis commands the user ran may go into the query history.
///
/// A command's arguments, not its words, carry a secret, so the rules
/// look at the command and its options: `AUTH`, `HELLO ... AUTH`,
/// `MIGRATE ... AUTH | AUTH2`, `ACL SETUSER`, `CONFIG SET` of a password
/// parameter, `SENTINEL SET` and `SENTINEL CONFIG SET`, and a script that
/// names one of them. Text whose quotes do not balance is withheld, since
/// where its arguments end is a guess.
pub fn history_recording(text: &str) -> HistoryRecording {
    for command in split_commands(text) {
        let Ok(arguments) = command.values else {
            return HistoryRecording::Withhold(WithholdReason::Untokenizable);
        };
        if carries_secret(&arguments) {
            return HistoryRecording::Withhold(WithholdReason::CredentialStatement);
        }
    }
    HistoryRecording::Record
}

fn carries_secret(arguments: &[Vec<u8>]) -> bool {
    let word = |at: usize| {
        arguments
            .get(at)
            .map(|word| String::from_utf8_lossy(word).to_ascii_uppercase())
    };
    let rest_mentions = |from: usize, words: &[&str]| {
        arguments
            .iter()
            .skip(from)
            .any(|argument| words.iter().any(|word| argument.eq_ignore_ascii_case(word.as_bytes())))
    };
    let Some(name) = word(0) else {
        return false;
    };
    match (name.as_str(), word(1).as_deref()) {
        ("AUTH", _) => true,
        ("HELLO", _) => rest_mentions(1, &["AUTH"]),
        ("MIGRATE", _) => rest_mentions(1, &["AUTH", "AUTH2"]),
        ("ACL", Some("SETUSER")) => true,
        ("CONFIG", Some("SET")) => rest_mentions(2, SECRET_PARAMETERS),
        ("SENTINEL", Some("SET")) => true,
        ("SENTINEL", Some("CONFIG")) => word(2).as_deref() == Some("SET"),
        ("EVAL" | "EVAL_RO" | "SCRIPT" | "FUNCTION", _) => arguments.iter().skip(1).any(|body| {
            let body = String::from_utf8_lossy(body).to_ascii_lowercase();
            SCRIPT_MARKERS
                .iter()
                .chain(SECRET_PARAMETERS)
                .any(|marker| body.contains(marker))
        }),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn withheld(text: &str) -> bool {
        history_recording(text) == HistoryRecording::Withhold(WithholdReason::CredentialStatement)
    }

    #[test]
    fn commands_that_carry_a_password_are_withheld() {
        for text in [
            "AUTH s3cret",
            "auth app s3cret",
            "HELLO 2 AUTH app s3cret",
            "MIGRATE host 6379 key 0 5000 AUTH s3cret",
            "MIGRATE host 6379 \"\" 0 5000 AUTH2 app s3cret KEYS a b",
            "ACL SETUSER app on >s3cret ~* +@all",
            "CONFIG SET requirepass s3cret",
            "config set maxmemory 1gb MASTERAUTH s3cret",
            "SENTINEL SET mymaster auth-pass s3cret",
            "SENTINEL CONFIG SET sentinel-pass s3cret",
            "EVAL \"return redis.call('auth', 's3cret')\" 0",
            "SCRIPT LOAD \"return redis.call('CONFIG','SET','tls-key-file-pass','s3cret')\"",
            "EVAL \"redis.call('config', 'set', 'TLS-CLIENT-KEY-FILE-PASS', 's3cret')\" 0",
            "GET a\nAUTH s3cret",
        ] {
            assert!(withheld(text), "{text}");
        }
    }

    #[test]
    fn everyday_commands_are_recorded() {
        for text in [
            "GET user:1",
            "SET auth:token value",
            "CONFIG SET maxmemory 1gb",
            "CONFIG GET requirepass",
            "HELLO 2",
            "ACL WHOAMI",
            "EVAL \"return 1\" 0",
        ] {
            assert_eq!(history_recording(text), HistoryRecording::Record, "{text}");
        }
    }

    #[test]
    fn unbalanced_quotes_are_withheld_as_untokenizable() {
        assert_eq!(
            history_recording("AUTH \"s3cret"),
            HistoryRecording::Withhold(WithholdReason::Untokenizable)
        );
    }
}
