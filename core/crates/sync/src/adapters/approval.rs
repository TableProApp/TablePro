// The approval queue (0044, Fields a pull applies only with approval; 0054, Rules for both providers; 0061, 2). A pulled
// change to an approval-required member never lands in the store: the store keeps the device's value and the pulled one
// waits for the person on this device. A rejection keeps the device's value as a local override, which never goes up.
// The diff leaves both out, so the device never pushes its old value back over the pulled one. A record new to the
// device that has a member waiting is held whole until each one is decided, since a connection with no host is no
// connection. The check is against what the store holds, so a value the device applied before it ran the engine counts
// as approved and the upgrade asks nothing new.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use serde_json::Value;
use sha2::{Digest, Sha256};
use tablepro_records::Kind;
use tablepro_records::merge::Merged;

use super::carry::holds;
use super::fields::{Rule, get, members, set};
use crate::api::adapter::{LocalChange, RecordAdapter};
use crate::api::control::{PendingApproval, RecordApproval, approval_digest, record_approval_digest};
use crate::api::error::{AdapterError, SyncError};
use crate::api::ids::{KindName, RecordKey, ScopeName};
use crate::api::state::{
    ApprovalDecision, ApprovalRow, HeldReason, Row, RowKey, RowRange, StateStore, StateTxn, Table,
};
use crate::engine::{Adapters, Fence};

// What the store takes of a pulled record, and the queue's rows for it.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Split {
    // The pulled record with each waiting member at the device's value, and what the device keeps to itself put back.
    pub fields: Value,
    // A record the store does not hold with a member still waiting or refused: it stays out of the store.
    pub hold: bool,
    pub put: Vec<ApprovalRow>,
    // Members whose row goes: settled, or no longer pulled.
    pub clear: Vec<String>,
}

fn pulled_value(value: Option<&Value>) -> Value {
    value.cloned().unwrap_or(Value::Null)
}

fn as_member(value: &Value) -> Option<Value> {
    (!value.is_null()).then(|| value.clone())
}

// `stored` is the store's copy, None when it holds none; `merged` what the merge would write; `rows` the queue's rows
// of this record.
pub fn split(kind: Kind, key: &RecordKey, stored: Option<&Value>, merged: &Value, rows: &[ApprovalRow]) -> Split {
    let mut out = Split {
        fields: merged.clone(),
        ..Split::default()
    };
    let mut seen = BTreeSet::new();
    let mut waiting = false;
    for member in members(kind, key.scope, stored, Some(merged)) {
        let pointer = member.pointer;
        let (old, new) = (get(stored, &pointer), get(Some(merged), &pointer));
        // A member the store has no place for rides on the base, so it never needs the person; the store keeps what
        // it holds, so an adapter that does keep it never takes the pulled value unasked.
        let approval = match member.rule {
            Rule::Applies => continue,
            Rule::Waits(approval) if holds(kind, &pointer) => approval,
            Rule::Stays | Rule::Waits(_) => {
                set(&mut out.fields, &pointer, old.cloned());
                continue;
            }
        };
        seen.insert(pointer.clone());
        let row = rows.iter().find(|row| row.field == pointer);
        if old == new {
            if row.is_some() {
                out.clear.push(pointer);
            }
            continue;
        }
        let asked_for = |row: &ApprovalRow| row.pulled == pulled_value(new);
        match row {
            // The person already said yes to this value of a record not yet in the store.
            Some(row) if row.decision == ApprovalDecision::Approved && asked_for(row) => continue,
            Some(row) if asked_for(row) => {}
            _ if !approval.waits(old, new) => {
                if row.is_some() {
                    out.clear.push(pointer);
                }
                continue;
            }
            _ => out.put.push(ApprovalRow {
                key: key.clone(),
                field: pointer.clone(),
                pulled: pulled_value(new),
                decision: ApprovalDecision::Waiting,
            }),
        }
        waiting = true;
        set(&mut out.fields, &pointer, old.cloned());
    }
    // A record new to the device lands only whole: once a pull brings a value the person has not seen, the values
    // refused with it wait again, so the person decides the record as it is now.
    if stored.is_none() && !out.put.is_empty() {
        let again: Vec<ApprovalRow> = rows
            .iter()
            .filter(|row| matches!(row.decision, ApprovalDecision::Rejected { .. }) && seen.contains(&row.field))
            .filter(|row| !out.clear.contains(&row.field) && !out.put.iter().any(|put| put.field == row.field))
            .map(|row| ApprovalRow {
                decision: ApprovalDecision::Waiting,
                ..row.clone()
            })
            .collect();
        out.put.extend(again);
    }
    out.clear.extend(
        rows.iter()
            .filter(|row| !seen.contains(&row.field))
            .map(|row| row.field.clone()),
    );
    out.hold = stored.is_none() && waiting;
    out
}

