// What the mirror last saw the Swift metadata hold, kept in the state file's `legacy_mirror` table (0054, Downgrade
// mirror). An older build that ran in between moves the server position, replaces the record cache, or clears marks
// it pushed. The mirror's own journal marks between two passes only add dirty marks and tombstones, so they never read
// as an older build. System fields are left out: CloudKit encodes them anew each time it rebuilds a record, and no
// older build changes them without changing the position or the marks too.

use std::collections::BTreeSet;

use sha2::{Digest, Sha256};

use crate::api::cloudkit::{CloudKitRecord, CloudKitValue};
use crate::api::error::SyncError;
use crate::api::legacy::{LegacyMetadata, LegacyRecordRef};
use crate::api::state::{LegacyMirrorRow, Row, RowKey, StateTxn};

const ITEM: &str = "swift_metadata";

type Mark = (String, String);

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(super) struct Seen {
    position: [u8; 32],
    dirty: BTreeSet<Mark>,
    tombstones: BTreeSet<Mark>,
    // The digest of the last metadata handed to the host, so a pass that changed nothing writes nothing.
    pub(super) sent: Option<[u8; 32]>,
}

// 0054's framing, `LP(x)`: a u32 big-endian length, then the bytes.
#[derive(Default)]
pub(super) struct Frame(Sha256);

impl Frame {
    pub(super) fn bytes(&mut self, bytes: &[u8]) {
        let length = u32::try_from(bytes.len()).unwrap_or(u32::MAX);
        self.0.update(length.to_be_bytes());
        self.0.update(bytes);
    }

    pub(super) fn text(&mut self, text: &str) {
        self.bytes(text.as_bytes());
    }

    pub(super) fn optional(&mut self, bytes: Option<&[u8]>) {
        match bytes {
            Some(bytes) => {
                self.0.update([1]);
                self.bytes(bytes);
            }
            None => self.0.update([0]),
        }
    }

    pub(super) fn count(&mut self, count: usize) {
        self.0.update(u32::try_from(count).unwrap_or(u32::MAX).to_be_bytes());
    }

    pub(super) fn texts<'t>(&mut self, texts: impl IntoIterator<Item = &'t String>) {
        let sorted: BTreeSet<&String> = texts.into_iter().collect();
        self.count(sorted.len());
        for text in sorted {
            self.text(text);
        }
    }

    fn value(&mut self, value: &CloudKitValue) {
        match value {
            CloudKitValue::Text(text) => {
                self.0.update([0]);
                self.text(text);
            }
            CloudKitValue::Int64(number) => {
                self.0.update([1]);
                self.bytes(&number.to_be_bytes());
            }
            CloudKitValue::Double(number) => {
                self.0.update([2]);
                self.bytes(&number.to_bits().to_be_bytes());
            }
            CloudKitValue::Timestamp(millis) => {
                self.0.update([3]);
                self.bytes(&millis.to_be_bytes());
            }
            CloudKitValue::Bytes(bytes) => {
                self.0.update([4]);
                self.bytes(bytes);
            }
            CloudKitValue::TextList(items) => {
                self.0.update([5]);
                self.count(items.len());
                for item in items {
                    self.text(item);
                }
            }
        }
    }

    // A record's type, name and set fields in name order; `system_fields` frames the change tag too.
    pub(super) fn record(&mut self, record: &CloudKitRecord, system_fields: bool) {
        self.text(&record.record_type);
        self.text(&record.name);
        if system_fields {
            self.optional(record.system_fields.as_deref());
        }
        let mut fields: Vec<_> = record
            .fields
            .iter()
            .filter_map(|field| Some((&field.name, field.value.as_ref()?)))
            .collect();
        fields.sort_by(|left, right| left.0.cmp(right.0));
        self.count(fields.len());
        for (name, value) in fields {
            self.text(name);
            self.value(value);
        }
    }

    pub(super) fn finish(self) -> [u8; 32] {
        self.0.finalize().into()
    }
}

fn mark(record: &LegacyRecordRef) -> Mark {
    (record.record_type.clone(), record.id.clone())
}

