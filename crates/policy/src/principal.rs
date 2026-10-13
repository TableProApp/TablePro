use serde::{Deserialize, Serialize};
use sha2::Digest;

/// Who is asking the database to do something. Authority rides on the
/// principal, not the connection: the same Prod connection allows a
/// human write with approval while denying an agent write.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Principal {
    Human {
        #[serde(default = "default_session")]
        session: String,
    },
    Agent {
        token: String,
        #[serde(default)]
        client: Option<String>,
        #[serde(default)]
        model: Option<String>,
    },
}

fn default_session() -> String {
    "gui".into()
}

impl Principal {
    pub fn human_gui() -> Self {
        Self::Human { session: "gui".into() }
    }

    pub fn is_agent(&self) -> bool {
        matches!(self, Self::Agent { .. })
    }

    /// Return the audit-safe representation of this principal. Agent tokens
    /// are replaced with a short stable digest so attempts can be correlated
    /// without persisting a credential.
    pub fn sanitized(&self) -> Self {
        match self {
            Self::Human { session } => Self::Human {
                session: session.clone(),
            },
            Self::Agent { token, client, model } => Self::Agent {
                token: format!("sha256:{}", &hex::encode(sha2::Sha256::digest(token.as_bytes()))[..16]),
                client: client.clone(),
                model: model.clone(),
            },
        }
    }

    pub fn label(&self) -> String {
        match self {
            Self::Human { session } => format!("human:{session}"),
            Self::Agent { token, client, .. } => {
                let short: String = token.chars().take(8).collect();
                match client {
                    Some(c) => format!("agent:{c}:{short}"),
                    None => format!("agent:{short}"),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(token: &str, client: Option<&str>) -> Principal {
        Principal::Agent {
            token: token.into(),
            client: client.map(str::to_string),
            model: None,
        }
    }

    #[test]
    fn a_label_shortens_the_token_without_splitting_a_character() {
        assert_eq!(agent("abcdefghijkl", None).label(), "agent:abcdefgh");
        assert_eq!(agent("short", None).label(), "agent:short");
        assert_eq!(agent("abcdefgh", Some("claude")).label(), "agent:claude:abcdefgh");
        assert_eq!(Principal::human_gui().label(), "human:gui");

        for token in ["tokéééééé", "ééééé-token", "日本語のトークン", "abcdefgé", "😀😀😀😀😀"]
        {
            let label = agent(token, Some("client")).label();
            assert!(label.starts_with("agent:client:"), "{token}: {label}");
            assert!(label.chars().count() <= "agent:client:".len() + 8, "{token}: {label}");
        }
    }

    #[test]
    fn the_audit_form_replaces_the_token_with_a_stable_digest() {
        let first = agent("super-secret-token", Some("claude")).sanitized();
        let again = agent("super-secret-token", Some("claude")).sanitized();
        let other = agent("another-token", Some("claude")).sanitized();

        let Principal::Agent { token, client, .. } = &first else {
            panic!("an agent stays an agent: {first:?}");
        };
        assert!(
            token.starts_with("sha256:") && token.len() == "sha256:".len() + 16,
            "{token}"
        );
        assert!(!token.contains("super-secret"));
        assert_eq!(client.as_deref(), Some("claude"));
        assert_eq!(first, again, "the digest is stable so attempts can be correlated");
        assert_ne!(first, other);
        assert_eq!(Principal::human_gui().sanitized(), Principal::human_gui());
    }

    #[test]
    fn a_principal_reads_from_json_with_its_defaults() {
        let human: Principal = serde_json::from_str(r#"{"kind":"human"}"#).unwrap();
        assert_eq!(human, Principal::human_gui());
        let agent: Principal = serde_json::from_str(r#"{"kind":"agent","token":"t"}"#).unwrap();
        assert_eq!(
            agent,
            super::Principal::Agent {
                token: "t".into(),
                client: None,
                model: None
            }
        );
        assert!(agent.is_agent() && !human.is_agent());
    }
}
