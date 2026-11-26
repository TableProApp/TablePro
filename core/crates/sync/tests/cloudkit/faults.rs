// Faults the fake zone and state file do not play on their own: records the zone lists but cannot return, a fetch
// that stops midway, a crash at one of the state commits, and a modify call's answers changed on the way back.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use tablepro_sync::api::cloudkit::{
    CloudKitAccount, CloudKitChanges, CloudKitFailure, CloudKitFetched, CloudKitOutcome, CloudKitRecord,
    CloudKitTransport,
};
use tablepro_sync::api::error::StateError;
use tablepro_sync::api::state::{
    Committed, KeysSettled, Opened, Row, RowKey, RowRange, StateIdentity, StateStore, StateTxn,
};
use tablepro_sync_testing::FakeCloudKit;

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

type Hook<'a> = Box<dyn FnOnce() + Send + 'a>;

#[derive(Default)]
struct Faults {
    unfetched: BTreeSet<String>,
    failing_reads: BTreeMap<String, u32>,
    // The wait a failing read names, and its code when not 15.
    read_wait: Option<u64>,
    read_code: Option<i64>,
    fetch_calls_before_failure: Option<(usize, CloudKitFailure)>,
    read_call_failure: Option<CloudKitFailure>,
    names_per_call: Option<usize>,
    hide_deletions: bool,
    endless: bool,
    repeat_token: Option<Vec<u8>>,
    renamed_answers: BTreeMap<String, String>,
    calls: usize,
    names_asked: Vec<Vec<String>>,
}

pub struct Unreliable<'a> {
    inner: &'a FakeCloudKit,
    faults: Mutex<Faults>,
    // Runs before the change fetch of that number, counted from 0.
    hooks: Mutex<Vec<(usize, Hook<'a>)>>,
}

