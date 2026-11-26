// Team conflicts (0044, Conflict rules; 0051, Conflict rules): a team record whose member both sides changed to
// different values, or a content edit against a deletion, waits for Keep Mine, Keep Theirs or Decide Later. Until then
// the store holds the agreed members with the server's value in each contested one, the device's own values wait in
// the `conflicts` row, and the diff leaves the record out. A later pull of the record is merged against the row, so
// Decide Later loses neither side.

use std::collections::BTreeSet;
use std::sync::Arc;

use serde_json::Value;
use tablepro_records::Kind;

use super::approval::{self, Split, split};
use crate::api::adapter::{LocalChange, LocalRecord, RecordAdapter};
use crate::api::control::{ConflictChoice, TeamConflict};
use crate::api::error::SyncError;
use crate::api::ids::RecordKey;
use crate::api::state::{
    ApprovalRow, BaseRow, ConflictRow, HeldReason, HeldRow, Row, RowKey, RowRange, StateStore, Table,
};
use crate::api::transport::PulledRecord;
use crate::engine::Adapters;

fn member<'a>(copy: Option<&'a Value>, name: &str) -> Option<&'a Value> {
    copy.and_then(|copy| copy.get(name))
}

fn names(copies: [Option<&Value>; 3]) -> BTreeSet<String> {
    copies
        .into_iter()
        .flatten()
        .filter_map(Value::as_object)
        .flat_map(|members| members.keys().cloned())
        .collect()
}

// A conflict over members, rather than an edit against a deletion.
fn over_members(row: &ConflictRow) -> bool {
    row.mine.is_some() && row.theirs.is_some()
}

// The members the person decides: changed on both sides to different values, or, against a deletion, changed on the
// side that kept the record.
pub fn contested(row: &ConflictRow) -> Vec<String> {
    let base = row.base.as_ref();
    let (mine, theirs) = (row.mine.as_ref(), row.theirs.as_ref());
    names([base, mine, theirs])
        .into_iter()
        .filter(|name| {
            let held = member(base, name);
            let (left, right) = (member(mine, name), member(theirs, name));
            if over_members(row) {
                left != held && right != held && left != right
            } else {
                left.or(right) != held
            }
        })
        .collect()
}

pub fn overlay(onto: &Value, from: Option<&Value>, names: &[String]) -> Value {
    let mut out = onto.clone();
    let Some(members) = out.as_object_mut() else {
        return out;
    };
    for name in names {
        match member(from, name) {
            Some(value) => {
                members.insert(name.clone(), value.clone());
            }
            None => {
                members.remove(name);
            }
        }
    }
    out
}

// What a pull of a record with an open conflict merges: the base it had before the conflict in the contested members,
// and the device's own values in them, beside the store's copy and the base for the rest.
pub fn sides(
    row: &ConflictRow,
    base: Option<&BaseRow>,
    stored: Option<&LocalRecord>,
) -> (Option<BaseRow>, Option<LocalRecord>) {
    if !over_members(row) {
        let base = base.map(|base| BaseRow {
            deleted: None,
            fields: row.base.clone(),
            ..base.clone()
        });
        return (base, stored.cloned());
    }
    let names = contested(row);
    let base = base.map(|base| BaseRow {
        fields: base
            .fields
            .as_ref()
            .map(|fields| overlay(fields, row.base.as_ref(), &names)),
        ..base.clone()
    });
    let stored = stored.map(|stored| LocalRecord {
        fields: overlay(&stored.fields, row.mine.as_ref(), &names),
        ..stored.clone()
    });
    (base, stored)
}

pub struct Conflicts<'a> {
    pub state: &'a Arc<dyn StateStore>,
    pub adapters: &'a Adapters,
}

