use secrecy::zeroize::Zeroizing;
use uuid::Uuid;

// Credential Manager caps one credential's blob, so a longer secret goes on in `<target>/1`, `<target>/2` and on.
pub(crate) trait PartStore {
    type Error;

    fn read(&self, target: &str) -> Result<Option<Stored>, Self::Error>;

    fn write(&self, target: &str, blob: &[u8], label: &str, layout: Option<Layout>) -> Result<(), Self::Error>;

    // Ok(false) lets a cleanup stop at the first part that is gone.
    fn delete(&self, target: &str) -> Result<bool, Self::Error>;
}

pub(crate) struct Stored {
    pub(crate) blob: Zeroizing<Vec<u8>>,
    pub(crate) layout: Option<Layout>,
}

// Every part of a split secret carries it, so a write cut short between parts reads as no secret, never as a mix.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Layout {
    pub(crate) write_id: [u8; 16],
    pub(crate) parts: u32,
    pub(crate) bytes: u32,
}

impl Layout {
    pub(crate) const SIZE: usize = 24;

    pub(crate) fn to_bytes(self) -> [u8; Self::SIZE] {
        let mut bytes = [0; Self::SIZE];
        bytes[..16].copy_from_slice(&self.write_id);
        bytes[16..20].copy_from_slice(&self.parts.to_le_bytes());
        bytes[20..].copy_from_slice(&self.bytes.to_le_bytes());
        bytes
    }

    pub(crate) fn from_bytes(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != Self::SIZE {
            return None;
        }
        Some(Self {
            write_id: bytes[..16].try_into().ok()?,
            parts: u32::from_le_bytes(bytes[16..20].try_into().ok()?),
            bytes: u32::from_le_bytes(bytes[20..].try_into().ok()?),
        })
    }
}

pub(crate) fn part_target(target: &str, index: usize) -> String {
    if index == 0 {
        target.to_owned()
    } else {
        format!("{target}/{index}")
    }
}

// A secret one credential holds has no layout, as every secret stored before the split had none.
pub(crate) fn read_secret<S: PartStore>(store: &S, target: &str) -> Result<Option<Zeroizing<Vec<u8>>>, S::Error> {
    let Some(first) = store.read(target)? else {
        return Ok(None);
    };
    let Some(layout) = first.layout else {
        return Ok(Some(first.blob));
    };
    let mut parts = vec![first.blob];
    for index in 1..layout.parts as usize {
        match store.read(&part_target(target, index))? {
            Some(part) if part.layout == Some(layout) => parts.push(part.blob),
            _ => return Ok(torn(target)),
        }
    }
    let size: usize = parts.iter().map(|part| part.len()).sum();
    if size != layout.bytes as usize {
        return Ok(torn(target));
    }
    // Sized up front: a growing buffer would leave parts of the secret in the memory it gave up.
    let mut blob = Zeroizing::new(Vec::with_capacity(size));
    for part in &parts {
        blob.extend_from_slice(part);
    }
    Ok(Some(blob))
}

// Read as not stored, so the app asks for the secret again rather than send a wrong one.
fn torn(target: &str) -> Option<Zeroizing<Vec<u8>>> {
    tracing::warn!(
        credential = target,
        "a secret split over several credentials has a part missing or from another write"
    );
    None
}

pub(crate) fn write_secret<S: PartStore>(
    store: &S,
    target: &str,
    blob: &[u8],
    label: &str,
    part_size: usize,
) -> Result<(), S::Error> {
    let before = held_parts(store, target)?;
    let parts: Vec<&[u8]> = if blob.len() <= part_size {
        vec![blob]
    } else {
        blob.chunks(part_size).collect()
    };
    let layout = match (u32::try_from(parts.len()), u32::try_from(blob.len())) {
        (Ok(count), Ok(bytes)) if count > 1 => Some(Layout {
            write_id: Uuid::new_v4().into_bytes(),
            parts: count,
            bytes,
        }),
        _ => None,
    };
    // The first part goes last, so a write cut short leaves the secret before it whole or reads as none.
    for (index, part) in parts.iter().enumerate().skip(1) {
        store.write(&part_target(target, index), part, label, layout)?;
    }
    store.write(target, parts[0], label, layout)?;
    delete_parts(store, target, parts.len(), before)
}

pub(crate) fn delete_secret<S: PartStore>(store: &S, target: &str) -> Result<(), S::Error> {
    let before = held_parts(store, target)?;
    delete_parts(store, target, 1, before)?;
    store.delete(target)?;
    Ok(())
}

fn held_parts<S: PartStore>(store: &S, target: &str) -> Result<usize, S::Error> {
    Ok(store
        .read(target)?
        .and_then(|stored| stored.layout)
        .map_or(1, |layout| layout.parts as usize))
}

// The parts of the secret before, last first, so a cleanup cut short leaves a run from `from` the next one finds.
fn delete_parts<S: PartStore>(store: &S, target: &str, from: usize, before: usize) -> Result<(), S::Error> {
    for index in (from..before).rev() {
        store.delete(&part_target(target, index))?;
    }
    let mut index = from.max(before);
    while store.delete(&part_target(target, index))? {
        index += 1;
    }
    Ok(())
}

