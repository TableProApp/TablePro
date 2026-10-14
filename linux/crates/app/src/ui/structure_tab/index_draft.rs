//! An index as the Add Index dialog holds it, checked on every change.

use tablepro_core::IndexInfo;
use tablepro_core::meta::IndexKey;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct IndexDraft {
    pub name: String,
    pub unique: bool,
    /// In key order, each column at most once.
    pub keys: Vec<DraftKey>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DraftKey {
    pub column: String,
    pub descending: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum IndexDraftError {
    NameMissing,
    NameTaken,
    NoKeys,
}

impl IndexDraftError {
    pub(crate) fn message(self) -> String {
        match self {
            Self::NameMissing => crate::i18n::gettext("Index name is required."),
            Self::NameTaken => crate::i18n::gettext("The table already has an index with this name."),
            Self::NoKeys => crate::i18n::gettext("Add at least one key column."),
        }
    }
}

impl IndexDraft {
    /// The index, or every problem in the order the form shows its
    /// fields. `existing` are the names the table's indexes already
    /// take.
    pub(crate) fn validate(&self, existing: &[String]) -> Result<IndexInfo, Vec<IndexDraftError>> {
        let name = self.name.trim();
        let mut errors = Vec::new();
        if name.is_empty() {
            errors.push(IndexDraftError::NameMissing);
        } else if existing.iter().any(|taken| same_name(taken, name)) {
            errors.push(IndexDraftError::NameTaken);
        }
        if self.keys.is_empty() {
            errors.push(IndexDraftError::NoKeys);
        }
        if !errors.is_empty() {
            return Err(errors);
        }
        Ok(IndexInfo {
            name: name.to_owned(),
            keys: self
                .keys
                .iter()
                .map(|key| IndexKey::Column {
                    name: key.column.clone(),
                    descending: key.descending,
                })
                .collect(),
            unique: self.unique,
            primary: false,
            predicate: None,
        })
    }

    /// The columns of `columns` no key uses yet, in table order.
    pub(crate) fn unused<'a>(&self, columns: &'a [String]) -> Vec<&'a str> {
        columns
            .iter()
            .map(String::as_str)
            .filter(|column| !self.keys.iter().any(|key| key.column == *column))
            .collect()
    }

    pub(crate) fn add_key(&mut self, column: &str) {
        if !self.keys.iter().any(|key| key.column == column) {
            self.keys.push(DraftKey {
                column: column.to_owned(),
                descending: false,
            });
        }
    }

    pub(crate) fn remove_key(&mut self, position: usize) {
        if position < self.keys.len() {
            self.keys.remove(position);
        }
    }

    pub(crate) fn set_descending(&mut self, position: usize, descending: bool) {
        if let Some(key) = self.keys.get_mut(position) {
            key.descending = descending;
        }
    }

    /// Swap the key at `position` with the one before it, or after it
    /// when `up` is false. A key at the end it moves toward stays.
    pub(crate) fn move_key(&mut self, position: usize, up: bool) {
        let other = match up {
            true => position.checked_sub(1),
            false => position.checked_add(1).filter(|other| *other < self.keys.len()),
        };
        if let Some(other) = other
            && position < self.keys.len()
        {
            self.keys.swap(position, other);
        }
    }
}

/// Engines differ on whether names fold case, so two that differ only
/// in case are taken as the same.
pub(crate) fn same_name(left: &str, right: &str) -> bool {
    left.trim().to_lowercase() == right.trim().to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn draft(name: &str, keys: &[&str]) -> IndexDraft {
        let mut draft = IndexDraft {
            name: name.to_owned(),
            ..IndexDraft::default()
        };
        for key in keys {
            draft.add_key(key);
        }
        draft
    }

    #[test]
    fn index_requires_name_and_key() {
        assert_eq!(
            draft(" ", &[]).validate(&[]),
            Err(vec![IndexDraftError::NameMissing, IndexDraftError::NoKeys])
        );
        assert_eq!(draft("by_email", &[]).validate(&[]), Err(vec![IndexDraftError::NoKeys]));
        assert_eq!(
            draft("", &["email"]).validate(&[]),
            Err(vec![IndexDraftError::NameMissing])
        );
        let index = draft(" by_email ", &["email"]).validate(&[]).expect("a valid index");
        assert_eq!(index.name, "by_email");
        assert!(!index.primary && index.predicate.is_none());
    }

    #[test]
    fn index_name_unique_case_insensitively() {
        let existing = vec!["By_Email".to_owned()];

        assert_eq!(
            draft("by_email", &["email"]).validate(&existing),
            Err(vec![IndexDraftError::NameTaken])
        );
        assert_eq!(
            draft("BY_EMAIL", &["email"]).validate(&existing),
            Err(vec![IndexDraftError::NameTaken])
        );
        assert!(draft("by_email_2", &["email"]).validate(&existing).is_ok());
    }

    #[test]
    fn key_order_is_preserved() {
        let mut draft = draft("by_name", &["last", "first", "last"]);
        draft.set_descending(1, true);

        let keys = draft.validate(&[]).expect("a valid index").keys;
        assert_eq!(
            keys,
            [
                IndexKey::Column {
                    name: "last".to_owned(),
                    descending: false
                },
                IndexKey::Column {
                    name: "first".to_owned(),
                    descending: true
                },
            ]
        );

        draft.move_key(1, true);
        draft.move_key(0, true);
        draft.move_key(1, false);
        assert_eq!(
            draft.keys.iter().map(|key| key.column.as_str()).collect::<Vec<_>>(),
            ["first", "last"]
        );
        let columns = ["first".to_owned(), "middle".to_owned(), "last".to_owned()];
        assert_eq!(draft.unused(&columns), ["middle"]);
        draft.remove_key(0);
        assert_eq!(draft.unused(&columns), ["first", "middle"]);
    }
}
