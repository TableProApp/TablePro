use std::fmt;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// One editor tab's saved text.
///
/// The tab record carries this instead of the text itself, so a
/// workspace file stays small however long the script is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct DraftId(Uuid);

impl DraftId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }

    pub fn from_uuid(id: Uuid) -> Self {
        Self(id)
    }

    pub fn as_uuid(&self) -> Uuid {
        self.0
    }
}

impl Default for DraftId {
    fn default() -> Self {
        Self::new()
    }
}

impl fmt::Display for DraftId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}
