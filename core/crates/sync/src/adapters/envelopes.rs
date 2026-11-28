// The personal `secret_envelope` kind (0044, Secrets; 0051, Kinds; 0056, Envelopes and history) over the device's own
// secret store. Each secret of a connection, SSH profile or credential profile that syncs goes up sealed for the
// destination its record names, and a pulled one lands in the device's store only while this device holds its record
// as the secret was sealed for; until then the engine holds it and offers it again on each pull. The copy the server
// and this device last agreed on is the record's base, so a secret that did not change reads as that copy and is not
// sealed again, unless the account's key moved on, which seals it again under the new version.

use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use serde_json::Value;
use sha2::{Digest, Sha256};
use tablepro_keys::encoding::Version;
use tablepro_keys::envelope::{EnvelopeId, ParentKind, SecretKind as SealedKind};
use tablepro_records::Kind;
use tablepro_records::envelope::{SecretKind, destination};
use tablepro_records::record_id::{parse_envelope_id, parse_uuid};
use tablepro_storage::ConnectionStore;
use uuid::Uuid;

use super::library::{DriverNames, LibraryAdapter, Provider};
use crate::api::adapter::{LocalChange, LocalRecord, LocalRecords, RecordAdapter, StoreStamp};
use crate::api::error::{AdapterError, SyncError};
use crate::api::ids::{KindName, ScopeName};
use crate::api::key_flows::KeyFlows;
use crate::api::secrets::{DeviceSecrets, SecretRef};
use crate::api::state::{Row, RowRange, Standing, StateStore, Table};

pub const SECRETS_STORE: &str = "secrets";

// The parents of 0056's personal envelope rows that a store on this device holds. A settings record's AI keys come
// with the host's settings, which no store here reads yet.
const PARENTS: [Kind; 3] = [Kind::Connection, Kind::SshProfile, Kind::CredentialProfile];

// The secrets each parent's envelopes can hold, besides a driver's own fields, which no store here keeps.
const SECRETS: [SecretKind; 5] = [
    SecretKind::Password,
    SecretKind::SslKeyPassphrase,
    SecretKind::SshPassword,
    SecretKind::SshKeyPassphrase,
    SecretKind::SshTotpSecret,
];

// The envelopes a journal pass reads: those it named, and each of the records it named, since a library write that
// saved a secret names the record the secret belongs to.
pub fn named(named: &HashMap<Kind, HashSet<String>>) -> HashSet<String> {
    let mut out = named.get(&Kind::SecretEnvelope).cloned().unwrap_or_default();
    for parent in PARENTS {
        for id in named.get(&parent).into_iter().flatten() {
            out.extend(
                SECRETS
                    .iter()
                    .filter(|secret| secret.belongs_to(parent))
                    .filter_map(|secret| envelope_of(parent, id, secret))
                    .map(|envelope| envelope.to_wire()),
            );
        }
    }
    out
}

// The device's secret store has no identity a restore would change, so nothing here puts the kind into refill.
const STAMP: StoreStamp = StoreStamp {
    generation: Uuid::nil(),
    sequence: 0,
};

// What a sealed copy holds, kept in memory only, so a copy is opened or sealed once per change and not on every pass.
#[derive(Debug, Clone)]
struct Known {
    sealed: Value,
    secret: [u8; 32],
    dest: Value,
    kv: Version,
}

impl Known {
    fn holds(&self, secret: &[u8; 32], dest: &Value, version: Option<Version>) -> bool {
        self.secret == *secret && self.dest == *dest && version.is_none_or(|version| self.kv >= version)
    }
}

pub struct EnvelopeAdapter {
    // Readers of the parents' records of their own, so a read here never moves what a parent's store last read.
    parents: Vec<Arc<dyn RecordAdapter>>,
    secrets: Arc<dyn DeviceSecrets>,
    keys: Arc<dyn KeyFlows>,
    state: Arc<dyn StateStore>,
    // Copies this device opened, as bases are, and copies it sealed that have not gone up yet.
    opened: Mutex<HashMap<String, Known>>,
    sealed: Mutex<HashMap<String, Known>>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn digest(secret: &SecretString) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(b"tablepro/v1/envelope-secret");
    hasher.update(secret.expose_secret().as_bytes());
    hasher.finalize().into()
}

fn unreadable(detail: &str) -> AdapterError {
    AdapterError::Unreadable {
        detail: detail.to_owned(),
    }
}

fn state_error(error: impl std::fmt::Display) -> AdapterError {
    AdapterError::Store {
        store: SECRETS_STORE.to_owned(),
        detail: error.to_string(),
    }
}

