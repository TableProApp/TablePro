use std::sync::LazyLock;

use regex::Regex;

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

    fn pattern(self) -> &'static str {
        match self {
            Self::AwsAccessKey => r"AKIA[0-9A-Z]{16}",
            Self::PrivateKey => r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----",
            Self::JsonWebToken => r"eyJ[\w-]+\.eyJ[\w-]+\.[\w-]+",
            Self::GitHubToken => r"gh[pousr]_[A-Za-z0-9]{36,}",
            Self::SlackToken => r"xox[abprs]-",
            Self::StripeKey => r"sk_live_",
            Self::GoogleApiKey => r"AIza[0-9A-Za-z_-]{35}",
            Self::UrlCredentials => r"\w+://[^\s:/]+:[^\s@]+@",
            // A name may close its own quote or bracket before the operator, as in JSON or T-SQL.
            Self::AssignedSecret => {
                r#"(?i)\w*(?:password|passwd|pwd|secret|token|api_key)\w*["'`\]]?\s*(?:=>|:=|=|:)\s*(?:'[^'\n]+'|"[^"\n]+")"#
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

// Each kind once per line, by line.
pub fn scan_sql(sql: &str) -> Vec<SecretHit> {
    let line_starts: Vec<usize> = std::iter::once(0)
        .chain(sql.match_indices('\n').map(|(at, _)| at + 1))
        .collect();
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

// Separators and case go, so api_key, apiKey and API-KEY read alike. "ssn" must be a word of its own, or
// "class_name" would match.
fn column_may_hold_secret(name: &str) -> bool {
    const PARTS: [&str; 7] = [
        "password",
        "passwd",
        "secret",
        "token",
        "apikey",
        "creditcard",
        "cardnumber",
    ];
    let joined: String = name
        .chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect();
    PARTS.iter().any(|part| joined.contains(part)) || words(name).any(|word| word == "ssn")
}

// Split at anything not a letter or digit and where a lower-case letter meets an upper-case one.
fn words(name: &str) -> impl Iterator<Item = String> + '_ {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut previous_lower = false;
    for character in name.chars() {
        if !character.is_alphanumeric() {
            if !word.is_empty() {
                words.push(std::mem::take(&mut word));
            }
            previous_lower = false;
            continue;
        }
        if character.is_uppercase() && previous_lower && !word.is_empty() {
            words.push(std::mem::take(&mut word));
        }
        previous_lower = character.is_lowercase() || character.is_ascii_digit();
        word.extend(character.to_lowercase());
    }
    if !word.is_empty() {
        words.push(word);
    }
    words.into_iter()
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