// CredWriteW refuses a longer comment, and the label only describes the entry, so it is cut between characters.
pub(crate) fn fitted(label: &str, units: usize) -> &str {
    let mut used = 0;
    for (index, character) in label.char_indices() {
        used += character.len_utf16();
        if used > units {
            return &label[..index];
        }
    }
    label
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::BTreeMap;

    const SIZE: usize = 4;

    type Held = BTreeMap<String, (Vec<u8>, Option<Layout>)>;

    // Refuses a blob over SIZE bytes, as CredWriteW refuses one over CRED_MAX_CREDENTIAL_BLOB_SIZE.
    #[derive(Default)]
    struct Store {
        held: RefCell<Held>,
        refuses: Option<String>,
    }

    impl PartStore for Store {
        type Error = String;

        fn read(&self, target: &str) -> Result<Option<Stored>, String> {
            Ok(self.held.borrow().get(target).map(|(blob, layout)| Stored {
                blob: Zeroizing::new(blob.clone()),
                layout: *layout,
            }))
        }

        fn write(&self, target: &str, blob: &[u8], _label: &str, layout: Option<Layout>) -> Result<(), String> {
            if blob.len() > SIZE || self.refuses.as_deref() == Some(target) {
                return Err(format!("refused {target}"));
            }
            self.held
                .borrow_mut()
                .insert(target.to_owned(), (blob.to_vec(), layout));
            Ok(())
        }

        fn delete(&self, target: &str) -> Result<bool, String> {
            Ok(self.held.borrow_mut().remove(target).is_some())
        }
    }

    impl Store {
        fn names(&self) -> Vec<String> {
            self.held.borrow().keys().cloned().collect()
        }

        fn secret(&self) -> Option<Vec<u8>> {
            read_secret(self, "t").unwrap().map(|blob| blob.to_vec())
        }

        fn save(&self, secret: &[u8]) -> Result<(), String> {
            write_secret(self, "t", secret, "label", SIZE)
        }

        fn put(&self, target: &str, blob: &[u8]) {
            self.held.borrow_mut().insert(target.to_owned(), (blob.to_vec(), None));
        }
    }

    #[test]
    fn a_secret_longer_than_one_part_reads_back_whole() {
        let store = Store::default();

        store.save(b"0123456789").unwrap();

        assert_eq!(store.names(), ["t", "t/1", "t/2"]);
        assert_eq!(store.secret(), Some(b"0123456789".to_vec()));
    }

    #[test]
    fn a_secret_that_fills_its_parts_exactly_reads_back() {
        let store = Store::default();

        store.save(b"01234567").unwrap();

        assert_eq!(store.names(), ["t", "t/1"]);
        assert_eq!(store.secret(), Some(b"01234567".to_vec()));
    }

    #[test]
    fn a_secret_one_part_holds_is_stored_as_before_the_split() {
        let store = Store::default();
        store.put("t", b"ab");

        assert_eq!(store.secret(), Some(b"ab".to_vec()));

        store.save(b"abcd").unwrap();

        assert_eq!(store.held.borrow()["t"], (b"abcd".to_vec(), None));
    }

    #[test]
    fn a_shorter_secret_leaves_none_of_a_longer_ones_parts() {
        let store = Store::default();
        store.save(b"0123456789").unwrap();

        store.save(b"abcd").unwrap();

        assert_eq!(store.names(), ["t"]);
        assert_eq!(store.secret(), Some(b"abcd".to_vec()));
    }

    #[test]
    fn an_empty_secret_is_stored_as_one() {
        let store = Store::default();
        store.save(b"0123456789").unwrap();

        store.save(b"").unwrap();

        assert_eq!(store.names(), ["t"]);
        assert_eq!(store.secret(), Some(Vec::new()));
    }

    #[test]
    fn deleting_removes_every_part_and_a_missing_secret_reads_as_none() {
        let store = Store::default();
        store.save(b"0123456789").unwrap();
        store.put("other", b"kept");

        delete_secret(&store, "t").unwrap();

        assert_eq!(store.names(), ["other"]);
        assert_eq!(store.secret(), None);
    }

    #[test]
    fn a_write_cut_short_over_a_split_secret_reads_as_none_never_a_mix() {
        let store = Store::default();
        store.save(b"0123456789").unwrap();
        let refusing = Store {
            held: RefCell::new(store.held.borrow().clone()),
            refuses: Some("t".to_owned()),
        };

        assert!(refusing.save(b"abcdefghij").is_err());

        assert_eq!(refusing.secret(), None);
    }

    #[test]
    fn a_write_cut_short_keeps_the_secret_one_credential_held() {
        let store = Store {
            refuses: Some("t/2".to_owned()),
            ..Store::default()
        };
        store.put("t", b"ab");

        assert!(store.save(b"0123456789").is_err());

        assert_eq!(store.secret(), Some(b"ab".to_vec()));
    }

    #[test]
    fn parts_a_cleanup_left_behind_go_with_the_next_write_or_delete() {
        let store = Store::default();
        store.put("t", b"ab");
        store.put("t/1", b"0123");
        store.put("t/2", b"45");

        store.save(b"xy").unwrap();

        assert_eq!(store.names(), ["t"]);

        store.held.borrow_mut().remove("t");
        store.put("t/1", b"0123");

        delete_secret(&store, "t").unwrap();

        assert!(store.names().is_empty());
    }

    #[test]
    fn a_layout_reads_back_from_its_bytes() {
        let layout = Layout {
            write_id: *Uuid::new_v4().as_bytes(),
            parts: 3,
            bytes: 6000,
        };

        assert_eq!(Layout::from_bytes(&layout.to_bytes()), Some(layout));
        assert_eq!(Layout::from_bytes(&[0; 8]), None);
    }

    #[test]
    fn a_label_is_cut_between_characters() {
        assert_eq!(fitted("short", 255), "short");
        assert_eq!(fitted("abcdef", 4), "abcd");
        // The key is two UTF-16 units, which a cut never splits.
        assert_eq!(fitted("abc\u{1f511}d", 4), "abc");
        assert_eq!(fitted("abc\u{1f511}d", 5), "abc\u{1f511}");
    }
}
