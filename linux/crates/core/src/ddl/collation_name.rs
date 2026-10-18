/// A collation as the catalogue names it.
///
/// PostgreSQL collations are schema objects, so `"de_DE"` in one schema
/// is not the one in `pg_catalog`. Engines whose collations are global
/// leave `schema` as `None`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CollationName {
    pub schema: Option<String>,
    pub name: String,
}

impl CollationName {
    pub fn new(schema: Option<String>, name: impl Into<String>) -> Self {
        Self {
            schema,
            name: name.into(),
        }
    }
}