// The envelope id of a parent's secret, as 0052 names it.
fn envelope_of(parent: Kind, parent_id: &str, secret: &SecretKind) -> Option<EnvelopeId> {
    let parent_kind = match parent {
        Kind::Connection => ParentKind::Connection,
        Kind::SshProfile => ParentKind::SshProfile,
        Kind::CredentialProfile => ParentKind::CredentialProfile,
        _ => return None,
    };
    let secret = SealedKind::parse(&secret.to_string()).ok()?;
    EnvelopeId::new(parent_kind, parent_id, secret).ok()
}

impl EnvelopeAdapter {
    pub fn new(
        store: &ConnectionStore,
        names: DriverNames,
        publisher: Option<Uuid>,
        secrets: Arc<dyn DeviceSecrets>,
        keys: Arc<dyn KeyFlows>,
        state: Arc<dyn StateStore>,
    ) -> Self {
        let parents = LibraryAdapter::all(store, names, Provider::TableproSync, publisher)
            .into_iter()
            .filter(|adapter| PARENTS.contains(&adapter.kind()))
            .collect();
        Self::over(parents, secrets, keys, state)
    }

    pub fn over(
        parents: Vec<Arc<dyn RecordAdapter>>,
        secrets: Arc<dyn DeviceSecrets>,
        keys: Arc<dyn KeyFlows>,
        state: Arc<dyn StateStore>,
    ) -> Self {
        Self {
            parents,
            secrets,
            keys,
            state,
            opened: Mutex::default(),
            sealed: Mutex::default(),
        }
    }

    fn parent(&self, kind: Kind) -> Option<&Arc<dyn RecordAdapter>> {
        self.parents.iter().find(|adapter| adapter.kind() == kind)
    }

    fn keeps(&self, parent: Kind, secret: &SecretKind) -> bool {
        self.parent(parent).is_some() && self.secrets.kinds(parent).contains(secret)
    }

    // The live envelopes the server and this device last agreed on.
    async fn bases(&self) -> Result<HashMap<String, Value>, AdapterError> {
        let mut txn = self.state.begin().await.map_err(state_error)?;
        let rows = txn
            .scan(&RowRange::ScopeKind(
                Table::Bases,
                ScopeName::Personal,
                KindName::of(Kind::SecretEnvelope),
            ))
            .await
            .map_err(state_error)?;
        Ok(rows
            .into_iter()
            .filter_map(|row| match row {
                Row::Base(base) if base.deleted.is_none() => base.fields.map(|fields| (base.key.record_id, fields)),
                _ => None,
            })
            .collect())
    }

    // What `fields` holds, from memory or by opening it. A copy the keys will not open holds nothing this device can
    // compare, so the secret is sealed again.
    async fn known(&self, envelope: &EnvelopeId, record_id: &str, fields: &Value) -> Option<Known> {
        for cache in [&self.opened, &self.sealed] {
            if let Some(known) = lock(cache).get(record_id).filter(|known| known.sealed == *fields) {
                return Some(known.clone());
            }
        }
        match self
            .keys
            .open_personal_envelope(envelope.clone(), fields.clone(), None)
            .await
        {
            Ok(opened) => {
                let known = Known {
                    sealed: fields.clone(),
                    secret: digest(&opened.secret),
                    dest: opened.dest,
                    kv: opened.kv,
                };
                lock(&self.opened).insert(record_id.to_owned(), known.clone());
                Some(known)
            }
            Err(error) => {
                tracing::debug!(code = error.code(), "a held envelope did not open to compare");
                None
            }
        }
    }

    // The sealed copy that stands for `secret` sealed for `dest`: the base when it holds both under the version
    // written now, else a copy sealed here. None while this device cannot seal.
    async fn current(
        &self,
        envelope: &EnvelopeId,
        record_id: &str,
        secret: &SecretString,
        dest: &Value,
        base: Option<&Value>,
        version: Option<Version>,
    ) -> Option<Value> {
        let print = digest(secret);
        if let Some(base) = base
            && self
                .known(envelope, record_id, base)
                .await
                .is_some_and(|known| known.holds(&print, dest, version))
        {
            return Some(base.clone());
        }
        // Sealed once and kept until it goes up, so a pass that sends it again sends the same request.
        if let Some(known) = lock(&self.sealed)
            .get(record_id)
            .filter(|known| known.holds(&print, dest, version))
        {
            return Some(known.sealed.clone());
        }
        let version = version?;
        match self
            .keys
            .seal_personal_envelope(envelope.clone(), secret.clone(), dest.clone())
            .await
        {
            Ok(sealed) => {
                let kv = sealed
                    .get("kv")
                    .and_then(Value::as_u64)
                    .and_then(|kv| u32::try_from(kv).ok())
                    .and_then(|kv| Version::new(kv).ok())
                    .unwrap_or(version);
                lock(&self.sealed).insert(
                    record_id.to_owned(),
                    Known {
                        sealed: sealed.clone(),
                        secret: print,
                        dest: dest.clone(),
                        kv,
                    },
                );
                Some(sealed)
            }
            Err(error) => {
                tracing::debug!(code = error.code(), "a secret waits for keys that seal it");
                None
            }
        }
    }

