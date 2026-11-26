// The anchor in the device store (0054, Freshness): a root item with the file id, the current entry and at most one
// pending entry, and the checkpoint items each entry names by its digest. The root also keeps what an open found and
// no flow has settled yet, and the checkpoints a settle left unnamed until their items are gone.

use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use super::super::codec;
use crate::api::device_store::{DeviceItem, DeviceStoreError, HostDeviceStore};
use crate::api::error::StateError;
use crate::api::ids::{FileId, StateName};
use crate::api::state::{Checkpoint, Row, Table};

const ROOT_FORMAT: u8 = 1;
const CHECKPOINT_FORMAT: u8 = 1;

// Windows Credential Manager keeps at most 2,560 bytes in one item (0054, Windows).
pub(crate) const PART_BYTES: usize = if cfg!(windows) { 2560 } else { 64 * 1024 };

// The checkpoint tables, in the key digest's order.
pub(crate) const CHECKPOINT_TABLES: [Table; 3] = [Table::KeyPins, Table::KeyVersions, Table::KeyEnvelopes];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct CheckpointRef {
    pub(crate) digest: [u8; 32],
    pub(crate) parts: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Entry {
    pub(crate) counter: u64,
    pub(crate) mac: [u8; 32],
    pub(crate) key_digest: [u8; 32],
    pub(crate) checkpoint: CheckpointRef,
}

// What an open found of the key tables and no key flow has settled, strictest last.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Owed {
    Trusted,
    // The floor the rebuild accepts from, kept until the server showed all of it.
    Rebuild(CheckpointRef),
    Unanchored,
}

impl Owed {
    const fn rank(self) -> u8 {
        match self {
            Self::Trusted => 0,
            Self::Rebuild(_) => 1,
            Self::Unanchored => 2,
        }
    }

