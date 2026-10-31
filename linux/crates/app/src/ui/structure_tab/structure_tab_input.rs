use super::columns_input::ColumnsInput;
use super::foreign_keys_input::ForeignKeysInput;
use super::indexes_input::IndexesInput;
use super::load_input::LoadInput;
use super::save_input::SaveInput;
use super::table_input::TableInput;

/// An input to the tab, grouped by the state it changes, each group
/// handled on its own.
#[derive(Debug)]
pub(crate) enum StructureTabInput {
    Load(LoadInput),
    Columns(ColumnsInput),
    Indexes(IndexesInput),
    ForeignKeys(ForeignKeysInput),
    Table(TableInput),
    Save(SaveInput),
}

impl StructureTabInput {
    pub(super) fn edits_draft(&self) -> bool {
        matches!(
            self,
            Self::Columns(_)
                | Self::Indexes(_)
                | Self::ForeignKeys(_)
                | Self::Table(
                    TableInput::TableNameEdited(_)
                        | TableInput::CharacterSetPicked(_)
                        | TableInput::CollationPicked(_)
                        | TableInput::ConvertColumnsToggled(_)
                        | TableInput::NextAutoIncrementEdited(_)
                )
        )
    }
}

impl From<LoadInput> for StructureTabInput {
    fn from(input: LoadInput) -> Self {
        Self::Load(input)
    }
}

impl From<ColumnsInput> for StructureTabInput {
    fn from(input: ColumnsInput) -> Self {
        Self::Columns(input)
    }
}

impl From<IndexesInput> for StructureTabInput {
    fn from(input: IndexesInput) -> Self {
        Self::Indexes(input)
    }
}

impl From<ForeignKeysInput> for StructureTabInput {
    fn from(input: ForeignKeysInput) -> Self {
        Self::ForeignKeys(input)
    }
}

impl From<TableInput> for StructureTabInput {
    fn from(input: TableInput) -> Self {
        Self::Table(input)
    }
}

impl From<SaveInput> for StructureTabInput {
    fn from(input: SaveInput) -> Self {
        Self::Save(input)
    }
}
