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
use tablepro_records::Kind;
use tablepro_records::merge::Merged;

use super::carry::holds;
use super::fields::{Rule, get, members, set};
use crate::api::adapter::{LocalChange, RecordAdapter};
use crate::api::control::{PendingApproval, approval_digest};
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

// The store's copy of a record an approval waits on.
enum StoreCopy {
    Held(Value),
    Unreadable,
    Gone,
}

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

    pub async fn waiting(&self) -> Result<Vec<PendingApproval>, SyncError> {
        let mut txn = self.state.begin().await?;
        let rows = txn.scan(&RowRange::Table(Table::Approvals)).await?;
        drop(txn);
        let mut out = Vec::new();
        let mut copies: BTreeMap<RecordKey, Option<Value>> = BTreeMap::new();
        for row in rows {
            let Row::Approval(row) = row else { continue };
            if row.decision != ApprovalDecision::Waiting {
                continue;
            }
            if !copies.contains_key(&row.key) {
                let copy = self.stored(&row.key).await?;
                copies.insert(row.key.clone(), copy);
            }
            let current = copies
                .get(&row.key)
                .and_then(|copy| get(copy.as_ref(), &row.field))
                .cloned();
            out.push(PendingApproval {
                key: row.key,
                field: row.field,
                digest: approval_digest(&row.pulled),
                pulled: row.pulled,
                current,
            });
        }
        Ok(out)
    }

    // `seen` names the value the person was shown. A pull that changed it since leaves nothing decided, and the person
    // is asked about the new value (0066, Rules).
    pub async fn decide(&self, key: &RecordKey, field: &str, seen: [u8; 32], approve: bool) -> Result<(), SyncError> {
        let mut txn = self.state.begin().await?;
        let Some(Row::Approval(mut row)) = txn.get(&RowKey::Approval(key.clone(), field.to_owned())).await? else {
            return Err(SyncError::Unknown { what: "approval" });
        };
        if approval_digest(&row.pulled) != seen {
            return Err(SyncError::Changed { what: "approval" });
        }
        let held = match txn.get(&RowKey::Held(key.clone())).await? {
            Some(Row::Held(held)) if held.reason == HeldReason::AwaitingApproval => Some(held),
            _ => None,
        };
        drop(txn);
        let stored = self.decided_copy(key).await?;
        if let Some(held) = held {
            return self.decide_held(row, held.record.fields, approve).await;
        }
        let adapter = self.adapter(key);
        let mut txn = self.state.begin().await?;
        match (stored, adapter) {
            (Some(mut fields), Some(adapter)) if approve => {
                set(&mut fields, field, as_member(&row.pulled));
                // The store first: a crash before the state commits leaves a row that a later pull clears.
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
                txn.delete(&RowKey::Approval(key.clone(), field.to_owned())).await?;
            }
            (Some(fields), Some(_)) => {
                row.decision = ApprovalDecision::Rejected {
                    local: pulled_value(get(Some(&fields), field)),
                };
                txn.put(Row::Approval(row)).await?;
            }
            // The store no longer holds the record: nothing is left to decide.
            _ => txn.delete(&RowKey::Approval(key.clone(), field.to_owned())).await?,
        }
        self.fence.check()?;
        txn.commit().await?;
        Ok(())
    }

    // A record new to the device goes into the store once every member that waited is approved. A refusal keeps the
    // whole record off this device, the only value it had of it.
    async fn decide_held(&self, mut row: ApprovalRow, pulled: Option<Value>, approve: bool) -> Result<(), SyncError> {
        let key = row.key.clone();
        row.decision = if approve {
            ApprovalDecision::Approved
        } else {
            ApprovalDecision::Rejected { local: Value::Null }
        };
        let mut txn = self.state.begin().await?;
        txn.put(Row::Approval(row)).await?;
        let rows = rows_of(txn.as_mut(), &key).await?;
        self.fence.check()?;
        txn.commit().await?;
        if rows.iter().all(|row| row.decision == ApprovalDecision::Approved) {
            self.apply_held(&key, pulled, rows).await?;
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

    pub async fn count(&self) -> Result<u32, SyncError> {
        let mut txn = self.state.begin().await?;
        let rows = txn.scan(&RowRange::Table(Table::Approvals)).await?;
        let waiting = rows
            .iter()
            .filter(|row| matches!(row, Row::Approval(row) if row.decision == ApprovalDecision::Waiting))
            .count();
        Ok(u32::try_from(waiting).unwrap_or(u32::MAX))
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
