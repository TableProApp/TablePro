//! A session as the target of a window action, so a tree row or a toast
//! names the session it acts on rather than the one in front.

use gtk4::glib;
use gtk4::prelude::*;
use tablepro_session::SessionKey;
use uuid::Uuid;

const SAVED: &str = "saved:";
const FILE: &str = "file:";

/// `saved:<uuid>` or `file:<uri>`.
pub(crate) fn to_variant(key: &SessionKey) -> glib::Variant {
    match key {
        SessionKey::Saved(id) => format!("{SAVED}{id}"),
        SessionKey::File(uri) => format!("{FILE}{uri}"),
    }
    .to_variant()
}

/// `None` for a target no session key spells.
pub(crate) fn from_variant(value: &glib::Variant) -> Option<SessionKey> {
    let text = value.str()?;
    if let Some(id) = text.strip_prefix(SAVED) {
        return Uuid::parse_str(id).ok().map(SessionKey::Saved);
    }
    text.strip_prefix(FILE)
        .filter(|uri| glib::Uri::peek_scheme(uri).is_some())
        .map(|uri| SessionKey::File(uri.to_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_round_trips() {
        let keys = [
            SessionKey::Saved(Uuid::new_v4()),
            SessionKey::File("file:///home/u/R%26D/sales.db".to_owned()),
            SessionKey::File("file:///srv/caf%C3%A9.sqlite3".to_owned()),
        ];

        for key in keys {
            assert_eq!(from_variant(&to_variant(&key)), Some(key));
        }
    }

    #[test]
    fn the_target_is_a_string() {
        let id = Uuid::new_v4();

        let target = to_variant(&SessionKey::Saved(id));

        assert_eq!(target.str(), Some(format!("saved:{id}").as_str()));
        assert_eq!(
            to_variant(&SessionKey::File("file:///srv/app.db".to_owned())).str(),
            Some("file:file:///srv/app.db")
        );
    }

    #[test]
    fn what_is_not_a_key_names_no_session() {
        for text in [
            "",
            "saved:",
            "saved:not-a-uuid",
            "file:",
            "table:users",
            "file:///srv/app.db",
        ] {
            assert_eq!(from_variant(&text.to_variant()), None, "{text}");
        }
        assert_eq!(from_variant(&7u32.to_variant()), None);
    }
}
