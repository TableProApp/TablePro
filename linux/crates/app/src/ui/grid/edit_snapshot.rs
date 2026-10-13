use super::RowObject;

/// An edit as it stood when it began. The commit goes to `row`, not to
/// whatever row the cell shows by then.
#[derive(Debug, Clone)]
pub struct EditSnapshot {
    pub row: RowObject,
    pub column: usize,
    pub original_text: String,
}
