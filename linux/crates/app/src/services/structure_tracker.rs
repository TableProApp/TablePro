//! Passive per-tab DDL ops cache for the Structure workspace tab.
//!
//! StructureTab now owns the canonical source of truth for pending
//! changes — it computes them on every edit by diffing the loaded
//! snapshot against the live model (`sql_ddl::diff_to_ops`). On each
//! recompute the tab calls [`with_tab`] to overwrite this cache so
//! out-of-band callers (close-with-pending dialog, save-by-id, the
//! window-close prompt) can ask whether a tab is dirty and emit its
//! current SQL without coupling to the tab's UI internals.
//!
//! There is no undo / redo machinery here — DDL undo is a session
//! concept (Discard reverts the model to the snapshot). Per-keystroke
//! op history is the wrong granularity for schema editing and was
//! removed in the Structure-Refactor batch.
//!
//! Threading: GTK main thread only. `RefCell` interior mutability.

use std::cell::RefCell;
use std::collections::HashMap;

use uuid::Uuid;

use tablepro_core::sql_ddl::{BuildDdlError, StructureOp, materialize_ops};

/// Per-tab cache. Holds the current pending-op list emitted by the
/// tab's diff. `materialize` re-runs SQL emission on demand; the
/// cache means out-of-band callers don't have to re-derive ops from
/// the tab's model.
#[derive(Debug, Default)]
pub struct StructureChangeTracker {
    ops: Vec<StructureOp>,
}

impl StructureChangeTracker {
    pub fn has_pending(&self) -> bool {
        !self.ops.is_empty()
    }

    pub fn ops(&self) -> &[StructureOp] {
        &self.ops
    }

    /// Replace the cached op list. Called by StructureTab on every
    /// model mutation; the tab is the source of truth for what ops
    /// the diff currently produces.
    pub fn set_ops(&mut self, ops: Vec<StructureOp>) {
        self.ops = ops;
    }

    pub fn clear(&mut self) {
        self.ops.clear();
    }

    pub fn materialize(&self, driver_id: &str) -> Result<Vec<String>, BuildDdlError> {
        materialize_ops(&self.ops, driver_id)
    }
}

#[derive(Debug, Default)]
pub struct StructureTrackerRegistry {
    trackers: HashMap<Uuid, StructureChangeTracker>,
}

impl StructureTrackerRegistry {
    pub fn open_tab(&mut self, tab_id: Uuid) {
        self.trackers.entry(tab_id).or_default();
    }

    pub fn close_tab(&mut self, tab_id: Uuid) {
        self.trackers.remove(&tab_id);
    }

    pub fn with_tab<F, R>(&mut self, tab_id: Uuid, f: F) -> R
    where
        F: FnOnce(&mut StructureChangeTracker) -> R,
    {
        f(self.trackers.entry(tab_id).or_default())
    }

    pub fn with_tab_ref<F, R>(&self, tab_id: Uuid, f: F) -> Option<R>
    where
        F: FnOnce(&StructureChangeTracker) -> R,
    {
        self.trackers.get(&tab_id).map(f)
    }

    pub fn any_pending_globally(&self) -> bool {
        self.trackers.values().any(|t| t.has_pending())
    }

    pub fn pending_tabs(&self) -> Vec<Uuid> {
        self.trackers
            .iter()
            .filter_map(|(id, t)| if t.has_pending() { Some(*id) } else { None })
            .collect()
    }
}

thread_local! {
    static REGISTRY: RefCell<StructureTrackerRegistry> = RefCell::new(StructureTrackerRegistry::default());
}

pub fn open_tab(tab_id: Uuid) {
    REGISTRY.with(|r| r.borrow_mut().open_tab(tab_id));
}

pub fn close_tab(tab_id: Uuid) {
    REGISTRY.with(|r| r.borrow_mut().close_tab(tab_id));
}

pub fn with_tab<F, R>(tab_id: Uuid, f: F) -> R
where
    F: FnOnce(&mut StructureChangeTracker) -> R,
{
    REGISTRY.with(|r| r.borrow_mut().with_tab(tab_id, f))
}

pub fn with_tab_ref<F, R>(tab_id: Uuid, f: F) -> Option<R>
where
    F: FnOnce(&StructureChangeTracker) -> R,
{
    REGISTRY.with(|r| r.borrow().with_tab_ref(tab_id, f))
}

pub fn any_pending_globally() -> bool {
    REGISTRY.with(|r| r.borrow().any_pending_globally())
}

pub fn pending_tabs() -> Vec<Uuid> {
    REGISTRY.with(|r| r.borrow().pending_tabs())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::sql_ddl::DraftColumn;

    fn dc(name: &str, ty: &str) -> DraftColumn {
        DraftColumn {
            original: None,
            name: name.into(),
            data_type: ty.into(),
            nullable: true,
            primary_key: false,
            auto_increment: false,
            default_value: None,
        }
    }

    #[test]
    fn empty_tracker_has_no_pending() {
        let t = StructureChangeTracker::default();
        assert!(!t.has_pending());
        assert_eq!(t.ops().len(), 0);
    }

    #[test]
    fn set_ops_replaces_cache() {
        let mut t = StructureChangeTracker::default();
        t.set_ops(vec![StructureOp::AddColumn {
            schema: None,
            table: "t".into(),
            column: dc("a", "int"),
        }]);
        assert!(t.has_pending());
        assert_eq!(t.ops().len(), 1);
        t.set_ops(vec![]);
        assert!(!t.has_pending());
    }

    #[test]
    fn materialize_emits_sql() {
        let mut t = StructureChangeTracker::default();
        t.set_ops(vec![StructureOp::AddColumn {
            schema: None,
            table: "t".into(),
            column: dc("a", "int"),
        }]);
        let sql = t.materialize("postgres").unwrap();
        assert_eq!(sql.len(), 1);
        assert!(sql[0].contains("ALTER TABLE"));
    }

    #[test]
    fn registry_isolates_per_tab() {
        let mut r = StructureTrackerRegistry::default();
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        r.with_tab(a, |t| {
            t.set_ops(vec![StructureOp::AddColumn {
                schema: None,
                table: "t".into(),
                column: dc("a", "int"),
            }])
        });
        assert!(r.with_tab_ref(a, |t| t.has_pending()).unwrap());
        assert!(!r.with_tab_ref(b, |t| t.has_pending()).unwrap_or(false));
        assert_eq!(r.pending_tabs(), vec![a]);
        r.close_tab(a);
        assert!(!r.any_pending_globally());
    }
}
