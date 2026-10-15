/// What the tab does with the table as a whole.
#[derive(Debug)]
pub(crate) enum TableInput {
    TableNameEdited(String),
    DropTableRequested,
}
