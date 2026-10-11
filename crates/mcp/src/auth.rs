use serde::{Deserialize, Deserializer, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum McpScope {
    ToolsRead,
    ToolsWrite,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TokenPermissions {
    ReadOnly,
    ReadWrite,
}

impl TokenPermissions {
    pub fn scopes(self) -> Vec<McpScope> {
        match self {
            Self::ReadOnly => vec![McpScope::ToolsRead],
            Self::ReadWrite => vec![McpScope::ToolsRead, McpScope::ToolsWrite],
        }
    }

    pub fn allows(self, required: McpScope) -> bool {
        self.scopes().contains(&required)
    }
}

impl<'de> Deserialize<'de> for TokenPermissions {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        match raw.as_str() {
            "read_only" => Ok(Self::ReadOnly),
            "read_write" | "full_access" => Ok(Self::ReadWrite),
            other => Err(serde::de::Error::unknown_variant(other, &["read_only", "read_write"])),
        }
    }
}

pub fn authorize_scopes(perms: TokenPermissions, required: McpScope) -> Result<(), String> {
    if perms.allows(required) {
        Ok(())
    } else {
        Err(format!("token lacks scope {:?}; has {:?}", required, perms.scopes()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_only_blocks_write() {
        assert!(authorize_scopes(TokenPermissions::ReadOnly, McpScope::ToolsWrite).is_err());
        assert!(authorize_scopes(TokenPermissions::ReadWrite, McpScope::ToolsWrite).is_ok());
    }

    #[test]
    fn a_stored_full_access_token_is_read_write() {
        let permissions: TokenPermissions = serde_json::from_str("\"full_access\"").unwrap();
        assert_eq!(permissions, TokenPermissions::ReadWrite);
        assert!(permissions.allows(McpScope::ToolsWrite));
        assert!(authorize_scopes(permissions, McpScope::ToolsWrite).is_ok());
    }
}
