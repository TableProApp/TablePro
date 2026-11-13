use std::sync::LazyLock;

use regex::Regex;

use crate::masking::MaskingStyle;
use crate::masking::detect::{Term, longest_term, name_words};

// What a shared query or result may give away. Each app words the kind; a hit warns and never blocks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SecretHitKind {
    AwsAccessKey,
    PrivateKey,
    JsonWebToken,
    GitHubToken,
    SlackToken,
    StripeKey,
    GoogleApiKey,
    UrlCredentials,
    AssignedSecret,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SecretHit {
    pub kind: SecretHitKind,
    // From 1.
    pub line: u32,
}

impl SecretHitKind {
    pub const ALL: [Self; 9] = [
        Self::AwsAccessKey,
        Self::PrivateKey,
        Self::JsonWebToken,
        Self::GitHubToken,
        Self::SlackToken,
        Self::StripeKey,
        Self::GoogleApiKey,
        Self::UrlCredentials,
        Self::AssignedSecret,
    ];

    pub fn code(self) -> &'static str {
        match self {
            Self::AwsAccessKey => "aws_access_key",
            Self::PrivateKey => "private_key",
            Self::JsonWebToken => "json_web_token",
            Self::GitHubToken => "github_token",
            Self::SlackToken => "slack_token",
            Self::StripeKey => "stripe_key",
            Self::GoogleApiKey => "google_api_key",
            Self::UrlCredentials => "url_credentials",
            Self::AssignedSecret => "assigned_secret",
        }
    }

    // PLAN-MASKING 8.3: only what Rust's and Swift's engines both read, no lookaround and no possessive runs.
    pub(crate) fn pattern(self) -> &'static str {
        match self {
            Self::AwsAccessKey => r"AKIA[0-9A-Z]{16}",
            Self::PrivateKey => r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----",
            Self::JsonWebToken => r"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+",
            Self::GitHubToken => r"gh[pousr]_[A-Za-z0-9]{36,}",
            Self::SlackToken => r"xox[abprs]-",
            Self::StripeKey => r"sk_live_",
            Self::GoogleApiKey => r"AIza[0-9A-Za-z_-]{35}",
            Self::UrlCredentials => r"\w+://[^\s:/@]+:[^\s@]+@",
            // A name may be quoted or bracketed, as in JSON or T-SQL; the value closes with the quote it opened with.
            Self::AssignedSecret => {
                r#"(?i)\w*(?:password|passwd|pwd|secret|token|api_key)\w*["'`\]]?\s*(?:=>|:=|=|:)\s*(?:'[^']+'|"[^"]+")"#
            }
        }
    }
}

static PATTERNS: LazyLock<Vec<(SecretHitKind, Regex)>> = LazyLock::new(|| {
    SecretHitKind::ALL
        .into_iter()
        .filter_map(|kind| Regex::new(kind.pattern()).ok().map(|regex| (kind, regex)))
        .collect()
});

// Each kind once per line, by line. CR, LF and CRLF each end a line.
pub fn scan_sql(sql: &str) -> Vec<SecretHit> {
    let line_starts = line_starts(sql);
    let line_of =
        |offset: usize| u32::try_from(line_starts.partition_point(|start| *start <= offset)).unwrap_or(u32::MAX);
    let mut hits: Vec<SecretHit> = PATTERNS
        .iter()
        .flat_map(|(kind, regex)| {
            regex.find_iter(sql).map(move |found| SecretHit {
                kind: *kind,
                line: line_of(found.start()),
            })
        })
        .collect();
    hits.sort_by_key(|hit| (hit.line, hit.kind));
    hits.dedup();
    hits
}

// Byte offsets where each line starts; a CRLF pair is one break.
pub(crate) fn line_starts(text: &str) -> Vec<usize> {
    let bytes = text.as_bytes();
    let mut starts = vec![0];
    let mut at = 0;
    while at < bytes.len() {
        match bytes[at] {
            b'\r' if bytes.get(at + 1) == Some(&b'\n') => {
                at += 2;
                starts.push(at);
            }
            b'\r' | b'\n' => {
                at += 1;
                starts.push(at);
            }
            _ => at += 1,
        }
    }
    starts
}

// The names of the columns that may hold a secret, in their order, each once.
pub fn scan_columns<S: AsRef<str>>(names: &[S]) -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    for name in names.iter().map(AsRef::as_ref) {
        if column_may_hold_secret(name) && !found.iter().any(|kept| kept == name) {
            found.push(name.to_owned());
        }
    }
    found
}

const SECRET_TERMS: [Term; 8] = [
    secret_term("password"),
    secret_term("passwd"),
    secret_term("secret"),
    secret_term("token"),
    secret_term("apikey"),
    secret_term("ssn"),
    secret_term("creditcard"),
    secret_term("cardnumber"),
];

const fn secret_term(compact: &'static str) -> Term {
    Term {
        compact,
        single_word: false,
        style: MaskingStyle::Full,
    }
}

