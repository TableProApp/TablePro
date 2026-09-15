use std::collections::HashMap;

use tablepro_core::credentials::SecretKind;
use uuid::Uuid;

/// Attributes for one secret. The Secret Service matches these exactly,
/// so their shape is a compatibility surface.
pub(super) fn for_secret(schema: &str, id: Uuid, kind: SecretKind) -> HashMap<&'static str, String> {
    let mut attributes = for_connection(schema, id);
    attributes.insert("kind", kind.attribute().to_owned());
    attributes
}

/// Attributes matching every secret of one connection, so a delete can
/// remove all three kinds in a single call.
pub(super) fn for_connection(schema: &str, id: Uuid) -> HashMap<&'static str, String> {
    let mut attributes = HashMap::new();
    attributes.insert("xdg:schema", schema.to_owned());
    attributes.insert("connection-id", id.to_string());
    attributes
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCHEMA: &str = "app.tablepro.TablePro.Password";

    #[test]
    fn attributes_for_connection_omit_kind() {
        let id = Uuid::new_v4();

        let connection = for_connection(SCHEMA, id);
        let secret = for_secret(SCHEMA, id, SecretKind::DatabasePassword);

        assert!(!connection.contains_key("kind"));
        assert_eq!(connection.get("xdg:schema").map(String::as_str), Some(SCHEMA));
        assert_eq!(secret.get("kind").map(String::as_str), Some("db_password"));
        assert_eq!(connection.get("connection-id"), secret.get("connection-id"));
    }

    #[test]
    fn each_kind_has_a_distinct_attribute() {
        let id = Uuid::new_v4();
        let mut seen = std::collections::HashSet::new();

        for kind in SecretKind::ALL {
            let attributes = for_secret(SCHEMA, id, kind);
            assert!(
                seen.insert(attributes.get("kind").cloned()),
                "{kind:?} reuses another kind's attribute"
            );
        }
    }

    #[test]
    fn a_different_schema_is_a_different_item() {
        let id = Uuid::new_v4();

        let installed = for_secret(SCHEMA, id, SecretKind::DatabasePassword);
        let devel = for_secret("app.tablepro.TablePro.Devel.Password", id, SecretKind::DatabasePassword);

        assert_ne!(installed.get("xdg:schema"), devel.get("xdg:schema"));
    }

    #[test]
    fn the_uuid_is_canonical_lowercase_hyphenated() {
        let id = Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").expect("a valid uuid");

        let attributes = for_connection(SCHEMA, id);

        assert_eq!(
            attributes.get("connection-id").map(String::as_str),
            Some("550e8400-e29b-41d4-a716-446655440000")
        );
    }
}
