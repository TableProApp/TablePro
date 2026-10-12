use std::fmt;

use tablepro_core::DriverError;

/// A SQLite library version, as `sqlite_version()` reports it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SqliteVersion {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

/// The oldest library the driver reads a catalogue from. 3.37.0 added
/// `PRAGMA table_list`, which is what says whether a table is STRICT.
/// Every system that ships GTK 4.22 has a newer one, so the floor turns
/// away no supported system.
pub const SQLITE_MIN_VERSION: SqliteVersion = SqliteVersion::new(3, 37, 0);

impl SqliteVersion {
    pub const fn new(major: u32, minor: u32, patch: u32) -> Self {
        Self { major, minor, patch }
    }

    /// Read `3.46.1`. A missing patch number reads as zero.
    pub fn parse(text: &str) -> Option<Self> {
        let mut parts = text.trim().split('.');
        let major = parts.next()?.parse().ok()?;
        let minor = parts.next()?.parse().ok()?;
        let patch = match parts.next() {
            Some(patch) => patch.parse().ok()?,
            None => 0,
        };
        Some(Self::new(major, minor, patch))
    }
}

impl fmt::Display for SqliteVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

/// Refuse a library older than the catalogue queries need, before any
/// of them runs.
pub fn check_runtime_version(version: &SqliteVersion) -> Result<(), DriverError> {
    if *version < SQLITE_MIN_VERSION {
        return Err(DriverError::Unsupported {
            feature: "SQLite 3.37.0 or later",
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sqlite_runtime_version_below_3_37_is_unsupported() {
        let refused = check_runtime_version(&SqliteVersion::new(3, 36, 0));

        assert_eq!(
            refused,
            Err(DriverError::Unsupported {
                feature: "SQLite 3.37.0 or later"
            })
        );
        assert_eq!(check_runtime_version(&SqliteVersion::new(3, 37, 0)), Ok(()));
        assert_eq!(check_runtime_version(&SqliteVersion::new(3, 45, 1)), Ok(()));
    }

    #[test]
    fn a_version_reads_with_or_without_its_patch_number() {
        assert_eq!(SqliteVersion::parse("3.46.1"), Some(SqliteVersion::new(3, 46, 1)));
        assert_eq!(SqliteVersion::parse("3.50"), Some(SqliteVersion::new(3, 50, 0)));
        assert_eq!(SqliteVersion::parse("three"), None);
        assert_eq!(SqliteVersion::new(3, 46, 1).to_string(), "3.46.1");
    }
}
