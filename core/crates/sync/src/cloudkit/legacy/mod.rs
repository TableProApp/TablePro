// The engine's side of the Swift engine's metadata (0054, The Apple apps on the engine; Downgrade mirror). The first
// pass over a state file reads what the host holds and imports it when the file never held the zone, or when an older
// build ran since the mirror last saw it. After every pass the mirror writes what the previous stable reads, and on
// every journal signal, offline too, it marks the records that write changed. While the host's metadata cannot be
// read, nothing syncs and nothing is written over what an older build left.

mod export;
mod import;
mod seen;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use tablepro_records::Kind;
use tablepro_records::settings::owner;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use tokio::sync::watch;
use uuid::Uuid;

pub(in crate::cloudkit) use export::Context;
use seen::Seen;

use crate::api::adapter::RecordAdapter;
use crate::api::cloudkit::CloudKitTransport;
use crate::api::error::{AdapterError, SyncError};
use crate::api::legacy::{LegacyMetadata, LegacyMirror, LegacyRecordRef, LegacyTombstone};
use crate::api::state::StateStore;
use crate::cloudkit::fetch::Categories;
use crate::engine::{Clock, JournalEntry, JournalObserver};

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

struct Shared {
    host: Arc<dyn LegacyMirror>,
    // A pass's write and the journal's marks reach the host one at a time and in order, so the mark of a store write
    // the pass's diff did not see lands after that write.
    order: tokio::sync::Mutex<()>,
    // What the host holds as this session last read it, with the marks since; None until a read succeeds.
    known: Mutex<Option<LegacyMetadata>>,
    // The owner of each record whose base names one, for the journal's deletions (`export::owners`).
    owners: Mutex<HashMap<(String, String), Uuid>>,
    // Signals whose marks the host refused, sent again with the next ones and by a flush.
    failed: Mutex<Vec<JournalEntry>>,
    clock: Arc<dyn Clock>,
    // The journal signals queued, and those the queue's task has taken; a flush waits for the second to reach the
    // first.
    queued: AtomicU64,
    taken: watch::Sender<u64>,
}

// The queue's task outlives the engine: it ends once every clone of the journal is gone and it has sent what they
// queued, so an edit made just before the engine stops still reaches the host.
pub(in crate::cloudkit) struct LegacyLink {
    shared: Arc<Shared>,
}

struct MarkQueue {
    sender: UnboundedSender<Vec<JournalEntry>>,
    shared: Arc<Shared>,
}

impl JournalObserver for MarkQueue {
    fn changed(&self, entries: &[JournalEntry]) {
        if self.sender.send(entries.to_vec()).is_ok() {
            self.shared.queued.fetch_add(1, Ordering::SeqCst);
        }
    }
}

