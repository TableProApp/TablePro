//! Per-tab DDL changeset tracker for the Structure workspace tab.
//!
//! Mirrors the architecture of `change_tracker.rs` (thread-local
//! registry keyed by tab UUID, subscription channel, undo / redo
//! stacks) but operates at the schema-operation level instead of the
//! row-data level. Row DML and DDL have fundamentally different
//! shapes (DML keys by RowKey + cell coords; DDL keys by table /
//! column name) and trying to share the abstraction would force
//! both sides into an awkward generic shell. Two parallel modules
//! is cleaner.
//!
//! Threading: GTK main thread only (relm4 contract). `RefCell`
//! interior mutability rather than `Mutex`. Tests construct fresh
//! `StructureTrackerRegistry::new()` instances to avoid contaminating
//! each other through the thread-local global.

#![allow(dead_code)]

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};

use uuid::Uuid;

use tablepro_core::sql_ddl::{
    BuildDdlError, DraftColumn, build_add_column, build_add_foreign_key, build_alter_column, build_create_index,
    build_create_table, build_drop_column, build_drop_foreign_key, build_drop_index, build_rename_column,
    build_rename_table, build_reorder_column,
};
use tablepro_core::{ForeignKeyInfo, IndexInfo};

const UNDO_LIMIT: usize = 50;

/// One pending DDL operation. The tracker accumulates a `Vec<StructureOp>`
/// and `materialize` walks it to produce the ordered SQL strings
/// per driver dialect.
#[derive(Debug, Clone)]
pub enum StructureOp {
    /// Whole-table create. Used by `New` mode where there's exactly
    /// one CreateTable op rebuilt from the in-memory model on every
    /// edit. `Edit` mode never produces this variant.
    CreateTable {
        schema: Option<String>,
        table: String,
        columns: Vec<DraftColumn>,
        indexes: Vec<IndexInfo>,
        fks: Vec<ForeignKeyInfo>,
    },
    RenameTable {
        schema: Option<String>,
        old_name: String,
        new_name: String,
    },
    AddColumn {
        schema: Option<String>,
        table: String,
        column: DraftColumn,
    },
    DropColumn {
        schema: Option<String>,
        table: String,
        column_name: String,
    },
    RenameColumn {
        schema: Option<String>,
        table: String,
        old_name: String,
        new_name: String,
    },
    /// Single op for any combination of type / nullable / default
    /// changes on one column. Materialize groups all AlterColumn ops
    /// for the same column into one MODIFY COLUMN statement on
    /// MySQL; Postgres and SQLite emit per-attribute statements.
    AlterColumn {
        schema: Option<String>,
        table: String,
        column: DraftColumn,
    },
    /// MySQL-only. `after = None` means FIRST.
    ReorderColumn {
        schema: Option<String>,
        table: String,
        column: DraftColumn,
        after: Option<String>,
    },
    AddIndex {
        schema: Option<String>,
        table: String,
        index: IndexInfo,
    },
    DropIndex {
        schema: Option<String>,
        table: String,
        index_name: String,
    },
    AddForeignKey {
        schema: Option<String>,
        table: String,
        fk: ForeignKeyInfo,
    },
    DropForeignKey {
        schema: Option<String>,
        table: String,
        fk_name: String,
    },
}

#[derive(Debug, Clone)]
pub enum StructureTrackerEvent {
    /// Pending op count changed; carries the new count.
    OpsChanged(usize),
    /// Tracker was wiped (Discard or post-Save).
    Cleared,
}

/// Paired (forward, inverse) entry stored on undo / redo deques. Both
/// directions are kept so `redo` can re-establish the correct undo
/// step without asking the caller to re-derive it.
#[derive(Debug, Clone)]
struct OpPair {
    forward: StructureOp,
    inverse: StructureOp,
}