    // A newer finding replaces an owed rebuild's floor; a weaker one never loosens what is owed.
    pub(crate) fn stricter(self, found: Self) -> Self {
        if found.rank() >= self.rank() { found } else { self }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Root {
    pub(crate) file_id: FileId,
    pub(crate) owed: Owed,
    pub(crate) current: Option<Entry>,
    pub(crate) pending: Option<Entry>,
    // Checkpoints no entry names any more, whose items go once the root that drops them is stored.
    pub(crate) retired: Vec<CheckpointRef>,
}

impl Root {
    pub(crate) const fn new(file_id: FileId) -> Self {
        Self {
            file_id,
            owed: Owed::Trusted,
            current: None,
            pending: None,
            retired: Vec::new(),
        }
    }

    // The checkpoints whose items this root still needs: its entries' and an owed rebuild's floor.
    pub(crate) fn named(&self) -> Vec<CheckpointRef> {
        let floor = match self.owed {
            Owed::Rebuild(floor) => Some(floor),
            Owed::Trusted | Owed::Unanchored => None,
        };
        [
            self.current.map(|entry| entry.checkpoint),
            self.pending.map(|entry| entry.checkpoint),
            floor,
        ]
        .into_iter()
        .flatten()
        .collect()
    }

    pub(crate) fn names(&self, checkpoint: CheckpointRef) -> bool {
        self.named().contains(&checkpoint)
    }

    // What a rebuild accepts from: the pending entry's checkpoint when one is left (0054, A stale file).
    pub(crate) fn newest(&self) -> Option<CheckpointRef> {
        self.pending.or(self.current).map(|entry| entry.checkpoint)
    }

    // Retires a checkpoint this root stops naming.
    pub(crate) fn retire(&mut self, checkpoint: CheckpointRef) {
        if !self.names(checkpoint) && !self.retired.contains(&checkpoint) {
            self.retired.push(checkpoint);
        }
    }

    pub(crate) fn encode(&self) -> Vec<u8> {
        let mut out = vec![ROOT_FORMAT];
        out.extend_from_slice(&self.file_id.0);
        match self.owed {
            Owed::Trusted => out.push(0),
            Owed::Rebuild(floor) => {
                out.push(1);
                checkpoint_ref(&mut out, floor);
            }
            Owed::Unanchored => out.push(2),
        }
        for entry in [self.current, self.pending] {
            match entry {
                None => out.push(0),
                Some(entry) => {
                    out.push(1);
                    out.extend_from_slice(&entry.counter.to_be_bytes());
                    out.extend_from_slice(&entry.mac);
                    out.extend_from_slice(&entry.key_digest);
                    checkpoint_ref(&mut out, entry.checkpoint);
                }
            }
        }
        out.extend_from_slice(&u32::try_from(self.retired.len()).unwrap_or(u32::MAX).to_be_bytes());
        for retired in &self.retired {
            checkpoint_ref(&mut out, *retired);
        }
        out
    }

    pub(crate) fn decode(bytes: &[u8]) -> Option<Self> {
        let mut read = Bytes(bytes);
        if read.take::<1>()? != [ROOT_FORMAT] {
            return None;
        }
        let file_id = FileId(read.take()?);
        let owed = match read.take::<1>()? {
            [0] => Owed::Trusted,
            [1] => Owed::Rebuild(read.checkpoint_ref()?),
            [2] => Owed::Unanchored,
            _ => return None,
        };
        let mut entries = [None, None];
        for slot in &mut entries {
            *slot = match read.take::<1>()? {
                [0] => None,
                [1] => Some(Entry {
                    counter: u64::from_be_bytes(read.take()?),
                    mac: read.take()?,
                    key_digest: read.take()?,
                    checkpoint: read.checkpoint_ref()?,
                }),
                _ => return None,
            };
        }
        let count = u32::from_be_bytes(read.take()?);
        let retired = (0..count).map(|_| read.checkpoint_ref()).collect::<Option<Vec<_>>>()?;
        if !read.0.is_empty() {
            return None;
        }
        let [current, pending] = entries;
        Some(Self {
            file_id,
            owed,
            current,
            pending,
            retired,
        })
    }
}

fn checkpoint_ref(out: &mut Vec<u8>, checkpoint: CheckpointRef) {
    out.extend_from_slice(&checkpoint.digest);
    out.extend_from_slice(&checkpoint.parts.to_be_bytes());
}

struct Bytes<'a>(&'a [u8]);

impl Bytes<'_> {
    fn take<const N: usize>(&mut self) -> Option<[u8; N]> {
        let (taken, rest) = self.0.split_first_chunk::<N>()?;
        self.0 = rest;
        Some(*taken)
    }

    fn lp(&mut self) -> Option<Vec<u8>> {
        let length = usize::try_from(u32::from_be_bytes(self.take()?)).ok()?;
        let (taken, rest) = self.0.split_at_checked(length)?;
        self.0 = rest;
        Some(taken.to_vec())
    }

    fn checkpoint_ref(&mut self) -> Option<CheckpointRef> {
        Some(CheckpointRef {
            digest: self.take()?,
            parts: u32::from_be_bytes(self.take()?),
        })
    }
}

fn lp(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&u32::try_from(bytes.len()).unwrap_or(u32::MAX).to_be_bytes());
    out.extend_from_slice(bytes);
}

// The checkpoint's bytes: per table, in the key digest's order, its name, its row count, then each row as its encoded
// primary key and its columns, both framed, in key order.
pub(crate) fn checkpoint_bytes(checkpoint: &Checkpoint) -> Vec<u8> {
    let tables: [Vec<Row>; 3] = [
        checkpoint.pins.iter().cloned().map(Row::KeyPin).collect(),
        checkpoint.versions.iter().cloned().map(Row::KeyVersion).collect(),
        checkpoint.envelopes.iter().cloned().map(Row::KeyEnvelope).collect(),
    ];
    let mut out = vec![CHECKPOINT_FORMAT];
    for (table, rows) in CHECKPOINT_TABLES.into_iter().zip(tables) {
        let mut encoded: Vec<(Vec<u8>, Vec<u8>)> = rows
            .iter()
            .map(|row| (row.key().encoded(), codec::columns(row)))
            .collect();
        encoded.sort();
        lp(&mut out, table.name().as_bytes());
        out.extend_from_slice(&u32::try_from(encoded.len()).unwrap_or(u32::MAX).to_be_bytes());
        for (key, columns) in encoded {
            lp(&mut out, &key);
            lp(&mut out, &columns);
        }
    }
    out
}

