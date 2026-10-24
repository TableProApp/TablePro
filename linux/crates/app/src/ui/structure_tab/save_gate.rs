use crate::services::pending_structure::{PendingStructure, SaveBlocker};

/// What Save does with the pending structure as it stands. The draft
/// is checked before the changes, so a draft that cannot be written
/// says why even when it changes nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum SaveGate {
    Enabled,
    NothingToSave,
    Blocked(SaveBlocker),
}

impl SaveGate {
    pub(super) fn of(pending: &PendingStructure) -> Self {
        if let Err(blocker) = pending.check() {
            return Self::Blocked(blocker);
        }
        if !pending.has_changes() {
            return Self::NothingToSave;
        }
        Self::Enabled
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::ColumnDefault;
    use tablepro_core::ddl::{
        ColumnAttributes, ColumnDefinition, DraftColumn, DraftProblem, DraftType, TableChanges, TableDefinition,
        TableDraft, diff_table,
    };
    use tablepro_core::dialect::SqlDialect;
    use tablepro_core::meta::TableRef;
    use tablepro_core::{ColumnInfo, ServerInfo};

    use super::*;

    fn users() -> TableDefinition {
        let postgres = tablepro_driver_postgres::PgDialect::new(&ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0));
        let id = ColumnInfo {
            name: "id".to_owned(),
            column_type: postgres.parse_type("integer").expect("a PostgreSQL type"),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        };
        TableDefinition {
            table: TableRef::new(None, "users"),
            columns: vec![ColumnDefinition::new(id, ColumnAttributes::default())],
            primary_key: None,
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            inbound_foreign_keys: Vec::new(),
            source: None,
        }
    }

    fn edited(edit: impl FnOnce(&mut TableDraft)) -> PendingStructure {
        let original = users();
        let mut draft = TableDraft::from_definition(&original);
        edit(&mut draft);
        PendingStructure {
            changes: diff_table(&original, &draft),
            original: Some(original),
            draft,
            unparsed_defaults: Vec::new(),
        }
    }

    fn created(columns: &[&str]) -> PendingStructure {
        let mut draft = TableDraft::new(TableRef::new(None, "users"));
        draft.columns = columns
            .iter()
            .map(|name| DraftColumn::new(*name, DraftType::Typed("integer".to_owned())))
            .collect();
        PendingStructure {
            original: None,
            draft,
            changes: TableChanges::default(),
            unparsed_defaults: Vec::new(),
        }
    }

    #[test]
    fn nothing_to_save_when_changes_are_empty() {
        let unchanged = edited(|_| {});

        assert!(unchanged.changes.is_empty());
        assert_eq!(SaveGate::of(&unchanged), SaveGate::NothingToSave);
    }

    #[test]
    fn blocked_with_the_draft_problem() {
        let unnamed = edited(|draft| draft.columns[0].name = String::new());

        assert_eq!(
            SaveGate::of(&unnamed),
            SaveGate::Blocked(SaveBlocker::Draft(DraftProblem::EmptyColumnName))
        );
        assert_eq!(
            SaveGate::of(&created(&[])),
            SaveGate::Blocked(SaveBlocker::Draft(DraftProblem::NoColumns)),
            "an empty new table is a problem before it is nothing to save"
        );
    }

    #[test]
    fn a_default_the_parser_refused_blocks_the_save() {
        let pending = PendingStructure {
            unparsed_defaults: vec!["id".to_owned()],
            ..edited(|_| {})
        };

        assert_eq!(
            SaveGate::of(&pending),
            SaveGate::Blocked(SaveBlocker::UnparsedDefault("id".to_owned()))
        );
    }

    #[test]
    fn enabled_for_valid_changes() {
        let added = edited(|draft| {
            draft
                .columns
                .push(DraftColumn::new("name", DraftType::Typed("text".to_owned())));
        });

        assert_eq!(SaveGate::of(&added), SaveGate::Enabled);
        assert_eq!(SaveGate::of(&created(&["id"])), SaveGate::Enabled);
    }
}
