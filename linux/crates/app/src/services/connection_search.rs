//! What the picker's search matches a saved connection against.

use tablepro_storage::{ConnectionTag, SavedConnection};

/// The words typed into the picker's search, each of which a connection
/// has to hold somewhere for it to show. Empty shows every connection.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct ConnectionSearch {
    terms: Vec<String>,
}

impl ConnectionSearch {
    pub(crate) fn new(text: &str) -> Self {
        Self {
            terms: text.split_whitespace().map(str::to_lowercase).collect(),
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.terms.is_empty()
    }

    /// Whether every word is in the connection's name, where it
    /// connects, its driver, its group or one of its tags' names, in any
    /// case. `tags` is the list's, to read the names of `saved`'s from.
    pub(crate) fn matches(&self, saved: &SavedConnection, tags: &[ConnectionTag]) -> bool {
        if self.terms.is_empty() {
            return true;
        }
        let mut fields: Vec<String> = [
            Some(saved.name.as_str()),
            Some(saved.host.as_str()),
            Some(saved.database.as_str()),
            Some(saved.username.as_str()),
            Some(saved.driver_id.as_str()),
            saved.group.as_ref().map(|group| group.as_str()),
        ]
        .into_iter()
        .flatten()
        .map(str::to_lowercase)
        .collect();
        fields.extend(
            tags.iter()
                .filter(|tag| saved.tags.contains(&tag.id))
                .map(|tag| tag.name.as_str().to_lowercase()),
        );
        self.terms
            .iter()
            .all(|term| fields.iter().any(|field| field.contains(term.as_str())))
    }
}

#[cfg(test)]
mod tests {
    use tablepro_storage::{ConnectionColor, ConnectionGroupName, ConnectionTagName};
    use uuid::Uuid;

    use super::*;

    fn tag(name: &str) -> ConnectionTag {
        ConnectionTag::new(ConnectionTagName::new(name).expect("a tag name"), ConnectionColor::Red)
    }

    fn saved(name: &str, tags: &[&ConnectionTag]) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: name.to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db.acme.example".to_owned(),
            port: 5432,
            database: "orders".to_owned(),
            username: "deploy".to_owned(),
            tls: tablepro_core::TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: Some(ConnectionGroupName::new("Clients").expect("a group name")),
            tags: tags.iter().map(|tag| tag.id).collect(),
            icon: None,
            options: Default::default(),
        }
    }

    #[test]
    fn a_tag_name_finds_every_connection_that_has_it() {
        let (production, staging) = (tag("production"), tag("staging"));
        let tags = [production.clone(), staging.clone()];
        let acme = saved("acme-prod", &[&production]);
        let globex = saved("globex-prod", &[&production, &staging]);
        let dev = saved("acme-dev", &[&staging]);

        let search = ConnectionSearch::new("Production");

        assert!(search.matches(&acme, &tags));
        assert!(search.matches(&globex, &tags));
        assert!(!search.matches(&dev, &tags));
    }

    #[test]
    fn a_tag_the_connection_does_not_carry_matches_nothing() {
        let production = tag("production");
        let untagged = saved("acme", &[]);

        assert!(!ConnectionSearch::new("production").matches(&untagged, &[production]));
    }

    #[test]
    fn each_word_has_to_match_some_field() {
        let production = tag("production");
        let tags = [production.clone()];
        let acme = saved("acme-prod", &[&production]);

        for (text, shown) in [
            ("acme production", true),
            ("ORDERS deploy", true),
            ("clients postgres", true),
            ("db.acme", true),
            ("acme staging", false),
            ("", true),
            ("   ", true),
        ] {
            assert_eq!(ConnectionSearch::new(text).matches(&acme, &tags), shown, "{text:?}");
        }
        assert!(ConnectionSearch::new(" \t ").is_empty());
        assert_eq!(ConnectionSearch::new("a  B"), ConnectionSearch::new("A b"));
    }
}
