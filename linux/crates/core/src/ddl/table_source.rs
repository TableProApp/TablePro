use super::SchemaObjectSource;

/// A table as the server would recreate it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TableSource {
    pub create_statement: String,
    /// Indexes, triggers and views a rebuild has to replay, in the order
    /// the schema created them.
    pub dependents: Vec<SchemaObjectSource>,
}