// Everything but the marks and the system fields, each collection in its own order.
fn position(metadata: &LegacyMetadata) -> [u8; 32] {
    let mut frame = Frame::default();
    frame.optional(metadata.token.as_deref());
    frame.texts(&metadata.deferred_deletions);
    frame.texts(&metadata.changes_held_for_unreadable);
    frame.texts(&metadata.removals_pending_for_unreadable);
    frame.texts(&metadata.deletions_held_for_unreadable);
    let owners: Vec<String> = metadata.owners_kept_off_sync.iter().map(ToString::to_string).collect();
    frame.texts(&owners);
    let standing: Vec<String> = metadata
        .standing
        .iter()
        .map(|entry| format!("{}={:?}", entry.connection, entry.standing))
        .collect();
    frame.texts(&standing);
    frame.texts(&metadata.readable_record_types);
    frame.optional(metadata.account.as_deref().map(str::as_bytes));
    frame.optional(metadata.zone_state.as_deref().map(str::as_bytes));
    let mut cache: Vec<&CloudKitRecord> = metadata.cache.iter().collect();
    cache.sort_by(|left, right| (&left.record_type, &left.name).cmp(&(&right.record_type, &right.name)));
    frame.count(cache.len());
    for record in cache {
        frame.record(record, false);
    }
    frame.finish()
}

// The row's encoding: the position, a presence byte and the sent digest, then each set of marks as a u32 count and
// `LP` of each record type and id.
fn put_text(out: &mut Vec<u8>, text: &str) {
    out.extend_from_slice(&u32::try_from(text.len()).unwrap_or(u32::MAX).to_be_bytes());
    out.extend_from_slice(text.as_bytes());
}

fn put_marks(out: &mut Vec<u8>, marks: &BTreeSet<Mark>) {
    out.extend_from_slice(&u32::try_from(marks.len()).unwrap_or(u32::MAX).to_be_bytes());
    for (record_type, id) in marks {
        put_text(out, record_type);
        put_text(out, id);
    }
}

struct Reader<'a>(&'a [u8]);

impl Reader<'_> {
    fn take(&mut self, count: usize) -> Option<&[u8]> {
        let (taken, rest) = self.0.split_at_checked(count)?;
        self.0 = rest;
        Some(taken)
    }

    fn digest(&mut self) -> Option<[u8; 32]> {
        self.take(32)?.try_into().ok()
    }

    fn count(&mut self) -> Option<usize> {
        usize::try_from(u32::from_be_bytes(self.take(4)?.try_into().ok()?)).ok()
    }

    fn text(&mut self) -> Option<String> {
        let length = self.count()?;
        String::from_utf8(self.take(length)?.to_vec()).ok()
    }

    fn marks(&mut self) -> Option<BTreeSet<Mark>> {
        (0..self.count()?).map(|_| Some((self.text()?, self.text()?))).collect()
    }
}

fn decoded(bytes: &[u8]) -> Option<Seen> {
    let mut reader = Reader(bytes);
    let position = reader.digest()?;
    let sent = match reader.take(1)? {
        [0] => None,
        [1] => Some(reader.digest()?),
        _ => return None,
    };
    let dirty = reader.marks()?;
    let tombstones = reader.marks()?;
    reader.0.is_empty().then_some(Seen {
        position,
        dirty,
        tombstones,
        sent,
    })
}

impl Seen {
    pub(super) fn of(metadata: &LegacyMetadata) -> Self {
        Self {
            position: position(metadata),
            dirty: metadata.dirty.iter().map(mark).collect(),
            tombstones: metadata
                .tombstones
                .iter()
                .map(|tombstone| mark(&tombstone.record))
                .collect(),
            sent: None,
        }
    }

    // An older build ran since this was seen: the position moved, a tombstone is gone, or a dirty mark is gone without
    // a deletion here having turned it into a tombstone.
    pub(super) fn older_build_ran(&self, now: &LegacyMetadata) -> bool {
        let seen = Self::of(now);
        self.position != seen.position
            || !self.tombstones.is_subset(&seen.tombstones)
            || self
                .dirty
                .iter()
                .any(|dirty| !seen.dirty.contains(dirty) && !seen.tombstones.contains(dirty))
    }