pub(crate) fn decode_checkpoint(bytes: &[u8]) -> Option<Checkpoint> {
    let mut read = Bytes(bytes);
    if read.take::<1>()? != [CHECKPOINT_FORMAT] {
        return None;
    }
    let mut checkpoint = Checkpoint::default();
    for table in CHECKPOINT_TABLES {
        if read.lp()? != table.name().as_bytes() {
            return None;
        }
        let count = u32::from_be_bytes(read.take()?);
        for _ in 0..count {
            let key = read.lp()?;
            let columns = read.lp()?;
            match codec::decode(table, &key, &columns).ok()? {
                Row::KeyPin(row) => checkpoint.pins.push(row),
                Row::KeyVersion(row) => checkpoint.versions.push(row),
                Row::KeyEnvelope(row) => checkpoint.envelopes.push(row),
                _ => return None,
            }
        }
    }
    read.0.is_empty().then_some(checkpoint)
}

pub(crate) fn checkpoint_ref_of(bytes: &[u8], part_bytes: usize) -> CheckpointRef {
    let parts = bytes.len().div_ceil(part_bytes.max(1)).max(1);
    CheckpointRef {
        digest: Sha256::digest(bytes).into(),
        parts: u32::try_from(parts).unwrap_or(u32::MAX),
    }
}

// Which failures leave the anchor unknown rather than absent.
pub(crate) fn unsettled(error: &DeviceStoreError) -> StateError {
    tracing::debug!(code = error.code(), "the anchor could not be read or written");
    StateError::AnchorUnsettled
}

pub(crate) struct Items<'a> {
    pub(crate) store: &'a dyn HostDeviceStore,
    pub(crate) name: &'a StateName,
}

