use serde::{Deserialize, Serialize};

/// What the AI assistant may send from one connection.
///
/// It is persisted with the connection, so a variant is never renamed:
/// the stored spelling is the serde name. A new connection starts at
/// `Ask`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AiPolicy {
    /// The window asks before the first request, and the answer lasts
    /// until it disconnects.
    #[default]
    Ask,
    Allow,
    /// Nothing from the connection goes into a prompt: not its schema,
    /// its rows, its editor text or a question asked beside it.
    Never,
    // As a Mac connection that never picked one follows the AI settings; an app with no default asks.
    AppDefault,
}

impl AiPolicy {
    pub const ALL: [AiPolicy; 4] = [Self::Ask, Self::Allow, Self::Never, Self::AppDefault];

    // A form with no App Default choice shows it as the app's default, and sending that back keeps it.
    pub fn edited(stored: Self, picked: Self, app_default: Self) -> Self {
        if picked == stored.or_app_default(app_default) {
            stored
        } else {
            picked
        }
    }

    pub fn or_app_default(self, app_default: AiPolicy) -> AiPolicy {
        match (self, app_default) {
            (Self::AppDefault, Self::AppDefault) => Self::Ask,
            (Self::AppDefault, policy) => policy,
            (policy, _) => policy,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_stored_spelling_is_snake_case_and_asking_is_the_default() {
        let spelled: Vec<String> = AiPolicy::ALL
            .into_iter()
            .filter_map(|policy| serde_json::to_string(&policy).ok())
            .collect();

        assert_eq!(spelled, ["\"ask\"", "\"allow\"", "\"never\"", "\"app_default\""]);
        assert_eq!(AiPolicy::default(), AiPolicy::Ask);
    }

    #[test]
    fn the_app_default_stands_in_and_an_app_without_one_asks() {
        assert_eq!(AiPolicy::AppDefault.or_app_default(AiPolicy::Never), AiPolicy::Never);
        assert_eq!(AiPolicy::AppDefault.or_app_default(AiPolicy::AppDefault), AiPolicy::Ask);
        assert_eq!(AiPolicy::Allow.or_app_default(AiPolicy::Never), AiPolicy::Allow);
        assert_eq!(
            AiPolicy::edited(AiPolicy::AppDefault, AiPolicy::Ask, AiPolicy::Ask),
            AiPolicy::AppDefault
        );
        assert_eq!(
            AiPolicy::edited(AiPolicy::AppDefault, AiPolicy::Never, AiPolicy::Ask),
            AiPolicy::Never
        );
    }
}
