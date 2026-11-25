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
use crate::api::ids::{Cursor, RecordKey, ScopeName};
use crate::api::state::{Row, RowKey, StateIdentity, StateStore};

mod copy;
mod full;
mod held;
mod rebase;
mod settle;

pub use rebase::{RebaseFailure, Rebased, ServerChanged};

use copy::Incoming;
use settle::{Batch, Finish};

// iCloud carries the personal kinds, in one zone.
pub const SCOPE: ScopeName = ScopeName::Personal;

// A profile's deletion unlinks connections and removes Keychain secrets no pull can bring back: it waits for a build
// that reads the profile, and a deletion found late, deferred or by a full fetch, never removes one.
const PROFILES: [Kind; 2] = [Kind::SshProfile, Kind::CredentialProfile];

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
}

impl Counts {
    fn add(&mut self, other: Self) {
        self.written += other.written;
        self.removed += other.removed;
        self.held += other.held;
        self.deferred += other.deferred;
        self.inferred += other.inferred;
        self.skipped += other.skipped;
        self.recovered += other.recovered;
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
}

pub struct Fetcher<'a> {
    transport: &'a dyn CloudKitTransport,
    state: &'a dyn StateStore,
    account: String,
    adapters: BTreeMap<Kind, Arc<dyn RecordAdapter>>,
    categories: Categories,
}

// Where the fetch starts: the stored token, the kinds whose store went back or was replaced, and every store's
// identity as the fetch found it.
struct Start {
    token: Option<Vec<u8>>,
    refill: BTreeSet<Kind>,
    stamps: BTreeMap<String, StoreStamp>,
}

struct Pass {
    next: Option<Vec<u8>>,
    full: bool,
    started_over: bool,
    listed: BTreeSet<RecordKey>,
    refill: BTreeSet<Kind>,
    stamps: BTreeMap<String, StoreStamp>,
}

impl Pass {
    fn new(start: Start) -> Self {
        let full = start.token.is_none() || !start.refill.is_empty();
        Self {
            next: start.token.filter(|_| !full),
            full,
            started_over: false,
            listed: BTreeSet::new(),
            refill: start.refill,
            stamps: start.stamps,
        }
    }

    // Until the full fetch ends, the state keeps the token it had, so a fetch stopped midway starts over whole and
    // its deletions are judged on a complete listing.
    fn start_over(&mut self) {
        self.next = None;
        self.full = true;
        self.started_over = true;
        self.listed.clear();
    }

    fn batch(&mut self, items: Vec<Incoming>, token: Vec<u8>, last: bool) -> Batch {
        if self.full {
            self.listed
                .extend(items.iter().filter(|item| item.listed()).map(|item| item.key().clone()));
        }
        let finish = (self.full && last).then(|| Finish {
            listed: std::mem::take(&mut self.listed),
            refill: self.refill.clone(),
        });
        Batch {
            items,
            pull_wins: self.refill.clone(),
            token: (!self.full || last).then_some(token),
            caught_up: last,
            finish,
            stamps: std::mem::take(&mut self.stamps),
            release: Vec::new(),
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
        })
    }

    pub async fn fetch(&self) -> Result<FetchReport, SyncError> {
        let start = self.start().await?;
        let mut report = FetchReport {
            refilled: start.refill.iter().copied().collect(),
            ..FetchReport::default()
        };
        let mut pass = Pass::new(start);
        loop {
            let asked = pass.next.clone();
            let changes = match self.transport.fetch_changes(self.account.clone(), asked.clone()).await {
                Ok(changes) => changes,
                Err(CloudKitFailure::TokenExpired) if !pass.started_over => {
                    report.token_expired = true;
                    pass.start_over();
                    continue;
                }
                Err(failure) => return Err(failure.into()),
            };
            report.pages += 1;
            if changes.more && asked.as_ref() == Some(&changes.token) {
                return Err(SyncError::Malformed { what: "change token" });
            }
            let last = !changes.more;
            let token = changes.token.clone();
            let items = self.read(changes).await?;
            let batch = pass.batch(items, token.clone(), last);
            report.counts.add(self.settle(batch).await?);
            if last {
                break;
            }
            pass.next = Some(token);
        }
        report.full = pass.full;
        report.counts.add(self.recover().await?);
        Ok(report)
    }

    async fn start(&self) -> Result<Start, SyncError> {
        let mut txn = self.state.begin().await?;
        let scope = match txn.get(&RowKey::Scope(SCOPE)).await? {
            Some(Row::Scope(scope)) => Some(scope),
            _ => None,
        };
        let everything = scope.as_ref().is_some_and(|scope| scope.refill);
        let token = scope.and_then(|scope| match scope.cursor {
            Some(Cursor::CloudKit(token)) => Some(token),
            _ => None,
        });
        let mut refill = BTreeSet::new();
        let mut stamps = BTreeMap::new();
        for (kind, adapter) in &self.adapters {
            let stamp = adapter.identity().await?;
            let seen = match txn.get(&RowKey::Store(adapter.store().to_owned())).await? {
                Some(Row::Store(seen)) => Some(StoreStamp {
                    generation: seen.generation,
                    sequence: seen.sequence,
                }),
                _ => None,
            };
            // A store whose category is off keeps the row it had, so it refills once the category is on.
            let refills = everything || seen.is_some_and(|seen| stamp.needs_refill(seen));
            if refills && self.categories.syncs(*kind) {
                refill.insert(*kind);
            }
            stamps.insert(adapter.store().to_owned(), stamp);
        }
        Ok(Start { token, refill, stamps })
    }

    // A record the zone reported changed whose fetch failed is fetched by name, and held when it still fails, so the
    // token can pass it without losing the change.
    async fn read(&self, changes: CloudKitChanges) -> Result<Vec<Incoming>, SyncError> {
        let mut items: Vec<Incoming> = changes.changed.iter().filter_map(copy::changed).collect();
        let unfetched: Vec<String> = changes
            .unfetched
            .into_iter()
            .filter(|name| copy::key_of_name(name).is_some())
            .collect();
        let mut unanswered: BTreeSet<String> = unfetched.iter().cloned().collect();
        for answer in self.fetch_names(unfetched).await? {
            match answer {
                CloudKitFetched::Found { record } => {
                    unanswered.remove(&record.name);
                    items.extend(copy::changed(&record));
                }
                CloudKitFetched::Missing { name } => {
                    unanswered.remove(&name);
                }
                CloudKitFetched::Failed { name, .. } => {
                    unanswered.remove(&name);
                    items.extend(copy::key_of_name(&name).map(|key| Incoming::Unread { key, tag: None }));
                }
            }
        }
        items.extend(
            unanswered
                .iter()
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
pub async fn read_everything_again(state: &dyn StateStore) -> Result<(), SyncError> {
    let mut txn = state.begin().await?;
    if let Some(Row::Scope(mut scope)) = txn.get(&RowKey::Scope(SCOPE)).await? {
        scope.cursor = None;
        txn.put(Row::Scope(scope)).await?;
        txn.commit().await?;
    }
    Ok(())
}
