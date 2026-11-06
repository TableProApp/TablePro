/// A schema to create.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct SchemaDraft {
    pub name: String,
    /// The role that owns it, or the user who creates it. Only an engine
    /// with `schema_owner` takes one.
    pub owner: Option<String>,
}

/// How a schema is dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct DropSchemaOptions {
    /// Drop everything in it, and what depends on that elsewhere. Only an
    /// engine with `drop_schema_cascade` takes it.
    pub cascade: bool,
}
