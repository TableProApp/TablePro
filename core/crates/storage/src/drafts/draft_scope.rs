use std::fmt;

use crate::StorageError;

/// The directory a set of drafts lives in, one per workspace.
///
/// It reaches the filesystem as a path segment, so it is checked
/// rather than trusted: a scope built from a file name must not be
/// able to climb out of the drafts directory.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DraftScope(String);

/// Long enough for any workspace name, short enough to stay inside the
/// filename limit once a draft id is appended.
const MAX_SCOPE_LEN: usize = 128;

/// Where drafts go when the caller does not name a workspace.
const DEFAULT_SCOPE: &str = "workspace";

impl DraftScope {
    pub fn new(name: &str) -> Result<Self, StorageError> {
        if name.is_empty() || name.len() > MAX_SCOPE_LEN {
            return Err(StorageError::Schema(format!(
                "a draft scope must be 1 to {MAX_SCOPE_LEN} characters, got {}",
                name.len()
            )));
        }
        // `.` and `..` are directory entries, not names.
        if name == "." || name == ".." {
            return Err(StorageError::Schema(format!("{name:?} is not a usable draft scope")));
        }
        let allowed = name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'));
        if !allowed {
            return Err(StorageError::Schema(format!(
                "a draft scope may only hold letters, digits, dot, underscore and hyphen, got {name:?}"
            )));
        }
        Ok(Self(name.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Default for DraftScope {
    fn default() -> Self {
        Self(DEFAULT_SCOPE.to_owned())
    }
}

impl fmt::Display for DraftScope {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scope_rejects_traversal() {
        for name in ["..", ".", "../etc", "a/b", "a\\b", "a\0b", ""] {
            assert!(DraftScope::new(name).is_err(), "{name:?} was accepted");
        }
    }

    #[test]
    fn scope_accepts_a_workspace_file_stem() {
        for name in ["workspace_state", "sales-2026", "a.b_c-1"] {
            assert_eq!(DraftScope::new(name).expect(name).as_str(), name);
        }
    }

    #[test]
    fn the_default_scope_passes_the_rules_it_skips() {
        assert_eq!(
            DraftScope::new(DEFAULT_SCOPE).expect("the default name").as_str(),
            DraftScope::default().as_str()
        );
    }

    #[test]
    fn scope_rejects_an_over_long_name() {
        let long = "a".repeat(MAX_SCOPE_LEN + 1);

        assert!(DraftScope::new(&long).is_err());
        assert!(DraftScope::new(&"a".repeat(MAX_SCOPE_LEN)).is_ok());
    }
}