// Whole words as the masking detectors split a name, so api_key, apiKey and API-KEY read alike and class_name holds
// no "ssn".
fn column_may_hold_secret(name: &str) -> bool {
    longest_term(&name_words(name), &SECRET_TERMS).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(sql: &str) -> Vec<(SecretHitKind, u32)> {
        scan_sql(sql).into_iter().map(|hit| (hit.kind, hit.line)).collect()
    }

    #[test]
    fn every_pattern_compiles() {
        assert_eq!(PATTERNS.len(), SecretHitKind::ALL.len());
    }

    #[test]
    fn each_kind_is_found_on_its_line() {
        let sql = [
            "SELECT 1;",
            "-- AKIAIOSFODNN7EXAMPLE",
            "-----BEGIN RSA PRIVATE KEY-----",
            "-- eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc-DEF_123",
            "-- ghp_0123456789abcdefghijABCDEFGHIJ012345",
            "-- xoxb-123",
            "-- sk_live_abc",
            "-- AIzaSyA1234567890abcdefghijklmnopqrstuv",
            "-- postgres://app:hunter2@db.internal/shop",
            "UPDATE users SET api_key = 'abc123' WHERE id = 1;",
        ]
        .join("\n");

        assert_eq!(
            kinds(&sql),
            [
                (SecretHitKind::AwsAccessKey, 2),
                (SecretHitKind::PrivateKey, 3),
                (SecretHitKind::JsonWebToken, 4),
                (SecretHitKind::GitHubToken, 5),
                (SecretHitKind::SlackToken, 6),
                (SecretHitKind::StripeKey, 7),
                (SecretHitKind::GoogleApiKey, 8),
                (SecretHitKind::UrlCredentials, 9),
                (SecretHitKind::AssignedSecret, 10),
            ]
        );
    }

    #[test]
    fn an_assigned_literal_is_found_in_sql_json_and_brackets() {
        for sql in [
            "WHERE u.password = 'hunter2'",
            r#"SELECT '{"token": "abc"}'::jsonb"#,
            "SET [db_passwd] = 'x'",
            "INSERT ... VALUES (secret => 'x')",
            "SET @pwd := 'x'",
            "WHERE `Api_Key`='x'",
        ] {
            assert_eq!(kinds(sql), [(SecretHitKind::AssignedSecret, 1)], "{sql}");
        }
    }

    #[test]
    fn a_name_without_a_quoted_literal_is_no_secret() {
        for sql in [
            "SELECT password FROM users",
            "WHERE password = ''",
            "WHERE password = $1",
            "WHERE token = :token",
            "WHERE password_hash IS NULL",
            "SELECT 'password' AS label",
        ] {
            assert!(kinds(sql).is_empty(), "{sql}: {:?}", kinds(sql));
        }
    }

    #[test]
    fn a_kind_counts_once_per_line_and_lines_are_ordered() {
        let sql = "SELECT 'AKIAIOSFODNN7EXAMPLE', 'AKIAIOSFODNN7EXAMPLF';\nSELECT 'sk_live_a'";

        assert_eq!(
            kinds(sql),
            [(SecretHitKind::AwsAccessKey, 1), (SecretHitKind::StripeKey, 2)]
        );
    }

    #[test]
    fn near_misses_are_not_secrets() {
        for sql in [
            "AKIA123",
            "-----BEGIN PUBLIC KEY-----",
            "eyJhbGciOiJIUzI1NiJ9",
            "ghp_short",
            "sk_test_abc",
            "AIzaShort",
            "https://tablepro.app/docs",
        ] {
            assert!(kinds(sql).is_empty(), "{sql}: {:?}", kinds(sql));
        }
    }

    #[test]
    fn a_line_is_counted_from_1_whatever_the_line_endings() {
        assert_eq!(kinds("\r\n\r\nsk_live_x"), [(SecretHitKind::StripeKey, 3)]);
        assert_eq!(kinds("sk_live_x"), [(SecretHitKind::StripeKey, 1)]);
    }

    #[test]
    fn secret_columns_are_named_in_their_order_once() {
        let names = [
            "id",
            "user_password",
            "PasswordHash",
            "access_token",
            "apiKey",
            "API-KEY",
            "client_secret",
            "ssn",
            "customerSSN",
            "ssn_last4",
            "credit_card",
            "CardNumber",
            "class_name",
            "lesson",
            "id",
            "user_password",
        ];

        assert_eq!(
            scan_columns(&names),
            [
                "user_password",
                "PasswordHash",
                "access_token",
                "apiKey",
                "API-KEY",
                "client_secret",
                "ssn",
                "customerSSN",
                "ssn_last4",
                "credit_card",
                "CardNumber",
            ]
        );
    }

    #[test]
    fn every_kind_has_its_own_code() {
        let mut codes: Vec<&str> = SecretHitKind::ALL.iter().map(|kind| kind.code()).collect();
        codes.sort_unstable();
        codes.dedup();

        assert_eq!(codes.len(), SecretHitKind::ALL.len());
    }
}