    // A record this build cannot read matches no metadata, so the Swift metadata is imported again.
    pub(super) async fn read(txn: &mut dyn StateTxn) -> Result<Option<Self>, SyncError> {
        let Some(Row::LegacyMirror(row)) = txn.get(&RowKey::LegacyMirror(ITEM.to_owned())).await? else {
            return Ok(None);
        };
        let parsed = decoded(&row.value);
        if parsed.is_none() {
            tracing::warn!("the legacy mirror's record does not read; importing the Swift metadata again");
        }
        Ok(Some(parsed.unwrap_or_default()))
    }

    fn encoded(&self) -> Vec<u8> {
        let mut value = self.position.to_vec();
        match self.sent {
            Some(sent) => {
                value.push(1);
                value.extend_from_slice(&sent);
            }
            None => value.push(0),
        }
        put_marks(&mut value, &self.dirty);
        put_marks(&mut value, &self.tombstones);
        value
    }

    pub(super) async fn put(&self, txn: &mut dyn StateTxn) -> Result<(), SyncError> {
        txn.put(Row::LegacyMirror(LegacyMirrorRow {
            item: ITEM.to_owned(),
            value: self.encoded(),
        }))
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::legacy::LegacyTombstone;

    fn reference(id: &str) -> LegacyRecordRef {
        LegacyRecordRef {
            record_type: "Connection".to_owned(),
            id: id.to_owned(),
        }
    }

    fn written() -> LegacyMetadata {
        LegacyMetadata {
            token: Some(vec![1]),
            dirty: vec![reference("A"), reference("B")],
            tombstones: vec![LegacyTombstone {
                record: reference("C"),
                deleted_at_ms: 1,
                owner: None,
            }],
            account: Some("_a".to_owned()),
            ..LegacyMetadata::default()
        }
    }

    #[test]
    fn the_mirror_s_own_marks_since_are_no_older_build() {
        let seen = Seen::of(&written());
        let mut marked = written();
        marked.dirty.retain(|dirty| dirty.id != "A");
        marked.dirty.push(reference("D"));
        marked.tombstones.push(LegacyTombstone {
            record: reference("A"),
            deleted_at_ms: 2,
            owner: None,
        });

        assert!(!seen.older_build_ran(&written()));
        assert!(!seen.older_build_ran(&marked));
    }

    #[test]
    fn a_moved_position_or_a_pushed_mark_is_an_older_build() {
        let seen = Seen::of(&written());
        let mut pulled = written();
        pulled.token = Some(vec![2]);
        let mut pushed = written();
        pushed.dirty.retain(|dirty| dirty.id != "A");
        let mut deleted = written();
        deleted.tombstones.clear();

        assert!(seen.older_build_ran(&pulled));
        assert!(seen.older_build_ran(&pushed));
        assert!(seen.older_build_ran(&deleted));
    }

    #[test]
    fn the_record_reads_back_as_it_was_put_and_a_cut_one_does_not_read() {
        let mut seen = Seen::of(&written());
        seen.sent = Some([7; 32]);
        let value = seen.encoded();

        assert_eq!(decoded(&value), Some(seen.clone()));
        assert_eq!(decoded(&value[..value.len() - 1]), None);
        assert_eq!(decoded(&[value.as_slice(), &[0]].concat()), None);
    }

    #[test]
    fn system_fields_and_the_order_of_a_list_are_no_change() {
        let record = |system_fields: u8| CloudKitRecord {
            record_type: "ConnectionTag".to_owned(),
            name: "Tag_A".to_owned(),
            system_fields: Some(vec![system_fields]),
            created_ms: None,
            fields: Vec::new(),
        };
        let mut first = written();
        first.cache = vec![record(1)];
        first.deferred_deletions = vec!["Group_A".to_owned(), "Group_B".to_owned()];
        let mut again = first.clone();
        again.cache = vec![record(2)];
        again.deferred_deletions.reverse();

        assert!(!Seen::of(&first).older_build_ran(&again));
    }
}
