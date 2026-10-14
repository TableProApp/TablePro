use tablepro_core::meta::SchemaInfo;

/// Whether a table tab names the table's schema.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) enum TableNaming {
    #[default]
    Bare,
    SchemaQualified,
}

impl TableNaming {
    /// Qualified once the user has two schemas of their own to tell
    /// apart; the engine's own schemas do not count.
    pub(crate) fn of(schemas: &[SchemaInfo]) -> Self {
        match schemas.iter().filter(|schema| !schema.is_system).count() {
            0 | 1 => Self::Bare,
            _ => Self::SchemaQualified,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn schema(name: &str, is_system: bool) -> SchemaInfo {
        SchemaInfo {
            name: name.to_owned(),
            is_default: name == "public",
            is_system,
        }
    }

    #[test]
    fn system_schemas_do_not_make_names_qualified() {
        let schemas = [schema("public", false), schema("pg_catalog", true)];

        assert_eq!(TableNaming::of(&schemas), TableNaming::Bare);
        assert_eq!(
            TableNaming::of(&[schema("public", false), schema("sales", false)]),
            TableNaming::SchemaQualified
        );
    }
}
