// What a committed pass leaves the previous stable (0054, Downgrade mirror), built from the state file and the stores:
// the token, the dirty and tombstone keys, standing, the held and deferred sets, and the `SyncRecordCache` records,
// rebuilt from the bases and their system fields.
//
// - Dirty and tombstone keys are the diff the push reads, whatever the categories, as the Swift engine kept marks for a
//   category that is off. A pass a journal signal started diffs only the records it named (0060) and keeps the other
//   marks as the host holds them.
// - A record type this engine has no adapter for is the Swift engine's still: its marks and sets stay as the host holds
//   them, and the readable types leave it out, so the previous stable reads it whole again.
// - A value waiting for the person, or kept here after a rejection, is a change held by id, which the previous stable
//   fetches and applies as it always did. A record held whole for the person leaves its type out of the readable
//   types, so the previous stable reads that type whole.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::Arc;

use serde_json::Value;
use tablepro_records::Kind;
use tablepro_records::cloudkit::{Carries, from_wire, parse_record_name};
use tablepro_records::cloudkit::{CloudValue, RecordType, record_name, record_type_of};
use tablepro_records::record_id::{parse_uuid, shortened, uuid_id};
use tablepro_records::settings::owner;
use uuid::Uuid;

use super::super::fetch::{Categories, PRIOR, SCOPE, prior_of, stored_id};
use super::super::modify::{Pusher, at_base};
use super::import;
use super::seen::Frame;
use crate::adapters::approval;
use crate::api::adapter::RecordAdapter;
use crate::api::cloudkit::{CloudKitField, CloudKitRecord, CloudKitValue};
use crate::api::error::SyncError;
use crate::api::ids::{ChangeTag, Cursor, KindName, RecordKey};
use crate::api::legacy::{LegacyMetadata, LegacyRecordRef, LegacyStanding, LegacyTombstone};
use crate::api::state::{BaseRow, HeldReason, PushWait, Row, RowKey, RowRange, Standing, StateStore, Table};
use crate::engine::{JournalIds, PendingOp, diff};

// A record type the previous stable knows: one Production holds.
pub(super) fn mirrored(kind: Kind) -> Option<&'static RecordType> {
    record_type_of(kind).filter(|record_type| record_type.deployed)
}

// The kinds this engine reads now.
pub(super) fn reads(adapters: &[Arc<dyn RecordAdapter>], categories: &Categories) -> BTreeSet<Kind> {
    adapters
        .iter()
        .map(|adapter| adapter.kind())
        .filter(|kind| mirrored(*kind).is_some() && categories.syncs(*kind))
        .collect()
}

pub(in crate::cloudkit) struct Context<'a> {
    pub state: &'a dyn StateStore,
    pub adapters: &'a [Arc<dyn RecordAdapter>],
    pub categories: &'a Categories,
    pub account: &'a str,
    pub zone_removed: bool,
    pub named: Option<&'a JournalIds>,
    pub now_ms: i64,
}

// The kinds whose tombstones the Mac's stores tag with the connection the record belongs to.
pub(super) const fn owned(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::FavouriteTable | Kind::FavouriteDatabase | Kind::TableFolder | Kind::TableFolderItem
    )
}

// `SyncBoundary.owner(ofRecordId:)` and the owners the Mac's stores tag tombstones with: the connection a column
// layout's category or a table's record names.
fn owner_of(kind: Kind, id: &str, fields: Option<&Value>) -> Option<Uuid> {
    match kind {
        kind if owned(kind) => fields
            .and_then(|fields| fields.get("connection_id"))
            .and_then(Value::as_str)
            .and_then(parse_uuid),
        kind if kind.is_settings() => owner(id),
        _ => None,
    }
}