impl Items<'_> {
    fn root_item(&self) -> DeviceItem {
        DeviceItem::AnchorRoot {
            state: self.name.clone(),
        }
    }

    fn part(&self, checkpoint: CheckpointRef, part: u32) -> DeviceItem {
        DeviceItem::AnchorCheckpoint {
            state: self.name.clone(),
            checkpoint: checkpoint.digest,
            part,
        }
    }

    fn mac_key_item(&self) -> DeviceItem {
        DeviceItem::StateMacKey {
            state: self.name.clone(),
        }
    }

    // A root that does not parse is no anchor: nothing it says can be relied on.
    pub(crate) async fn root(&self) -> Result<Option<Root>, DeviceStoreError> {
        let Some(bytes) = self.store.load(self.root_item()).await? else {
            return Ok(None);
        };
        let root = Root::decode(&bytes);
        if root.is_none() {
            tracing::warn!("the state file's anchor root is malformed and counts as no anchor");
        }
        Ok(root)
    }

    pub(crate) async fn put_root(&self, root: &Root) -> Result<(), DeviceStoreError> {
        self.store.store(self.root_item(), Zeroizing::new(root.encode())).await
    }

    pub(crate) async fn mac_key(&self) -> Result<Option<Zeroizing<[u8; 32]>>, DeviceStoreError> {
        let held = self.store.load(self.mac_key_item()).await?;
        Ok(held.and_then(|bytes| <[u8; 32]>::try_from(bytes.as_slice()).ok().map(Zeroizing::new)))
    }

    pub(crate) async fn put_mac_key(&self, key: &Zeroizing<[u8; 32]>) -> Result<(), DeviceStoreError> {
        self.store
            .store(self.mac_key_item(), Zeroizing::new(key.to_vec()))
            .await
    }

    pub(crate) async fn put_checkpoint(&self, bytes: &[u8], part_bytes: usize) -> Result<(), DeviceStoreError> {
        let checkpoint = checkpoint_ref_of(bytes, part_bytes);
        let chunks: Vec<&[u8]> = if bytes.is_empty() {
            vec![bytes]
        } else {
            bytes.chunks(part_bytes.max(1)).collect()
        };
        for (part, chunk) in (0..).zip(chunks) {
            self.store
                .store(self.part(checkpoint, part), Zeroizing::new(chunk.to_vec()))
                .await?;
        }
        Ok(())
    }

    // None when a part is gone or the parts do not hash to the digest that names them.
    pub(crate) async fn checkpoint(&self, checkpoint: CheckpointRef) -> Result<Option<Checkpoint>, DeviceStoreError> {
        let mut bytes = Vec::new();
        for part in 0..checkpoint.parts {
            match self.store.load(self.part(checkpoint, part)).await? {
                Some(chunk) => bytes.extend_from_slice(&chunk),
                None => return Ok(None),
            }
        }
        if <[u8; 32]>::from(Sha256::digest(&bytes)) != checkpoint.digest {
            return Ok(None);
        }
        Ok(decode_checkpoint(&bytes))
    }

    pub(crate) async fn delete_checkpoint(&self, checkpoint: CheckpointRef) -> Result<(), DeviceStoreError> {
        for part in 0..checkpoint.parts {
            self.store.delete(self.part(checkpoint, part)).await?;
        }
        Ok(())
    }

    // Every item of the anchor: the checkpoints the root names or retired, the root, then the MAC key.
    pub(crate) async fn forget(&self) -> Result<(), DeviceStoreError> {
        if let Some(root) = self.root().await? {
            for checkpoint in root.named().into_iter().chain(root.retired.iter().copied()) {
                self.delete_checkpoint(checkpoint).await?;
            }
        }
        self.store.delete(self.root_item()).await?;
        self.store.delete(self.mac_key_item()).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn checkpoint(byte: u8) -> CheckpointRef {
        CheckpointRef {
            digest: [byte; 32],
            parts: u32::from(byte),
        }
    }

    fn entry(counter: u64) -> Entry {
        Entry {
            counter,
            mac: [7; 32],
            key_digest: [8; 32],
            checkpoint: checkpoint(2),
        }
    }

    #[test]
    fn a_root_reads_back_as_it_was_written() {
        let root = Root {
            file_id: FileId([5; 16]),
            owed: Owed::Rebuild(checkpoint(1)),
            current: Some(entry(4)),
            pending: Some(entry(5)),
            retired: vec![checkpoint(3), checkpoint(4)],
        };
        let bare = Root::new(FileId([6; 16]));

        assert_eq!(Root::decode(&root.encode()), Some(root.clone()));
        assert_eq!(Root::decode(&bare.encode()), Some(bare));
        assert_eq!(Root::decode(&root.encode()[..20]), None);
        assert_eq!(Root::decode(&[root.encode(), vec![0]].concat()), None);
    }

    #[test]
    fn a_newer_finding_never_loosens_what_is_owed() {
        let floor = Owed::Rebuild(checkpoint(1));
        let newer = Owed::Rebuild(checkpoint(2));

        assert_eq!(Owed::Trusted.stricter(floor), floor);
        assert_eq!(floor.stricter(Owed::Trusted), floor);
        assert_eq!(floor.stricter(newer), newer);
        assert_eq!(Owed::Unanchored.stricter(newer), Owed::Unanchored);
        assert_eq!(newer.stricter(Owed::Unanchored), Owed::Unanchored);
    }

    #[test]
    fn a_checkpoint_counts_its_parts_by_size() {
        let bytes = vec![1; 2561];

        assert_eq!(checkpoint_ref_of(&bytes, 2560).parts, 2);
        assert_eq!(checkpoint_ref_of(&bytes[..2560], 2560).parts, 1);
        assert_eq!(checkpoint_ref_of(&[], 2560).parts, 1);
    }
}
