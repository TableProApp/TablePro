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
                let short = if token.len() > 8 { &token[..8] } else { token };
                match client {
                    Some(c) => format!("agent:{c}:{short}"),
                    None => format!("agent:{short}"),
                }
            }
        }
    }
}
