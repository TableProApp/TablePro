use super::shell_lexer::{ShellTokenKind, lex_shell};
use crate::sql_syntax::{HistoryRecording, WithholdReason};

/// Methods whose arguments carry a password: a user's, or the one the
/// shell logs in with.
const CREDENTIAL_METHODS: [&str; 6] = [
    "createUser",
    "updateUser",
    "changeUserPassword",
    "auth",
    "connect",
    "Mongo",
];

/// Keys that hold a password in a command or a user document.
const CREDENTIAL_KEYS: [&str; 3] = ["pwd", "password", "passwordDigestor"];

/// Whether shell text may go into the query history. Read from its
/// tokens, so a statement that does not parse is judged too: a method
/// that sets or sends a password, a key that holds one, or a string with
/// a connection string that names one keeps the whole text out.
pub fn history_recording(text: &str) -> HistoryRecording {
    let tokens = lex_shell(text);
    if tokens.iter().any(|token| token.kind.is_open()) {
        return HistoryRecording::Withhold(WithholdReason::Untokenizable);
    }
    let significant: Vec<_> = tokens.iter().filter(|token| !token.kind.is_trivia()).collect();
    let punct = |index: Option<usize>, mark: &str| {
        index
            .and_then(|index| significant.get(index))
            .is_some_and(|token| token.kind == ShellTokenKind::Punct && token.text(text) == mark)
    };
    let carries = significant.iter().enumerate().any(|(index, token)| match token.kind {
        ShellTokenKind::Identifier => {
            let word = token.text(text);
            CREDENTIAL_METHODS.contains(&word) || is_credential_key(word)
        }
        ShellTokenKind::String { .. } => {
            let quoted = token.text(text);
            let inner = quoted.get(1..quoted.len().saturating_sub(1)).unwrap_or_default();
            // `db['changeUserPassword'](...)` names the method in quotes.
            let member = punct(index.checked_sub(1), "[") && punct(Some(index + 1), "]");
            (member && CREDENTIAL_METHODS.contains(&inner)) || is_credential_key(inner) || names_a_password(inner)
        }
        _ => false,
    });
    match carries {
        true => HistoryRecording::Withhold(WithholdReason::CredentialStatement),
        false => HistoryRecording::Record,
    }
}

fn is_credential_key(word: &str) -> bool {
    CREDENTIAL_KEYS.iter().any(|key| word.eq_ignore_ascii_case(key))
}

/// A URI with a password in its user part, `scheme://user:secret@host`.
fn names_a_password(text: &str) -> bool {
    text.match_indices("://").any(|(at, scheme)| {
        let authority = &text[at + scheme.len()..];
        let authority = authority.split(['/', '?', '#']).next().unwrap_or_default();
        authority.rsplit_once('@').is_some_and(|(user, _)| user.contains(':'))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const WITHHELD: HistoryRecording = HistoryRecording::Withhold(WithholdReason::CredentialStatement);

    #[test]
    fn a_statement_that_sets_or_sends_a_password_is_withheld() {
        for text in [
            "db.createUser({user: 'ann', pwd: 's3cret', roles: []})",
            "db.updateUser('ann', {pwd: 'new'})",
            "db.changeUserPassword('ann', 'new')",
            "db.auth('ann', 's3cret')",
            "db.runCommand({createUser: 'ann', \"pwd\": 'x', roles: []})",
            "db.getSiblingDB('admin').runCommand({updateUser: 'ann', 'PWD': passwordPrompt()})",
            "db.x.insertOne({link: 'mongodb://ann:s3cret@db.example.com/shop'})",
            "connect('mongodb+srv://ann:s3cret@cluster0.example.net')",
            "db.x.updateOne({_id: 1}, {$set: {password: 'x'}})",
            "db.createUser({user: 'ann', pwd: passwordPrompt(), roles: []",
            "db['changeUserPassword']('ann', 'new')",
            "db.getSiblingDB('admin')[\"createUser\"]({user: 'ann', roles: []})",
        ] {
            assert_eq!(history_recording(text), WITHHELD, "{text}");
        }
    }

    #[test]
    fn everyday_statements_are_kept() {
        for text in [
            "db.users.find({name: 'ann'})",
            "db.x.insertOne({link: 'mongodb://db.example.com/shop', user: 'ann@example.com'})",
            "db.x.find({url: 'https://ann@example.com'})",
            "db.logs.find({event: 'auth'})",
            "show dbs",
        ] {
            assert_eq!(history_recording(text), HistoryRecording::Record, "{text}");
        }
    }

    #[test]
    fn an_open_string_is_not_kept() {
        assert_eq!(
            history_recording("db.x.find({a: 'open"),
            HistoryRecording::Withhold(WithholdReason::Untokenizable)
        );
    }
}
