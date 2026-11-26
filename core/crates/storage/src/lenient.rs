use std::collections::HashSet;
use std::ops::{Deref, DerefMut};

use serde::de::DeserializeOwned;
use serde::ser::SerializeSeq;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use uuid::Uuid;

/// A list of a document read entry by entry.
///
/// An entry this build cannot read, such as one a newer build wrote with a value this one does not
/// know, is held as it was and written back after the others, so it survives the rewrite and the rest
/// of the file stays usable. A readable entry with the same id replaces it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Lenient<T> {
    read: Vec<T>,
    held: Vec<Value>,
}

impl<T> Default for Lenient<T> {
    fn default() -> Self {
        Self {
            read: Vec::new(),
            held: Vec::new(),
        }
    }
}

impl<T> Lenient<T> {
    pub(crate) fn held_ids(&self) -> Vec<Uuid> {
        self.held.iter().filter_map(entry_id).collect()
    }

    pub(crate) fn held_count(&self) -> usize {
        self.held.len()
    }

    pub(crate) fn held_entries(&self) -> impl Iterator<Item = (Uuid, &Value)> {
        self.held.iter().filter_map(|entry| Some((entry_id(entry)?, entry)))
    }

    /// Drop the held copies of `id`, once a readable one takes its place or the entry is deleted.
    /// Returns whether there was one.
    pub(crate) fn release(&mut self, id: Uuid) -> bool {
        let before = self.held.len();
        self.held.retain(|entry| entry_id(entry) != Some(id));
        self.held.len() < before
    }

    /// Removes the entry with `id`, readable or held. Returns whether there was one.
    pub(crate) fn remove_id(&mut self, id: Uuid) -> bool
    where
        T: Identified,
    {
        let before = self.read.len();
        self.read.retain(|entry| entry.id() != id);
        let held = self.release(id);
        held || self.read.len() < before
    }

    pub(crate) fn without_held(&self) -> Self
    where
        T: Clone,
    {
        Self {
            read: self.read.clone(),
            held: Vec::new(),
        }
    }
}

impl<T> From<Vec<T>> for Lenient<T> {
    fn from(read: Vec<T>) -> Self {
        Self { read, held: Vec::new() }
    }
}

impl<T> Deref for Lenient<T> {
    type Target = Vec<T>;

    fn deref(&self) -> &Vec<T> {
        &self.read
    }
}

impl<T> DerefMut for Lenient<T> {
    fn deref_mut(&mut self) -> &mut Vec<T> {
        &mut self.read
    }
}

impl<'a, T> IntoIterator for &'a Lenient<T> {
    type Item = &'a T;
    type IntoIter = std::slice::Iter<'a, T>;

    fn into_iter(self) -> Self::IntoIter {
        self.read.iter()
    }
}

impl<'a, T> IntoIterator for &'a mut Lenient<T> {
    type Item = &'a mut T;
    type IntoIter = std::slice::IterMut<'a, T>;

    fn into_iter(self) -> Self::IntoIter {
        self.read.iter_mut()
    }
}

impl<T: Serialize> Serialize for Lenient<T> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.read.len() + self.held.len()))?;
        for entry in &self.read {
            seq.serialize_element(entry)?;
        }
        for entry in &self.held {
            seq.serialize_element(entry)?;
        }
        seq.end()
    }
}

impl<'de, T: DeserializeOwned + Identified> Deserialize<'de> for Lenient<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let entries = Vec::<Value>::deserialize(deserializer)?;
        let mut read = Vec::with_capacity(entries.len());
        let mut held = Vec::new();
        for entry in entries {
            match T::deserialize(&entry) {
                Ok(value) => read.push(value),
                Err(_) => held.push(entry),
            }
        }
        let readable: HashSet<Uuid> = read.iter().map(Identified::id).collect();
        held.retain(|entry| entry_id(entry).is_none_or(|id| !readable.contains(&id)));
        if !held.is_empty() {
            tracing::warn!(entries = held.len(), "kept list entries this build cannot read");
        }
        Ok(Self { read, held })
    }
}

/// An entry that a list names by its UUID.
pub(crate) trait Identified {
    fn id(&self) -> Uuid;
}

fn entry_id(entry: &Value) -> Option<Uuid> {
    entry
        .get("id")
        .and_then(Value::as_str)
        .and_then(|id| Uuid::parse_str(id).ok())
}

#[cfg(test)]
#[expect(
    clippy::disallowed_types,
    reason = "JSON in a test is written with json!; its key order means nothing to the store"
)]
mod tests {
    use super::*;

    #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
    struct Item {
        id: Uuid,
        mode: Mode,
    }

    #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
    #[serde(rename_all = "snake_case")]
    enum Mode {
        Plain,
    }

    impl Identified for Item {
        fn id(&self) -> Uuid {
            self.id
        }
    }

    #[test]
    fn an_entry_with_an_unknown_value_is_held_and_written_back() {
        let unknown = Uuid::new_v4();
        let known = Uuid::new_v4();
        let text = format!(r#"[{{"id":"{unknown}","mode":"newer"}},{{"id":"{known}","mode":"plain"}}]"#);

        let list: Lenient<Item> = serde_json::from_str(&text).unwrap();
        let written = serde_json::to_value(&list).unwrap();

        assert_eq!(list.len(), 1);
        assert_eq!(list.held_ids(), vec![unknown]);
        assert_eq!(
            written,
            serde_json::json!([{"id": known, "mode": "plain"}, {"id": unknown, "mode": "newer"}])
        );
    }

    #[test]
    fn a_readable_entry_replaces_the_held_one() {
        let id = Uuid::new_v4();
        let text = format!(r#"[{{"id":"{id}","mode":"newer"}}]"#);
        let mut list: Lenient<Item> = serde_json::from_str(&text).unwrap();

        list.release(id);
        list.push(Item { id, mode: Mode::Plain });

        assert_eq!(list.held_count(), 0);
        assert_eq!(
            serde_json::to_value(&list).unwrap(),
            serde_json::json!([{"id": id, "mode": "plain"}])
        );
    }

    #[test]
    fn a_held_duplicate_of_a_readable_entry_is_dropped() {
        let id = Uuid::new_v4();
        let text = format!(r#"[{{"id":"{id}","mode":"plain"}},{{"id":"{id}","mode":"newer"}}]"#);

        let list: Lenient<Item> = serde_json::from_str(&text).unwrap();

        assert_eq!(list.len(), 1);
        assert_eq!(list.held_count(), 0);
    }
}