#[derive(Debug, Default)]
pub struct StructureChangeTracker {
    ops: Vec<StructureOp>,
    /// Stores `(forward, inverse)` pairs for every entry currently in
    /// `ops` plus any entries the user has undone. `undo()` pops the
    /// most recent pair, applies the inverse to the caller's model,
    /// and moves the pair to `redo`. `redo()` reverses the move.
    undo: VecDeque<OpPair>,
    redo: VecDeque<OpPair>,
    subscribers: Vec<relm4::Sender<StructureTrackerEvent>>,
}

impl StructureChangeTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn pending_count(&self) -> usize {
        self.ops.len()
    }

    pub fn has_pending(&self) -> bool {
        !self.ops.is_empty()
    }

    pub fn ops(&self) -> &[StructureOp] {
        &self.ops
    }

    /// Surgically remove every op for which `predicate` returns true.
    /// Drops the matching entries from `ops`, `undo`, and `redo` in
    /// lockstep so the undo invariant (ops length == undo length)
    /// holds. Used by Structure tab to replace stale `AddColumn` ops
    /// when the user edits a freshly-added column's name / type.
    pub fn retain_ops<F: Fn(&StructureOp) -> bool>(&mut self, predicate: F) {
        let before = self.ops.len();
        self.ops.retain(|op| !predicate(op));
        self.undo.retain(|pair| !predicate(&pair.forward));
        self.redo.retain(|pair| !predicate(&pair.forward));
        if self.ops.len() != before {
            self.emit(StructureTrackerEvent::OpsChanged(self.ops.len()));
        }
    }

    pub fn subscribe(&mut self, sender: relm4::Sender<StructureTrackerEvent>) {
        self.subscribers.push(sender);
    }

    fn emit(&self, event: StructureTrackerEvent) {
        for s in &self.subscribers {
            let _ = s.send(event.clone());
        }
    }

    /// Push an op + its inverse for one-step undo. The caller must
    /// have already mutated the in-memory model; this just records
    /// for materialize + undo.
    pub fn push(&mut self, op: StructureOp, inverse: StructureOp) {
        self.ops.push(op.clone());
        if self.undo.len() == UNDO_LIMIT {
            self.undo.pop_front();
        }
        self.undo.push_back(OpPair { forward: op, inverse });
        self.redo.clear();
        self.emit(StructureTrackerEvent::OpsChanged(self.ops.len()));
    }

    /// Pop the most recent op + its inverse. Returns the inverse op
    /// for the caller to apply against the model. The pair moves to
    /// `redo` so a subsequent redo() can re-apply the forward op and
    /// re-establish the undo entry.
    pub fn undo(&mut self) -> Option<StructureOp> {
        let pair = self.undo.pop_back()?;
        self.ops.pop()?;
        let inverse = pair.inverse.clone();
        self.redo.push_back(pair);
        self.emit(StructureTrackerEvent::OpsChanged(self.ops.len()));
        Some(inverse)
    }

    /// Pop the most recent redo entry. Returns the forward op for the
    /// caller to re-apply; the pair moves back to `undo` so undo()
    /// can reverse it again.
    pub fn redo(&mut self) -> Option<StructureOp> {
        let pair = self.redo.pop_back()?;
        let forward = pair.forward.clone();
        self.ops.push(forward.clone());
        self.undo.push_back(pair);
        self.emit(StructureTrackerEvent::OpsChanged(self.ops.len()));
        Some(forward)
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    pub fn clear(&mut self) {
        self.ops.clear();
        self.undo.clear();
        self.redo.clear();
        // Cleared subsumes "count is now zero"; subscribers that need
        // both signals derive count=0 from the Cleared variant.
        self.emit(StructureTrackerEvent::Cleared);
    }

    /// Walk the op log and produce ordered DDL statements ready for
    /// `Connection::execute`. Statement ordering avoids dependency
    /// errors:
    ///
    ///   1. RenameTable (rename targets the old name; later ops use new)
    ///   2. DropForeignKey
    ///   3. DropIndex
    ///   4. DropColumn
    ///   5. RenameColumn (so subsequent alters use the new name)
    ///   6. AlterColumn (MySQL: grouped per column into one MODIFY)
    ///   7. AddColumn
    ///   8. ReorderColumn (MySQL only)
    ///   9. AddIndex
    ///  10. AddForeignKey
    ///
    /// For `New` mode (single `CreateTable` op): bypasses the ordering
    /// pipeline entirely and uses `build_create_table` to emit the
    /// CREATE TABLE + secondary CREATE INDEX / ADD FK statements
    /// inline.
    pub fn materialize(&self, driver_id: &str) -> Result<Vec<String>, BuildDdlError> {
        // Fast path: New-mode CreateTable.
        if let Some(StructureOp::CreateTable {
            schema,
            table,
            columns,
            indexes,
            fks,
        }) = self.ops.first()
            && self.ops.len() == 1
        {
            return build_create_table(driver_id, schema.as_deref(), table, columns, indexes, fks);
        }

        let mut out: Vec<String> = Vec::new();

        // Phase 1: rename table
        for op in &self.ops {
            if let StructureOp::RenameTable {
                schema,
                old_name,
                new_name,
            } = op
            {
                out.push(build_rename_table(driver_id, schema.as_deref(), old_name, new_name)?);
            }
        }

        // Phase 2: drop FKs
        for op in &self.ops {
            if let StructureOp::DropForeignKey { schema, table, fk_name } = op {
                out.push(build_drop_foreign_key(driver_id, schema.as_deref(), table, fk_name)?);
            }
        }

        // Phase 3: drop indexes
        for op in &self.ops {
            if let StructureOp::DropIndex {
                schema,
                table,
                index_name,
            } = op
            {
                out.push(build_drop_index(driver_id, schema.as_deref(), table, index_name)?);
            }
        }

        // Phase 4: drop columns
        for op in &self.ops {
            if let StructureOp::DropColumn {
                schema,
                table,
                column_name,
            } = op
            {
                out.push(build_drop_column(driver_id, schema.as_deref(), table, column_name)?);
            }
        }

        // Phase 5: rename columns
        for op in &self.ops {
            if let StructureOp::RenameColumn {
                schema,
                table,
                old_name,
                new_name,
            } = op
            {
                out.push(build_rename_column(
                    driver_id,
                    schema.as_deref(),
                    table,
                    old_name,
                    new_name,
                )?);
            }
        }

        // Phase 6: alter columns. MySQL needs all alter-attribute ops
        // per (schema, table, column_name) collapsed into a single
        // MODIFY COLUMN statement. Postgres and SQLite emit per-op.
        if driver_id == "mysql" {
            // Walk in op-order so the LAST alter wins (the user's
            // most-recent intent for that column). Build an ordered
            // index of (key → final DraftColumn) so insertion order is
            // preserved deterministically.
            let mut order: Vec<(Option<String>, String, String)> = Vec::new();
            let mut latest: HashMap<(Option<String>, String, String), DraftColumn> = HashMap::new();
            for op in &self.ops {
                if let StructureOp::AlterColumn { schema, table, column } = op {
                    let key = (schema.clone(), table.clone(), column.name.clone());
                    if !latest.contains_key(&key) {
                        order.push(key.clone());
                    }
                    latest.insert(key, column.clone());
                }
            }
            for key in order {
                if let Some(col) = latest.get(&key) {
                    out.push(build_alter_column(driver_id, key.0.as_deref(), &key.1, col)?);
                }
            }
        } else {
            for op in &self.ops {
                if let StructureOp::AlterColumn { schema, table, column } = op {
                    out.push(build_alter_column(driver_id, schema.as_deref(), table, column)?);
                }
            }
        }

        // Phase 7: add columns
        for op in &self.ops {
            if let StructureOp::AddColumn { schema, table, column } = op {
                out.push(build_add_column(driver_id, schema.as_deref(), table, column)?);
            }
        }

        // Phase 8: reorder columns (MySQL only)
        for op in &self.ops {
            if let StructureOp::ReorderColumn {
                schema,
                table,
                column,
                after,
            } = op
            {
                out.push(build_reorder_column(
                    driver_id,
                    schema.as_deref(),
                    table,
                    column,
                    after.as_deref(),
                )?);
            }
        }

        // Phase 9: add indexes
        for op in &self.ops {
            if let StructureOp::AddIndex { schema, table, index } = op {
                out.push(build_create_index(driver_id, schema.as_deref(), table, index)?);
            }
        }

        // Phase 10: add FKs
        for op in &self.ops {
            if let StructureOp::AddForeignKey { schema, table, fk } = op {
                out.push(build_add_foreign_key(driver_id, schema.as_deref(), table, fk)?);
            }
        }

        Ok(out)
    }
}

