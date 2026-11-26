// A scope's push (0051, Push; Idempotency; 0054, The offline queue is on disk): the diff, split to the server's limits,
// each batch's key kept in the outbox before it is sent so a retry after a lost answer is the same request, and each
// answer written to the bases in one commit with the outbox cleared.

use std::collections::{BTreeSet, HashMap, HashSet};

use sha2::{Digest, Sha256};
use tablepro_keys::encoding::HistoryId;
use tablepro_records::Kind;
use tablepro_records::record_id::parse_uuid;
use uuid::Uuid;

use super::scopes::kind_off;
use super::{PassCtx, ServiceSync, begin};
use crate::adapters::{approval, local_view};
use crate::api::adapter::LocalRecords;
use crate::api::error::SyncError;
use crate::api::ids::{ChangeTag, EpochId, IdempotencyKey, KindName, RecordKey, ScopeName};
use crate::api::scopes::ScopeInfo;
use crate::api::state::{
    BaseRow, DeletedHistoryRow, OutboxRow, RefusedRow, Row, RowKey, RowRange, ScopeRow, Standing, StandingRow, Table,
};
use crate::api::transport::{Change, ChangeOp, ChangeOutcome, DeletedReason, Proof, PushBatch, TransportError};
use crate::engine::{
    KeptOff, Pending, PendingOp, change_bytes, diff, forget_kept_off, hold_kept_off, hold_left_behind,
    kept_off_connections, split,
};

enum Sent {
    Answered { conflicts: bool },
    EpochChanged,
}

// One push answer's writes, committed with the outbox cleared.
struct Answer {
    puts: Vec<BaseRow>,
    drops: Vec<RecordKey>,
    deleted_history: Vec<String>,
    gone: Vec<RecordKey>,
    refusals: Refusals,
}

// The `refused` rows a diff or an answer writes and removes.
#[derive(Default)]
struct Refusals {
    puts: Vec<RefusedRow>,
    drops: Vec<RecordKey>,
}

impl Refusals {
    fn is_empty(&self) -> bool {
        self.puts.is_empty() && self.drops.is_empty()
    }

    fn keep(&mut self, held: &HashMap<RecordKey, RefusedRow>, key: RecordKey, digest: [u8; 32], code: &str) {
        let row = RefusedRow {
            key,
            digest,
            code: code.to_owned(),
        };
        if held.get(&row.key) != Some(&row) {
            self.puts.push(row);
        }
    }

    // A refusal of a record of `kind` the diff read and no longer stands by: the change it refused went, or what the
    // pass would send of it is new. A journal pass read only what it was told of.
    fn drop_unless(
        &mut self,
        held: &HashMap<RecordKey, RefusedRow>,
        scope: ScopeName,
        kind: Kind,
        named: Option<&HashSet<String>>,
        standing: &HashSet<RecordKey>,
    ) {
        let name = KindName::of(kind);
        self.drops.extend(
            held.keys()
                .filter(|key| key.scope == scope && key.kind == name)
                .filter(|key| named.is_none_or(|ids| ids.contains(&key.record_id)))
                .filter(|key| !standing.contains(*key))
                .cloned(),
        );
    }
}

// What a scope needs after its push: nothing, a pull for the stored copies of its conflicts, or a new scopes body and
// a refill, since the server is in another epoch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum AfterPush {
    Done,
    Pull,
    NewEpoch,
}

fn framed(hasher: &mut Sha256, part: &[u8]) {
    hasher.update(u32::try_from(part.len()).unwrap_or(u32::MAX).to_be_bytes());
    hasher.update(part);
}

fn hash_change(hasher: &mut Sha256, change: &Change) {
    framed(hasher, change.kind.as_str().as_bytes());
    framed(hasher, change.record_id.as_bytes());
    // Tagged, so a create and a change on an empty tag never hash alike.
    match &change.base {
        Some(ChangeTag::Service(tag)) => framed(hasher, &[&[1][..], tag.as_bytes()].concat()),
        Some(ChangeTag::CloudKit(bytes)) => framed(hasher, &[&[2][..], bytes].concat()),
        None => framed(hasher, &[0]),
    }
    match &change.op {
        ChangeOp::Write { patch, .. } => {
            framed(hasher, b"patch");
            framed(hasher, patch.to_string().as_bytes());
        }
        ChangeOp::Delete => framed(hasher, b"delete"),
    }
}