// The connection each base of an owned record names, by record type and the id the Swift engine marks the record
// with, so a deletion the journal reports offline carries the owner the Mac's stores tagged its tombstone with.
pub(super) async fn owners(state: &dyn StateStore) -> Result<HashMap<(String, String), Uuid>, SyncError> {
    let mut txn = state.begin().await?;
    let mut owners = HashMap::new();
    for row in txn.scan(&RowRange::Scope(Table::Bases, SCOPE)).await? {
        let Row::Base(base) = row else {
            continue;
        };
        let (Some(kind), Some(fields)) = (base.key.kind.known(), base.fields.as_ref()) else {
            continue;
        };
        let Some(record_type) = mirrored(kind) else {
            continue;
        };
        let id = stored_id(kind, &base.key.record_id, fields);
        if let Some(owner) = owner_of(kind, &id, Some(fields)) {
            owners.insert((record_type.name.to_owned(), id), owner);
        }
    }
    Ok(owners)
}

fn reference(record_type: &RecordType, id: String) -> LegacyRecordRef {
    LegacyRecordRef {
        record_type: record_type.name.to_owned(),
        id,
    }
}

fn type_of(name: &str) -> Option<&'static str> {
    parse_record_name(name).map(|(record_type, _)| record_type.name)
}

fn cloudkit_value(value: CloudValue) -> CloudKitValue {
    match value {
        CloudValue::Text(text) => CloudKitValue::Text(text),
        CloudValue::Int64(number) => CloudKitValue::Int64(number),
        CloudValue::Double(number) => CloudKitValue::Double(number),
        CloudValue::Timestamp(millis) => CloudKitValue::Timestamp(millis),
        CloudValue::Bytes(bytes) => CloudKitValue::Bytes(bytes),
        CloudValue::TextList(items) => CloudKitValue::TextList(items),
    }
}

// A base as the record the previous stable merges a push onto. `modifiedAtLocal` is left out: every push stamps it
// and nobody reads it, and a fixed record lets a pass that changed nothing write nothing.
fn cached(record_type: &RecordType, base: &BaseRow) -> Option<CloudKitRecord> {
    let ChangeTag::CloudKit(system_fields) = &base.tag else {
        return None;
    };
    let fields = base.fields.as_ref()?;
    if system_fields.is_empty() {
        return None;
    }
    let id = &base.key.record_id;
    let saved = from_wire(record_type.kind, id, fields, 0).ok()??;
    let fields = saved
        .into_iter()
        .filter(|(name, _)| {
            record_type
                .field(name)
                .is_none_or(|field| field.carries != Carries::Stamp)
        })
        .filter_map(|(name, value)| {
            Some(CloudKitField {
                name: name.to_owned(),
                value: Some(cloudkit_value(value?)),
            })
        })
        .collect();
    Some(CloudKitRecord {
        record_type: record_type.name.to_owned(),
        name: record_name(record_type.kind, id)?,
        system_fields: Some(system_fields.clone()),
        created_ms: base.created_ms,
        fields,
    })
}

// What the state file says, read in one transaction that is dropped before any store is read.
#[derive(Default)]
struct Rows {
    token: Option<Vec<u8>>,
    zone_seen: bool,
    // The zone's push waits for this device's person to upload again, after a restart too.
    upload_again: bool,
    bases: BTreeMap<Kind, Vec<BaseRow>>,
    held: BTreeMap<RecordKey, (HeldReason, bool)>,
    deferred: Vec<RecordKey>,
    standing: Vec<LegacyStanding>,
    waiting: BTreeMap<(KindName, String), BTreeSet<String>>,
    // The copy from before the pull that started a wait, by record.
    prior: HashMap<RecordKey, (Vec<u8>, Value)>,
}