// What a pull may write once the queue has seen it.
#[derive(Debug, Clone, PartialEq)]
pub enum Gated {
    Apply(Merged),
    // Hold the pulled copy by id with `HeldReason::AwaitingApproval`; the store writes nothing.
    Hold,
}

// The queue's rows of one record.
pub async fn rows_of(txn: &mut dyn StateTxn, key: &RecordKey) -> Result<Vec<ApprovalRow>, SyncError> {
    let rows = txn
        .scan(&RowRange::ScopeKind(Table::Approvals, key.scope, key.kind.clone()))
        .await?;
    Ok(rows
        .into_iter()
        .filter_map(|row| match row {
            Row::Approval(row) if row.key.record_id == key.record_id => Some(row),
            _ => None,
        })
        .collect())
}

// The sides a merge reads, for a pull that settles inside one state transaction, as the CloudKit fetch does: a record
// held whole until the person decides merges as one new to the device, and the device's side has the base's value in
// each member that waits or was refused, so the merge never reads a value the device did not take as its own edit.
// The caller merges these, then passes the result to `gate`.
pub async fn merge_sides(
    txn: &mut dyn StateTxn,
    key: &RecordKey,
    kind: Kind,
    base: Option<&Value>,
    stored: Option<&Value>,
) -> Result<(Option<Value>, Option<Value>), SyncError> {
    if stored.is_none() && awaits(txn, key).await? {
        return Ok((None, None));
    }
    let held: BTreeSet<String> = rows_of(txn, key)
        .await?
        .into_iter()
        .filter(|row| row.decision != ApprovalDecision::Approved)
        .map(|row| row.field)
        .collect();
    let local = stored.map(|stored| super::local_view(kind, key.scope, stored, base, &held));
    Ok((base.cloned(), local))
}

// Whether the record is held whole until the person decides.
pub async fn awaits(txn: &mut dyn StateTxn, key: &RecordKey) -> Result<bool, SyncError> {
    Ok(matches!(
        txn.get(&RowKey::Held(key.clone())).await?,
        Some(Row::Held(held)) if held.reason == HeldReason::AwaitingApproval
    ))
}

// For a pull that settles inside one state transaction, as the CloudKit fetch does: called with the result of merging
// `merge_sides` before the store's copy is planned. A deletion clears the record's rows; a copy the device keeps as it is, as a
// contested deletion or an envelope sealed again, passes as it came.
pub async fn gate(
    txn: &mut dyn StateTxn,
    key: &RecordKey,
    kind: Kind,
    stored: Option<&Value>,
    merged: Merged,
) -> Result<Gated, SyncError> {
    let rows = rows_of(txn, key).await?;
    let fields = match &merged {
        Merged::Record(fields) | Merged::Contested { record: fields, .. } => fields,
        Merged::Deleted => {
            for row in rows {
                txn.delete(&RowKey::Approval(row.key, row.field)).await?;
            }
            txn.delete(&RowKey::Held(key.clone())).await?;
            return Ok(Gated::Apply(merged));
        }
        Merged::DeletionContested { .. } | Merged::Reseal => return Ok(Gated::Apply(merged)),
    };
    let split = split(kind, key, stored, fields, &rows);
    write(txn, key, &split).await?;
    if split.hold {
        return Ok(Gated::Hold);
    }
    // A record that waited whole and now goes in is no longer held, so no later decision writes the held copy over it.
    if awaits(txn, key).await? {
        txn.delete(&RowKey::Held(key.clone())).await?;
    }
    Ok(Gated::Apply(match merged {
        Merged::Contested { fields, .. } => Merged::Contested {
            record: split.fields,
            fields,
        },
        _ => Merged::Record(split.fields),
    }))
}

