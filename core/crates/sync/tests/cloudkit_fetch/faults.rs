// Faults the fake zone and state file do not play on their own: records the zone lists but cannot return, a fetch
// that stops midway, and a crash between the store write and the state commit.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use tablepro_sync::api::cloudkit::{
    CloudKitAccount, CloudKitChanges, CloudKitFailure, CloudKitFetched, CloudKitOutcome, CloudKitRecord,
    CloudKitTransport,
};
use tablepro_sync::api::error::StateError;
use tablepro_sync::api::state::{Committed, Opened, Row, RowKey, RowRange, StateIdentity, StateStore, StateTxn};
use tablepro_sync_testing::FakeCloudKit;

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[derive(Default)]
struct Faults {
    unfetched: BTreeSet<String>,
    failing_reads: BTreeMap<String, u32>,
    fetch_calls_before_failure: Option<usize>,
    names_asked: Vec<Vec<String>>,
}

pub struct Unreliable<'a> {
    inner: &'a FakeCloudKit,
    faults: Mutex<Faults>,
}

impl<'a> Unreliable<'a> {
    pub fn new(inner: &'a FakeCloudKit) -> Self {
        Self {
            inner,
            faults: Mutex::new(Faults::default()),
        }
    }

    // The zone reports the record changed, but the change fetch does not return it.
    pub fn leave_unfetched(&self, name: &str) {
        lock(&self.faults).unfetched.insert(name.to_owned());
    }

    // The next `times` reads of the record by name fail.
    pub fn fail_reads(&self, name: &str, times: u32) {
        lock(&self.faults).failing_reads.insert(name.to_owned(), times);
    }

    // After `calls` more change fetches, the next one fails with the network.
    pub fn stop_after(&self, calls: usize) {
        lock(&self.faults).fetch_calls_before_failure = Some(calls);
    }

    pub fn names_asked(&self) -> Vec<Vec<String>> {
        lock(&self.faults).names_asked.clone()
    }
}

#[async_trait]
impl CloudKitTransport for Unreliable<'_> {
    async fn account_status(&self) -> Result<CloudKitAccount, CloudKitFailure> {
        self.inner.account_status().await
    }

    async fn ensure_zone(&self, account: String) -> Result<(), CloudKitFailure> {
        self.inner.ensure_zone(account).await
    }

    async fn delete_zone(&self, account: String) -> Result<(), CloudKitFailure> {
        self.inner.delete_zone(account).await
    }

    async fn fetch_changes(&self, account: String, token: Option<Vec<u8>>) -> Result<CloudKitChanges, CloudKitFailure> {
        {
            let mut faults = lock(&self.faults);
            match faults.fetch_calls_before_failure {
                Some(0) => {
                    faults.fetch_calls_before_failure = None;
                    return Err(CloudKitFailure::Network);
                }
                Some(calls) => faults.fetch_calls_before_failure = Some(calls - 1),
                None => {}
            }
        }
        let mut changes = self.inner.fetch_changes(account, token).await?;
        let unfetched = lock(&self.faults).unfetched.clone();
        let (left, kept): (Vec<CloudKitRecord>, Vec<CloudKitRecord>) = changes
            .changed
            .into_iter()
            .partition(|record| unfetched.contains(&record.name));
        changes.changed = kept;
        changes.unfetched.extend(left.into_iter().map(|record| record.name));
        Ok(changes)
    }

    async fn fetch_records(
        &self,
        account: String,
        names: Vec<String>,
    ) -> Result<Vec<CloudKitFetched>, CloudKitFailure> {
        lock(&self.faults).names_asked.push(names.clone());
        let answers = self.inner.fetch_records(account, names).await?;
        let mut faults = lock(&self.faults);
        Ok(answers
            .into_iter()
            .map(|answer| {
                let name = match &answer {
                    CloudKitFetched::Found { record } => record.name.clone(),
                    CloudKitFetched::Missing { name } | CloudKitFetched::Failed { name, .. } => name.clone(),
                };
                match faults.failing_reads.get_mut(&name) {
                    Some(times) if *times > 0 => {
                        *times -= 1;
                        CloudKitFetched::Failed {
                            name,
                            code: 15,
                            retry_after_ms: None,
                        }
                    }
                    _ => answer,
                }
            })
            .collect())
    }

    async fn modify(
        &self,
        account: String,
        saves: Vec<CloudKitRecord>,
        deletes: Vec<String>,
    ) -> Result<Vec<CloudKitOutcome>, CloudKitFailure> {
        self.inner.modify(account, saves, deletes).await
    }
}

// The process stops after the stores took a batch and before the state file committed it.
pub struct Crashing {
    inner: Arc<dyn StateStore>,
    crash_next_commit: Arc<Mutex<bool>>,
}

impl Crashing {
    pub fn new(inner: Arc<dyn StateStore>) -> Self {
        Self {
            inner,
            crash_next_commit: Arc::new(Mutex::new(false)),
        }
    }

    pub fn crash_next_commit(&self) {
        *lock(&self.crash_next_commit) = true;
    }
}

#[async_trait]
impl StateStore for Crashing {
    fn identity(&self) -> &StateIdentity {
        self.inner.identity()
    }

    fn opened(&self) -> &Opened {
        self.inner.opened()
    }

    async fn begin(&self) -> Result<Box<dyn StateTxn>, StateError> {
        Ok(Box::new(CrashingTxn {
            inner: self.inner.begin().await?,
            crash: Arc::clone(&self.crash_next_commit),
        }))
    }
}

struct CrashingTxn {
    inner: Box<dyn StateTxn>,
    crash: Arc<Mutex<bool>>,
}

#[async_trait]
impl StateTxn for CrashingTxn {
    async fn get(&mut self, key: &RowKey) -> Result<Option<Row>, StateError> {
        self.inner.get(key).await
    }

    async fn scan(&mut self, range: &RowRange) -> Result<Vec<Row>, StateError> {
        self.inner.scan(range).await
    }

    async fn put(&mut self, row: Row) -> Result<(), StateError> {
        self.inner.put(row).await
    }

    async fn delete(&mut self, key: &RowKey) -> Result<(), StateError> {
        self.inner.delete(key).await
    }

    async fn clear_key_tables(&mut self) -> Result<(), StateError> {
        self.inner.clear_key_tables().await
    }

    async fn commit(self: Box<Self>) -> Result<Committed, StateError> {
        if std::mem::take(&mut *lock(&self.crash)) {
            return Err(StateError::Io {
                detail: "the process stopped".to_owned(),
            });
        }
        self.inner.commit().await
    }
}
