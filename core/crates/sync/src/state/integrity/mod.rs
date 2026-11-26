// The state file's integrity and freshness (0054, Integrity and freshness). Every commit raises the counter and seals
// the file with the state MAC over the key digest and the sync digest; the anchor in the device store, written in two
// steps around the commit, tells the latest file from a restored copy. An open compares the file with its anchor:
// a stale file refills its sync tables and rebuilds its key tables from the anchored checkpoint, and a file with no
// anchor handles no secret until it is approved again. What an open finds stays owed in the anchor until a key flow
// settles it, so a restart cannot launder it.

mod anchor;
mod digest;
mod rebuild;

pub use digest::{key_digest, sync_digest};
pub use rebuild::{Reading, rebuild_shown};

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use aws_lc_rs::{constant_time, hmac};
use sqlx::{AssertSqlSafe, Sqlite, Transaction};
use tablepro_keys::encoding::{AccountId, Label, Origin, SUITE};
use tablepro_keys::state_mac::{StateSnapshot, state_mac};
use tokio::sync::Mutex as AsyncMutex;
use zeroize::Zeroizing;

use self::anchor::{
    CHECKPOINT_TABLES, CheckpointRef, Entry, Items, Owed, PART_BYTES, Root, RootItem, checkpoint_bytes,
    checkpoint_ref_of, unsettled,
};
use super::codec;
use super::file::{read, sql, write};
use super::name::state_name;
use crate::api::device_store::{DeviceStoreError, HostDeviceStore};
use crate::api::error::StateError;
use crate::api::ids::{FileId, ScopeName, StateName};
use crate::api::state::{
    BindingRow, Checkpoint, Committed, KeyTrust, KeysSettled, Opened, Provider, Row, RowKey, StateIdentity, SyncTrust,
    Table,
};

// Whom the MAC binds the file to.
enum Party {
    Service { origin: Origin, account: AccountId },
    ICloud { user: String },
}

impl Party {
    fn of(identity: &StateIdentity) -> Self {
        match identity {
            StateIdentity::Service { origin, account, .. } => Self::Service {
                origin: origin.clone(),
                account: *account,
            },
            StateIdentity::ICloud { user_record_name } => Self::ICloud {
                user: user_record_name.clone(),
            },
        }
    }

    const fn provider(&self) -> Provider {
        match self {
            Self::Service { .. } => Provider::Service,
            Self::ICloud { .. } => Provider::ICloud,
        }
    }

    fn mac(
        &self,
        key: &Zeroizing<[u8; 32]>,
        file_id: &FileId,
        counter: u64,
        key_digest: &[u8; 32],
        sync_digest: &[u8; 32],
    ) -> Result<[u8; 32], StateError> {
        match self {
            Self::Service { origin, account } => {
                let snapshot = StateSnapshot {
                    file_id: &file_id.0,
                    counter,
                    key_digest,
                    sync_digest,
                };
                state_mac(key, origin, *account, snapshot).map_err(|error| StateError::Io {
                    detail: error.to_string(),
                })
            }
            // 0054 frames the origin and the account; an iCloud file has no server, so its origin is empty and its
            // account the iCloud user record name.
            Self::ICloud { user } => {
                let mut input = Vec::new();
                let counter = counter.to_be_bytes();
                for part in [
                    Label::State.as_str().as_bytes(),
                    SUITE.as_bytes(),
                    b"",
                    user.as_bytes(),
                    &file_id.0,
                    &counter,
                    key_digest,
                    sync_digest,
                ] {
                    lp(&mut input, part);
                }
                let tag = hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, key.as_slice()), &input);
                <[u8; 32]>::try_from(tag.as_ref()).map_err(|_| StateError::Integrity)
            }
        }
    }
}

fn lp(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&u32::try_from(bytes.len()).unwrap_or(u32::MAX).to_be_bytes());
    out.extend_from_slice(bytes);
}

// The MAC column of a file no device store ever sealed. A real MAC is all zeros with probability 2^-256.
const UNSEALED: [u8; 32] = [0; 32];

// What one commit settles of the distrust an open found (0054, A stale file). It takes effect only with that commit's
// second step, so a commit that never lands settles nothing.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Settles {
    rebuilt: bool,
    reapproved: bool,
    // Sign Out cleared the key tables: the device joins again as a new device would.
    cleared: bool,
}

