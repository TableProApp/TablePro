use crate::ddl::ReferentialAction;

/// A foreign key as the catalogue reports it.
///
/// The actions are typed rather than kept as the server's keyword
/// string, so the DDL builder and the UI cannot disagree about what
/// `NO ACTION` means. `None` is a keyword this build does not know: the
/// UI shows nothing and generated DDL omits the clause, leaving the
/// server's own default in place.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignKeyInfo {
    pub name: String,
    pub columns: Vec<String>,
    pub ref_schema: Option<String>,
    pub ref_table: String,
    pub ref_columns: Vec<String>,
    pub on_delete: Option<ReferentialAction>,
    pub on_update: Option<ReferentialAction>,
}

impl ForeignKeyInfo {
    /// Whether this key is the inbound side of a relationship, which
    /// the structure tab lists separately from the outbound ones.
    pub fn references(&self, schema: Option<&str>, table: &str) -> bool {
        self.ref_table == table && self.ref_schema.as_deref() == schema
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> ForeignKeyInfo {
        ForeignKeyInfo {
            name: "orders_customer_id_fkey".to_owned(),
            columns: vec!["customer_id".to_owned()],
            ref_schema: Some("public".to_owned()),
            ref_table: "customers".to_owned(),
            ref_columns: vec!["id".to_owned()],
            on_delete: Some(ReferentialAction::Cascade),
            on_update: None,
        }
    }

    #[test]
    fn references_matches_schema_and_table_together() {
        let key = key();

        assert!(key.references(Some("public"), "customers"));
        assert!(!key.references(Some("audit"), "customers"));
        assert!(!key.references(Some("public"), "orders"));
        assert!(!key.references(None, "customers"));
    }

    #[test]
    fn an_unknown_action_is_none_rather_than_a_guess() {
        assert_eq!(key().on_update, None);
        assert_eq!(key().on_delete, Some(ReferentialAction::Cascade));
    }
}
