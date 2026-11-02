use crate::AiProvider;

/// A secret that belongs to no saved connection, so deleting a
/// connection's secrets never reaches it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SecretItem {
    /// The token MCP clients present.
    McpToken,
    AiKey(AiProvider),
}
