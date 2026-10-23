use serde::{Deserialize, Serialize};

/// What the AI assistant may send from one connection.
///
/// It is persisted with the connection, so a variant is never renamed:
/// the stored spelling is the serde name. A connection saved before the
/// policy existed reads as `Ask`, the policy a new one starts at.
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
}

impl AiPolicy {
    pub const ALL: [AiPolicy; 3] = [Self::Ask, Self::Allow, Self::Never];
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

        assert_eq!(spelled, ["\"ask\"", "\"allow\"", "\"never\""]);
        assert_eq!(AiPolicy::default(), AiPolicy::Ask);
    }
}
