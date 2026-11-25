// A CloudKit private database as 0054 describes it, one zone per iCloud account: saves guarded by system fields as
// `.ifServerRecordUnchanged` does, `serverRecordChanged` with the server's copy, `unknownItem`, deletions without a
// change tag, change tokens that page and expire, `limitExceeded`, a zone the person removed, and an account switch
// that saves nothing to either account.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use tablepro_sync::api::cloudkit::{
    CloudKitAccount, CloudKitChanges, CloudKitDeletion, CloudKitFailure, CloudKitFetched, CloudKitField,
    CloudKitOutcome, CloudKitRecord, CloudKitTransport, CloudKitValue,
};
use uuid::Uuid;

#[derive(Debug, Clone)]
struct Stored {
    record_type: String,
    fields: BTreeMap<String, CloudKitValue>,
    system_fields: Vec<u8>,
    change: u64,
}

#[derive(Debug, Default)]
struct Zone {
    records: BTreeMap<String, Stored>,
    deletions: Vec<(u64, CloudKitDeletion)>,
    next_change: u64,
    // Tokens below it have expired.
    token_floor: u64,
}

#[derive(Debug)]
struct State {
    signed_in: Option<String>,
    zones: HashMap<String, Zone>,
    removed_by_user: HashMap<String, bool>,
    fail_next: Vec<CloudKitFailure>,
    // The account the device switches to while the next call runs.
    switch_mid_call: Option<Option<String>>,
    failing_records: HashMap<String, i64>,
    page_size: usize,
    max_batch: usize,
    max_batch_bytes: usize,
}

#[derive(Debug)]
pub struct FakeCloudKit {
    state: Mutex<State>,
}

