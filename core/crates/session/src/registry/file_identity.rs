use std::path::PathBuf;

/// A file the user opened, as both a resolved path and the URI it came
/// in as.
///
/// Two ways of naming the same database, a symlink and its target, or a
/// relative and an absolute path, have to open one session rather than
/// two. The canonical path is what decides that; the URI is what gets
/// persisted and shown when there is no canonical path, such as a file
/// on a mount that is not there any more.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileIdentity {
    pub canonical_path: Option<PathBuf>,
    pub uri: String,
}

impl FileIdentity {
    pub fn new(canonical_path: Option<PathBuf>, uri: String) -> Self {
        Self { canonical_path, uri }
    }
}
