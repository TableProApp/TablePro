use std::collections::{BTreeSet, HashMap, HashSet};

use super::{
    ChangedAttributes, ColumnAlteration, ColumnRename, PrimaryKeyChange, PrimaryKeyConstraint, TableChanges,
    TableDefinition, TableDraft,
};

/// What the draft changed about the table it started from.
///
/// Columns are matched by the name they had when the table was read, so
/// a rename is a rename and not a drop and an add. Indexes and foreign
/// keys are matched whole: one that changed is dropped and added again,
/// since no engine alters either in place.
pub fn diff_table(original: &TableDefinition, draft: &TableDraft) -> TableChanges {
    let name = draft.table.name.trim();
    let renamed_table = (!name.is_empty() && name != original.table.name).then(|| name.to_owned());

    let kept: HashSet<&str> = draft
        .columns
        .iter()
        .filter_map(|column| column.original_name())
        .collect();
    let dropped_columns = original
        .columns
        .iter()
        .filter(|column| !kept.contains(column.name()))
        .cloned()
        .collect();
    let mut renamed_columns = Vec::new();
    let mut altered_columns = Vec::new();
    let mut added_columns = Vec::new();
    for column in &draft.columns {
        let Some(before) = &column.original else {
            added_columns.push(column.clone());
            continue;
        };
        if before.name() != column.name {
            renamed_columns.push(ColumnRename {
                from: before.name().to_owned(),
                to: column.name.clone(),
            });
        }
        let changed = ChangedAttributes::between(before, column);
        if changed.any() {
            altered_columns.push(ColumnAlteration {
                original: before.clone(),
                draft: column.clone(),
                changed,
            });
        }
    }

    let secondary = |indexes: &[crate::meta::IndexInfo], other: &[crate::meta::IndexInfo]| {
        indexes
            .iter()
            .filter(|index| !index.primary && !other.contains(index))
            .cloned()
            .collect::<Vec<_>>()
    };
    let missing = |keys: &[crate::ForeignKeyInfo], other: &[crate::ForeignKeyInfo]| {
        keys.iter()
            .filter(|key| !other.contains(key))
            .cloned()
            .collect::<Vec<_>>()
    };

    TableChanges {
        renamed_table,
        dropped_foreign_keys: missing(&original.foreign_keys, &draft.foreign_keys),
        dropped_indexes: secondary(&original.indexes, &draft.indexes),
        dropped_columns,
        primary_key: primary_key_change(original, draft, &renamed_columns),
        renamed_columns,
        altered_columns,
        added_columns,
        added_indexes: secondary(&draft.indexes, &original.indexes),
        added_foreign_keys: missing(&draft.foreign_keys, &original.foreign_keys),
    }
}

/// The key compared as a set of columns under their new names: listing
/// the same columns in another order is not a change the user made.
fn primary_key_change(
    original: &TableDefinition,
    draft: &TableDraft,
    renames: &[ColumnRename],
) -> Option<PrimaryKeyChange> {
    let renamed: HashMap<&str, &str> = renames
        .iter()
        .map(|rename| (rename.from.as_str(), rename.to.as_str()))
        .collect();
    let from = original.primary_key.clone().or_else(|| {
        let columns: Vec<String> = original
            .columns
            .iter()
            .filter(|column| column.info.primary_key)
            .map(|column| column.name().to_owned())
            .collect();
        (!columns.is_empty()).then_some(PrimaryKeyConstraint { name: None, columns })
    });
    let before: BTreeSet<&str> = from
        .iter()
        .flat_map(|key| key.columns.iter())
        .map(|name| renamed.get(name.as_str()).copied().unwrap_or(name))
        .collect();
    let to = draft.primary_key();
    let after: BTreeSet<&str> = to.iter().copied().collect();
    (before != after).then(|| PrimaryKeyChange {
        from,
        to: to.into_iter().map(str::to_owned).collect(),
    })
}