impl FakeCloudKit {
    pub fn signed_in(user_record_name: &str) -> Self {
        Self {
            state: Mutex::new(State {
                signed_in: Some(user_record_name.to_owned()),
                zones: HashMap::new(),
                removed_by_user: HashMap::new(),
                fail_next: Vec::new(),
                switch_mid_call: None,
                failing_records: HashMap::new(),
                page_size: 200,
                max_batch: 400,
                max_batch_bytes: 2 << 20,
            }),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    // `CKAccountChanged`: another user, or none.
    pub fn switch_account(&self, user_record_name: Option<&str>) {
        self.lock().signed_in = user_record_name.map(str::to_owned);
    }

    // The account changes after the next call's first check and before CloudKit receives it.
    pub fn switch_account_during_next_call(&self, user_record_name: Option<&str>) {
        self.lock().switch_mid_call = Some(user_record_name.map(str::to_owned));
    }

    pub fn fail_next(&self, failure: CloudKitFailure) {
        self.lock().fail_next.push(failure);
    }

    // The next save or deletion of `name` fails with `code`, once.
    pub fn fail_record(&self, name: &str, code: i64) {
        self.lock().failing_records.insert(name.to_owned(), code);
    }

    // Every token the zone gave so far now answers `TokenExpired`.
    pub fn expire_tokens(&self, account: &str) {
        if let Some(zone) = self.lock().zones.get_mut(account) {
            zone.token_floor = zone.next_change + 1;
        }
    }

    // The person deleted the zone in Settings: calls answer `ZoneDeletedByUser` until it is made again.
    pub fn remove_zone_by_user(&self, account: &str) {
        let mut state = self.lock();
        state.zones.remove(account);
        state.removed_by_user.insert(account.to_owned(), true);
    }

    pub fn set_limits(&self, page_size: usize, max_batch: usize, max_batch_bytes: usize) {
        let mut state = self.lock();
        state.page_size = page_size.max(1);
        state.max_batch = max_batch;
        state.max_batch_bytes = max_batch_bytes;
    }

    // Another device's save, outside this device's calls.
    pub fn save_elsewhere(&self, account: &str, record_type: &str, name: &str, fields: Vec<CloudKitField>) {
        let mut state = self.lock();
        let zone = state.zones.entry(account.to_owned()).or_default();
        let mut stored = zone.records.get(name).cloned().unwrap_or_else(|| Stored {
            record_type: record_type.to_owned(),
            fields: BTreeMap::new(),
            system_fields: Vec::new(),
            change: 0,
        });
        set_fields(&mut stored.fields, fields);
        zone.next_change += 1;
        stored.change = zone.next_change;
        stored.system_fields = new_system_fields();
        zone.records.insert(name.to_owned(), stored);
    }

    pub fn delete_elsewhere(&self, account: &str, name: &str) {
        let mut state = self.lock();
        if let Some(zone) = state.zones.get_mut(account) {
            delete(zone, name);
        }
    }

    pub fn record(&self, account: &str, name: &str) -> Option<CloudKitRecord> {
        self.lock()
            .zones
            .get(account)
            .and_then(|zone| zone.records.get(name).map(|stored| record(name, stored)))
    }

    pub fn record_names(&self, account: &str) -> Vec<String> {
        self.lock()
            .zones
            .get(account)
            .map_or_else(Vec::new, |zone| zone.records.keys().cloned().collect())
    }

    // The checks before an operation; the second element is the check after it.
    fn begin(&self, account: &str) -> Result<MutexGuard<'_, State>, CloudKitFailure> {
        let mut state = self.lock();
        if !state.fail_next.is_empty() {
            return Err(state.fail_next.remove(0));
        }
        let signed_in = state.signed_in.clone().ok_or(CloudKitFailure::NoAccount)?;
        if signed_in != account {
            return Err(CloudKitFailure::AccountChanged);
        }
        if let Some(next) = state.switch_mid_call.take() {
            state.signed_in = next;
            return Err(CloudKitFailure::AccountChanged);
        }
        Ok(state)
    }
}

fn new_system_fields() -> Vec<u8> {
    Uuid::new_v4().as_bytes().to_vec()
}

fn set_fields(target: &mut BTreeMap<String, CloudKitValue>, fields: Vec<CloudKitField>) {
    for field in fields {
        match field.value {
            Some(value) => {
                target.insert(field.name, value);
            }
            None => {
                target.remove(&field.name);
            }
        }
    }
}

fn record(name: &str, stored: &Stored) -> CloudKitRecord {
    CloudKitRecord {
        record_type: stored.record_type.clone(),
        name: name.to_owned(),
        system_fields: Some(stored.system_fields.clone()),
        fields: stored
            .fields
            .iter()
            .map(|(name, value)| CloudKitField {
                name: name.clone(),
                value: Some(value.clone()),
            })
            .collect(),
    }
}

fn delete(zone: &mut Zone, name: &str) {
    if let Some(stored) = zone.records.remove(name) {
        zone.next_change += 1;
        let deletion = CloudKitDeletion {
            name: name.to_owned(),
            record_type: stored.record_type,
        };
        zone.deletions.push((zone.next_change, deletion));
    }
}

fn value_bytes(value: &CloudKitValue) -> usize {
    match value {
        CloudKitValue::Text(text) => text.len(),
        CloudKitValue::Int64(_) | CloudKitValue::Double(_) | CloudKitValue::Timestamp(_) => 8,
        CloudKitValue::Bytes(bytes) => bytes.len(),
        CloudKitValue::TextList(list) => list.iter().map(String::len).sum(),
    }
}

fn token(change: u64) -> Vec<u8> {
    change.to_be_bytes().to_vec()
}

fn read_token(token: &[u8]) -> Result<u64, CloudKitFailure> {
    let bytes: [u8; 8] = token.try_into().map_err(|_| CloudKitFailure::TokenExpired)?;
    Ok(u64::from_be_bytes(bytes))
}

fn zone<'a>(state: &'a mut State, account: &str) -> Result<&'a mut Zone, CloudKitFailure> {
    if state.zones.contains_key(account) {
        return state.zones.get_mut(account).ok_or(CloudKitFailure::ZoneNotFound);
    }
    if state.removed_by_user.get(account).copied().unwrap_or(false) {
        Err(CloudKitFailure::ZoneDeletedByUser)
    } else {
        Err(CloudKitFailure::ZoneNotFound)
    }
}

fn save(zone: &mut Zone, save: CloudKitRecord) -> CloudKitOutcome {
    let current = zone.records.get(&save.name).cloned();
    match (&save.system_fields, current) {
        (None, Some(current)) | (Some(_), Some(current))
            if save.system_fields.as_ref() != Some(&current.system_fields) =>
        {
            CloudKitOutcome::ServerChanged {
                server: Some(record(&save.name, &current)),
                name: save.name,
            }
        }
        (Some(_), None) => CloudKitOutcome::UnknownItem { name: save.name },
        (_, current) => {
            let mut stored = current.unwrap_or_else(|| Stored {
                record_type: save.record_type.clone(),
                fields: BTreeMap::new(),
                system_fields: Vec::new(),
                change: 0,
            });
            set_fields(&mut stored.fields, save.fields);
            zone.next_change += 1;
            stored.change = zone.next_change;
            stored.system_fields = new_system_fields();
            let system_fields = stored.system_fields.clone();
            zone.records.insert(save.name.clone(), stored);
            CloudKitOutcome::Saved {
                name: save.name,
                system_fields,
            }
        }
    }
}