// The previous stable's marks of one or more journal entries: the last of a record's changes in them stands. A
// deleted record names the connection its base named, or a column layout's category names. An owned record whose base
// names no connection gets no tombstone: it never reached the zone from here, or its owner is not read yet, and the
// pass's write names its deletion from the diff, so a Local only connection's record is never deleted unowned.
fn marks_of(
    entries: &[JournalEntry],
    now_ms: i64,
    owners: &HashMap<(String, String), Uuid>,
) -> (Vec<LegacyRecordRef>, Vec<LegacyTombstone>) {
    let mut last: BTreeMap<(&'static str, String), (Kind, bool)> = BTreeMap::new();
    for entry in entries {
        let Some(record_type) = export::mirrored(entry.kind) else {
            continue;
        };
        for id in &entry.written {
            last.insert((record_type.name, id.clone()), (entry.kind, false));
        }
        for id in &entry.deleted {
            last.insert((record_type.name, id.clone()), (entry.kind, true));
        }
    }
    let mut dirty = Vec::new();
    let mut tombstones = Vec::new();
    for ((record_type, id), (kind, deleted)) in last {
        let record = LegacyRecordRef {
            record_type: record_type.to_owned(),
            id,
        };
        if deleted {
            let tagged = owners.get(&(record.record_type.clone(), record.id.clone())).copied();
            if export::owned(kind) && tagged.is_none() {
                continue;
            }
            tombstones.push(LegacyTombstone {
                owner: tagged.or_else(|| kind.is_settings().then(|| owner(&record.id)).flatten()),
                record,
                deleted_at_ms: now_ms,
            });
        } else {
            dirty.push(record);
        }
    }
    (dirty, tombstones)
}

// As the host's mark applies them: a written record is dirty, a deleted one's dirty mark becomes its tombstone.
fn marked(known: &mut LegacyMetadata, dirty: Vec<LegacyRecordRef>, tombstones: Vec<LegacyTombstone>) {
    for record in dirty {
        if !known.dirty.contains(&record) {
            known.dirty.push(record);
        }
    }
    for tombstone in tombstones {
        known.dirty.retain(|record| *record != tombstone.record);
        known.tombstones.retain(|kept| kept.record != tombstone.record);
        known.tombstones.push(tombstone);
    }
}

// The signals refused before go first, so a record's last change still stands. A refusal keeps them all for the next
// try.
async fn send_marks(shared: &Shared, entries: Vec<JournalEntry>) -> Result<(), AdapterError> {
    let _order = shared.order.lock().await;
    let mut entries = std::mem::take(&mut *lock(&shared.failed))
        .into_iter()
        .chain(entries)
        .collect::<Vec<_>>();
    let owners = lock(&shared.owners).clone();
    let (dirty, tombstones) = marks_of(&entries, shared.clock.now_ms(), &owners);
    if dirty.is_empty() && tombstones.is_empty() {
        return Ok(());
    }
    match shared.host.mark(dirty.clone(), tombstones.clone()).await {
        Ok(()) => {
            if let Some(known) = lock(&shared.known).as_mut() {
                marked(known, dirty, tombstones);
            }
            Ok(())
        }
        Err(error) => {
            tracing::warn!(
                code = error.code(),
                "the journal's marks did not reach the Swift metadata"
            );
            let mut failed = lock(&shared.failed);
            entries.append(&mut failed);
            *failed = entries;
            Err(error)
        }
    }
}

async fn run_marks(shared: Arc<Shared>, mut queue: UnboundedReceiver<Vec<JournalEntry>>) {
    while let Some(mut entries) = queue.recv().await {
        let mut count = 1;
        while let Ok(more) = queue.try_recv() {
            entries.extend(more);
            count += 1;
        }
        let _ = send_marks(&shared, entries).await;
        shared.taken.send_modify(|taken| *taken += count);
    }
}

// Each mark the host holds is one the export holds too, so writing the export again would change nothing.
fn same_marks(known: &LegacyMetadata, metadata: &LegacyMetadata) -> bool {
    let dirty = |metadata: &LegacyMetadata| -> HashSet<LegacyRecordRef> { metadata.dirty.iter().cloned().collect() };
    let tombstones = |metadata: &LegacyMetadata| -> HashSet<LegacyRecordRef> {
        metadata
            .tombstones
            .iter()
            .map(|tombstone| tombstone.record.clone())
            .collect()
    };
    dirty(known) == dirty(metadata) && tombstones(known) == tombstones(metadata)
}

impl LegacyLink {
    // On the runtime: the journal's marks go out on a task of their own.
    pub(in crate::cloudkit) fn new(
        host: Arc<dyn LegacyMirror>,
        clock: Arc<dyn Clock>,
    ) -> (Self, Arc<dyn JournalObserver>) {
        let shared = Arc::new(Shared {
            host,
            order: tokio::sync::Mutex::new(()),
            known: Mutex::new(None),
            owners: Mutex::new(HashMap::new()),
            failed: Mutex::new(Vec::new()),
            clock,
            queued: AtomicU64::new(0),
            taken: watch::Sender::new(0),
        });
        let (sender, receiver) = unbounded_channel();
        tokio::spawn(run_marks(Arc::clone(&shared), receiver));
        let queue = MarkQueue {
            sender,
            shared: Arc::clone(&shared),
        };
        (Self { shared }, Arc::new(queue))
    }

    // Returns once every journal signal queued before the call has marked the host, as the app quits, and fails while
    // the host refuses a mark: what it refused is kept for the next try.
    pub(in crate::cloudkit) async fn flush(&self) -> Result<(), SyncError> {
        let queued = self.shared.queued.load(Ordering::SeqCst);
        let mut taken = self.shared.taken.subscribe();
        // The count's sender lives as long as `shared`, so this ends only once the count is reached.
        let _ = taken.wait_for(|taken| *taken >= queued).await;
        if lock(&self.shared.failed).is_empty() {
            return Ok(());
        }
        Ok(send_marks(&self.shared, Vec::new()).await?)
    }

    // At the start of the first pass over `state`: the host's metadata is read, and imported when the file never held
    // the zone or an older build ran since the mirror last saw it. A file that held the zone with no record of the
    // mirror keeps what it holds. While the host cannot be read the pass fails: it would otherwise fetch a record the
    // Swift engine, or an older build that ran in between, holds an unsent deletion for, and take it as new.
    pub(in crate::cloudkit) async fn check(
        &self,
        state: &dyn StateStore,
        transport: &dyn CloudKitTransport,
        account: &str,
        adapters: &[Arc<dyn RecordAdapter>],
        categories: &Categories,
    ) -> Result<(), SyncError> {
        let read = {
            let _order = self.shared.order.lock().await;
            let read = self.shared.host.read().await?;
            *lock(&self.shared.known) = Some(read.clone());
            read
        };
        let mut txn = state.begin().await?;
        let seen = Seen::read(txn.as_mut()).await?;
        let imports = match &seen {
            None => import::fresh(txn.as_mut()).await?,
            Some(seen) => seen.older_build_ran(&read),
        };
        if !imports && seen.is_some() {
            drop(txn);
            *lock(&self.shared.owners) = export::owners(state).await?;
            return Ok(());
        }
        if imports {
            tracing::info!(again = seen.is_some(), "importing the Swift sync metadata");
            drop(txn);
            let metadata = read.clone().for_account(account);
            let zone = import::uncached(transport, account, &metadata).await?;
            txn = state.begin().await?;
            let reads = export::reads(adapters, categories);
            import::import(txn.as_mut(), &metadata, &zone, &reads).await?;
        }
        Seen::of(&read).put(txn.as_mut()).await?;
        txn.commit().await?;
        *lock(&self.shared.owners) = export::owners(state).await?;
        Ok(())
    }

    // After a pass: what the previous stable reads, unless it is what the last pass wrote. A failed write leaves the
    // record of the last one, so the next launch imports what the host holds.
    pub(in crate::cloudkit) async fn write(&self, cx: Context<'_>) -> Result<(), SyncError> {
        // A mark queued before this point may name a deletion this pass already sent: it lands first, so the export
        // replaces it rather than the mark coming back after the export. One the host refuses is sent again later.
        let _ = self.flush().await;
        *lock(&self.shared.owners) = export::owners(cx.state).await?;
        let order = self.shared.order.lock().await;
        let Some(known) = lock(&self.shared.known).clone() else {
            return Ok(());
        };
        let metadata = export::metadata(&cx, &known).await?;
        let sent = export::digest(&metadata);
        let mut txn = cx.state.begin().await?;
        let last = Seen::read(txn.as_mut()).await?;
        drop(txn);
        if last.as_ref().and_then(|last| last.sent) == Some(sent) && same_marks(&known, &metadata) {
            return Ok(());
        }
        if let Err(error) = self.shared.host.write(metadata.clone()).await {
            tracing::warn!(code = error.code(), "the Swift sync metadata was not written");
            return Ok(());
        }
        // A pass that diffed every store wrote each refused mark's record as it stands now.
        if cx.named.is_none() {
            lock(&self.shared.failed).clear();
        }
        let back = match self.shared.host.read().await {
            Ok(back) => back,
            Err(error) => {
                tracing::warn!(code = error.code(), "the Swift sync metadata did not read back");
                *lock(&self.shared.known) = Some(metadata);
                return Ok(());
            }
        };
        *lock(&self.shared.known) = Some(back.clone());
        drop(order);
        let mut seen = Seen::of(&back);
        seen.sent = Some(sent);
        let mut txn = cx.state.begin().await?;
        seen.put(txn.as_mut()).await?;
        txn.commit().await?;
        Ok(())
    }

    // Another state file opens: what the host holds is read again for it.
    pub(in crate::cloudkit) fn forget(&self) {
        *lock(&self.shared.known) = None;
    }
}

// The downgrade mirror's marks on a device whose provider is not iCloud (0054, Downgrade mirror: on every journal
// signal, offline too): the previous stable marks what the app writes whatever its switch says, so the marks go to the
// Swift metadata with no iCloud engine, and the quit drains them.
pub struct LegacyMarks {
    link: LegacyLink,
    queue: Arc<dyn JournalObserver>,
}

impl LegacyMarks {
    // On the runtime: the marks go out on a task of their own.
    pub fn new(host: Arc<dyn LegacyMirror>, clock: Arc<dyn Clock>) -> Self {
        let (link, queue) = LegacyLink::new(host, clock);
        Self { link, queue }
    }

    // After the store write landed, as the journal's signal.
    pub fn changed(&self, entries: &[JournalEntry]) {
        self.queue.changed(entries);
    }

    // Once every write named so far has marked the host; fails while the host refuses a mark.
    pub async fn flush(&self) -> Result<(), SyncError> {
        self.link.flush().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_last_change_of_a_record_stands_and_other_kinds_are_left_out() {
        let entries = [
            JournalEntry {
                kind: Kind::Group,
                written: vec!["A".to_owned()],
                deleted: vec!["B".to_owned()],
            },
            JournalEntry {
                kind: Kind::Group,
                written: vec!["B".to_owned()],
                deleted: vec!["A".to_owned()],
            },
            JournalEntry {
                kind: Kind::HistoryEntry,
                written: vec!["H".to_owned()],
                deleted: Vec::new(),
            },
        ];

        let (dirty, tombstones) = marks_of(&entries, 7, &HashMap::new());

        assert_eq!(dirty.iter().map(|record| record.id.as_str()).collect::<Vec<_>>(), ["B"]);
        assert_eq!(tombstones.len(), 1);
        assert_eq!(
            (
                tombstones[0].record.record_type.as_str(),
                tombstones[0].record.id.as_str(),
                tombstones[0].deleted_at_ms
            ),
            ("ConnectionGroup", "A", 7)
        );
    }

    #[test]
    fn a_deleted_column_layout_names_its_connection() {
        let connection = uuid::Uuid::from_u128(5);
        let category = tablepro_records::record_id::column_layout_category(connection, None, None, "users");
        let entries = [JournalEntry {
            kind: Kind::MacosSettings,
            written: Vec::new(),
            deleted: vec![category],
        }];

        let (_, tombstones) = marks_of(&entries, 1, &HashMap::new());

        assert_eq!(tombstones[0].owner, Some(connection));
    }

    #[test]
    fn a_deleted_favourite_names_the_connection_its_base_named_and_one_with_no_base_gets_no_tombstone() {
        let connection = uuid::Uuid::from_u128(6);
        let owners = HashMap::from([(("FavoriteTable".to_owned(), "F".to_owned()), connection)]);
        let entries = [JournalEntry {
            kind: Kind::FavouriteTable,
            written: Vec::new(),
            deleted: vec!["F".to_owned(), "G".to_owned()],
        }];

        let (_, tombstones) = marks_of(&entries, 1, &owners);

        let owned: Vec<(&str, Option<uuid::Uuid>)> = tombstones
            .iter()
            .map(|tombstone| (tombstone.record.id.as_str(), tombstone.owner))
            .collect();
        assert_eq!(owned, [("F", Some(connection))]);
    }

    #[test]
    fn a_mark_moves_a_dirty_record_to_its_tombstone() {
        let record = LegacyRecordRef {
            record_type: "Connection".to_owned(),
            id: "A".to_owned(),
        };
        let mut known = LegacyMetadata {
            dirty: vec![record.clone()],
            ..LegacyMetadata::default()
        };

        marked(
            &mut known,
            Vec::new(),
            vec![LegacyTombstone {
                record: record.clone(),
                deleted_at_ms: 3,
                owner: None,
            }],
        );

        assert!(known.dirty.is_empty());
        assert_eq!(known.tombstones.len(), 1);
    }
}
