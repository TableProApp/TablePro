// What the server holds now, read from the bases the engine keeps for every record it pulled or pushed, judged
// against the server's lineage by 0051's lost-write rule: a base written in an epoch the server does not list is lost,
// and so is one written in a listed epoch above the kept revision of the epoch after it. A missing base is no
// evidence the server holds the object, so it counts as lacking: pushing an object the server holds again answers
// `applied` (0051, Push).

use std::collections::HashMap;

use tablepro_keys::record_id::KeyRecordId;

use super::plan::ServerView;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::scopes::{LineageEpoch, ScopesBody};
use crate::api::state::{BaseRow, Row, RowRange, StateTxn, Table};

#[derive(Debug, Default)]
pub(crate) struct Bases {
    rows: HashMap<(ScopeName, String, String), BaseRow>,
}

// A scope whose key objects have no base at all gives no view of the server: every object would read as lost, and an
// account set the server holds would go back with a recovery blob it deleted, which it refuses for good.
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
}

impl<'a> BaseView<'a> {
    pub(crate) fn new(body: &'a ScopesBody, bases: &'a Bases) -> Self {
        let lineages = body
            .scopes
            .iter()
            .map(|info| (info.scope, info.epochs.as_slice()))
            .collect();
        Self { lineages, bases }
    }
}

impl ServerView for BaseView<'_> {
    fn holds(&self, scope: ScopeName, id: &KeyRecordId) -> bool {
        let (Some(base), Some(lineage)) = (self.bases.get(scope, id), self.lineages.get(&scope)) else {
            return false;
        };
        survives(base, lineage)
    }

    fn judged(&self, scope: ScopeName, id: &KeyRecordId) -> bool {
        self.lineages.contains_key(&scope)
            && self
                .bases
                .get(scope, id)
                .is_some_and(|base| base.epoch.is_some() && base.revision.is_some())
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
