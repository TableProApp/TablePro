/// A table, named the way the server would qualify it.
///
/// `None` for the schema means the engine has no schemas, or the
/// table sits in the connection's default one. It is not the same as
/// an empty string, which would qualify to `"".name`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TableRef {
    pub schema: Option<String>,
    pub name: String,
}

impl TableRef {
    pub fn new(schema: Option<String>, name: impl Into<String>) -> Self {
        Self {
            schema,
            name: name.into(),
        }
    }

    pub fn unqualified(name: impl Into<String>) -> Self {
        Self::new(None, name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_schema_of_none_is_not_an_empty_schema() {
        assert_ne!(
            TableRef::unqualified("users"),
            TableRef::new(Some(String::new()), "users")
        );
    }
}