/// Per-tab tracker registry. Singleton via `thread_local!` since all
/// UI work runs on the GTK main thread.
#[derive(Debug, Default)]
pub struct StructureTrackerRegistry {
    trackers: HashMap<Uuid, StructureChangeTracker>,
}

impl StructureTrackerRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn open_tab(&mut self, tab_id: Uuid) {
        self.trackers.entry(tab_id).or_default();
    }

    pub fn close_tab(&mut self, tab_id: Uuid) {
        self.trackers.remove(&tab_id);
    }

    pub fn any_pending(&self) -> bool {
        self.trackers.values().any(|t| t.has_pending())
    }

    pub fn pending_tabs(&self) -> Vec<Uuid> {
        self.trackers
            .iter()
            .filter(|(_, t)| t.has_pending())
            .map(|(id, _)| *id)
            .collect()
    }
}

thread_local! {
    static REGISTRY: RefCell<StructureTrackerRegistry> = RefCell::new(StructureTrackerRegistry::new());
}

pub fn with_tab<F, R>(tab_id: Uuid, f: F) -> Option<R>
where
    F: FnOnce(&mut StructureChangeTracker) -> R,
{
    REGISTRY.with(|reg| reg.borrow_mut().trackers.get_mut(&tab_id).map(f))
}

pub fn with_tab_ref<F, R>(tab_id: Uuid, f: F) -> Option<R>
where
    F: FnOnce(&StructureChangeTracker) -> R,
{
    REGISTRY.with(|reg| reg.borrow().trackers.get(&tab_id).map(f))
}

