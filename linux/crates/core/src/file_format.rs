use std::path::Path;

/// Bytes every database file of an engine holds at a fixed place, which
/// is how a file says which engine wrote it whatever its name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct FileSignature {
    pub offset: usize,
    pub bytes: &'static [u8],
}

impl FileSignature {
    /// Whether `header`, the first bytes of a file, carries the
    /// signature. An empty signature matches nothing.
    pub fn matches(&self, header: &[u8]) -> bool {
        let end = self.offset + self.bytes.len();
        !self.bytes.is_empty() && header.get(self.offset..end) == Some(self.bytes)
    }

    /// How much of a file's head has to be read to check it.
    pub fn header_len(&self) -> usize {
        self.offset + self.bytes.len()
    }
}

/// How a file engine's database files are told apart from any other
/// file: what the file chooser filters on and what decides which engine
/// opens a file handed over from Files or the command line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct FileFormat {
    pub signature: FileSignature,
    /// Name suffixes without the dot, the one a new file gets first.
    pub suffixes: &'static [&'static str],
    /// The shared MIME database's types for the engine's files.
    pub mime_types: &'static [&'static str],
    /// Whether a file of no bytes opens as an empty database, as SQLite
    /// reads one. Such a file carries no signature.
    pub empty_file_is_database: bool,
}

impl FileFormat {
    /// The suffix a new database file gets, without the dot.
    pub fn new_file_suffix(&self) -> Option<&'static str> {
        self.suffixes.first().copied()
    }

    /// Whether `path` ends in one of the engine's suffixes, in any case.
    pub fn names(&self, path: &Path) -> bool {
        path.extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| {
                self.suffixes
                    .iter()
                    .any(|suffix| suffix.eq_ignore_ascii_case(extension))
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DUCK: FileFormat = FileFormat {
        signature: FileSignature {
            offset: 8,
            bytes: b"DUCK",
        },
        suffixes: &["duckdb", "ddb"],
        mime_types: &[],
        empty_file_is_database: false,
    };

    #[test]
    fn a_signature_matches_at_its_offset_only() {
        let mut header = vec![0u8; 16];
        header[8..12].copy_from_slice(b"DUCK");

        assert!(DUCK.signature.matches(&header));
        assert!(!DUCK.signature.matches(&header[..11]), "a short header cannot carry it");
        assert!(!DUCK.signature.matches(b"DUCK000000000000"));
        assert_eq!(DUCK.signature.header_len(), 12);
    }

    #[test]
    fn an_empty_signature_matches_nothing() {
        let none = FileSignature { offset: 0, bytes: b"" };

        assert!(!none.matches(b""));
        assert!(!none.matches(b"anything"));
    }

    #[test]
    fn a_name_matches_a_suffix_in_any_case() {
        assert!(DUCK.names(Path::new("/srv/app.duckdb")));
        assert!(DUCK.names(Path::new("/srv/APP.DDB")));
        assert!(!DUCK.names(Path::new("/srv/app.duckdb.wal")));
        assert!(!DUCK.names(Path::new("/srv/duckdb")));
        assert_eq!(DUCK.new_file_suffix(), Some("duckdb"));
    }
}