// The request a batch sends: the epoch and each change. A rebuilt batch reuses its key only when this matches.
fn request_digest(epoch: EpochId, changes: &[Change]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    framed(&mut hasher, epoch.0.as_bytes());
    for change in changes {
        hash_change(&mut hasher, change);
    }
    hasher.finalize().into()
}

// What a store's copy sends: with the members the store cannot hold from the base, and at the base's value each
// member the device keeps to itself or that waits for the person (0054, Dirty state is a diff).
pub(super) fn going_up(
    kind: Kind,
    scope: ScopeName,
    mut local: LocalRecords,
    bases: &[BaseRow],
    held: &std::collections::BTreeMap<(KindName, String), BTreeSet<String>>,
) -> LocalRecords {
    let by_id: HashMap<&str, &BaseRow> = bases.iter().map(|base| (base.key.record_id.as_str(), base)).collect();
    let none = BTreeSet::new();
    let name = KindName::of(kind);
    for record in &mut local.records {
        let base = by_id
            .get(record.record_id.as_str())
            .filter(|base| base.deleted.is_none())
            .and_then(|base| base.fields.as_ref());
        let members = held.get(&(name.clone(), record.record_id.clone())).unwrap_or(&none);
        record.fields = local_view(kind, scope, &record.fields, base, members);
    }
    local
}

// The move marker is left out, so a refused create stands for the same create sent later without it, and goes again
// only once the record itself changed.
pub(super) fn fingerprint(change: &Change) -> [u8; 32] {
    let mut hasher = Sha256::new();
    match &change.op {
        ChangeOp::Write { fields, patch } if patch.get(tablepro_records::move_marker::MEMBER).is_some() => {
            let mut patch = patch.clone();
            crate::adapters::fields::set(&mut patch, &format!("/{}", tablepro_records::move_marker::MEMBER), None);
            hash_change(
                &mut hasher,
                &Change {
                    op: ChangeOp::Write {
                        fields: fields.clone(),
                        patch,
                    },
                    ..change.clone()
                },
            );
        }
        _ => hash_change(&mut hasher, change),
    }
    hasher.finalize().into()
}

impl ServiceSync {
    pub(super) async fn push_scope(&self, ctx: &mut PassCtx, info: &ScopeInfo) -> Result<AfterPush, SyncError> {
        let scope = info.scope;
        // Nothing of the person's own goes up before they chose for a new account or server (0054, Another account or
        // server).
        if !matches!(scope, ScopeName::Team(_)) {
            let wait = self.own_push_wait().await?;
            if wait.is_some() {
                ctx.report.push_wait = wait;
                return Ok(AfterPush::Done);
            }
        }
        let Some(row) = self.scope_row(scope).await? else {
            return Ok(AfterPush::Done);
        };
        let Some(epoch) = row.epoch else {
            return Ok(AfterPush::Done);
        };
        if row.refill || !row.caught_up {
            return Ok(AfterPush::Done);
        }
        // Past grace or after a lapse only key-object writes are taken (0051, Gates).
        if !info.writable {
            ctx.report.pull_only = true;
            return Ok(AfterPush::Done);
        }
        // Personal and history data go up only from an approved device, and not once a key flow locked it in this pass.
        if !matches!(scope, ScopeName::Team(_)) && (info.approved != Some(true) || self.hooks.locked().is_some()) {
            return Ok(AfterPush::Done);
        }
        let pending = self.pending(ctx, &row).await?;
        ctx.report.queued += pending.len();
        *ctx.report.queued_in.entry(scope).or_default() += pending.len();
        if pending.is_empty() {
            self.clear_outbox(scope).await?;
        }
        let mut after = AfterPush::Done;
        let limits = ctx.body.limits;
        for batch in split(pending, &limits, |pending: &Pending| change_bytes(&pending.change())) {
            match self.send(ctx, scope, epoch, &batch).await? {
                Sent::Answered { conflicts: true } => after = AfterPush::Pull,
                Sent::Answered { conflicts: false } => {}
                Sent::EpochChanged => return Ok(AfterPush::NewEpoch),
            }
        }
        Ok(after)
    }