pub async fn write(txn: &mut dyn StateTxn, key: &RecordKey, split: &Split) -> Result<(), SyncError> {
    for field in &split.clear {
        txn.delete(&RowKey::Approval(key.clone(), field.clone())).await?;
    }
    for row in &split.put {
        txn.put(Row::Approval(row.clone())).await?;
    }
    Ok(())
}

// The members of each record the diff leaves at the base's value: waiting, or kept here after a rejection.
pub async fn held_members(
    txn: &mut dyn StateTxn,
    scope: ScopeName,
) -> Result<BTreeMap<(KindName, String), BTreeSet<String>>, SyncError> {
    let mut held: BTreeMap<(KindName, String), BTreeSet<String>> = BTreeMap::new();
    for row in txn.scan(&RowRange::Scope(Table::Approvals, scope)).await? {
        let Row::Approval(row) = row else { continue };
        if row.decision == ApprovalDecision::Approved {
            continue;
        }
        held.entry((row.key.kind, row.key.record_id))
            .or_default()
            .insert(row.field);
    }
    Ok(held)
}

// What the person calls a record: its name, else its settings category.
fn display_name(fields: &Value) -> Option<String> {
    ["name", "category"]
        .into_iter()
        .find_map(|member| fields.get(member).and_then(Value::as_str))
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Tally {
    // Records with at least one value waiting.
    pub records: u32,
    // SHA-256 over every waiting value, so a listener hears of a change the count alone would hide.
    pub mark: [u8; 32],
}

// Over the rows the caller shows, in the state file's order.
pub fn tally<'a>(rows: impl Iterator<Item = &'a ApprovalRow>) -> Tally {
    let mut records = BTreeSet::new();
    let mut hasher = Sha256::new();
    for row in rows.filter(|row| row.decision == ApprovalDecision::Waiting) {
        for part in [
            row.key.scope.to_string().as_str(),
            row.key.kind.as_str(),
            row.key.record_id.as_str(),
            row.field.as_str(),
        ] {
            hasher.update(u64::try_from(part.len()).unwrap_or(u64::MAX).to_be_bytes());
            hasher.update(part.as_bytes());
        }
        hasher.update(approval_digest(&row.pulled));
        records.insert(&row.key);
    }
    Tally {
        records: u32::try_from(records.len()).unwrap_or(u32::MAX),
        mark: hasher.finalize().into(),
    }
}

// The store's copy of a record an approval waits on.
enum StoreCopy {
    Held(Value),
    Unreadable,
    Gone,
}

// The `legacy_mirror` item that holds an iCloud record's copy from before the pull that started its wait, which the
// downgrade mirror hands the previous stable while the wait lasts.
pub(crate) fn prior_item(key: &RecordKey) -> String {
    format!("{PRIOR}{}/{}", key.kind.as_str(), key.record_id)
}

pub(crate) const PRIOR: &str = "prior/";

// The person's side of the queue, over one state file and its stores.
pub struct Queue<'a> {
    pub state: &'a Arc<dyn StateStore>,
    pub adapters: &'a Adapters,
    // Checked before each store write and commit, so a provider stop keeps a decision out (P1-M4).
    pub fence: &'a dyn Fence,
}

