#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FileOpenMode {
    OpenExisting,
    // Only where nothing is; a file there is refused, never replaced.
    CreateNew,
    // Over a file the user agreed to replace.
    Replace,
}
