use serde::{Deserialize, Serialize};
use tablepro_session::SessionKey;
use uuid::Uuid;

/// A session key as the open-sessions file holds it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SessionKeyRecord {
    Saved { id: Uuid },
    File { uri: String },
}

impl From<&SessionKey> for SessionKeyRecord {
    fn from(key: &SessionKey) -> Self {
        match key {
            SessionKey::Saved(id) => Self::Saved { id: *id },
            SessionKey::File(uri) => Self::File { uri: uri.clone() },
        }
    }
}

impl SessionKeyRecord {
    pub fn into_key(self) -> SessionKey {
        match self {
            Self::Saved { id } => SessionKey::Saved(id),
            Self::File { uri } => SessionKey::File(uri),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_key_comes_back_as_it_went_in() {
        for key in [
            SessionKey::Saved(Uuid::new_v4()),
            SessionKey::File("file:///srv/app.db".to_owned()),
        ] {
            assert_eq!(SessionKeyRecord::from(&key).into_key(), key);
        }
    }
}
