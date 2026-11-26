// What the server holds now, read from the bases the engine keeps for every record it pulled or pushed, judged
// against the server's lineage by 0051's lost-write rule: a base written in an epoch the server does not list is lost,
// and so is one written in a listed epoch above the kept revision of the epoch after it. A missing base is no
// evidence the server holds the object, so it counts as lacking: pushing an object the server holds again answers
// `applied` (0051, Push).

use std::collections::HashMap;

use serde_json::Value;

use tablepro_keys::record_id::KeyRecordId;

use super::plan::ServerView;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::scopes::{LineageEpoch, ScopesBody};
use crate::api::state::{BaseRow, Row, RowRange, StateTxn, Table};
use crate::keys::HeldObject;

#[derive(Debug, Default)]
pub(crate) struct Bases {
    rows: HashMap<(ScopeName, String, String), BaseRow>,
}

// A personal scope whose key objects have no base at all gives no view of the server: every account set would read as
// lost and go back. A team needs no such guard: a team object read as lacking goes back as `applied`, or stops the team.
pub(crate) fn has_view(bases: &Bases, scope: ScopeName) -> bool {
    bases.rows.keys().any(|(of, ..)| *of == scope)
}

impl Bases {
    pub(crate) async fn load(&mut self, txn: &mut dyn StateTxn, scope: ScopeName) -> Result<(), SyncError> {
        for row in txn.scan(&RowRange::Scope(Table::Bases, scope)).await? {
            if let Row::Base(base) = row
                && base.key.kind.is_key()
            {
                let key = (scope, base.key.kind.as_str().to_owned(), base.key.record_id.clone());
                self.rows.insert(key, base);
            }
        }
        Ok(())
    }

    fn get(&self, scope: ScopeName, id: &KeyRecordId) -> Option<&BaseRow> {
        self.rows.get(&(scope, id.kind().name().to_owned(), id.to_wire()))
    }
}

pub(crate) struct BaseView<'a> {
    lineages: HashMap<ScopeName, &'a [LineageEpoch]>,
    bases: &'a Bases,
    // The fields of each key object this device holds, by scope and wire id.
    held: HashMap<(ScopeName, String), Value>,
}

impl<'a> BaseView<'a> {
    pub(crate) fn new(body: &'a ScopesBody, bases: &'a Bases, held: &[(ScopeName, &HeldObject)]) -> Self {
        let lineages = body
            .scopes
            .iter()
            .map(|info| (info.scope, info.epochs.as_slice()))
            .collect();
        let held = held
            .iter()
            .filter_map(|(scope, object)| {
                let fields = serde_json::from_str(&object.fields).ok()?;
                Some(((*scope, wire(&object.object.id)), fields))
            })
            .collect();
        Self { lineages, bases, held }
    }

    // The base the server holds now at the id, the lost-write rule applied.
    fn surviving(&self, scope: ScopeName, id: &KeyRecordId) -> Option<&BaseRow> {
        let (base, lineage) = (self.bases.get(scope, id)?, self.lineages.get(&scope)?);
        survives(base, lineage).then_some(base)
    }

    // Whether the server's copy is another record than the one this device holds at the id.
    fn other_record(&self, scope: ScopeName, id: &KeyRecordId, base: &BaseRow) -> bool {
        match (&base.fields, self.held.get(&(scope, wire(id)))) {
            (Some(served), Some(held)) => served != held,
            _ => false,
        }
    }
}

fn wire(id: &KeyRecordId) -> String {
    format!("{}\u{0}{}", id.kind().name(), id.to_wire())
}

impl ServerView for BaseView<'_> {
    // Held only as the same record this device holds: another one at the id is no copy of it (0051, What cannot go
    // back).
    fn holds(&self, scope: ScopeName, id: &KeyRecordId) -> bool {
        self.surviving(scope, id)
            .is_some_and(|base| !self.other_record(scope, id, base))
    }

    fn holds_another(&self, scope: ScopeName, id: &KeyRecordId) -> bool {
        self.surviving(scope, id)
            .is_some_and(|base| self.other_record(scope, id, base))
    }
}

pub(crate) fn survives(base: &BaseRow, lineage: &[LineageEpoch]) -> bool {
    let (Some(epoch), Some(revision), None) = (base.epoch, base.revision, base.deleted) else {
        return false;
    };
    let Some(at) = lineage.iter().position(|listed| listed.id == epoch) else {
        return false;
    };
    lineage.get(at + 1).is_none_or(|next| revision <= next.kept_revision)
}
