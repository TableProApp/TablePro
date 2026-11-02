use serde::{Deserialize, Serialize};

/// How a saved connection logs in.
///
/// It is persisted with the connection, so a variant is never renamed:
/// the stored spelling is the serde name.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthMode {
    #[default]
    Password,
    /// SQL Server integrated login over Kerberos, with the ticket the
    /// user already holds from `kinit`. No username or password is
    /// sent.
    Kerberos,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_stored_spelling_is_snake_case() {
        assert_eq!(
            serde_json::to_string(&AuthMode::Kerberos).ok().as_deref(),
            Some("\"kerberos\"")
        );
        assert_eq!(
            serde_json::from_str::<AuthMode>("\"password\"").ok(),
            Some(AuthMode::Password)
        );
    }
}
