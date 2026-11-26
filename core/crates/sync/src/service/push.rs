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
use super::{PassCtx, ServiceSync, Session, begin};
use crate::adapters::{approval, local_view};
use crate::api::adapter::LocalRecords;
use crate::api::error::SyncError;
use crate::api::ids::{ChangeTag, EpochId, IdempotencyKey, KindName, RecordKey, ScopeName};
use crate::api::scopes::ScopeInfo;
use crate::api::state::{BaseRow, DeletedHistoryRow, OutboxRow, Row, RowKey, RowRange, ScopeRow, Table};
use crate::api::transport::{Change, ChangeOp, ChangeOutcome, DeletedReason, Proof, PushBatch, TransportError};
use crate::engine::{Pending, PendingOp, change_bytes, diff, split};

enum Sent {
    Answered { conflicts: bool },
    EpochChanged,
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
fn going_up(
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

fn fingerprint(change: &Change) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hash_change(&mut hasher, change);
    hasher.finalize().into()
}

impl ServiceSync {
    pub(super) async fn push_scope(
        &self,
        ctx: &mut PassCtx,
        session: &mut Session,
        info: &ScopeInfo,
    ) -> Result<AfterPush, SyncError> {
        let scope = info.scope;
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
        let pending = self.pending(ctx, session, &row).await?;
        ctx.report.queued += pending.len();
        *ctx.report.queued_in.entry(scope).or_default() += pending.len();
        if pending.is_empty() {
            self.clear_outbox(scope).await?;
        }
        let mut after = AfterPush::Done;
        let limits = ctx.body.limits;
        for batch in split(pending, &limits, |pending: &Pending| change_bytes(&pending.change())) {
            match self.send(ctx, session, scope, epoch, &batch).await? {
                Sent::Answered { conflicts: true } => after = AfterPush::Pull,
                Sent::Answered { conflicts: false } => {}
                Sent::EpochChanged => return Ok(AfterPush::NewEpoch),
            }
        }
        Ok(after)
    }

    // What the held, contested and refused records leave of each kind's diff.
    async fn pending(
        &self,
        ctx: &mut PassCtx,
        session: &mut Session,
        row: &ScopeRow,
    ) -> Result<Vec<Pending>, SyncError> {
        let scope = row.scope;
        let skip = self.skipped(scope).await?;
        let held = approval::held_members(begin(&self.state).await?.as_mut(), scope).await?;
        let categories = ctx.categories_in(scope);
        let none = HashSet::new();
        let mut out = Vec::new();
        let mut pruned = Vec::new();
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
            if let Some(ids) = named {
                diffed.pending.retain(|pending| ids.contains(&pending.key.record_id));
                diffed.pruned.retain(|key| ids.contains(&key.record_id));
                diffed.refused.retain(|(key, _)| ids.contains(&key.record_id));
            }
            pruned.extend(diffed.pruned);
            for (key, code) in diffed.refused {
                ctx.report.refused.push((key.clone(), code.to_owned()));
                session.refused.insert(key, ([0; 32], code.to_owned()));
            }
            let pending: Vec<Pending> = diffed
                .pending
                .into_iter()
                .filter(|pending| {
                    let print = fingerprint(&pending.change());
                    session.refused.get(&pending.key).is_none_or(|(held, _)| *held != print)
                })
                .collect();
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
        if !pruned.is_empty() {
            self.check_stop()?;
            let mut txn = begin(&self.state).await?;
            for key in pruned {
                txn.delete(&RowKey::Base(key)).await?;
            }
            self.check_stop()?;
            txn.commit().await?;
        }
        Ok(out)
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

    async fn skipped(&self, scope: ScopeName) -> Result<HashMap<KindName, HashSet<String>>, SyncError> {
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

    async fn bases_in(&self, scope: ScopeName, kind: Kind) -> Result<Vec<BaseRow>, SyncError> {
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
        session: &mut Session,
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
            let request = PushBatch {
                scope,
                epoch: Some(epoch),
                idempotency_key: Some(key),
                changes: changes.clone(),
                proof: proof.clone(),
            };
            match self.transport.push(request).await {
                Ok(answer) => return self.answered(ctx, session, scope, epoch, batch, answer.outcomes).await,
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
        session: &mut Session,
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
                    session.refused.remove(&pending.key);
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
                    session.refused.insert(pending.key.clone(), (print, code));
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
        self.commit_answer(scope, puts, drops, deleted_history, gone).await?;
        self.tombstones_pushed(scope, tombstones).await?;
        Ok(Sent::Answered { conflicts })
    }

    async fn commit_answer(
        &self,
        scope: ScopeName,
        puts: Vec<BaseRow>,
        drops: Vec<RecordKey>,
        deleted_history: Vec<String>,
        gone: Vec<RecordKey>,
    ) -> Result<(), SyncError> {
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