    fn forget(&self, record_id: &str) {
        lock(&self.opened).remove(record_id);
        lock(&self.sealed).remove(record_id);
    }

    // The parent's fields and standing as this device's store holds them now.
    async fn parent_record(
        &self,
        parent: Kind,
        parent_id: &str,
        read: &mut HashMap<Kind, LocalRecords>,
    ) -> Result<Option<LocalRecord>, AdapterError> {
        let Some(adapter) = self.parent(parent) else {
            return Ok(None);
        };
        if let Entry::Vacant(slot) = read.entry(parent) {
            slot.insert(adapter.records(ScopeName::Personal).await?);
        }
        Ok(read.get(&parent).and_then(|records| {
            records
                .records
                .iter()
                .find(|record| record.record_id == parent_id)
                .cloned()
        }))
    }

    // A pulled envelope lands only on the record it was sealed for, as this device holds it: a destination changed
    // since, by the person here or by a pull that waits for them, is the approval case 0044 requires (0056, At use).
    async fn take(
        &self,
        record_id: &str,
        fields: &Value,
        read: &mut HashMap<Kind, LocalRecords>,
    ) -> Result<(), AdapterError> {
        let Some((parent, parent_id, secret)) = parse_envelope_id(record_id) else {
            return Err(unreadable("an envelope id this build does not read"));
        };
        let (Some(id), Some(envelope)) = (parse_uuid(parent_id), envelope_of(parent, parent_id, &secret)) else {
            return Err(unreadable("an envelope of a record no store here holds"));
        };
        if !self.keeps(parent, &secret) {
            return Err(unreadable("a secret this device does not keep"));
        }
        let Some(record) = self.parent_record(parent, parent_id, read).await? else {
            return Err(unreadable("the envelope's record is not on this device"));
        };
        // A record this device keeps to itself takes nothing a pull brings (0054, Rules for both providers).
        if record.standing == Standing::LocalOnly {
            return Ok(());
        }
        if record.standing != Standing::Syncs {
            return Err(unreadable("the envelope's record has no standing yet"));
        }
        let opened = self
            .keys
            .open_personal_envelope(envelope, fields.clone(), None)
            .await
            .map_err(|error: SyncError| unreadable(error.code()))?;
        if destination(parent, &secret, &record.fields) != opened.dest {
            return Err(unreadable("the record points elsewhere than the secret was sealed for"));
        }
        let reference = SecretRef {
            parent,
            parent_id: id,
            secret,
        };
        self.secrets
            .store(&reference, &opened.secret)
            .await
            .map_err(|error| unreadable(error.code()))?;
        lock(&self.sealed).remove(record_id);
        lock(&self.opened).insert(
            record_id.to_owned(),
            Known {
                sealed: fields.clone(),
                secret: digest(&opened.secret),
                dest: opened.dest,
                kv: opened.kv,
            },
        );
        Ok(())
    }

    // The person removed the secret on another device, or its record.
    async fn remove(&self, record_id: &str) -> Result<(), AdapterError> {
        self.forget(record_id);
        let Some((parent, parent_id, secret)) = parse_envelope_id(record_id) else {
            return Ok(());
        };
        let Some(id) = parse_uuid(parent_id).filter(|_| self.keeps(parent, &secret)) else {
            return Ok(());
        };
        let reference = SecretRef {
            parent,
            parent_id: id,
            secret,
        };
        self.secrets
            .delete(&reference)
            .await
            .map_err(|error| unreadable(error.code()))
    }
}

// The records each parent store holds, by id, and the ids it cannot read.
#[derive(Default)]
struct Parents {
    held: HashSet<(Kind, String)>,
    unreadable: HashSet<(Kind, String)>,
}

#[async_trait]
impl RecordAdapter for EnvelopeAdapter {
    fn kind(&self) -> Kind {
        Kind::SecretEnvelope
    }

    fn store(&self) -> &str {
        SECRETS_STORE
    }

    // A refill would let the server's copy win over a secret this device holds, as no move of personal data does
    // (0054, Moving between providers), and would hold a refused envelope as a refill's, never as one waiting for its
    // record (0076).
    fn refills(&self) -> bool {
        false
    }