async fn rows(state: &dyn StateStore) -> Result<Rows, SyncError> {
    let mut txn = state.begin().await?;
    let mut rows = Rows::default();
    if let Some(Row::Scope(scope)) = txn.get(&RowKey::Scope(SCOPE)).await? {
        rows.zone_seen = true;
        rows.upload_again = scope.push_wait == Some(PushWait::UploadAgain);
        if let Some(Cursor::CloudKit(token)) = scope.cursor {
            rows.token = Some(token);
        }
    }
    for row in txn.scan(&RowRange::Scope(Table::Bases, SCOPE)).await? {
        if let Row::Base(base) = row
            && let Some(kind) = base.key.kind.known()
        {
            rows.bases.entry(kind).or_default().push(base);
        }
    }
    for row in txn.scan(&RowRange::Scope(Table::Held, SCOPE)).await? {
        if let Row::Held(held) = row {
            rows.held.insert(held.key, (held.reason, held.record.deleted.is_some()));
        }
    }
    for row in txn.scan(&RowRange::Scope(Table::Deferred, SCOPE)).await? {
        if let Row::Deferred(deferred) = row
            && deferred.record.deleted.is_some()
        {
            rows.deferred.push(deferred.key);
        }
    }
    let connections = RowRange::ScopeKind(Table::Standing, SCOPE, KindName::of(Kind::Connection));
    for row in txn.scan(&connections).await? {
        if let Row::Standing(row) = row
            && row.standing != Standing::Unknown
            && let Some(connection) = parse_uuid(&row.key.record_id)
        {
            rows.standing.push(LegacyStanding {
                connection,
                standing: row.standing,
            });
        }
    }
    rows.waiting = approval::held_members(txn.as_mut(), SCOPE).await?;
    for row in txn.scan(&RowRange::Table(Table::LegacyMirror)).await? {
        let Row::LegacyMirror(row) = row else { continue };
        let Some((kind, id)) = row.item.strip_prefix(PRIOR).and_then(|rest| rest.split_once('/')) else {
            continue;
        };
        let (Ok(kind), Some(prior)) = (KindName::parse(kind), prior_of(&row.value)) else {
            continue;
        };
        if rows.waiting.contains_key(&(kind.clone(), id.to_owned())) {
            rows.prior.insert(RecordKey::new(SCOPE, kind, id.to_owned()), prior);
        }
    }
    Ok(rows)
}

// The dirty and tombstone keys of one kind, by the ids the Swift engine marked them with.
#[derive(Default)]
struct Marks {
    dirty: BTreeSet<String>,
    // Each deletion with the base it deletes.
    deleted: BTreeMap<String, Option<Value>>,
}

async fn diffed(
    adapter: &dyn RecordAdapter,
    kind: Kind,
    rows: &Rows,
    only: Option<&HashSet<String>>,
) -> Result<Marks, SyncError> {
    let name = KindName::of(kind);
    let stored = adapter.records(SCOPE).await?;
    let (mut local, mut kept, _) = Pusher::carried_copies(kind, stored);
    let bases = rows.bases.get(&kind).cloned().unwrap_or_default();
    at_base(&name, &rows.waiting, &bases, &mut local, &mut kept);
    let skip: HashSet<String> = rows
        .held
        .keys()
        .filter(|key| key.kind == name)
        .map(|key| key.record_id.clone())
        .collect();
    let found = diff(SCOPE, kind, &local, &bases, &skip);
    // The settings adapter names a long category by its digest; the Swift engine marked the category itself.
    let swift_id = |wire: &str| {
        kept.get(wire).map_or_else(
            || wire.to_owned(),
            |record| stored_id(kind, &record.record_id, &record.fields),
        )
    };
    let mut marks = Marks::default();
    let named = |key: &RecordKey| only.is_none_or(|only| only.contains(&key.record_id));
    for (key, _) in found.refused.iter().filter(|(key, _)| named(key)) {
        marks.dirty.insert(swift_id(&key.record_id));
    }
    for pending in found.pending.into_iter().filter(|pending| named(&pending.key)) {
        match pending.op {
            PendingOp::Write { .. } => {
                marks.dirty.insert(swift_id(&pending.key.record_id));
            }
            PendingOp::Delete => {
                let fields = pending.base.and_then(|base| base.fields);
                let id = fields.as_ref().map_or_else(
                    || pending.key.record_id.clone(),
                    |fields| stored_id(kind, &pending.key.record_id, fields),
                );
                marks.deleted.insert(id, fields);
            }
        }
    }
    Ok(marks)
}

