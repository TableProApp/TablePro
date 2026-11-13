use tablepro_core::secret_scan::{self, SecretHit, SecretHitKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SecretHitKindTag {
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct SecretHitInfo {
    pub kind: SecretHitKindTag,
    // From 1.
    pub line: u32,
}

// Each kind once per line, by line. A hit warns before a share and never blocks it.
#[uniffi::export]
pub fn scan_sql_for_secrets(sql: String) -> Vec<SecretHitInfo> {
    secret_scan::scan_sql(&sql)
        .into_iter()
        .map(SecretHitInfo::from)
        .collect()
}

// The names of the columns that may hold a secret, in their order, each once.
#[uniffi::export]
pub fn scan_columns_for_secrets(names: Vec<String>) -> Vec<String> {
    secret_scan::scan_columns(&names)
}

// The token of `tablepro://share?token=<token>`, None for any other link or a malformed token.
#[uniffi::export]
pub fn share_token_from_link(link: String) -> Option<String> {
    tablepro_account::share_token_from_link(&link)
}

impl From<SecretHit> for SecretHitInfo {
    fn from(hit: SecretHit) -> Self {
        Self {
            kind: hit.kind.into(),
            line: hit.line,
        }
    }
}

impl From<SecretHitKind> for SecretHitKindTag {
    fn from(kind: SecretHitKind) -> Self {
        match kind {
            SecretHitKind::AwsAccessKey => Self::AwsAccessKey,
            SecretHitKind::PrivateKey => Self::PrivateKey,
            SecretHitKind::JsonWebToken => Self::JsonWebToken,
            SecretHitKind::GitHubToken => Self::GitHubToken,
            SecretHitKind::SlackToken => Self::SlackToken,
            SecretHitKind::StripeKey => Self::StripeKey,
            SecretHitKind::GoogleApiKey => Self::GoogleApiKey,
            SecretHitKind::UrlCredentials => Self::UrlCredentials,
            SecretHitKind::AssignedSecret => Self::AssignedSecret,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hit_crosses_with_its_kind_and_line() {
        let hits = scan_sql_for_secrets("SELECT 1;\nSELECT 'AKIAIOSFODNN7EXAMPLE';".to_owned());

        assert_eq!(
            hits,
            [SecretHitInfo {
                kind: SecretHitKindTag::AwsAccessKey,
                line: 2
            }]
        );
    }

    #[test]
    fn every_kind_has_a_tag() {
        let tags: Vec<SecretHitKindTag> = SecretHitKind::ALL.into_iter().map(SecretHitKindTag::from).collect();

        assert_eq!(tags.len(), 9);
        assert_eq!(tags[8], SecretHitKindTag::AssignedSecret);
    }

    #[test]
    fn secret_columns_and_the_deep_link_token_cross() {
        let token = "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7dEf0hIjK";

        assert_eq!(
            scan_columns_for_secrets(vec!["id".to_owned(), "api_key".to_owned()]),
            ["api_key"]
        );
        assert_eq!(
            share_token_from_link(format!("tablepro://share?token={token}")).as_deref(),
            Some(token)
        );
        assert_eq!(share_token_from_link("tablepro://share?token=x".to_owned()), None);
    }
}
