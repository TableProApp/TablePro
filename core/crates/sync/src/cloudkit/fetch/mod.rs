// The fetch half of the CloudKit engine (0054, The CloudKit transport; A pass; Rules for both providers). It reads the
// zone's changes from its change token and merges each record three ways against its base, then writes the stores,
// the bases, and last the token. It holds by id what this build cannot read, defers the deletions of a category that
// is off, starts a full fetch when the token expired, treats a record a full fetch did not return as deleted, refills
// a restored store, and merges a save CloudKit refused with `serverRecordChanged`.
//
// No CloudKit call runs inside a state transaction, and a call that fails commits nothing of its results: an
// `AccountChanged` ends the fetch with nothing written to either account.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use tablepro_records::Kind;
use tablepro_records::cloudkit::record_type_of;

use crate::api::adapter::{RecordAdapter, StoreStamp};
use crate::api::cloudkit::{CloudKitChanges, CloudKitFailure, CloudKitFetched, CloudKitTransport};
use crate::api::error::{StateError, SyncError};
use crate::api::ids::{Cursor, KindName, RecordKey, ScopeName};
use crate::api::state::{
    HeldReason, Row, RowKey, RowRange, StateIdentity, StateStore, StateTxn, StoreRow, StoresKindRow, Table,
};
use crate::cloudkit::codes;
use crate::engine::{Backoff, StopSignal};

pub(in crate::cloudkit) mod copy;
mod full;
mod held;
mod pending;
mod rebase;
mod settle;
mod stores;

pub(crate) use copy::{key_of_name as listed_key, wire_fields};
pub use rebase::{RebaseFailure, Rebased, ServerChanged};
pub(in crate::cloudkit) use settle::{PRIOR, prior_of};
pub(in crate::cloudkit) use stores::{carried, stored_id};

use copy::Incoming;
use settle::{Batch, Finish};

// iCloud carries the personal kinds, in one zone.
pub const SCOPE: ScopeName = ScopeName::Personal;

// A profile's deletion unlinks connections and removes Keychain secrets no pull can bring back: it waits for a build
// that reads the profile, and a deletion found late, deferred or by a full fetch, never removes one.
pub(in crate::cloudkit) const PROFILES: [Kind; 2] = [Kind::SshProfile, Kind::CredentialProfile];

// The kinds whose category is on. Another kind sends nothing and takes no pulled change, and a deletion pulled for it
// waits until a full fetch reads its category.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Categories(BTreeSet<Kind>);

impl Categories {
    pub fn new(kinds: impl IntoIterator<Item = Kind>) -> Self {
        Self(kinds.into_iter().collect())
    }