#[async_trait]
impl CloudKitTransport for FakeCloudKit {
    async fn account_status(&self) -> Result<CloudKitAccount, CloudKitFailure> {
        let mut state = self.lock();
        if !state.fail_next.is_empty() {
            return Err(state.fail_next.remove(0));
        }
        let user_record_name = state.signed_in.clone().ok_or(CloudKitFailure::NoAccount)?;
        Ok(CloudKitAccount { user_record_name })
    }

    async fn ensure_zone(&self, account: String) -> Result<(), CloudKitFailure> {
        let mut state = self.begin(&account)?;
        state.removed_by_user.remove(&account);
        state.zones.entry(account).or_default();
        Ok(())
    }

    async fn delete_zone(&self, account: String) -> Result<(), CloudKitFailure> {
        let mut state = self.begin(&account)?;
        state.zones.remove(&account);
        Ok(())
    }

    async fn fetch_changes(&self, account: String, token: Option<Vec<u8>>) -> Result<CloudKitChanges, CloudKitFailure> {
        let mut state = self.begin(&account)?;
        let page_size = state.page_size;
        let zone = zone(&mut state, &account)?;
        let since = token.as_deref().map(read_token).transpose()?.unwrap_or(0);
        if token.is_some() && since < zone.token_floor {
            return Err(CloudKitFailure::TokenExpired);
        }
        // Each change at most once, in the order the zone took them.
        let mut events: Vec<(u64, Option<&str>, Option<&CloudKitDeletion>)> = zone
            .records
            .iter()
            .filter(|(_, stored)| stored.change > since)
            .map(|(name, stored)| (stored.change, Some(name.as_str()), None))
            .collect();
        if token.is_some() {
            events.extend(
                zone.deletions
                    .iter()
                    .filter(|(change, deletion)| *change > since && !zone.records.contains_key(&deletion.name))
                    .map(|(change, deletion)| (*change, None, Some(deletion))),
            );
        }
        events.sort_by_key(|(change, ..)| *change);
        let more = events.len() > page_size;
        events.truncate(page_size);
        let last = events
            .last()
            .map_or(zone.next_change.max(since), |(change, ..)| *change);
        let changed = events
            .iter()
            .filter_map(|(_, name, _)| name.and_then(|name| zone.records.get(name).map(|stored| record(name, stored))))
            .collect();
        let deleted = events
            .iter()
            .filter_map(|(.., deletion)| (*deletion).cloned())
            .collect();
        Ok(CloudKitChanges {
            changed,
            deleted,
            unfetched: Vec::new(),
            token: self::token(if more { last } else { zone.next_change.max(since) }),
            more,
        })
    }

    async fn fetch_records(
        &self,
        account: String,
        names: Vec<String>,
    ) -> Result<Vec<CloudKitFetched>, CloudKitFailure> {
        let mut state = self.begin(&account)?;
        let zone = zone(&mut state, &account)?;
        Ok(names
            .into_iter()
            .map(|name| match zone.records.get(&name) {
                Some(stored) => CloudKitFetched::Found {
                    record: record(&name, stored),
                },
                None => CloudKitFetched::Missing { name },
            })
            .collect())
    }

    async fn modify(
        &self,
        account: String,
        saves: Vec<CloudKitRecord>,
        deletes: Vec<String>,
    ) -> Result<Vec<CloudKitOutcome>, CloudKitFailure> {
        let mut state = self.begin(&account)?;
        let bytes: usize = saves
            .iter()
            .flat_map(|save| save.fields.iter())
            .map(|field| field.name.len() + field.value.as_ref().map_or(0, value_bytes))
            .sum();
        if saves.len() + deletes.len() > state.max_batch || bytes > state.max_batch_bytes {
            return Err(CloudKitFailure::LimitExceeded);
        }
        let mut failing = std::mem::take(&mut state.failing_records);
        let zone = zone(&mut state, &account)?;
        let mut outcomes = Vec::with_capacity(saves.len() + deletes.len());
        for record in saves {
            outcomes.push(match failing.remove(&record.name) {
                Some(code) => CloudKitOutcome::Failed {
                    name: record.name,
                    code,
                    retry_after_ms: None,
                },
                None => save(zone, record),
            });
        }
        for name in deletes {
            outcomes.push(match failing.remove(&name) {
                Some(code) => CloudKitOutcome::Failed {
                    name,
                    code,
                    retry_after_ms: None,
                },
                None => {
                    delete(zone, &name);
                    CloudKitOutcome::Deleted { name }
                }
            });
        }
        state.failing_records = failing;
        Ok(outcomes)
    }
}

#[cfg(test)]
mod tests;