impl Settles {
    pub(crate) fn add(&mut self, settled: KeysSettled) {
        match settled {
            KeysSettled::Rebuilt => self.rebuilt = true,
            KeysSettled::Reapproved => self.reapproved = true,
        }
    }

    pub(crate) fn clear(&mut self) {
        self.cleared = true;
    }

    fn apply(self, owed: Owed) -> Owed {
        match owed {
            _ if self.cleared => Owed::Trusted,
            Owed::Rebuild(_) if self.rebuilt => Owed::Trusted,
            Owed::Unanchored if self.reapproved => Owed::Trusted,
            owed => owed,
        }
    }
}

// What the last settled commit left: its key digest and checkpoint, which a commit that leaves the key tables alone
// keeps, the anchor's root as this process last stored it, and what the pending entry's commit settles.
struct Anchor {
    root: Option<Root>,
    key_digest: [u8; 32],
    checkpoint: CheckpointRef,
    pending_settles: Settles,
}

// One open file's seal. Without a device store nothing can be sealed or anchored: the file then holds no key it could
// protect and syncs team plaintext records only (0056, Device stores).
pub(crate) struct Seal {
    store: Arc<dyn HostDeviceStore>,
    name: StateName,
    party: Party,
    key: Option<Zeroizing<[u8; 32]>>,
    // A key made for a file whose key was gone goes into the device store only once the file it seals landed, so a
    // crash before leaves a file whose key is gone again, never one sealed under a key the file does not match.
    key_unstored: AtomicBool,
    part_bytes: usize,
    anchor: AsyncMutex<Anchor>,
}

impl std::fmt::Debug for Seal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Seal")
            .field("name", &self.name)
            .field("sealed", &self.key.is_some())
            .finish_non_exhaustive()
    }
}

impl Seal {
    fn items(&self) -> Items<'_> {
        Items {
            store: self.store.as_ref(),
            name: &self.name,
        }
    }

    pub(crate) const fn provider(&self) -> Provider {
        self.party.provider()
    }
}

// What a commit changed beyond its rows.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct Written {
    // A key table changed, so the key digest and the checkpoint are computed again.
    pub(crate) key_tables: bool,
    pub(crate) settles: Settles,
}

// The binding an open found or made, and whether the file is new.
pub(crate) struct Bound {
    pub(crate) binding: BindingRow,
    pub(crate) new_file: bool,
}

// What comparing the file with its anchor found (0054, On open).
enum Found {
    // The file is the latest. `pending` when it matches the pending entry, whose second step a crash cut off.
    Fresh { pending: bool },
    // Restored, replaced or uncertain: its sync tables refill, and its key tables are owed as this says.
    Restored { keys: Owed },
}

fn found(binding: &BindingRow, root: &RootItem) -> Found {
    let stale = |root: &Root| Found::Restored {
        keys: root.newest().map_or(Owed::Unanchored, Owed::Rebuild),
    };
    let RootItem::Held(root) = root else {
        return Found::Restored { keys: Owed::Unanchored };
    };
    if root.file_id != binding.file_id {
        return stale(root);
    }
    let at = |entry: &Entry| entry.counter == binding.counter && entry.mac == binding.state_mac;
    match (root.current, root.pending) {
        (_, Some(pending)) if at(&pending) => Found::Fresh { pending: true },
        (Some(current), None) if at(&current) => Found::Fresh { pending: false },
        // A commit that never landed, or one that landed and a restore of the copy before it.
        (Some(current), Some(pending)) if at(&current) => Found::Restored {
            keys: if pending.key_digest == current.key_digest {
                Owed::Trusted
            } else {
                Owed::Rebuild(pending.checkpoint)
            },
        },
        _ => stale(root),
    }
}

async fn holds_key_rows(tx: &mut Transaction<'static, Sqlite>) -> Result<bool, StateError> {
    for table in Table::KEY {
        let statement = format!("SELECT EXISTS (SELECT 1 FROM {})", table.name());
        let held: bool = sqlx::query_scalar(AssertSqlSafe(statement))
            .fetch_one(&mut **tx)
            .await
            .map_err(sql)?;
        if held {
            return Ok(true);
        }
    }
    Ok(false)
}