impl Conflicts<'_> {
    pub async fn open(&self) -> Result<Vec<TeamConflict>, SyncError> {
        let mut txn = self.state.begin().await?;
        let rows = txn.scan(&RowRange::Table(Table::Conflicts)).await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| match row {
                Row::Conflict(row) => Some(TeamConflict {
                    fields: contested(&row),
                    key: row.key,
                    mine: row.mine,
                    theirs: row.theirs,
                }),
                _ => None,
            })
            .collect())
    }

    fn adapter(&self, key: &RecordKey) -> Option<Arc<dyn RecordAdapter>> {
        let kind = key.kind.known()?;
        self.adapters
            .in_scope(key.scope)
            .into_iter()
            .find(|adapter| adapter.kind() == kind)
    }

    // The store takes the side the person kept; the diff then sends Keep Mine on the stored tag, and Keep Theirs
    // leaves nothing to send. What the server holds still goes through the approval queue.
    pub async fn resolve(&self, key: &RecordKey, keep: ConflictChoice) -> Result<(), SyncError> {
        let mut txn = self.state.begin().await?;
        let Some(Row::Conflict(row)) = txn.get(&RowKey::Conflict(key.clone())).await? else {
            return Err(SyncError::Unknown { what: "conflict" });
        };
        let rows = approval::rows_of(txn.as_mut(), key).await?;
        drop(txn);
        let (Some(adapter), Some(kind)) = (self.adapter(key), key.kind.known()) else {
            return Err(SyncError::Unknown { what: "conflict" });
        };
        let stored = adapter
            .records(key.scope)
            .await?
            .records
            .into_iter()
            .find(|record| record.record_id == key.record_id)
            .map(|record| record.fields);
        let outcome = outcome(&row, &rows, kind, key, stored.as_ref(), keep);
        match &outcome {
            Outcome::Delete if stored.is_some() => {
                adapter
                    .apply(
                        key.scope,
                        vec![LocalChange::Delete {
                            record_id: key.record_id.clone(),
                        }],
                    )
                    .await?;
            }
            Outcome::Put(fields, _) if stored.as_ref() != Some(fields) => {
                adapter
                    .apply(
                        key.scope,
                        vec![LocalChange::Put {
                            record_id: key.record_id.clone(),
                            fields: fields.clone(),
                        }],
                    )
                    .await?;
            }
            _ => {}
        }
        let mut txn = self.state.begin().await?;
        if let Outcome::Put(_, Some(split)) = &outcome {
            approval::write(txn.as_mut(), key, split).await?;
        }
        if let Outcome::Hold(split, fields) = outcome {
            approval::write(txn.as_mut(), key, &split).await?;
            let tag = base_tag(txn.as_mut(), key).await?;
            txn.put(Row::Held(HeldRow {
                key: key.clone(),
                reason: HeldReason::AwaitingApproval,
                record: PulledRecord {
                    kind: key.kind.clone(),
                    record_id: key.record_id.clone(),
                    tag,
                    fields: Some(fields),
                    fields_json: None,
                    deleted: None,
                    service: None,
                },
            }))
            .await?;
        }
        txn.delete(&RowKey::Conflict(key.clone())).await?;
        txn.commit().await?;
        Ok(())
    }
}