struct Builder<'a> {
    cx: &'a Context<'a>,
    // What the host holds, of this account.
    known: LegacyMetadata,
    out: LegacyMetadata,
    // Record types this engine cannot read now: no adapter, or a record held whole for the person.
    unread: BTreeSet<&'static str>,
}

impl Builder<'_> {
    // By the name the record goes by, since the host keeps a long settings category whole.
    fn known_tombstone(&self, record_type: &RecordType, id: &str) -> Option<&LegacyTombstone> {
        let wire = shortened(record_type.kind, id.to_owned());
        self.known.tombstones.iter().find(|tombstone| {
            tombstone.record.record_type == record_type.name
                && shortened(record_type.kind, tombstone.record.id.clone()) == wire
        })
    }

    // The host's marks of a record type, of the ids `keep` takes.
    fn keep_known(&mut self, record_type: &str, keep: impl Fn(&str) -> bool) {
        let dirty: Vec<LegacyRecordRef> = self
            .known
            .dirty
            .iter()
            .filter(|dirty| dirty.record_type == record_type && keep(&dirty.id))
            .cloned()
            .collect();
        let tombstones: Vec<LegacyTombstone> = self
            .known
            .tombstones
            .iter()
            .filter(|tombstone| tombstone.record.record_type == record_type && keep(&tombstone.record.id))
            .cloned()
            .collect();
        self.out.dirty.extend(dirty);
        self.out.tombstones.extend(tombstones);
    }

    // A tombstone of a connection kept off sync has no base here, so no diff finds it: it stays the Swift engine's.
    fn keep_kept_off(&mut self, record_type: &RecordType) {
        let kept_off = import::kept_off(&self.known);
        let kept: Vec<LegacyTombstone> = self
            .known
            .tombstones
            .iter()
            .filter(|tombstone| {
                tombstone.record.record_type == record_type.name
                    && import::kept_off_sync(record_type.kind, tombstone, &kept_off)
            })
            .cloned()
            .collect();
        self.out.tombstones.extend(kept);
    }

    fn add(&mut self, record_type: &RecordType, marks: Marks) {
        let kind = record_type.kind;
        for id in marks.dirty {
            self.out.dirty.push(reference(record_type, id));
        }
        for (id, fields) in marks.deleted {
            let tombstone = self
                .known_tombstone(record_type, &id)
                .cloned()
                .unwrap_or_else(|| LegacyTombstone {
                    record: reference(record_type, id.clone()),
                    deleted_at_ms: self.cx.now_ms,
                    owner: owner_of(kind, &id, fields.as_ref()),
                });
            self.out.tombstones.push(tombstone);
        }
    }

    async fn marks(&mut self, adapters: &BTreeMap<Kind, Arc<dyn RecordAdapter>>, rows: &Rows) -> Result<(), SyncError> {
        for (kind, adapter) in adapters {
            let Some(record_type) = mirrored(*kind) else {
                continue;
            };
            self.keep_kept_off(record_type);
            let Some(named) = self.cx.named else {
                let marks = diffed(adapter.as_ref(), *kind, rows, None).await?;
                self.add(record_type, marks);
                continue;
            };
            let Some(ids) = named.get(kind) else {
                self.keep_known(record_type.name, |_| true);
                continue;
            };
            let wire: HashSet<String> = ids.iter().map(|id| shortened(*kind, id.clone())).collect();
            let marks = diffed(adapter.as_ref(), *kind, rows, Some(&wire)).await?;
            self.keep_known(record_type.name, |id| !wire.contains(&shortened(*kind, id.to_owned())));
            self.add(record_type, marks);
        }
        Ok(())
    }

    fn held(&mut self, adapters: &BTreeMap<Kind, Arc<dyn RecordAdapter>>, rows: &Rows) {
        let ours = |name: &str| {
            parse_record_name(name).is_some_and(|(record_type, _)| adapters.contains_key(&record_type.kind))
        };
        for (key, (reason, deleted)) in &rows.held {
            let Some(kind) = key.kind.known().filter(|kind| adapters.contains_key(kind)) else {
                continue;
            };
            let (Some(record_type), Some(name)) = (mirrored(kind), record_name(kind, &key.record_id)) else {
                continue;
            };
            match (reason, deleted) {
                (HeldReason::Unreadable | HeldReason::UnknownKind | HeldReason::RefusedInRefill, true) => {
                    self.out.deletions_held_for_unreadable.push(name);
                }
                (HeldReason::Unreadable | HeldReason::UnknownKind | HeldReason::RefusedInRefill, false) => {
                    self.out.changes_held_for_unreadable.push(name);
                }
                (HeldReason::AwaitingApproval, _) => {
                    self.unread.insert(record_type.name);
                }
                (HeldReason::AwaitingDeviceApproval | HeldReason::Collides | HeldReason::AwaitingStore, _) => {}
            }
        }
        for (kind, id) in rows.waiting.keys() {
            if let Some(name) = kind
                .known()
                .filter(|kind| adapters.contains_key(kind))
                .and_then(|kind| record_name(kind, id))
            {
                self.out.changes_held_for_unreadable.push(name);
            }
        }
        for key in &rows.deferred {
            if let Some(name) = key
                .kind
                .known()
                .filter(|kind| adapters.contains_key(kind))
                .and_then(|kind| record_name(kind, &key.record_id))
            {
                self.out.deferred_deletions.push(name);
            }
        }
        let theirs = |names: &[String]| -> Vec<String> {
            names
                .iter()
                .filter(|name| type_of(name).is_some() && !ours(name))
                .cloned()
                .collect()
        };
        let known = &self.known;
        self.out
            .changes_held_for_unreadable
            .extend(theirs(&known.changes_held_for_unreadable));
        self.out
            .deletions_held_for_unreadable
            .extend(theirs(&known.deletions_held_for_unreadable));
        self.out
            .removals_pending_for_unreadable
            .extend(theirs(&known.removals_pending_for_unreadable));
        self.out.deferred_deletions.extend(theirs(&known.deferred_deletions));
    }

    // What the last pull read: the types this engine reads, with the host's own entries for them, such as the content
    // kinds the previous stable names within a type.
    fn readable(&mut self, raw: &LegacyMetadata) {
        let reads: BTreeSet<&'static str> = reads(self.cx.adapters, self.cx.categories)
            .into_iter()
            .filter_map(mirrored)
            .map(|record_type| record_type.name)
            .filter(|name| !self.unread.contains(name))
            .collect();
        let entries: BTreeSet<String> = raw
            .readable_record_types
            .iter()
            .cloned()
            .chain(reads.iter().map(|name| (*name).to_owned()))
            .filter(|entry| {
                let record_type = entry.split('/').next().unwrap_or_default();
                reads.contains(record_type)
            })
            .collect();
        self.out.readable_record_types = entries.into_iter().collect();
    }

    fn finish(mut self) -> LegacyMetadata {
        let out = &mut self.out;
        out.dirty
            .sort_by(|left, right| (&left.record_type, &left.id).cmp(&(&right.record_type, &right.id)));
        out.dirty.dedup();
        out.tombstones.sort_by(|left, right| {
            (&left.record.record_type, &left.record.id).cmp(&(&right.record.record_type, &right.record.id))
        });
        out.tombstones.dedup_by(|left, right| left.record == right.record);
        for names in [
            &mut out.deferred_deletions,
            &mut out.changes_held_for_unreadable,
            &mut out.removals_pending_for_unreadable,
            &mut out.deletions_held_for_unreadable,
        ] {
            names.sort();
            names.dedup();
        }
        out.owners_kept_off_sync.sort();
        out.owners_kept_off_sync.dedup();
        out.standing.sort_by_key(|entry| uuid_id(entry.connection));
        out.standing.dedup();
        out.cache.sort_by(|left, right| left.name.cmp(&right.name));
        self.out
    }
}