    // A team's envelopes are its library's secrets, which this store does not keep.
    fn serves(&self, scope: ScopeName) -> bool {
        scope == ScopeName::Personal
    }

    async fn identity(&self) -> Result<StoreStamp, AdapterError> {
        Ok(STAMP)
    }

    async fn records(&self, scope: ScopeName) -> Result<LocalRecords, AdapterError> {
        let mut out = LocalRecords::default();
        if scope != ScopeName::Personal {
            return Ok(out);
        }
        // Each record and its secrets as one save left them, never a destination from before it and a secret after.
        let _held = self.secrets.hold().await;
        let bases = self.bases().await?;
        let version = self.keys.personal_envelope_version().await.unwrap_or_else(|error| {
            tracing::debug!(code = error.code(), "no version to seal personal secrets under");
            None
        });
        let mut parents = Parents::default();
        let mut listed: HashSet<String> = HashSet::new();
        for adapter in &self.parents {
            let parent = adapter.kind();
            let kinds = self.secrets.kinds(parent);
            let local = adapter.records(scope).await?;
            parents
                .unreadable
                .extend(local.unreadable.iter().map(|id| (parent, id.clone())));
            for record in local.records {
                parents.held.insert((parent, record.record_id.clone()));
                let Some(parent_id) = parse_uuid(&record.record_id) else {
                    continue;
                };
                for secret in &kinds {
                    let Some(envelope) = envelope_of(parent, &record.record_id, secret) else {
                        continue;
                    };
                    let record_id = envelope.to_wire();
                    let base = bases.get(&record_id);
                    listed.insert(record_id.clone());
                    // A record that stays on the device keeps its envelope where it is: neither sent nor deleted.
                    if record.standing != Standing::Syncs {
                        if let Some(base) = base {
                            out.records.push(LocalRecord {
                                record_id,
                                fields: base.clone(),
                                standing: record.standing,
                            });
                        }
                        continue;
                    }
                    let reference = SecretRef {
                        parent,
                        parent_id,
                        secret: secret.clone(),
                    };
                    let held = match self.secrets.load(&reference).await {
                        Ok(held) => held,
                        // A secret the store cannot read now is no deletion.
                        Err(error) => {
                            tracing::warn!(code = error.code(), "a secret could not be read to sync");
                            if base.is_some() {
                                out.unreadable.push(record_id);
                            }
                            continue;
                        }
                    };
                    let Some(held) = held else {
                        // Removed here: its envelope goes, as the diff reads a base with no record.
                        listed.remove(&record_id);
                        continue;
                    };
                    let dest = destination(parent, secret, &record.fields);
                    match self.current(&envelope, &record_id, &held, &dest, base, version).await {
                        Some(fields) => out.records.push(LocalRecord {
                            record_id,
                            fields,
                            standing: Standing::Syncs,
                        }),
                        None => out.unreadable.push(record_id),
                    }
                }
            }
        }
        for record_id in bases.keys().filter(|record_id| !listed.contains(*record_id)) {
            if !gone(self, &parents, record_id) {
                out.unreadable.push(record_id.clone());
            }
        }
        out.unreadable.sort();
        out.records.sort_by(|a, b| a.record_id.cmp(&b.record_id));
        Ok(out)
    }

    async fn apply(&self, scope: ScopeName, changes: Vec<LocalChange>) -> Result<StoreStamp, AdapterError> {
        if scope != ScopeName::Personal {
            return Err(unreadable("an envelope outside the personal scope"));
        }
        // A record a save changes between the check and the write would take a secret sealed for where it pointed.
        let _held = self.secrets.hold().await;
        let mut read = HashMap::new();
        for change in changes {
            match change {
                LocalChange::Put { record_id, fields } => self.take(&record_id, &fields, &mut read).await?,
                LocalChange::Delete { record_id } => self.remove(&record_id).await?,
            }
        }
        Ok(STAMP)
    }

    async fn tombstones_pushed(&self, _scope: ScopeName, _record_ids: Vec<String>) -> Result<(), AdapterError> {
        Ok(())
    }
}

// Whether a base the parents' secrets did not list stands for a secret removed here: its record is gone, or the
// record is here and the device keeps that secret kind but no longer holds it. A kind this device does not keep, a
// record it cannot read and an id it does not read are sent back unchanged, never deleted.
fn gone(adapter: &EnvelopeAdapter, parents: &Parents, record_id: &str) -> bool {
    let Some((parent, parent_id, secret)) = parse_envelope_id(record_id) else {
        return false;
    };
    let key = (parent, parent_id.to_owned());
    if adapter.parent(parent).is_none() || parents.unreadable.contains(&key) {
        return false;
    }
    !parents.held.contains(&key) || adapter.keeps(parent, &secret)
}