async fn checkpoint_in(tx: &mut Transaction<'static, Sqlite>) -> Result<Checkpoint, StateError> {
    let mut checkpoint = Checkpoint::default();
    for table in CHECKPOINT_TABLES {
        for (key, columns) in digest::read_table(tx, table).await? {
            match codec::decode(table, &key, &columns)? {
                Row::KeyPin(row) => checkpoint.pins.push(row),
                Row::KeyVersion(row) => checkpoint.versions.push(row),
                Row::KeyEnvelope(row) => checkpoint.envelopes.push(row),
                _ => return Err(StateError::Integrity),
            }
        }
    }
    Ok(checkpoint)
}

fn random_key() -> Result<Zeroizing<[u8; 32]>, StateError> {
    let mut key = Zeroizing::new([0_u8; 32]);
    aws_lc_rs::rand::fill(key.as_mut_slice()).map_err(|_| StateError::Io {
        detail: "the system random generator failed".to_owned(),
    })?;
    Ok(key)
}

// A stale file's sync tables refill as a restored store does (0054, A stale file), in the open's own commit so a crash
// cannot lose it. On the service every store refills while it has no `stores` row, and every scope pulls a snapshot
// again, which brings back the key objects a rebuild starts without. An iCloud file refills whole while its zone's
// scope row says so.
async fn refill(tx: &mut Transaction<'static, Sqlite>, provider: Provider) -> Result<(), StateError> {
    match provider {
        Provider::Service => {
            sqlx::query("DELETE FROM stores")
                .execute(&mut **tx)
                .await
                .map_err(sql)?;
            for (key, columns) in digest::read_table(tx, Table::Scopes).await? {
                if let Row::Scope(mut scope) = codec::decode(Table::Scopes, &key, &columns)? {
                    scope.cursor = None;
                    scope.key_version = None;
                    write(tx, &Row::Scope(scope)).await?;
                }
            }
        }
        Provider::ICloud => {
            if let Some(Row::Scope(mut scope)) = read(tx, &RowKey::Scope(ScopeName::Personal)).await? {
                scope.refill = true;
                write(tx, &Row::Scope(scope)).await?;
            }
        }
    }
    Ok(())
}

// The key tables of a stale file go, and the anchored checkpoint stands in for them: the pins, versions and envelopes
// the rebuild accepts only at or above (0054, A stale file). The rest stays in the file alone and is lost with it.
async fn install(tx: &mut Transaction<'static, Sqlite>, checkpoint: &Checkpoint) -> Result<(), StateError> {
    for table in Table::KEY {
        let statement = format!("DELETE FROM {}", table.name());
        sqlx::query(AssertSqlSafe(statement))
            .execute(&mut **tx)
            .await
            .map_err(sql)?;
    }
    let rows = checkpoint
        .pins
        .iter()
        .cloned()
        .map(Row::KeyPin)
        .chain(checkpoint.versions.iter().cloned().map(Row::KeyVersion))
        .chain(checkpoint.envelopes.iter().cloned().map(Row::KeyEnvelope));
    for row in rows {
        write(tx, &row).await?;
    }
    Ok(())
}

// A file no device store sealed, met by a device that holds its MAC key: nothing proves any of it, so none of it is
// kept and the file starts again as a new one would, with a new file id. A local writer gets no further than by
// deleting the file.
async fn start_over(tx: &mut Transaction<'static, Sqlite>, binding: &BindingRow) -> Result<BindingRow, StateError> {
    for table in Table::SYNC.into_iter().chain(Table::KEY) {
        let statement = format!("DELETE FROM {}", table.name());
        sqlx::query(AssertSqlSafe(statement))
            .execute(&mut **tx)
            .await
            .map_err(sql)?;
    }
    let fresh = BindingRow {
        file_id: FileId(*uuid::Uuid::new_v4().as_bytes()),
        counter: 0,
        state_mac: UNSEALED,
        ..binding.clone()
    };
    write(tx, &Row::Binding(fresh.clone())).await?;
    Ok(fresh)
}

