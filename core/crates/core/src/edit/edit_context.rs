/// Which row an edit lands in, which decides what an empty cell means.
///
/// Only an insert can omit a column and let the server fill it, so an
/// empty cell asks for the default in a draft row and never in an
/// existing one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditContext {
    InsertDraft,
    UpdateRow,
}