    // What the held, contested and refused records leave of each kind's diff.
    async fn pending(&self, ctx: &mut PassCtx, row: &ScopeRow) -> Result<Vec<Pending>, SyncError> {
        let scope = row.scope;
        let skip = self.skipped(scope).await?;
        let held = approval::held_members(begin(&self.state).await?.as_mut(), scope).await?;
        let refused = self.refused_in(scope).await?;
        let categories = ctx.categories_in(scope);
        let none = HashSet::new();
        let mut out = Vec::new();
        let mut pruned = Vec::new();
        let mut refusals = Refusals::default();
        let kept_off = self.kept_off(scope).await?;
        let left = self.left_behind(scope).await?;
        let mut left_drops = Vec::new();
        for adapter in self.adapters.in_scope(scope) {
            let kind = adapter.kind();
            if kind_off(row.policies, scope, kind)
                || !categories.syncs(kind)
                || (kind == Kind::SecretEnvelope && !self.seals(ctx, row))
            {
                continue;
            }
            // A journal pass diffs only what the journal named, and a kind it named nothing of not at all (0060).
            let named = match &ctx.named {
                Some(named) => match named.get(&kind) {
                    Some(ids) => Some(ids),
                    None => continue,
                },
                None => None,
            };
            let bases = self.bases_in(scope, kind).await?;
            let local = going_up(kind, scope, adapter.records(scope).await?, &bases, &held);
            let mut diffed = diff(
                scope,
                kind,
                &local,
                &bases,
                skip.get(&KindName::of(kind)).unwrap_or(&none),
            );
            forget_kept_off(&mut diffed, kind, &kept_off);
            let kept_back = hold_kept_off(&mut diffed, kind, &kept_off);
            left_drops.extend(hold_left_behind(&mut diffed, &bases, &left));
            // The marker goes on before a refusal is looked up, so the change a refusal names is the one sent.
            if let Some(arrival) = ctx.arrival.as_deref().filter(|_| scope == ScopeName::Personal) {
                arrival.mark(&mut diffed.pending);
            }
            if let Some(ids) = named {
                diffed.pending.retain(|pending| ids.contains(&pending.key.record_id));
                diffed.pruned.retain(|key| ids.contains(&key.record_id));
                diffed.refused.retain(|(key, _)| ids.contains(&key.record_id));
            }
            pruned.extend(diffed.pruned);
            // Each refusal this diff still stands by: a change it would send as it was refused, or one it refuses
            // itself, which no digest stands for. Any other refusal of what it read is gone with the change.
            // A change kept back while its connection stays on the device was not sent either.
            let mut standing: HashSet<RecordKey> = kept_back.into_iter().collect();
            for (key, code) in diffed.refused {
                ctx.report.refused.push((key.clone(), code.to_owned()));
                standing.insert(key.clone());
                refusals.keep(&refused, key, [0; 32], code);
            }
            let pending: Vec<Pending> = diffed
                .pending
                .into_iter()
                .filter(|pending| {
                    let print = fingerprint(&pending.change());
                    let held = refused.get(&pending.key).filter(|held| held.digest == print);
                    if held.is_some() {
                        standing.insert(pending.key.clone());
                    }
                    held.is_none()
                })
                .collect();
            // A record a conflict, a hold or its store's failure to read it keeps out of the diff keeps its refusal
            // for when it comes back: nothing different was seen of it.
            standing.extend(
                skip.get(&KindName::of(kind))
                    .into_iter()
                    .flatten()
                    .chain(&local.unreadable)
                    .map(|id| RecordKey::new(scope, kind, id.clone())),
            );
            refusals.drop_unless(&refused, scope, kind, named, &standing);
            if kind == Kind::HistoryEntry {
                out.extend(self.sealed(ctx, pending).await?);
            } else {
                out.extend(pending);
            }
            if !diffed.acknowledged.is_empty() {
                self.check_stop()?;
                adapter
                    .tombstones_pushed(
                        scope,
                        diffed.acknowledged.into_iter().map(|key| key.record_id).collect(),
                    )
                    .await?;
            }
        }
        self.forget_pruned(pruned, refusals, left_drops).await?;
        Ok(out)
    }