pub(crate) async fn open(
    mut tx: Transaction<'static, Sqlite>,
    identity: &StateIdentity,
    bound: Bound,
    store: Arc<dyn HostDeviceStore>,
) -> Result<(Arc<Seal>, Opened), StateError> {
    let party = Party::of(identity);
    if party.provider() == Provider::ICloud && holds_key_rows(&mut tx).await? {
        return Err(StateError::Integrity);
    }
    let name = state_name(identity);
    let items = Items {
        store: store.as_ref(),
        name: &name,
    };
    let loaded = match items.mac_key().await {
        Ok(key) => items.root().await.map(|root| (key, root)),
        Err(error) => Err(error),
    };
    let (key, root) = match loaded {
        Ok(loaded) => loaded,
        // A file no store ever sealed goes on unsealed; a sealed one waits for its store to come back, since commits
        // it could not seal would leave it unable to verify once the store is back.
        Err(DeviceStoreError::Unavailable { .. }) if bound.new_file || bound.binding.state_mac == UNSEALED => {
            return unsealed(tx, bound, store, name, party).await;
        }
        Err(error) => return Err(unsettled(&error)),
    };
    let Bound {
        mut binding,
        mut new_file,
    } = bound;
    if !new_file && key.is_some() && binding.state_mac == UNSEALED {
        binding = start_over(&mut tx, &binding).await?;
        new_file = true;
    }
    let key_digest = digest::key_digest_in(&mut tx, party.provider()).await?;
    let checkpoint = checkpoint_ref_of(&checkpoint_bytes(&checkpoint_in(&mut tx).await?), PART_BYTES);
    let checked = Checked {
        party: &party,
        binding: &binding,
        new_file,
        key_digest,
    };
    let found = checked.find(&mut tx, key.as_ref(), &root).await?;
    // A new file writes its MAC key before its anchor (0054, A new file writes its anchor first): the file exists only
    // once that commit lands. An existing file whose key is gone gets its new key once the commit sealing it landed.
    let (key, key_unstored) = match key {
        Some(key) => (key, false),
        None => {
            let key = random_key()?;
            if new_file {
                items.put_mac_key(&key).await.map_err(|error| unsettled(&error))?;
            }
            (key, !new_file)
        }
    };
    let root = match root {
        RootItem::Held(root) => Some(*root),
        RootItem::Absent | RootItem::Malformed => None,
    };
    let seal = Arc::new(Seal {
        store,
        name,
        party,
        key: Some(key),
        key_unstored: AtomicBool::new(key_unstored),
        part_bytes: PART_BYTES,
        anchor: AsyncMutex::new(Anchor {
            root,
            key_digest,
            checkpoint,
            pending_settles: Settles::default(),
        }),
    });
    let opened = finish_open(&seal, tx, &binding, new_file, found).await?;
    Ok((seal, opened))
}

// Acts on what the open found: a new file's first commit, the second step a crash cut off, or a stale file's repair.
async fn finish_open(
    seal: &Seal,
    tx: Transaction<'static, Sqlite>,
    binding: &BindingRow,
    new_file: bool,
    found: Found,
) -> Result<Opened, StateError> {
    Ok(match found {
        Found::Fresh { pending } => {
            if new_file {
                commit(
                    seal,
                    tx,
                    Written {
                        key_tables: true,
                        ..Written::default()
                    },
                )
                .await?;
            } else {
                drop(tx);
                let mut anchor = seal.anchor.lock().await;
                if pending {
                    settle_forward(seal, &mut anchor).await;
                }
                forget_retired(seal, &mut anchor).await;
            }
            Opened {
                sync_tables: SyncTrust::Trusted,
                key_tables: owed_trust(seal).await?,
            }
        }
        Found::Restored { keys } => {
            repair(seal, tx, binding, keys).await?;
            Opened {
                sync_tables: SyncTrust::Refill,
                key_tables: owed_trust(seal).await?,
            }
        }
    })
}

// What an open compares against the anchor.
struct Checked<'a> {
    party: &'a Party,
    binding: &'a BindingRow,
    new_file: bool,
    key_digest: [u8; 32],
}