pub fn open_tab(tab_id: Uuid) {
    REGISTRY.with(|reg| reg.borrow_mut().open_tab(tab_id));
}

pub fn close_tab(tab_id: Uuid) {
    REGISTRY.with(|reg| reg.borrow_mut().close_tab(tab_id));
}

pub fn any_pending_globally() -> bool {
    REGISTRY.with(|reg| reg.borrow().any_pending())
}

pub fn pending_tabs() -> Vec<Uuid> {
    REGISTRY.with(|reg| reg.borrow().pending_tabs())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::ColumnInfo;

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

    fn dc_with_original(name: &str, ty: &str) -> DraftColumn {
        let info = ColumnInfo {
            name: name.into(),
            data_type: ty.into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
        };
        DraftColumn::from_info(info)
    }

    #[test]
    fn empty_tracker_pending_count_zero() {
        let t = StructureChangeTracker::new();
        assert_eq!(t.pending_count(), 0);
        assert!(!t.has_pending());
    }

    #[test]
    fn push_and_undo_round_trip() {
        let mut t = StructureChangeTracker::new();
        let col = dc("a", "int");
        let op = StructureOp::AddColumn {
            schema: None,
            table: "t".into(),
            column: col.clone(),
        };
        let inverse = StructureOp::DropColumn {
            schema: None,
            table: "t".into(),
            column_name: "a".into(),
        };
        t.push(op, inverse);
        assert_eq!(t.pending_count(), 1);
        assert!(t.can_undo());
        let popped = t.undo().unwrap();
        assert!(matches!(popped, StructureOp::DropColumn { .. }));
        assert_eq!(t.pending_count(), 0);
        assert!(t.can_redo());
    }

    #[test]
    fn clear_drops_all_state() {
        let mut t = StructureChangeTracker::new();
        t.push(
            StructureOp::AddColumn {
                schema: None,
                table: "t".into(),
                column: dc("a", "int"),
            },
            StructureOp::DropColumn {
                schema: None,
                table: "t".into(),
                column_name: "a".into(),
            },
        );
        t.clear();
        assert_eq!(t.pending_count(), 0);
        assert!(!t.can_undo());
        assert!(!t.can_redo());
    }

    #[test]
    fn materialize_create_table_new_mode() {
        let mut t = StructureChangeTracker::new();
        t.push(
            StructureOp::CreateTable {
                schema: None,
                table: "users".into(),
                columns: vec![{
                    let mut c = dc("id", "integer");
                    c.primary_key = true;
                    c.auto_increment = true;
                    c.nullable = false;
                    c
                }],
                indexes: vec![],
                fks: vec![],
            },
            // Inverse for a CreateTable is "drop the table" — but
            // CreateTable is a New-mode-only op, undo isn't supported.
            // Push a stub inverse for symmetry.
            StructureOp::CreateTable {
                schema: None,
                table: "users".into(),
                columns: vec![],
                indexes: vec![],
                fks: vec![],
            },
        );
        let stmts = t.materialize("postgres").unwrap();
        assert_eq!(stmts.len(), 1);
        assert!(stmts[0].contains("CREATE TABLE \"users\""));
        assert!(stmts[0].contains("SERIAL PRIMARY KEY"));
    }

    #[test]
    fn materialize_orders_drop_fk_before_drop_index_before_drop_column() {
        let mut t = StructureChangeTracker::new();
        // Push in user-natural order: add a column, drop a FK, drop an
        // index, drop a column. Materialize must reorder.
        t.push(
            StructureOp::AddColumn {
                schema: None,
                table: "t".into(),
                column: dc("new_col", "int"),
            },
            StructureOp::DropColumn {
                schema: None,
                table: "t".into(),
                column_name: "new_col".into(),
            },
        );
        t.push(
            StructureOp::DropForeignKey {
                schema: None,
                table: "t".into(),
                fk_name: "fk_1".into(),
            },
            StructureOp::AddForeignKey {
                schema: None,
                table: "t".into(),
                fk: ForeignKeyInfo {
                    name: "fk_1".into(),
                    columns: vec!["a".into()],
                    ref_schema: None,
                    ref_table: "u".into(),
                    ref_columns: vec!["id".into()],
                    on_delete: None,
                    on_update: None,
                },
            },
        );
        t.push(
            StructureOp::DropIndex {
                schema: None,
                table: "t".into(),
                index_name: "i_1".into(),
            },
            StructureOp::AddIndex {
                schema: None,
                table: "t".into(),
                index: IndexInfo {
                    name: "i_1".into(),
                    columns: vec!["a".into()],
                    unique: false,
                    primary: false,
                },
            },
        );
        t.push(
            StructureOp::DropColumn {
                schema: None,
                table: "t".into(),
                column_name: "old_col".into(),
            },
            StructureOp::AddColumn {
                schema: None,
                table: "t".into(),
                column: dc("old_col", "int"),
            },
        );
        let stmts = t.materialize("postgres").unwrap();
        // Order: drop-fk (1), drop-index (2), drop-column (3), add-column (4).
        assert_eq!(stmts.len(), 4);
        assert!(stmts[0].contains("DROP CONSTRAINT \"fk_1\""));
        assert!(stmts[1].contains("DROP INDEX") && stmts[1].contains("i_1"));
        assert!(stmts[2].contains("DROP COLUMN \"old_col\""));
        assert!(stmts[3].contains("ADD COLUMN \"new_col\""));
    }

    #[test]
    fn materialize_mysql_groups_alter_column_into_one_modify() {
        let mut t = StructureChangeTracker::new();
        let mut col = dc_with_original("status", "VARCHAR(64)");
        col.nullable = false;
        t.push(
            StructureOp::AlterColumn {
                schema: None,
                table: "t".into(),
                column: col.clone(),
            },
            StructureOp::AlterColumn {
                schema: None,
                table: "t".into(),
                column: dc_with_original("status", "VARCHAR(64)"),
            },
        );
        // Second alter on same column with a default.
        col.default_value = Some("'open'".into());
        t.push(
            StructureOp::AlterColumn {
                schema: None,
                table: "t".into(),
                column: col.clone(),
            },
            StructureOp::AlterColumn {
                schema: None,
                table: "t".into(),
                column: dc_with_original("status", "VARCHAR(64)"),
            },
        );
        let stmts = t.materialize("mysql").unwrap();
        // Both alters collapse into ONE MODIFY COLUMN reflecting the
        // final post-edit state.
        assert_eq!(stmts.len(), 1);
        assert!(stmts[0].contains("MODIFY COLUMN `status`"));
        assert!(stmts[0].contains("NOT NULL"));
        assert!(stmts[0].contains("DEFAULT 'open'"));
    }

    #[test]
    fn materialize_postgres_emits_per_attribute_alter() {
        let mut t = StructureChangeTracker::new();
        // Two separate alters → two separate Postgres statements.
        let mut col_a = dc_with_original("x", "text");
        col_a.nullable = false;
        let mut col_b = dc_with_original("x", "text");
        col_b.default_value = Some("'foo'".into());
        t.push(
            StructureOp::AlterColumn {
                schema: None,
                table: "t".into(),
                column: col_a,
            },
            StructureOp::AlterColumn {
                schema: None,
                table: "t".into(),
                column: dc_with_original("x", "text"),
            },
        );
        t.push(
            StructureOp::AlterColumn {
                schema: None,
                table: "t".into(),
                column: col_b,
            },
            StructureOp::AlterColumn {
                schema: None,
                table: "t".into(),
                column: dc_with_original("x", "text"),
            },
        );
        let stmts = t.materialize("postgres").unwrap();
        assert_eq!(stmts.len(), 2);
        assert!(stmts.iter().any(|s| s.contains("SET NOT NULL")));
        assert!(stmts.iter().any(|s| s.contains("SET DEFAULT 'foo'")));
    }

    #[test]
    fn registry_isolates_tabs() {
        let mut reg = StructureTrackerRegistry::new();
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        reg.open_tab(a);
        reg.open_tab(b);
        reg.trackers.get_mut(&a).unwrap().push(
            StructureOp::AddColumn {
                schema: None,
                table: "t".into(),
                column: dc("x", "int"),
            },
            StructureOp::DropColumn {
                schema: None,
                table: "t".into(),
                column_name: "x".into(),
            },
        );
        assert!(reg.any_pending());
        let pending: Vec<_> = reg.pending_tabs();
        assert_eq!(pending.len(), 1);
        assert!(pending.contains(&a));
    }

    #[test]
    fn subscribe_increments_subscriber_count() {
        // The subscribe contract (events emit through the channel) is
        // exercised end-to-end by the BrowseTab tests in change_tracker;
        // this tracker uses the identical pattern. Test only the sync
        // observable: subscribers vec grows on subscribe.
        let (tx, _rx) = relm4::channel::<StructureTrackerEvent>();
        let mut t = StructureChangeTracker::new();
        assert_eq!(t.subscribers.len(), 0);
        t.subscribe(tx);
        assert_eq!(t.subscribers.len(), 1);
    }
}
