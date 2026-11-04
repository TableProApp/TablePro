use std::env::VarError;
use std::fmt::Debug;

use crate::{FixtureError, FixtureImage};

/// A release of one engine that a fixture can start.
///
/// A fixture starts the default release unless the engine's variable
/// names another, so CI runs a driver's whole suite again on the oldest
/// and the newest release the vendor supports.
pub trait ServerVersion: Copy + Debug + Default + PartialEq + 'static {
    /// The environment variable that picks the release.
    const VARIABLE: &'static str;
    const ALL: &'static [Self];

    /// What the variable says to pick this release: `14`, `8.0`, `2019`.
    fn name(self) -> &'static str;

    fn image(self) -> FixtureImage;

    /// The release the variable names, or the default when it is unset
    /// or empty.
    fn selected() -> Result<Self, FixtureError> {
        match std::env::var(Self::VARIABLE) {
            Ok(value) => Self::named(&value),
            Err(VarError::NotPresent) => Ok(Self::default()),
            Err(VarError::NotUnicode(value)) => Self::named(&value.to_string_lossy()),
        }
    }

    fn named(value: &str) -> Result<Self, FixtureError> {
        if value.is_empty() {
            return Ok(Self::default());
        }
        Self::ALL
            .iter()
            .copied()
            .find(|release| release.name() == value)
            .ok_or_else(|| FixtureError::UnknownRelease {
                variable: Self::VARIABLE,
                value: value.to_owned(),
                known: Self::ALL
                    .iter()
                    .map(|release| release.name())
                    .collect::<Vec<_>>()
                    .join(", "),
            })
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::collections::HashSet;

    use super::*;

    pub(crate) fn check_releases<V: ServerVersion>(image_name: &str) {
        let names: HashSet<_> = V::ALL.iter().map(|release| release.name()).collect();
        assert_eq!(names.len(), V::ALL.len(), "{} names a release twice", V::VARIABLE);
        assert!(V::ALL.contains(&V::default()));
        for &release in V::ALL {
            assert_eq!(release.image().name, image_name, "{release:?}");
            assert_eq!(V::named(release.name()).unwrap(), release);
        }
        assert_eq!(V::named("").unwrap(), V::default());
        let unknown = V::named("1.0").unwrap_err().to_string();
        assert!(unknown.contains(V::VARIABLE), "{unknown}");
        assert!(unknown.contains(V::default().name()), "{unknown}");
    }
}