impl Checked<'_> {
    async fn find(
        &self,
        tx: &mut Transaction<'static, Sqlite>,
        key: Option<&Zeroizing<[u8; 32]>>,
        root: &RootItem,
    ) -> Result<Found, StateError> {
        let found = match (key, root) {
            // An anchor with no file, as after a reinstall that kept the device store, rebuilds as a stale file does.
            // A MAC key with no anchor beside it says one existed and was lost, as does an anchor this build cannot
            // read.
            (_, RootItem::Held(root)) if self.new_file => Found::Restored {
                keys: root.newest().map_or(Owed::Unanchored, Owed::Rebuild),
            },
            (None, RootItem::Absent) if self.new_file => Found::Fresh { pending: false },
            _ if self.new_file => Found::Restored { keys: Owed::Unanchored },
            // A file whose state MAC key is gone cannot verify, and opens as a file with no anchor.
            (None, _) => Found::Restored { keys: Owed::Unanchored },
            (Some(key), root) => {
                let binding = self.binding;
                let sync_digest = digest::sync_digest_in(tx).await?;
                let expected =
                    self.party
                        .mac(key, &binding.file_id, binding.counter, &self.key_digest, &sync_digest)?;
                if constant_time::verify_slices_are_equal(&expected, &binding.state_mac).is_err() {
                    return Err(StateError::Integrity);
                }
                found(binding, root)
            }
        };
        // An iCloud file has no key tables, so nothing about them is owed.
        Ok(match found {
            Found::Restored { .. } if self.party.provider() == Provider::ICloud => {
                Found::Restored { keys: Owed::Trusted }
            }
            found => found,
        })
    }
}

// A stale or unanchored file's open: its refill and, for a rebuild, the anchored checkpoint in place of its key
// tables, in one commit whose anchor owes what was found.
async fn repair(
    seal: &Seal,
    mut tx: Transaction<'static, Sqlite>,
    binding: &BindingRow,
    keys: Owed,
) -> Result<(), StateError> {
    refill(&mut tx, seal.provider()).await?;
    let mut anchor = seal.anchor.lock().await;
    let mut root = anchor.root.clone().unwrap_or_else(|| Root::new(binding.file_id));
    root.file_id = binding.file_id;
    let before = root.owed;
    let mut owed = before.stricter(keys);
    if let (Owed::Rebuild(floor), Owed::Rebuild(_)) = (owed, keys) {
        match seal
            .items()
            .checkpoint(floor)
            .await
            .map_err(|error| unsettled(&error))?
        {
            Some(checkpoint) => install(&mut tx, &checkpoint).await?,
            // The anchor names a checkpoint it no longer holds: nothing bounds a rebuild from below.
            None => owed = Owed::Unanchored,
        }
    }
    root.owed = owed;
    if let Owed::Rebuild(floor) = before {
        root.retire(floor);
    }
    // The open judged the pending entry a crash left, and this commit's own takes its place.
    if let Some(left) = root.pending.take() {
        root.retire(left.checkpoint);
    }
    anchor.root = Some(root);
    drop(anchor);
    let written = Written {
        key_tables: true,
        ..Written::default()
    };
    commit(seal, tx, written).await.map(|_| ())
}

async fn owed_trust(seal: &Seal) -> Result<KeyTrust, StateError> {
    let mut anchor = seal.anchor.lock().await;
    let owed = anchor.root.as_ref().map_or(Owed::Trusted, |root| root.owed);
    Ok(match owed {
        Owed::Trusted => KeyTrust::Trusted,
        Owed::Unanchored => KeyTrust::Unanchored,
        Owed::Rebuild(floor) => match seal
            .items()
            .checkpoint(floor)
            .await
            .map_err(|error| unsettled(&error))?
        {
            Some(checkpoint) => KeyTrust::Rebuild {
                checkpoint: Box::new(checkpoint),
            },
            None => {
                // Stored with the next commit, so the lost floor is not forgotten.
                if let Some(root) = anchor.root.as_mut() {
                    root.owed = Owed::Unanchored;
                    root.retire(floor);
                }
                KeyTrust::Unanchored
            }
        },
    })
}