// What the store takes for the side the person kept.
fn outcome(
    row: &ConflictRow,
    rows: &[ApprovalRow],
    kind: Kind,
    key: &RecordKey,
    stored: Option<&Value>,
    keep: ConflictChoice,
) -> Outcome {
    let kept = match keep {
        ConflictChoice::KeepMine => row.mine.as_ref(),
        ConflictChoice::KeepTheirs => row.theirs.as_ref(),
    };
    let wanted = match (over_members(row), stored, kept) {
        (true, Some(stored), Some(_)) => Some(overlay(stored, kept, &contested(row))),
        (_, _, kept) => kept.cloned(),
    };
    match (wanted, keep) {
        (None, _) => Outcome::Delete,
        // The person chose the device's values, so what waited for approval in the contested members, or in a
        // record kept against a deletion, goes; their own values go up.
        (Some(fields), ConflictChoice::KeepMine) => {
            let names = contested(row);
            let decided = |field: &str| {
                !over_members(row)
                    || names.iter().any(|name| {
                        let pointer = format!("/{}", name.replace('~', "~0").replace('/', "~1"));
                        field == pointer || field.starts_with(&format!("{pointer}/"))
                    })
            };
            let cleared = Split {
                clear: rows
                    .iter()
                    .filter(|row| decided(&row.field))
                    .map(|row| row.field.clone())
                    .collect(),
                ..Split::default()
            };
            Outcome::Put(fields, Some(cleared))
        }
        (Some(fields), ConflictChoice::KeepTheirs) => {
            let split = split(kind, key, stored, &fields, rows);
            if split.hold {
                Outcome::Hold(split, fields)
            } else {
                Outcome::Put(split.fields.clone(), Some(split))
            }
        }
    }
}

enum Outcome {
    Delete,
    // With the approval rows the server's side leaves.
    Put(Value, Option<Split>),
    // What the server holds of a record the store lacks waits whole.
    Hold(Split, Value),
}

async fn base_tag(
    txn: &mut dyn crate::api::state::StateTxn,
    key: &RecordKey,
) -> Result<crate::api::ids::ChangeTag, SyncError> {
    Ok(match txn.get(&RowKey::Base(key.clone())).await? {
        Some(Row::Base(base)) => base.tag,
        _ => crate::api::ids::ChangeTag::Service(String::new()),
    })
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use tablepro_records::Kind;

    use super::*;
    use crate::api::ids::{ChangeTag, ScopeName};

    fn key() -> RecordKey {
        RecordKey::new(
            ScopeName::Team(tablepro_keys::encoding::TeamId(uuid::Uuid::from_u128(3))),
            Kind::LibraryQuery,
            "q1",
        )
    }

    fn row(base: Value, mine: Option<Value>, theirs: Option<Value>) -> ConflictRow {
        ConflictRow {
            key: key(),
            base: Some(base),
            mine,
            theirs,
        }
    }

    #[test]
    fn only_members_both_sides_changed_differently_are_contested() {
        let conflict = row(
            json!({"name": "a", "query": "q", "sort_order": 1}),
            Some(json!({"name": "mine", "query": "same", "sort_order": 1})),
            Some(json!({"name": "theirs", "query": "same", "sort_order": 2})),
        );

        assert_eq!(contested(&conflict), ["name"]);
    }

    #[test]
    fn against_a_deletion_the_edited_members_are_listed() {
        let conflict = row(
            json!({"name": "a", "query": "q"}),
            Some(json!({"name": "a", "query": "q2"})),
            None,
        );

        assert_eq!(contested(&conflict), ["query"]);
    }

    #[test]
    fn a_later_pull_merges_against_the_open_conflict() {
        let conflict = row(
            json!({"name": "a", "query": "q"}),
            Some(json!({"name": "mine", "query": "q"})),
            Some(json!({"name": "theirs", "query": "q"})),
        );
        let base = BaseRow {
            key: key(),
            tag: ChangeTag::Service("t1".to_owned()),
            version: Some(2),
            revision: Some(2),
            epoch: None,
            deleted: None,
            fields: Some(json!({"name": "theirs", "query": "q"})),
            created_ms: None,
        };
        let stored = LocalRecord {
            record_id: "q1".to_owned(),
            fields: json!({"name": "theirs", "query": "q", "keyword": "k"}),
            standing: crate::api::state::Standing::Syncs,
        };

        let (base, stored) = sides(&conflict, Some(&base), Some(&stored));

        assert_eq!(base.unwrap().fields, Some(json!({"name": "a", "query": "q"})));
        assert_eq!(
            stored.unwrap().fields,
            json!({"name": "mine", "query": "q", "keyword": "k"})
        );
    }
}