impl Queue<'_> {
    fn adapter(&self, key: &RecordKey) -> Option<Arc<dyn RecordAdapter>> {
        let kind = key.kind.known()?;
        self.adapters
            .in_scope(key.scope)
            .into_iter()
            .find(|adapter| adapter.kind() == kind)
    }

    async fn stored(&self, key: &RecordKey) -> Result<Option<Value>, SyncError> {
        Ok(match self.copy(key).await? {
            StoreCopy::Held(fields) => Some(fields),
            StoreCopy::Unreadable | StoreCopy::Gone => None,
        })
    }

    // The store's copy a decision lands on, None when it holds none. One it holds but cannot read is still the
    // device's: no decision lands on it, and the rows wait until it reads again.
    async fn decided_copy(&self, key: &RecordKey) -> Result<Option<Value>, SyncError> {
        match self.copy(key).await? {
            StoreCopy::Held(fields) => Ok(Some(fields)),
            StoreCopy::Unreadable => Err(AdapterError::Unreadable {
                detail: "the record an approval waits on".to_owned(),
            }
            .into()),
            StoreCopy::Gone => Ok(None),
        }
    }

    async fn copy(&self, key: &RecordKey) -> Result<StoreCopy, SyncError> {
        let Some(adapter) = self.adapter(key) else {
            return Ok(StoreCopy::Gone);
        };
        let records = adapter.records(key.scope).await?;
        if records.unreadable.contains(&key.record_id) {
            return Ok(StoreCopy::Unreadable);
        }
        Ok(records
            .records
            .into_iter()
            .find(|record| record.record_id == key.record_id)
            .map_or(StoreCopy::Gone, |record| StoreCopy::Held(record.fields)))
    }

    // One entry per record with a value waiting, its values in the state file's order, which `decide_record` reads
    // them in too.
    pub async fn waiting(&self) -> Result<Vec<RecordApproval>, SyncError> {
        let mut txn = self.state.begin().await?;
        let rows = txn.scan(&RowRange::Table(Table::Approvals)).await?;
        let mut grouped: BTreeMap<RecordKey, Vec<ApprovalRow>> = BTreeMap::new();
        for row in rows {
            let Row::Approval(row) = row else { continue };
            if row.decision == ApprovalDecision::Waiting {
                grouped.entry(row.key.clone()).or_default().push(row);
            }
        }
        let mut pulled_copies = BTreeMap::new();
        for key in grouped.keys() {
            if let Some(Row::Held(held)) = txn.get(&RowKey::Held(key.clone())).await?
                && held.reason == HeldReason::AwaitingApproval
            {
                pulled_copies.insert(key.clone(), held.record.fields);
            }
        }
        drop(txn);
        let mut out = Vec::new();
        for (key, rows) in grouped {
            let stored = self.stored(&key).await?;
            let held = pulled_copies.remove(&key);
            let fields: Vec<PendingApproval> = rows
                .into_iter()
                .map(|row| PendingApproval {
                    current: get(stored.as_ref(), &row.field).cloned(),
                    digest: approval_digest(&row.pulled),
                    field: row.field,
                    pulled: row.pulled,
                })
                .collect();
            let name = stored
                .as_ref()
                .or(held.as_ref().and_then(Option::as_ref))
                .and_then(display_name);
            out.push(RecordApproval {
                new_record: held.is_some() && stored.is_none(),
                digest: record_approval_digest(&fields),
                key,
                name,
                fields,
            });
        }
        Ok(out)
    }

    // `seen` names the value the person was shown. A pull that changed it since leaves nothing decided, and the person
    // is asked about the new value (0066, Rules).
    pub async fn decide(&self, key: &RecordKey, field: &str, seen: [u8; 32], approve: bool) -> Result<(), SyncError> {
        let mut txn = self.state.begin().await?;
        let Some(Row::Approval(row)) = txn.get(&RowKey::Approval(key.clone(), field.to_owned())).await? else {
            return Err(SyncError::Unknown { what: "approval" });
        };
        if approval_digest(&row.pulled) != seen {
            return Err(SyncError::Changed { what: "approval" });
        }
        drop(txn);
        self.decide_rows(key, vec![row], approve).await
    }

    // Every value of the record that waits, as `waiting` listed them under `seen`.
    pub async fn decide_record(&self, key: &RecordKey, seen: [u8; 32], approve: bool) -> Result<(), SyncError> {
        let mut txn = self.state.begin().await?;
        let rows: Vec<ApprovalRow> = rows_of(txn.as_mut(), key)
            .await?
            .into_iter()
            .filter(|row| row.decision == ApprovalDecision::Waiting)
            .collect();
        drop(txn);
        if rows.is_empty() {
            return Err(SyncError::Unknown { what: "approval" });
        }
        let listed: Vec<PendingApproval> = rows
            .iter()
            .map(|row| PendingApproval {
                field: row.field.clone(),
                pulled: row.pulled.clone(),
                digest: approval_digest(&row.pulled),
                current: None,
            })
            .collect();
        if record_approval_digest(&listed) != seen {
            return Err(SyncError::Changed { what: "approval" });
        }
        self.decide_rows(key, rows, approve).await
    }

    async fn decide_rows(&self, key: &RecordKey, rows: Vec<ApprovalRow>, approve: bool) -> Result<(), SyncError> {
        let mut txn = self.state.begin().await?;
        let held = match txn.get(&RowKey::Held(key.clone())).await? {
            Some(Row::Held(held)) if held.reason == HeldReason::AwaitingApproval => Some(held),
            _ => None,
        };
        drop(txn);
        let stored = self.decided_copy(key).await?;
        if let Some(held) = held {
            return self.decide_held(key, rows, held.record.fields, approve).await;
        }
        let adapter = self.adapter(key);
        let mut txn = self.state.begin().await?;
        match (stored, adapter) {
            (Some(mut fields), Some(adapter)) if approve => {
                for row in &rows {
                    set(&mut fields, &row.field, as_member(&row.pulled));
                }
                // The store first: a crash before the state commits leaves rows that a later pull clears.
                self.fence.check()?;
                adapter
                    .apply(
                        key.scope,
                        vec![LocalChange::Put {
                            record_id: key.record_id.clone(),
                            fields,
                        }],
                    )
                    .await?;
                for row in rows {
                    txn.delete(&RowKey::Approval(row.key, row.field)).await?;
                }
            }
            (Some(fields), Some(_)) => {
                for mut row in rows {
                    row.decision = ApprovalDecision::Rejected {
                        local: pulled_value(get(Some(&fields), &row.field)),
                    };
                    txn.put(Row::Approval(row)).await?;
                }
            }
            // The store no longer holds the record: nothing is left to decide.
            _ => {
                for row in rows {
                    txn.delete(&RowKey::Approval(row.key, row.field)).await?;
                }
            }
        }
        // The wait ends with its last approved member, and the copy from before it with it, so a later wait keeps its
        // own.
        if rows_of(txn.as_mut(), key)
            .await?
            .iter()
            .all(|row| row.decision == ApprovalDecision::Approved)
        {
            txn.delete(&RowKey::LegacyMirror(prior_item(key))).await?;
        }
        self.fence.check()?;
        txn.commit().await?;
        Ok(())
    }

    // A record new to the device goes into the store once every member that waited is approved. A refusal keeps the
    // whole record off this device, the only value it had of it. The decisions commit before the store write, so a
    // crash between them lands the record on the next pass without asking again (`finish_decided`).
    async fn decide_held(
        &self,
        key: &RecordKey,
        decided: Vec<ApprovalRow>,
        pulled: Option<Value>,
        approve: bool,
    ) -> Result<(), SyncError> {
        let mut txn = self.state.begin().await?;
        for mut row in decided {
            row.decision = if approve {
                ApprovalDecision::Approved
            } else {
                ApprovalDecision::Rejected { local: Value::Null }
            };
            txn.put(Row::Approval(row)).await?;
        }
        let rows = rows_of(txn.as_mut(), key).await?;
        self.fence.check()?;
        txn.commit().await?;
        if rows.iter().all(|row| row.decision == ApprovalDecision::Approved) {
            self.apply_held(key, pulled, rows).await?;
        }
        Ok(())
    }

    async fn apply_held(
        &self,
        key: &RecordKey,
        pulled: Option<Value>,
        rows: Vec<ApprovalRow>,
    ) -> Result<(), SyncError> {
        let key = key.clone();
        let (Some(pulled), Some(adapter), Some(kind)) = (pulled, self.adapter(&key), key.kind.known()) else {
            return Ok(());
        };
        // A copy the store cannot read took the id meanwhile, as a restored file can: the record stays held with its
        // decisions, and goes in once the copy reads again.
        if matches!(self.copy(&key).await?, StoreCopy::Unreadable) {
            return Ok(());
        }
        let split = split(kind, &key, None, &pulled, &rows);
        if split.hold {
            let mut txn = self.state.begin().await?;
            write(txn.as_mut(), &key, &split).await?;
            self.fence.check()?;
            txn.commit().await?;
            return Ok(());
        }
        self.fence.check()?;
        adapter
            .apply(
                key.scope,
                vec![LocalChange::Put {
                    record_id: key.record_id.clone(),
                    fields: split.fields,
                }],
            )
            .await?;
        let mut txn = self.state.begin().await?;
        for row in rows {
            txn.delete(&RowKey::Approval(row.key, row.field)).await?;
        }
        txn.delete(&RowKey::Held(key)).await?;
        self.fence.check()?;
        txn.commit().await?;
        Ok(())
    }

    // A record new to the device whose every waiting member the person approved, which a crash left out of the store:
    // it goes in now, before the pass reads the stores.
    pub async fn finish_decided(&self) -> Result<(), SyncError> {
        let mut txn = self.state.begin().await?;
        let held = txn.scan(&RowRange::Table(Table::Held)).await?;
        let mut ready = Vec::new();
        for row in held {
            let Row::Held(held) = row else { continue };
            if held.reason != HeldReason::AwaitingApproval {
                continue;
            }
            let rows = rows_of(txn.as_mut(), &held.key).await?;
            if !rows.is_empty() && rows.iter().all(|row| row.decision == ApprovalDecision::Approved) {
                ready.push((held, rows));
            }
        }
        drop(txn);
        for (held, rows) in ready {
            self.apply_held(&held.key, held.record.fields, rows).await?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn key() -> RecordKey {
        RecordKey::new(ScopeName::Personal, Kind::Connection, "C1")
    }

    fn waiting(field: &str, pulled: Value) -> ApprovalRow {
        ApprovalRow {
            key: key(),
            field: field.to_owned(),
            pulled,
            decision: ApprovalDecision::Waiting,
        }
    }

    #[test]
    fn a_pulled_host_waits_and_the_store_keeps_its_own() {
        let stored = json!({"name": "Prod", "host": "db.internal"});
        let merged = json!({"name": "Prod 2", "host": "evil.example.com"});

        let split = split(Kind::Connection, &key(), Some(&stored), &merged, &[]);

        assert_eq!(split.fields, json!({"name": "Prod 2", "host": "db.internal"}));
        assert_eq!(split.put, vec![waiting("/host", json!("evil.example.com"))]);
        assert!(!split.hold);
    }

    #[test]
    fn a_stricter_value_applies_and_a_looser_one_waits() {
        let stored = json!({"safe_mode_level": "alert", "ai_policy": "askEachTime"});
        let merged = json!({"safe_mode_level": "readOnly", "ai_policy": "alwaysAllow"});

        let split = split(Kind::Connection, &key(), Some(&stored), &merged, &[]);

        assert_eq!(
            split.fields,
            json!({"safe_mode_level": "readOnly", "ai_policy": "askEachTime"})
        );
        assert_eq!(split.put, vec![waiting("/ai_policy", json!("alwaysAllow"))]);
    }

    #[test]
    fn a_value_already_in_the_store_asks_nothing() {
        let stored = json!({"host": "db", "startup_commands": "SET x = 1"});

        let split = split(Kind::Connection, &key(), Some(&stored), &stored, &[]);

        assert_eq!(split.fields, stored);
        assert!(split.put.is_empty() && split.clear.is_empty());
    }

    #[test]
    fn a_rejected_value_pulled_again_stays_refused_and_a_new_one_asks_again() {
        let stored = json!({"host": "mine"});
        let rejected = ApprovalRow {
            decision: ApprovalDecision::Rejected { local: json!("mine") },
            ..waiting("/host", json!("theirs"))
        };

        let same = split(
            Kind::Connection,
            &key(),
            Some(&stored),
            &json!({"host": "theirs"}),
            std::slice::from_ref(&rejected),
        );
        let newer = split(
            Kind::Connection,
            &key(),
            Some(&stored),
            &json!({"host": "newer"}),
            &[rejected],
        );

        assert_eq!(same.fields, stored);
        assert!(same.put.is_empty() && same.clear.is_empty());
        assert_eq!(newer.fields, stored);
        assert_eq!(newer.put, vec![waiting("/host", json!("newer"))]);
    }

    #[test]
    fn a_pull_that_agrees_with_the_store_clears_the_row() {
        let stored = json!({"host": "db"});

        let split = split(
            Kind::Connection,
            &key(),
            Some(&stored),
            &stored,
            &[waiting("/host", json!("other"))],
        );

        assert_eq!(split.clear, vec!["/host".to_owned()]);
    }

    #[test]
    fn a_new_record_with_a_member_waiting_is_held_whole() {
        let merged = json!({"name": "New", "host": "db", "safe_mode_level": "readOnly"});

        let split = split(Kind::Connection, &key(), None, &merged, &[]);

        assert!(split.hold);
        assert_eq!(split.put, vec![waiting("/host", json!("db"))]);
    }

    #[test]
    fn a_new_record_whose_members_were_approved_goes_in() {
        let merged = json!({"name": "New", "host": "db"});
        let approved = ApprovalRow {
            decision: ApprovalDecision::Approved,
            ..waiting("/host", json!("db"))
        };

        let split = split(Kind::Connection, &key(), None, &merged, &[approved]);

        assert!(!split.hold);
        assert_eq!(split.fields, merged);
    }

    #[test]
    fn another_value_for_a_refused_new_record_asks_about_every_value_of_it_again() {
        let refused = |field: &str, pulled: Value| ApprovalRow {
            decision: ApprovalDecision::Rejected { local: Value::Null },
            ..waiting(field, pulled)
        };
        let rows = [refused("/host", json!("db")), refused("/port", json!(5432))];

        let same = split(
            Kind::Connection,
            &key(),
            None,
            &json!({"name": "New", "host": "db", "port": 5432}),
            &rows,
        );
        let moved = split(
            Kind::Connection,
            &key(),
            None,
            &json!({"name": "New", "host": "db2", "port": 5432}),
            &rows,
        );

        assert!(same.hold && same.put.is_empty());
        assert!(moved.hold);
        assert_eq!(
            moved.put,
            vec![waiting("/host", json!("db2")), waiting("/port", json!(5432))]
        );
    }

    // 0056's secrets travel only as envelopes, so no kind's wire schema names one at any depth, and a driver's secret
    // field a pull brings is never asked about or written, not even for a record new to the device.
    #[test]
    fn no_secret_ever_waits_for_the_person() {
        use tablepro_records::schema::{paths, schema};

        let secrets = [
            "password",
            "ssl_key_passphrase",
            "ssh_password",
            "ssh_key_passphrase",
            "ssh_totp_secret",
            "ai_key",
        ];
        for kind in Kind::ALL {
            for path in paths(schema(kind).fields) {
                let leaf = path.rsplit('.').next().unwrap_or_default();
                assert!(!secrets.contains(&leaf), "{kind:?} names {path}");
            }
        }
        let merged = json!({"name": "Lake", "additional_fields": [
            {"id": "awsSecretAccessKey", "value": "hunter2"},
            {"id": "awsRegion", "value": "eu-west-1"}
        ]});

        let split = split(Kind::Connection, &key(), None, &merged, &[]);

        assert!(split.put.iter().all(|row| !row.field.contains("awsSecretAccessKey")));
        assert!(split.put.iter().all(|row| row.pulled != json!("hunter2")));
        assert!(!split.fields.to_string().contains("hunter2"));
    }

    #[test]
    fn device_only_members_never_come_from_a_pull() {
        let stored = json!({"name": "Prod", "local_only": false});
        let merged = json!({"name": "Prod", "local_only": true, "is_sample": true});

        let split = split(Kind::Connection, &key(), Some(&stored), &merged, &[]);

        assert_eq!(split.fields, stored);
    }

    #[test]
    fn the_ai_options_0061_adds_wait_inside_a_settings_record() {
        let key = RecordKey::new(ScopeName::Personal, Kind::MacosSettings, "ai");
        let stored = json!({"category": "ai", "options": {
            "chatMode": "ask", "maxToolRoundtrips": 5, "inlineSuggestionDebounceMs": 100
        }});
        let merged = json!({"category": "ai", "options": {
            "chatMode": "agent", "maxToolRoundtrips": 50, "inlineSuggestionDebounceMs": 300,
            "telemetryEnabled": true
        }});

        let split = split(Kind::MacosSettings, &key, Some(&stored), &merged, &[]);

        assert_eq!(
            split.fields,
            json!({"category": "ai", "options": {
                "chatMode": "ask", "maxToolRoundtrips": 5, "inlineSuggestionDebounceMs": 300
            }})
        );
        let fields: Vec<&str> = split.put.iter().map(|row| row.field.as_str()).collect();
        assert_eq!(
            fields,
            [
                "/options/chatMode",
                "/options/maxToolRoundtrips",
                "/options/telemetryEnabled"
            ]
        );
    }
}