async fn unsealed(
    tx: Transaction<'static, Sqlite>,
    bound: Bound,
    store: Arc<dyn HostDeviceStore>,
    name: StateName,
    party: Party,
) -> Result<(Arc<Seal>, Opened), StateError> {
    if bound.new_file {
        tx.commit().await.map_err(sql)?;
    } else {
        drop(tx);
    }
    let seal = Arc::new(Seal {
        store,
        name,
        party,
        key: None,
        key_unstored: AtomicBool::new(false),
        part_bytes: PART_BYTES,
        anchor: AsyncMutex::new(Anchor {
            root: None,
            key_digest: [0; 32],
            checkpoint: CheckpointRef {
                digest: [0; 32],
                parts: 0,
            },
            pending_settles: Settles::default(),
        }),
    });
    // Nothing here proves the key tables are the device's latest.
    let opened = Opened {
        sync_tables: SyncTrust::Trusted,
        key_tables: KeyTrust::Unanchored,
    };
    Ok((seal, opened))
}

async fn binding_in(tx: &mut Transaction<'static, Sqlite>) -> Result<BindingRow, StateError> {
    match read(tx, &RowKey::Binding).await? {
        Some(Row::Binding(binding)) => Ok(binding),
        _ => Err(StateError::Integrity),
    }
}

// One commit (0054, A commit writes its anchor in two steps): the new counter and MAC, then before the file commits the
// checkpoint when it changed and a pending entry in the root, and after it the pending entry becomes the current one.
pub(crate) async fn commit(
    seal: &Seal,
    mut tx: Transaction<'static, Sqlite>,
    written: Written,
) -> Result<Committed, StateError> {
    let Some(key) = seal.key.as_ref() else {
        let mut binding = binding_in(&mut tx).await?;
        binding.counter = binding.counter.checked_add(1).ok_or(StateError::Integrity)?;
        write(&mut tx, &Row::Binding(binding.clone())).await?;
        tx.commit().await.map_err(sql)?;
        return Ok(Committed {
            counter: binding.counter,
        });
    };
    let mut anchor = seal.anchor.lock().await;
    settle_left(seal, &mut anchor, &mut tx).await?;
    let mut binding = binding_in(&mut tx).await?;
    binding.counter = binding.counter.checked_add(1).ok_or(StateError::Integrity)?;
    let (key_digest, checkpoint, bytes) = if written.key_tables {
        let bytes = checkpoint_bytes(&checkpoint_in(&mut tx).await?);
        (
            digest::key_digest_in(&mut tx, seal.provider()).await?,
            checkpoint_ref_of(&bytes, seal.part_bytes),
            Some(bytes),
        )
    } else {
        (anchor.key_digest, anchor.checkpoint, None)
    };
    write(&mut tx, &Row::Binding(binding.clone())).await?;
    let sync_digest = digest::sync_digest_in(&mut tx).await?;
    binding.state_mac = seal
        .party
        .mac(key, &binding.file_id, binding.counter, &key_digest, &sync_digest)?;
    write(&mut tx, &Row::Binding(binding.clone())).await?;
    let entry = Entry {
        counter: binding.counter,
        mac: binding.state_mac,
        key_digest,
        checkpoint,
    };

    let mut root = anchor.root.clone().unwrap_or_else(|| Root::new(binding.file_id));
    if !root.names(checkpoint) {
        let bytes = match bytes {
            Some(bytes) => bytes,
            None => checkpoint_bytes(&checkpoint_in(&mut tx).await?),
        };
        if let Err(error) = seal.items().put_checkpoint(&bytes, seal.part_bytes).await {
            retire_unstored(&mut anchor, checkpoint);
            return Err(unsettled(&error));
        }
    }
    root.retired.retain(|retired| *retired != checkpoint);
    if let Some(replaced) = root.pending.replace(entry) {
        root.retire(replaced.checkpoint);
    }
    if let Err(error) = seal.items().put_root(&root).await {
        retire_unstored(&mut anchor, checkpoint);
        return Err(unsettled(&error));
    }
    anchor.root = Some(root);
    anchor.pending_settles = written.settles;

    // Whether a failed commit landed is read at the next commit, which settles the pending entry either way first.
    tx.commit().await.map_err(sql)?;
    anchor.key_digest = key_digest;
    anchor.checkpoint = checkpoint;
    if seal.key_unstored.load(Ordering::SeqCst) {
        // The file now verifies only under this key: until it is stored, the next open finds the key gone again.
        seal.items().put_mac_key(key).await.map_err(|error| unsettled(&error))?;
        seal.key_unstored.store(false, Ordering::SeqCst);
    }
    settle_forward(seal, &mut anchor).await;
    Ok(Committed {
        counter: binding.counter,
    })
}

