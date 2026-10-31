/// What the tab does with the table as a whole.
#[derive(Debug)]
pub(crate) enum TableInput {
    TableNameEdited(String),
    /// A default character set picked for the table, which takes its
    /// default collation with it.
    CharacterSetPicked(String),
    CollationPicked(String),
    ConvertColumnsToggled(bool),
    /// The Next Auto Increment field as typed.
    NextAutoIncrementEdited(String),
    DropTableRequested,
}