    pub fn syncs(&self, kind: Kind) -> bool {
        self.0.contains(&kind)
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Counts {
    // Records a store wrote or deleted from what the zone said.
    pub written: u32,
    pub removed: u32,
    // Changes and deletions held by id.
    pub held: u32,
    // Deletions waiting for their category.
    pub deferred: u32,
    // Deletions a full fetch found by what it no longer listed.
    pub inferred: u32,
    // Changes of a category that is off.
    pub skipped: u32,
    // Held changes fetched by name once their copy read.
    pub recovered: u32,
    // Pulled changes the store refused to keep, held by id.
    pub refused: u32,
}

impl Counts {
    const fn add(&mut self, other: Self) {
        self.written = self.written.saturating_add(other.written);
        self.removed = self.removed.saturating_add(other.removed);
        self.held = self.held.saturating_add(other.held);
        self.deferred = self.deferred.saturating_add(other.deferred);
        self.inferred = self.inferred.saturating_add(other.inferred);
        self.skipped = self.skipped.saturating_add(other.skipped);
        self.recovered = self.recovered.saturating_add(other.recovered);
        self.refused = self.refused.saturating_add(other.refused);
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FetchReport {
    pub full: bool,
    pub token_expired: bool,
    // Kinds whose store refilled from this fetch.
    pub refilled: Vec<Kind>,
    pub pages: u32,
    pub counts: Counts,
    // The longest wait CloudKit named for a record it could not return; the next pass waits it out.
    pub retry_after_ms: Option<u64>,
    // Each record CloudKit asked to wait for, and how long, which the engine does not ask for before then.
    pub waits: Vec<(RecordKey, u64)>,
    // CloudKit asked to be tried again later, or the network dropped, for a record it named no wait for.
    pub throttled: bool,
}

pub struct Fetcher<'a> {
    pub(in crate::cloudkit) transport: &'a dyn CloudKitTransport,
    pub(in crate::cloudkit) state: &'a dyn StateStore,
    pub(in crate::cloudkit) account: String,
    pub(in crate::cloudkit) adapters: BTreeMap<Kind, Arc<dyn RecordAdapter>>,
    pub(in crate::cloudkit) categories: Categories,
    stop: Option<StopSignal>,
    // Records CloudKit asked to wait for that are still waiting: their changes stay held and are not asked for.
    waiting: BTreeSet<RecordKey>,
    // Records whose store refused their change in this fetch: its recovery does not ask for them again.
    pub(in crate::cloudkit) refused: std::sync::Mutex<BTreeSet<RecordKey>>,
}

// Records CloudKit could not return and asked to wait for, which the fetch does not ask for again. A wait past the
// scheduler's cap is read as the cap, so CloudKit cannot hold a record off until a restart.
#[derive(Debug, Default)]
struct Waited {
    keys: BTreeMap<RecordKey, u64>,
    later: bool,
}

impl Waited {
    fn note(&mut self, name: &str, code: i64, retry_after_ms: Option<u64>) {
        match (copy::key_of_name(name), retry_after_ms) {
            (Some(key), Some(wait)) => {
                let wait = wait.min(Backoff::MAX_RETRY_AFTER_MS);
                let held = self.keys.entry(key).or_insert(wait);
                *held = (*held).max(wait);
            }
            _ => self.later |= codes::later(code),
        }
    }

    fn holds(&self, name: &str) -> bool {
        copy::key_of_name(name).is_some_and(|key| self.keys.contains_key(&key))
    }
}

// Where the fetch starts: the stored token, the kinds that refill now, and each store's identity as the fetch found it.
struct Start {
    token: Option<Vec<u8>>,
    refill: BTreeSet<Kind>,
    // Kinds that are off while this start marked their store: each keeps the copy its store holds now, the one the
    // restore left, and a later refill of others never takes it again (0066, `deferred`).
    keep_copies: BTreeSet<Kind>,
    stores: BTreeMap<String, StoreStamp>,
    // Records a refill's store refused, which take the pull on whatever page brings them, as the refill would have.
    refill_held: BTreeSet<RecordKey>,
}

struct Pass {
    next: Option<Vec<u8>>,
    full: bool,
    started_over: bool,
    listed: BTreeSet<RecordKey>,
    oldest_created_ms: Option<i64>,
    // Tokens this pass was given, so a transport that never ends a fetch is refused.
    seen: BTreeSet<Vec<u8>>,
    start: Start,
    stamps: BTreeMap<String, StoreStamp>,
}

impl Pass {
    fn new(start: Start) -> Self {
        let full = start.token.is_none() || !start.refill.is_empty() || !start.keep_copies.is_empty();
        let stamps = start.stores.clone();
        Self {
            next: start.token.clone().filter(|_| !full),
            full,
            started_over: false,
            listed: BTreeSet::new(),
            oldest_created_ms: None,
            seen: start.token.iter().filter(|_| !full).cloned().collect(),
            start,
            stamps,
        }
    }

    // Until the full fetch ends, the state keeps the token it had, so a fetch stopped midway starts over whole and
    // its deletions are judged on a complete listing.
    fn start_over(&mut self) {
        self.next = None;
        self.full = true;
        self.started_over = true;
        self.listed.clear();
        self.oldest_created_ms = None;
        self.seen.clear();
    }

    fn refill(&self) -> BTreeSet<Kind> {
        self.start.refill.clone()
    }

    fn batch(&mut self, items: Vec<Incoming>, token: Vec<u8>, last: bool) -> Batch {
        if self.full {
            self.listed
                .extend(items.iter().filter(|item| item.listed()).map(|item| item.key().clone()));
            let created = items.iter().filter_map(|item| match item {
                Incoming::Changed(copy) => copy.created_ms,
                _ => None,
            });
            self.oldest_created_ms = created.chain(self.oldest_created_ms).min();
        }
        let finish = (self.full && last).then(|| Finish {
            listed: std::mem::take(&mut self.listed),
            oldest_created_ms: self.oldest_created_ms.take(),
            refill: self.refill(),
            started: self.start.stores.clone(),
        });
        Batch {
            items,
            pull_wins: self.refill(),
            token: (!self.full || last).then_some(token),
            caught_up: last,
            finish,
            stamps: std::mem::take(&mut self.stamps),
            started: self.start.stores.clone(),
            release: Vec::new(),
            keep_copies: self.start.keep_copies.clone(),
            pull_wins_keys: self.start.refill_held.clone(),
        }
    }
}

impl<'a> Fetcher<'a> {
    // Bound to the iCloud account the state file was made for; adapters of kinds iCloud does not carry are left out.
    pub fn new(
        transport: &'a dyn CloudKitTransport,
        state: &'a dyn StateStore,
        adapters: &[Arc<dyn RecordAdapter>],
        categories: Categories,
    ) -> Result<Self, SyncError> {
        let StateIdentity::ICloud { user_record_name } = state.identity() else {
            return Err(StateError::WrongIdentity.into());
        };
        Ok(Self {
            transport,
            state,
            account: user_record_name.clone(),
            adapters: adapters
                .iter()
                .filter(|adapter| record_type_of(adapter.kind()).is_some())
                .map(|adapter| (adapter.kind(), Arc::clone(adapter)))
                .collect(),
            categories,
            stop: None,
            waiting: BTreeSet::new(),
            refused: std::sync::Mutex::default(),
        })
    }

    // A provider stop ends the fetch before its next store write or state commit (P1-M4).
    #[must_use]
    pub fn stopped_by(mut self, stop: StopSignal) -> Self {
        self.stop = Some(stop);
        self
    }

    #[must_use]
    pub fn waiting(mut self, keys: BTreeSet<RecordKey>) -> Self {
        self.waiting = keys;
        self
    }

    pub(in crate::cloudkit) fn check_stop(&self) -> Result<(), SyncError> {
        self.stop.as_ref().map_or(Ok(()), StopSignal::check)
    }

    pub async fn fetch(&self) -> Result<FetchReport, SyncError> {
        self.settle_pending().await?;
        let start = self.start().await?;
        let mut report = FetchReport {
            refilled: start.refill.iter().copied().collect(),
            ..FetchReport::default()
        };
        let mut pass = Pass::new(start);
        let mut waited = Waited::default();
        loop {
            let changes = match self
                .transport
                .fetch_changes(self.account.clone(), pass.next.clone())
                .await
            {
                Ok(changes) => changes,
                Err(CloudKitFailure::TokenExpired) if !pass.started_over => {
                    report.token_expired = true;
                    pass.start_over();
                    continue;
                }
                Err(failure) => return Err(failure.into()),
            };
            report.pages = report.pages.saturating_add(1);
            let empty = changes.changed.is_empty() && changes.deleted.is_empty() && changes.unfetched.is_empty();
            if changes.more && (empty || !pass.seen.insert(changes.token.clone())) {
                return Err(SyncError::Malformed { what: "change token" });
            }
            let last = !changes.more;
            let token = changes.token.clone();
            let items = self.read(changes, &mut waited).await?;
            let batch = pass.batch(items, token.clone(), last);
            report.counts.add(self.settle(batch).await?);
            if last {
                break;
            }
            pass.next = Some(token);
        }
        report.full = pass.full;
        report.counts.add(self.recover(pass.refill(), &mut waited).await?);
        report.retry_after_ms = waited.keys.values().max().copied();
        report.waits = waited.keys.into_iter().collect();
        report.throttled = waited.later;
        Ok(report)
    }

    async fn start(&self) -> Result<Start, SyncError> {
        let mut txn = self.state.begin().await?;
        let scope = match txn.get(&RowKey::Scope(SCOPE)).await? {
            Some(Row::Scope(scope)) => Some(scope),
            _ => None,
        };
        let scope_refill = scope.as_ref().is_some_and(|scope| scope.refill);
        let token = scope.and_then(|scope| match scope.cursor {
            Some(Cursor::CloudKit(token)) => Some(token),
            _ => None,
        });
        let refill_held = held_in_refill(txn.as_mut()).await?;
        let mut start = Start {
            token,
            refill: BTreeSet::new(),
            keep_copies: BTreeSet::new(),
            stores: BTreeMap::new(),
            refill_held,
        };
        for adapter in self.adapters.values() {
            if !start.stores.contains_key(adapter.store()) {
                start
                    .stores
                    .insert(adapter.store().to_owned(), adapter.identity().await?);
            }
        }
        // One row per store file. A new generation or a lower sequence, or the whole file refilling, owes each of the
        // store's kinds a refill, which a kind takes once its category is on (0066, Per-kind refills). The marks land
        // before the fetch, so one cut short refills again.
        let mut wrote = false;
        let mut marked: BTreeSet<String> = BTreeSet::new();
        // A file schema 1 wrote holds a `stores` row per kind, `<store>/<kind>`, which a kind whose category was off kept
        // until it refilled. A kind whose row is behind its store still owes that refill, and the row goes.
        for (kind, adapter) in &self.adapters {
            let legacy = RowKey::Store(format!("{}/{}", adapter.store(), kind.as_str()));
            let Some(Row::Store(seen)) = txn.get(&legacy).await? else {
                continue;
            };
            let behind = start.stores.get(adapter.store()).is_some_and(|stamp| {
                stamp.needs_refill(StoreStamp {
                    generation: seen.generation,
                    sequence: seen.sequence,
                })
            });
            if behind {
                txn.put(Row::StoresKind(StoresKindRow {
                    store: adapter.store().to_owned(),
                    kind: KindName::of(*kind),
                }))
                .await?;
                marked.insert(adapter.store().to_owned());
            }
            txn.delete(&legacy).await?;
            wrote = true;
        }
        for (store, stamp) in &start.stores {
            let seen = match txn.get(&RowKey::Store(store.clone())).await? {
                Some(Row::Store(seen)) => Some(StoreStamp {
                    generation: seen.generation,
                    sequence: seen.sequence,
                }),
                _ => None,
            };
            let restored = seen.is_some_and(|seen| stamp.needs_refill(seen));
            if restored || scope_refill {
                marked.insert(store.clone());
                for kind in self.kinds_of(store) {
                    txn.put(Row::StoresKind(StoresKindRow {
                        store: store.clone(),
                        kind: KindName::of(kind),
                    }))
                    .await?;
                }
                wrote = true;
            }
            if seen.is_none() || restored {
                txn.put(Row::Store(StoreRow {
                    store: store.clone(),
                    generation: stamp.generation,
                    sequence: stamp.sequence,
                }))
                .await?;
                wrote = true;
            }
        }
        wrote |= carry_marks(txn.as_mut(), &self.adapters).await?;
        for (kind, adapter) in &self.adapters {
            let owed = txn
                .get(&RowKey::StoresKind(adapter.store().to_owned(), KindName::of(*kind)))
                .await?
                .is_some();
            if owed && self.categories.syncs(*kind) {
                start.refill.insert(*kind);
            } else if owed && marked.contains(adapter.store()) {
                start.keep_copies.insert(*kind);
            }
        }
        if wrote {
            self.check_stop()?;
            txn.commit().await?;
        }
        Ok(start)
    }

    fn kinds_of<'s>(&'s self, store: &'s str) -> impl Iterator<Item = Kind> + 's {
        self.adapters
            .iter()
            .filter(move |(_, adapter)| adapter.store() == store)
            .map(|(kind, _)| *kind)
    }

    // A record the zone reported changed whose fetch failed is fetched by name, and held when it still fails, so the
    // token can pass it without losing the change.
    async fn read(&self, changes: CloudKitChanges, waited: &mut Waited) -> Result<Vec<Incoming>, SyncError> {
        let mut items: Vec<Incoming> = changes.changed.iter().filter_map(copy::changed).collect();
        let (waiting, unfetched): (Vec<String>, Vec<String>) = changes
            .unfetched
            .into_iter()
            .filter(|name| copy::key_of_name(name).is_some())
            .partition(|name| copy::key_of_name(name).is_some_and(|key| self.waiting.contains(&key)));
        let (answers, unanswered) = self.fetch_asked(unfetched).await?;
        for answer in answers {
            match answer {
                CloudKitFetched::Found { record } => items.extend(copy::changed(&record)),
                CloudKitFetched::Missing { .. } => {}
                CloudKitFetched::Failed {
                    name,
                    code,
                    retry_after_ms,
                } => {
                    waited.note(&name, code, retry_after_ms);
                    items.extend(copy::key_of_name(&name).map(|key| Incoming::Unread { key, tag: None }));
                }
            }
        }
        items.extend(
            unanswered
                .iter()
                .chain(&waiting)
                .filter_map(|name| copy::key_of_name(name))
                .map(|key| Incoming::Unread { key, tag: None }),
        );
        items.extend(changes.deleted.iter().filter_map(copy::deleted));
        Ok(items)
    }
}

// Clears the zone's token, so the next fetch reads the whole zone. Called when a category turns on or the build
// stores a kind it did not: a delta never sends again what earlier pulls passed over, and the deletions that waited
// for that category apply once a full fetch read it.
// A refill a kind owed under the store its records lived in before, as the saved queries split out of the history's
// file, moves to the store that holds them now, so a split never drops one (K4h; Codex review round 2).
async fn carry_marks(
    txn: &mut dyn StateTxn,
    adapters: &BTreeMap<Kind, Arc<dyn RecordAdapter>>,
) -> Result<bool, SyncError> {
    let mut wrote = false;
    for row in txn.scan(&RowRange::Table(Table::StoresKinds)).await? {
        let Row::StoresKind(owed) = row else { continue };
        let Some(adapter) = owed.kind.known().and_then(|kind| adapters.get(&kind)) else {
            continue;
        };
        if adapter.store() != owed.store {
            txn.delete(&RowKey::StoresKind(owed.store.clone(), owed.kind.clone()))
                .await?;
            txn.put(Row::StoresKind(StoresKindRow {
                store: adapter.store().to_owned(),
                kind: owed.kind,
            }))
            .await?;
            wrote = true;
        }
    }
    Ok(wrote)
}

// Records a refill's store refused, which take the pull on whatever page brings them.
async fn held_in_refill(txn: &mut dyn StateTxn) -> Result<BTreeSet<RecordKey>, SyncError> {
    Ok(txn
        .scan(&RowRange::Scope(Table::Held, SCOPE))
        .await?
        .into_iter()
        .filter_map(|row| match row {
            Row::Held(held) if held.reason == HeldReason::RefusedInRefill => Some(held.key),
            _ => None,
        })
        .collect())
}

pub async fn read_everything_again(state: &dyn StateStore) -> Result<(), SyncError> {
    let mut txn = state.begin().await?;
    if let Some(Row::Scope(mut scope)) = txn.get(&RowKey::Scope(SCOPE)).await? {
        scope.cursor = None;
        txn.put(Row::Scope(scope)).await?;
        txn.commit().await?;
    }
    Ok(())
}