// `known` is the host's metadata as this session last read it, with the marks since.
pub(super) async fn metadata(cx: &Context<'_>, known: &LegacyMetadata) -> Result<LegacyMetadata, SyncError> {
    let adapters: BTreeMap<Kind, Arc<dyn RecordAdapter>> = cx
        .adapters
        .iter()
        .filter(|adapter| mirrored(adapter.kind()).is_some())
        .map(|adapter| (adapter.kind(), Arc::clone(adapter)))
        .collect();
    let rows = rows(cx.state).await?;
    let mut builder = Builder {
        cx,
        known: known.clone().for_account(cx.account),
        out: LegacyMetadata {
            token: rows.token.clone(),
            owners_kept_off_sync: known.owners_kept_off_sync.clone(),
            account: Some(cx.account.to_owned()),
            zone_state: Some(
                if cx.zone_removed || rows.upload_again {
                    "removed"
                } else if rows.zone_seen {
                    "confirmed"
                } else {
                    "unknown"
                }
                .to_owned(),
            ),
            ..LegacyMetadata::default()
        },
        unread: BTreeSet::new(),
    };
    builder.marks(&adapters, &rows).await?;
    for record_type in tablepro_records::cloudkit::RECORD_TYPES
        .iter()
        .filter(|record_type| record_type.deployed && !adapters.contains_key(&record_type.kind))
    {
        builder.keep_known(record_type.name, |_| true);
        builder.unread.insert(record_type.name);
    }
    builder.held(&adapters, &rows);
    builder.out.standing = if adapters.contains_key(&Kind::Connection) {
        rows.standing.clone()
    } else {
        builder.known.standing.clone()
    };
    builder.readable(known);
    builder.out.cache = rows
        .bases
        .iter()
        .filter_map(|(kind, bases)| Some((mirrored(*kind)?, bases)))
        .flat_map(|(record_type, bases)| {
            let prior = &rows.prior;
            bases.iter().filter_map(move |base| match prior.get(&base.key) {
                // A waiting record goes to the previous stable as it was before the pull that started the wait.
                Some((tag, fields)) => cached(
                    record_type,
                    &BaseRow {
                        tag: ChangeTag::CloudKit(tag.clone()),
                        fields: Some(fields.clone()),
                        ..base.clone()
                    },
                ),
                None => cached(record_type, base),
            })
        })
        .collect();
    Ok(builder.finish())
}

// Every field of what a pass hands the host, so an unchanged pass is known before the call.
pub(super) fn digest(metadata: &LegacyMetadata) -> [u8; 32] {
    let mut frame = Frame::default();
    frame.optional(metadata.token.as_deref());
    frame.count(metadata.dirty.len());
    for dirty in &metadata.dirty {
        frame.text(&dirty.record_type);
        frame.text(&dirty.id);
    }
    frame.count(metadata.tombstones.len());
    for tombstone in &metadata.tombstones {
        frame.text(&tombstone.record.record_type);
        frame.text(&tombstone.record.id);
        frame.bytes(&tombstone.deleted_at_ms.to_be_bytes());
        frame.optional(tombstone.owner.as_ref().map(Uuid::as_bytes).map(<[u8; 16]>::as_slice));
    }
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
    frame.count(metadata.cache.len());
    for record in &metadata.cache {
        frame.record(record, true);
    }
    frame.finish()
}
