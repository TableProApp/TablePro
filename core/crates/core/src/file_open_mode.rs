#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FileOpenMode {
    OpenExisting,
    CreateNew,
}