    // The settings records Start empty left on the device in `scope`, by record.
    async fn left_behind(&self, scope: ScopeName) -> Result<HashMap<RecordKey, [u8; 32]>, SyncError> {
        let rows = begin(&self.state)
            .await?
            .scan(&RowRange::Scope(Table::LeftBehind, scope))
            .await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| match row {
                Row::LeftBehind(row) => Some((row.key, row.digest)),
                _ => None,
            })
            .collect())
    }

    // The bases a diff let go of, the refusals it no longer stands by or newly found, and the settings left behind that
    // were edited or met on the provider, in one commit.
    async fn forget_pruned(
        &self,
        pruned: Vec<RecordKey>,
        refusals: Refusals,
        left_drops: Vec<RecordKey>,
    ) -> Result<(), SyncError> {
        if pruned.is_empty() && refusals.is_empty() && left_drops.is_empty() {
            return Ok(());
        }
        self.check_stop()?;
        let mut txn = begin(&self.state).await?;
        for key in pruned {
            txn.delete(&RowKey::Base(key)).await?;
        }
        for key in left_drops {
            txn.delete(&RowKey::LeftBehind(key)).await?;
        }
        for row in refusals.puts {
            txn.put(Row::Refused(row)).await?;
        }
        for key in refusals.drops {
            txn.delete(&RowKey::Refused(key)).await?;
        }
        self.check_stop()?;
        txn.commit().await?;
        Ok(())
    }

    // What the diff would still send of a scope, refused and kept-back records aside: a move is done only once this
    // is nothing, so no record goes up later without the marker its move owes it.
    pub(super) async fn unsent(&self, scope: ScopeName) -> Result<usize, SyncError> {
        let Some(row) = self.scope_row(scope).await? else {
            return Ok(0);
        };
        let skip = self.skipped(scope).await?;
        let held = approval::held_members(begin(&self.state).await?.as_mut(), scope).await?;
        let refused = self.refused_in(scope).await?;
        let kept_off = self.kept_off(scope).await?;
        let left = self.left_behind(scope).await?;
        let categories = self.categories();
        let none = HashSet::new();
        let mut unsent = 0;
        for adapter in self.adapters.in_scope(scope) {
            let kind = adapter.kind();
            if kind_off(row.policies, scope, kind) || !categories.syncs(kind) {
                continue;
            }
            let bases = self.bases_in(scope, kind).await?;
            let local = going_up(kind, scope, adapter.records(scope).await?, &bases, &held);
            let mut diffed = diff(
                scope,
                kind,
                &local,
                &bases,
                skip.get(&KindName::of(kind)).unwrap_or(&none),
            );
            forget_kept_off(&mut diffed, kind, &kept_off);
            hold_kept_off(&mut diffed, kind, &kept_off);
            hold_left_behind(&mut diffed, &bases, &left);
            // A record the server refused waits for the person whatever the marker made of its change.
            unsent += diffed
                .pending
                .iter()
                .filter(|pending| !refused.contains_key(&pending.key))
                .count();
        }
        Ok(unsent)
    }

    // The changes the server refused in `scope`, by record (0066, `refused`).
    pub(super) async fn refused_in(&self, scope: ScopeName) -> Result<HashMap<RecordKey, RefusedRow>, SyncError> {
        let rows = begin(&self.state)
            .await?
            .scan(&RowRange::Scope(Table::Refused, scope))
            .await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| match row {
                Row::Refused(row) => Some((row.key.clone(), row)),
                _ => None,
            })
            .collect())
    }

    // History entries go up sealed under the newest history key, at push time (0056, Envelopes and history). A refusal
    // is remembered by the plaintext it sealed, so the same entry is not sealed and sent again each pass. Entries wait
    // for a pass whose keys can seal them; a deletion carries no fields and goes as it is.
    async fn sealed(&self, ctx: &mut PassCtx, pending: Vec<Pending>) -> Result<Vec<Pending>, SyncError> {
        let mut out = Vec::with_capacity(pending.len());
        let mut sealing = true;
        for mut pending in pending {
            let PendingOp::Write { fields, .. } = &pending.op else {
                out.push(pending);
                continue;
            };
            let Some(id) = parse_uuid(&pending.key.record_id).filter(|_| sealing) else {
                continue;
            };
            let print = fingerprint(&pending.change());
            self.check_stop()?;
            let sealed = match self.keys.seal_history_entry(HistoryId(id), fields.clone()).await {
                Ok(sealed) => sealed,
                Err(error @ (SyncError::Keys(_) | SyncError::NotAllowed { .. } | SyncError::Locked { .. })) => {
                    tracing::debug!(code = error.code(), "history entries wait for keys that seal them");
                    sealing = false;
                    continue;
                }
                Err(error) => return Err(error),
            };
            pending.op = PendingOp::Write {
                fields: sealed.clone(),
                patch: sealed,
            };
            ctx.sealed_prints.insert(pending.key.clone(), print);
            out.push(pending);
        }
        Ok(out)
    }

    // Whether the scope's envelopes go up now: never from a locked or unapproved device, nor under a key version that
    // stopped or ended, nor in a team due a rotation (0051, Teams; 0056).
    fn seals(&self, ctx: &PassCtx, row: &ScopeRow) -> bool {
        let scope = row.scope;
        let rotation_due = matches!(scope, ScopeName::Team(_)) && row.rotation_due;
        !ctx.locked
            && self.hooks.locked().is_none()
            && ctx.approved
            && ctx.keys_ready
            && !rotation_due
            && !self.hooks.holds_secrets(scope)
    }

    // The personal scope's connections that keep their records on the device; a store that cannot be read keeps all.
    // The state file records each one a base names, so once the store no longer holds it, its deletion and its
    // records' stay here too (0054, Rules for both providers). One that syncs again loses its row.
    async fn kept_off(&self, scope: ScopeName) -> Result<KeptOff, SyncError> {
        if scope != ScopeName::Personal {
            return Ok(KeptOff::default());
        }
        let Some(adapter) = self
            .adapters
            .in_scope(scope)
            .into_iter()
            .find(|adapter| adapter.kind() == Kind::Connection)
        else {
            return Ok(KeptOff::none());
        };
        let connections = adapter.records(scope).await.ok();
        let name = KindName::of(Kind::Connection);
        let mut recorded: HashMap<String, Standing> = HashMap::new();
        for row in begin(&self.state)
            .await?
            .scan(&RowRange::ScopeKind(Table::Standing, scope, name.clone()))
            .await?
        {
            if let Row::Standing(row) = row {
                recorded.insert(row.key.record_id, row.standing);
            }
        }
        if let Some(local) = &connections {
            let bases = self.bases_in(scope, Kind::Connection).await?;
            let kept: HashSet<String> = kept_off_connections(local, &bases)
                .into_iter()
                .map(tablepro_records::record_id::uuid_id)
                .collect();
            let mut puts = Vec::new();
            let mut drops = Vec::new();
            for record in &local.records {
                let held = recorded.get(&record.record_id);
                if kept.contains(&record.record_id) {
                    if held != Some(&record.standing) {
                        puts.push(StandingRow {
                            key: RecordKey::new(scope, name.clone(), record.record_id.clone()),
                            standing: record.standing,
                        });
                    }
                } else if held.is_some() {
                    drops.push(RecordKey::new(scope, name.clone(), record.record_id.clone()));
                }
            }
            if !puts.is_empty() || !drops.is_empty() {
                self.check_stop()?;
                let mut txn = begin(&self.state).await?;
                for row in &puts {
                    txn.put(Row::Standing(row.clone())).await?;
                }
                for key in &drops {
                    txn.delete(&RowKey::Standing(key.clone())).await?;
                }
                self.check_stop()?;
                txn.commit().await?;
            }
            for row in puts {
                recorded.insert(row.key.record_id, row.standing);
            }
            for key in drops {
                recorded.remove(&key.record_id);
            }
        }
        let kept = recorded
            .into_iter()
            .filter(|(_, standing)| *standing != Standing::Syncs)
            .filter_map(|(id, _)| Uuid::parse_str(&id).ok());
        Ok(KeptOff::of(connections.as_ref()).recorded(kept))
    }

    pub(super) async fn skipped(&self, scope: ScopeName) -> Result<HashMap<KindName, HashSet<String>>, SyncError> {
        let mut txn = begin(&self.state).await?;
        let mut skip: HashMap<KindName, HashSet<String>> = HashMap::new();
        for table in [Table::Held, Table::Conflicts] {
            for row in txn.scan(&RowRange::Scope(table, scope)).await? {
                let key = match row {
                    Row::Held(row) => row.key,
                    Row::Conflict(row) => row.key,
                    _ => continue,
                };
                skip.entry(key.kind).or_default().insert(key.record_id);
            }
        }
        Ok(skip)
    }

    pub(super) async fn bases_in(&self, scope: ScopeName, kind: Kind) -> Result<Vec<BaseRow>, SyncError> {
        let mut txn = begin(&self.state).await?;
        let rows = txn
            .scan(&RowRange::ScopeKind(Table::Bases, scope, KindName::of(kind)))
            .await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| match row {
                Row::Base(base) => Some(base),
                _ => None,
            })
            .collect())
    }

    // Team plaintext carries no proof; personal and history calls, and team envelope or key writes, do (0051, DPoP).
    // The key is read for each push, since an approval or a recovery in this pass changes which DSK proves.
    async fn push_proof(&self, scope: ScopeName, changes: &[Change]) -> Result<Proof, SyncError> {
        let keyed = changes
            .iter()
            .any(|change| change.kind.is_key() || change.kind.known() == Some(Kind::SecretEnvelope));
        if matches!(scope, ScopeName::Team(_)) && !keyed {
            return Ok(Proof::None);
        }
        Ok(self.keys.dpop_key().await?.map_or(Proof::None, Proof::Dpop))
    }

    async fn send(
        &self,
        ctx: &mut PassCtx,
        scope: ScopeName,
        epoch: EpochId,
        batch: &[Pending],
    ) -> Result<Sent, SyncError> {
        let changes: Vec<Change> = batch.iter().map(Pending::change).collect();
        let proof = self.push_proof(scope, &changes).await?;
        let digest = request_digest(epoch, &changes);
        let retention_ms = i64::try_from(ctx.body.idempotency_retention_secs.saturating_mul(1_000)).unwrap_or(i64::MAX);
        for fresh in [false, true] {
            let key = self.outbox_key(scope, digest, retention_ms, fresh).await?;
            self.check_stop()?;
            // A team's edits go out only under the sign-in they were made in, and none once a delete of them began.
            if let Some(refused) = matches!(scope, ScopeName::Team(_))
                .then(|| self.team_send_refused())
                .flatten()
            {
                return Err(refused);
            }
            let request = PushBatch {
                scope,
                epoch: Some(epoch),
                idempotency_key: Some(key),
                changes: changes.clone(),
                proof: proof.clone(),
            };
            match self.transport.push(request).await {
                Ok(answer) => return self.answered(ctx, scope, epoch, batch, answer.outcomes).await,
                // Refill before any write of this device applies (0051, Push).
                Err(TransportError::EpochChanged) => {
                    self.epoch_changed(scope).await?;
                    return Ok(Sent::EpochChanged);
                }
                Err(TransportError::IdempotencyMismatch) if !fresh => {}
                Err(error) => return Err(error.into()),
            }
        }
        Err(TransportError::IdempotencyMismatch.into())
    }

    // The batch in flight keeps its key until answered: the same request within the server's retention reuses it, and
    // anything else, or an older batch, takes a new one (0051, Idempotency).
    async fn outbox_key(
        &self,
        scope: ScopeName,
        digest: [u8; 32],
        retention_ms: i64,
        fresh: bool,
    ) -> Result<IdempotencyKey, SyncError> {
        let now = self.clock.now_ms();
        let mut txn = begin(&self.state).await?;
        let held = match txn.get(&RowKey::Outbox(scope)).await? {
            Some(Row::Outbox(row))
                if !fresh && row.request_digest == digest && now.saturating_sub(row.created_at_ms) < retention_ms =>
            {
                Some(row)
            }
            _ => None,
        };
        let row = held.unwrap_or_else(|| OutboxRow {
            scope,
            idempotency_key: IdempotencyKey(Uuid::new_v4().to_string()),
            request_digest: digest,
            created_at_ms: now,
        });
        let key = row.idempotency_key.clone();
        txn.put(Row::Outbox(row)).await?;
        self.check_stop()?;
        txn.commit().await?;
        Ok(key)
    }

    // A batch in flight that the pull showed applied, or that the diff no longer holds, is no longer in flight.
    async fn clear_outbox(&self, scope: ScopeName) -> Result<(), SyncError> {
        let mut txn = begin(&self.state).await?;
        if txn.get(&RowKey::Outbox(scope)).await?.is_none() {
            return Ok(());
        }
        txn.delete(&RowKey::Outbox(scope)).await?;
        self.check_stop()?;
        txn.commit().await?;
        Ok(())
    }

    async fn epoch_changed(&self, scope: ScopeName) -> Result<(), SyncError> {
        self.check_stop()?;
        let mut txn = begin(&self.state).await?;
        if let Some(Row::Scope(mut row)) = txn.get(&RowKey::Scope(scope)).await? {
            row.refill = true;
            txn.put(Row::Scope(row)).await?;
        }
        txn.delete(&RowKey::Outbox(scope)).await?;
        self.check_stop()?;
        txn.commit().await?;
        Ok(())
    }

    async fn answered(
        &self,
        ctx: &mut PassCtx,
        scope: ScopeName,
        epoch: EpochId,
        batch: &[Pending],
        outcomes: Vec<ChangeOutcome>,
    ) -> Result<Sent, SyncError> {
        if outcomes.len() != batch.len() {
            return Err(SyncError::Malformed { what: "push answer" });
        }
        let mut puts = Vec::new();
        let mut drops = Vec::new();
        let mut refusals = Refusals::default();
        let mut conflicts = false;
        let mut tombstones: HashMap<Kind, Vec<String>> = HashMap::new();
        let applied: Vec<bool> = outcomes
            .iter()
            .map(|outcome| matches!(outcome, ChangeOutcome::Applied { .. }))
            .collect();
        for (pending, outcome) in batch.iter().zip(outcomes) {
            let kind = pending.key.kind.known();
            match outcome {
                ChangeOutcome::Applied { tag, service } => {
                    ctx.report.pushed += 1;
                    refusals.drops.push(pending.key.clone());
                    let create_once = kind.is_some_and(Kind::is_create_once);
                    match (&pending.op, tag) {
                        (PendingOp::Write { fields, .. }, Some(tag)) => puts.push(BaseRow {
                            key: pending.key.clone(),
                            tag,
                            version: service.map(|stamp| stamp.version),
                            revision: service.map(|stamp| stamp.revision),
                            epoch: Some(epoch),
                            deleted: None,
                            fields: (!create_once).then(|| fields.clone()),
                            created_ms: None,
                        }),
                        (PendingOp::Write { .. }, None) => {}
                        (PendingOp::Delete, Some(tag)) => puts.push(BaseRow {
                            key: pending.key.clone(),
                            tag,
                            version: service.map(|stamp| stamp.version),
                            revision: service.map(|stamp| stamp.revision),
                            epoch: Some(epoch),
                            deleted: Some(DeletedReason::User),
                            fields: None,
                            created_ms: None,
                        }),
                        (PendingOp::Delete, None) => drops.push(pending.key.clone()),
                    }
                    if let (Some(kind), PendingOp::Delete) = (kind.filter(|kind| kind.is_create_once()), &pending.op) {
                        tombstones.entry(kind).or_default().push(pending.key.record_id.clone());
                    }
                }
                // The service names the stored tag and no fields, so the device pulls it and merges (0054, A push).
                ChangeOutcome::Conflict { stored } => {
                    ctx.report.conflicts += 1;
                    conflicts = true;
                    if stored.is_none() && pending.base.is_some() {
                        drops.push(pending.key.clone());
                    }
                }
                ChangeOutcome::Rejected { code } => {
                    let code = code.as_str().to_owned();
                    ctx.report.refused.push((pending.key.clone(), code.clone()));
                    let print = ctx
                        .sealed_prints
                        .get(&pending.key)
                        .copied()
                        .unwrap_or_else(|| fingerprint(&pending.change()));
                    refusals.puts.push(RefusedRow {
                        key: pending.key.clone(),
                        digest: print,
                        code,
                    });
                }
                ChangeOutcome::Gone | ChangeOutcome::Failed { .. } => {}
            }
        }
        let deleted_history = tombstones.get(&Kind::HistoryEntry).cloned().unwrap_or_default();
        let gone: Vec<RecordKey> = batch
            .iter()
            .zip(&applied)
            .filter(|(pending, applied)| **applied && pending.op == PendingOp::Delete)
            .map(|(pending, _)| pending.key.clone())
            .collect();
        self.commit_answer(
            scope,
            Answer {
                puts,
                drops,
                deleted_history,
                gone,
                refusals,
            },
        )
        .await?;
        self.tombstones_pushed(scope, tombstones).await?;
        Ok(Sent::Answered { conflicts })
    }

    async fn commit_answer(&self, scope: ScopeName, answer: Answer) -> Result<(), SyncError> {
        let Answer {
            puts,
            drops,
            deleted_history,
            gone,
            refusals,
        } = answer;
        self.check_stop()?;
        let mut txn = begin(&self.state).await?;
        // A record the person deleted here has nothing left to approve.
        for key in &gone {
            for row in approval::rows_of(txn.as_mut(), key).await? {
                txn.delete(&RowKey::Approval(row.key, row.field)).await?;
            }
        }
        for base in puts {
            txn.put(Row::Base(base)).await?;
        }
        // The person deleted these entries: their ids never come back (0051, Tombstones).
        for record_id in deleted_history {
            txn.put(Row::DeletedHistory(DeletedHistoryRow { record_id })).await?;
        }
        for key in drops {
            txn.delete(&RowKey::Base(key)).await?;
        }
        // The answer and what the server refused land together, so a refusal outlives a restart (0066, `refused`).
        for row in refusals.puts {
            txn.put(Row::Refused(row)).await?;
        }
        for key in refusals.drops {
            txn.delete(&RowKey::Refused(key)).await?;
        }
        txn.delete(&RowKey::Outbox(scope)).await?;
        self.check_stop()?;
        txn.commit().await?;
        Ok(())
    }

    // After the commit, so a crash between sends the deletion again, which the server answers applied.
    async fn tombstones_pushed(
        &self,
        scope: ScopeName,
        tombstones: HashMap<Kind, Vec<String>>,
    ) -> Result<(), SyncError> {
        for (kind, ids) in tombstones {
            let adapter = self
                .adapters
                .in_scope(scope)
                .into_iter()
                .find(|adapter| adapter.kind() == kind);
            if let Some(adapter) = adapter {
                self.check_stop()?;
                adapter.tombstones_pushed(scope, ids).await?;
            }
        }
        Ok(())
    }
}
