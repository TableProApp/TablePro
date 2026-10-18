/// A schema the connection can see.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SchemaInfo {
    pub name: String,
    /// The one unqualified names resolve to, which the sidebar opens
    /// first.
    pub is_default: bool,
    /// The engine's own, such as `pg_catalog`. Hidden unless the user
    /// asks for it.
    pub is_system: bool,
}

/// Which schemas to list objects from.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ObjectScope {
    DefaultSchema,
    Schema(String),
    AllSchemas,
}
