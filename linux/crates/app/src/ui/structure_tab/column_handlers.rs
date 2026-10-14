use tablepro_core::ddl::{DraftColumn, DraftType};

use super::draft_column_object::{DraftColumnObject, UnparsedDefault};
use super::{ColumnField, ColumnsInput, StructureEffects, StructureModel, items};

impl StructureModel {
    pub(super) fn on_columns(&mut self, input: ColumnsInput, fx: &mut StructureEffects) {
        match input {
            ColumnsInput::ColumnEdited { column, field } => self.edit_column(&column, field, fx),
            ColumnsInput::AddColumn => {
                let column_type = self
                    .context
                    .borrow()
                    .ddl()
                    .map_or("text", |ddl| ddl.default_column_type())
                    .to_owned();
                let column = DraftColumn::new(self.placeholder_column_name(), DraftType::Typed(column_type));
                self.columns.append(&DraftColumnObject::new(column));
                self.recompute_dirty_state(fx);
            }
            ColumnsInput::RemoveColumn(column) => {
                if let Some(position) = self.columns.find(&column) {
                    self.columns.remove(position);
                    self.recompute_dirty_state(fx);
                }
            }
        }
    }

    fn edit_column(&mut self, column: &DraftColumnObject, field: ColumnField, fx: &mut StructureEffects) {
        // A row of a column the draft no longer holds.
        if self.columns.find(column).is_none() {
            return;
        }
        match field {
            ColumnField::Name(name) => column.update(|draft| draft.name = name),
            ColumnField::Type(text) => column.update(|draft| {
                // Retyping the declaration keeps the catalogue's type,
                // which is never parsed again.
                draft.column_type = match draft.original.as_ref() {
                    Some(original) if DraftType::Catalog(original.info.column_type.clone()).text() == text => {
                        DraftType::Catalog(original.info.column_type.clone())
                    }
                    _ => DraftType::Typed(text),
                };
            }),
            ColumnField::Nullable(nullable) => column.update(|draft| draft.nullable = nullable),
            // The row's Nullable and Auto increment switches follow the
            // key and send their own edits.
            ColumnField::PrimaryKey(primary_key) => column.update(|draft| draft.primary_key = primary_key),
            ColumnField::AutoIncrement(auto_increment) => column.update(|draft| draft.auto_increment = auto_increment),
            ColumnField::Default(text) => {
                let parsed = self.context.borrow().parse_default(&column.column(), &text);
                match parsed {
                    Ok(default) => {
                        column.set_unparsed_default(None);
                        column.update(|draft| draft.default = default);
                    }
                    // No edit of the column, but the tracker has to learn
                    // of it, or a close prompt would save without it.
                    Err(error) => column.set_unparsed_default(Some(UnparsedDefault { text, error })),
                }
            }
            ColumnField::Comment(comment) => column.update(|draft| draft.comment = comment),
        }
        self.recompute_dirty_state(fx);
    }

    /// `column_N` with the first N that no column of the draft is named.
    fn placeholder_column_name(&self) -> String {
        let names: Vec<String> = items::<DraftColumnObject>(&self.columns)
            .iter()
            .map(DraftColumnObject::name)
            .collect();
        (1_usize..)
            .map(|n| format!("column_{n}"))
            .find(|candidate| !names.iter().any(|name| name.eq_ignore_ascii_case(candidate)))
            .unwrap_or_default()
    }
}