// A checkpoint written for a pending entry that was never stored goes with the next root this process stores.
fn retire_unstored(anchor: &mut Anchor, checkpoint: CheckpointRef) {
    if let Some(root) = anchor.root.as_mut() {
        root.retire(checkpoint);
    }
}

// A pending entry an earlier commit left: the file says whether that commit landed. Until it is settled no commit
// starts (0054, A commit writes its anchor in two steps).
async fn settle_left(
    seal: &Seal,
    anchor: &mut Anchor,
    tx: &mut Transaction<'static, Sqlite>,
) -> Result<(), StateError> {
    let Some(pending) = anchor.root.as_ref().and_then(|root| root.pending) else {
        return Ok(());
    };
    let binding = binding_in(tx).await?;
    let current = anchor.root.as_ref().and_then(|root| root.current);
    if binding.counter == pending.counter && binding.state_mac == pending.mac {
        anchor.key_digest = pending.key_digest;
        anchor.checkpoint = pending.checkpoint;
        settle_forward(seal, anchor).await;
    } else if current.is_some_and(|current| binding.counter == current.counter && binding.state_mac == current.mac) {
        settle_back(seal, anchor).await;
    } else {
        return Err(StateError::AnchorUnsettled);
    }
    if anchor.root.as_ref().is_some_and(|root| root.pending.is_some()) {
        return Err(StateError::AnchorUnsettled);
    }
    Ok(())
}

// The commit landed: its pending entry becomes the current one, with the settles asked for since.
async fn settle_forward(seal: &Seal, anchor: &mut Anchor) {
    let Some(root) = anchor.root.clone() else {
        return;
    };
    let Some(pending) = root.pending else {
        return;
    };
    let mut next = Root {
        owed: anchor.pending_settles.apply(root.owed),
        current: Some(pending),
        pending: None,
        ..root.clone()
    };
    for dropped in root.named() {
        next.retire(dropped);
    }
    if let Err(error) = seal.items().put_root(&next).await {
        tracing::warn!(
            code = error.code(),
            "the anchor's second step waits for the next commit"
        );
        return;
    }
    anchor.root = Some(next);
    anchor.pending_settles = Settles::default();
    forget_retired(seal, anchor).await;
}

// The commit did not land: the pending entry goes, and with it the checkpoint only it named and what it settled.
async fn settle_back(seal: &Seal, anchor: &mut Anchor) {
    let Some(root) = anchor.root.clone() else {
        return;
    };
    let mut next = Root {
        pending: None,
        ..root.clone()
    };
    for dropped in root.named() {
        next.retire(dropped);
    }
    if let Err(error) = seal.items().put_root(&next).await {
        tracing::warn!(
            code = error.code(),
            "the anchor's pending entry waits for the next commit"
        );
        return;
    }
    anchor.root = Some(next);
    anchor.pending_settles = Settles::default();
    forget_retired(seal, anchor).await;
}

// Deletes the items of checkpoints the stored root retired. The root this process stores next drops those that went.
async fn forget_retired(seal: &Seal, anchor: &mut Anchor) {
    let Some(root) = anchor.root.as_mut() else {
        return;
    };
    let mut kept = Vec::new();
    for retired in std::mem::take(&mut root.retired) {
        if let Err(error) = seal.items().delete_checkpoint(retired).await {
            tracing::debug!(code = error.code(), "a retired checkpoint stays until the next commit");
            kept.push(retired);
        }
    }
    root.retired = kept;
}

// A file deleted whole takes its anchor with it, so a later file of the same identity starts as a new one. A failure
// leaves an anchor with no file, which rebuilds: the safe side.
pub(crate) async fn forget(store: &dyn HostDeviceStore, identity: &StateIdentity) -> Result<(), StateError> {
    let name = state_name(identity);
    let items = Items { store, name: &name };
    match items.forget().await {
        Ok(()) | Err(DeviceStoreError::Unavailable { .. }) => Ok(()),
        Err(error) => Err(unsettled(&error)),
    }
}