impl<'a> Unreliable<'a> {
    pub fn new(inner: &'a FakeCloudKit) -> Self {
        Self {
            inner,
            faults: Mutex::new(Faults::default()),
            hooks: Mutex::new(Vec::new()),
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

    // A failing read asks to be tried again after this long, as a throttled one does.
    pub fn wait_on_failed_reads(&self, ms: u64) {
        lock(&self.faults).read_wait = Some(ms);
    }

    pub fn failed_reads_answer(&self, code: i64) {
        lock(&self.faults).read_code = Some(code);
    }

    // After `calls` more change fetches, the next one fails with the network.
    pub fn stop_after(&self, calls: usize) {
        self.fail_after(calls, CloudKitFailure::Network);
    }

    pub fn fail_after(&self, calls: usize, failure: CloudKitFailure) {
        lock(&self.faults).fetch_calls_before_failure = Some((calls, failure));
    }

    // The next read by name fails whole.
    pub fn fail_next_read_call(&self, failure: CloudKitFailure) {
        lock(&self.faults).read_call_failure = Some(failure);
    }

    // The change fetch leaves deletions out, as a zone that lost them would.
    pub fn hide_deletions(&self) {
        lock(&self.faults).hide_deletions = true;
    }

    pub fn before_call(&self, call: usize, hook: Hook<'a>) {
        lock(&self.hooks).push((call, hook));
    }

    // A page that says more follows ends at this token instead of its own.
    pub fn repeat_token(&self, token: Vec<u8>) {
        lock(&self.faults).repeat_token = Some(token);
    }

    // A read by name of `asked` answers as if the record were `given`.
    pub fn rename_answer(&self, asked: &str, given: &str) {
        lock(&self.faults)
            .renamed_answers
            .insert(asked.to_owned(), given.to_owned());
    }

    // Every page is empty and says more follows, each with a new token.
    pub fn never_end(&self) {
        lock(&self.faults).endless = true;
    }

    // A read by name of more records than this answers `limitExceeded`.
    pub fn limit_names(&self, names: usize) {
        lock(&self.faults).names_per_call = Some(names);
    }

    pub fn names_asked(&self) -> Vec<Vec<String>> {
        lock(&self.faults).names_asked.clone()
    }
}

#[async_trait]
impl<'a> CloudKitTransport for Unreliable<'a> {
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
        let call = {
            let mut faults = lock(&self.faults);
            faults.calls += 1;
            faults.calls - 1
        };
        let due: Vec<Hook<'a>> = {
            let mut hooks = lock(&self.hooks);
            let (due, later): (Vec<_>, Vec<_>) = hooks.drain(..).partition(|(at, _)| *at == call);
            *hooks = later;
            due.into_iter().map(|(_, hook)| hook).collect()
        };
        for hook in due {
            hook();
        }
        {
            let mut faults = lock(&self.faults);
            match faults.fetch_calls_before_failure.take() {
                Some((0, failure)) => return Err(failure),
                Some((calls, failure)) => faults.fetch_calls_before_failure = Some((calls - 1, failure)),
                None => {}
            }
            if faults.endless {
                let mut next = token.unwrap_or_default();
                next.push(0);
                return Ok(CloudKitChanges {
                    changed: Vec::new(),
                    deleted: Vec::new(),
                    unfetched: Vec::new(),
                    token: next,
                    more: true,
                });
            }
        }
        let mut changes = self.inner.fetch_changes(account, token).await?;
        if lock(&self.faults).hide_deletions {
            changes.deleted.clear();
        }
        if let Some(token) = lock(&self.faults).repeat_token.clone().filter(|_| changes.more) {
            changes.token = token;
        }
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
        {
            let mut faults = lock(&self.faults);
            faults.names_asked.push(names.clone());
            if let Some(failure) = faults.read_call_failure.take() {
                return Err(failure);
            }
            if faults.names_per_call.is_some_and(|limit| names.len() > limit) {
                return Err(CloudKitFailure::LimitExceeded);
            }
        }
        let answers = self.inner.fetch_records(account, names).await?;
        let mut faults = lock(&self.faults);
        Ok(answers
            .into_iter()
            .map(|answer| {
                let name = match &answer {
                    CloudKitFetched::Found { record } => record.name.clone(),
                    CloudKitFetched::Missing { name } | CloudKitFetched::Failed { name, .. } => name.clone(),
                };
                if let (CloudKitFetched::Found { record }, Some(given)) = (&answer, faults.renamed_answers.get(&name)) {
                    let mut record = record.clone();
                    record.name = given.clone();
                    return CloudKitFetched::Found { record };
                }
                match faults.failing_reads.get_mut(&name) {
                    Some(times) if *times > 0 => {
                        *times -= 1;
                        CloudKitFetched::Failed {
                            name,
                            code: faults.read_code.unwrap_or(15),
                            retry_after_ms: faults.read_wait,
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

// The process stops at a state commit: the commits before it land, it and everything after it do not.
pub struct Crashing {
    inner: Arc<dyn StateStore>,
    // The commits still to land before the crash.
    crash: Arc<Mutex<Option<usize>>>,
}

impl Crashing {
    pub fn new(inner: Arc<dyn StateStore>) -> Self {
        Self {
            inner,
            crash: Arc::new(Mutex::new(None)),
        }
    }

    pub fn crash_next_commit(&self) {
        self.crash_after_commits(0);
    }

    pub fn crash_after_commits(&self, landing: usize) {
        *lock(&self.crash) = Some(landing);
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
            crash: Arc::clone(&self.crash),
        }))
    }
}

struct CrashingTxn {
    inner: Box<dyn StateTxn>,
    crash: Arc<Mutex<Option<usize>>>,
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

    fn settle_keys(&mut self, settled: KeysSettled) {
        self.inner.settle_keys(settled);
    }

    async fn commit(self: Box<Self>) -> Result<Committed, StateError> {
        {
            let mut crash = lock(&self.crash);
            match *crash {
                Some(0) => {
                    return Err(StateError::Io {
                        detail: "the process stopped".to_owned(),
                    });
                }
                Some(landing) => *crash = Some(landing - 1),
                None => {}
            }
        }
        self.inner.commit().await
    }
}

type ModifyHook = Box<dyn FnOnce(&FakeCloudKit) + Send>;

#[derive(Default)]
struct ModifyFaults {
    before_modify: Vec<ModifyHook>,
    // The next answer for the record, in place of what the zone gave.
    answers: BTreeMap<String, CloudKitOutcome>,
    // Answers the call leaves out.
    unanswered: BTreeSet<String>,
    // The next modify call never answers.
    hang: bool,
    // Records a change fetch lists but does not return, and the wait their next read by name asks for.
    unfetched: BTreeMap<String, u64>,
    // Each name read by name, in order.
    read: Vec<String>,
}

// The fake zone behind the pass, with calls it does not play on its own: the account switching as a modify call
// starts, a record's answer changed or left out, a call that never answers, and a record CloudKit asks to wait for.
pub struct Flaky {
    inner: Arc<FakeCloudKit>,
    faults: Mutex<ModifyFaults>,
    // Told once a modify call starts.
    pub modifying: tokio::sync::Notify,
}

impl Flaky {
    pub fn new(inner: Arc<FakeCloudKit>) -> Arc<Self> {
        Arc::new(Self {
            inner,
            faults: Mutex::new(ModifyFaults::default()),
            modifying: tokio::sync::Notify::new(),
        })
    }

    pub fn hang_next_modify(&self) {
        lock(&self.faults).hang = true;
    }

    // The change fetch leaves the record out, and its first read by name answers that CloudKit asks to wait `ms`.
    pub fn wait_on_read(&self, name: &str, ms: u64) {
        lock(&self.faults).unfetched.insert(name.to_owned(), ms);
    }

    pub fn reads_of(&self, name: &str) -> usize {
        lock(&self.faults).read.iter().filter(|read| *read == name).count()
    }

    pub fn before_next_modify(&self, hook: ModifyHook) {
        lock(&self.faults).before_modify.push(hook);
    }

    pub fn answer_once(&self, name: &str, outcome: CloudKitOutcome) {
        lock(&self.faults).answers.insert(name.to_owned(), outcome);
    }

    pub fn leave_unanswered(&self, name: &str) {
        lock(&self.faults).unanswered.insert(name.to_owned());
    }
}

#[async_trait]
impl CloudKitTransport for Flaky {
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
        let mut changes = self.inner.fetch_changes(account, token).await?;
        let faults = lock(&self.faults);
        let (left, kept): (Vec<CloudKitRecord>, Vec<CloudKitRecord>) = changes
            .changed
            .into_iter()
            .partition(|record| faults.unfetched.contains_key(&record.name));
        changes.changed = kept;
        changes.unfetched.extend(left.into_iter().map(|record| record.name));
        Ok(changes)
    }

    async fn fetch_records(
        &self,
        account: String,
        names: Vec<String>,
    ) -> Result<Vec<CloudKitFetched>, CloudKitFailure> {
        let answers = self.inner.fetch_records(account, names.clone()).await?;
        let mut faults = lock(&self.faults);
        faults.read.extend(names);
        Ok(answers
            .into_iter()
            .map(|answer| match answer {
                CloudKitFetched::Found { record } => match faults.unfetched.remove(&record.name) {
                    Some(wait) => CloudKitFetched::Failed {
                        name: record.name,
                        code: 7,
                        retry_after_ms: Some(wait),
                    },
                    None => CloudKitFetched::Found { record },
                },
                other => other,
            })
            .collect())
    }

    async fn modify(
        &self,
        account: String,
        saves: Vec<CloudKitRecord>,
        deletes: Vec<String>,
    ) -> Result<Vec<CloudKitOutcome>, CloudKitFailure> {
        self.modifying.notify_one();
        if std::mem::take(&mut lock(&self.faults).hang) {
            std::future::pending::<()>().await;
        }
        let hooks = std::mem::take(&mut lock(&self.faults).before_modify);
        for hook in hooks {
            hook(&self.inner);
        }
        let changed: BTreeSet<String> = {
            let faults = lock(&self.faults);
            saves
                .iter()
                .map(|save| &save.name)
                .chain(&deletes)
                .filter(|name| faults.answers.contains_key(*name))
                .cloned()
                .collect()
        };
        // A record whose answer is replaced never reaches the zone.
        let saves = saves.into_iter().filter(|save| !changed.contains(&save.name)).collect();
        let deletes = deletes.into_iter().filter(|name| !changed.contains(name)).collect();
        let mut outcomes = self.inner.modify(account, saves, deletes).await?;
        let mut faults = lock(&self.faults);
        for name in changed {
            outcomes.extend(faults.answers.remove(&name));
        }
        outcomes.retain(|outcome| !faults.unanswered.remove(outcome.name()));
        Ok(outcomes)
    }
}
