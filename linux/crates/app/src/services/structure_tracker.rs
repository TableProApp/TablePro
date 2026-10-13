//! The DDL a Structure tab would run, cached so the close prompt and
//! the save dispatcher can read it without reaching into the tab. The
//! tab recomputes the ops from its snapshot diff on every edit; DDL has
//! no per-op undo, only Discard back to the snapshot.

use tablepro_core::sql_ddl::StructureOp;

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

    pub fn set_ops(&mut self, ops: Vec<StructureOp>) {
        self.ops = ops;
    }

    pub fn clear(&mut self) {
        self.ops.clear();
    }
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
            comment: None,
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
}
