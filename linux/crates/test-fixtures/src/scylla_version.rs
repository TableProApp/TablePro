use crate::{FixtureImage, ServerVersion};

/// The ScyllaDB release a fixture runs: the long-term releases ScyllaDB
/// still supports.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ScyllaVersion {
    V2025_1,
    #[default]
    V2026_1,
}

impl ScyllaVersion {
    /// The year and release number `system.versions` reports.
    pub fn reported(self) -> (u32, u32) {
        match self {
            Self::V2025_1 => (2025, 1),
            Self::V2026_1 => (2026, 1),
        }
    }
}

impl ServerVersion for ScyllaVersion {
    const VARIABLE: &'static str = "TABLEPRO_TEST_SCYLLA";
    const ALL: &'static [Self] = &[Self::V2025_1, Self::V2026_1];

    fn name(self) -> &'static str {
        match self {
            Self::V2025_1 => "2025.1",
            Self::V2026_1 => "2026.1",
        }
    }

    fn image(self) -> FixtureImage {
        match self {
            Self::V2025_1 => FixtureImage::SCYLLA_2025_1,
            Self::V2026_1 => FixtureImage::SCYLLA,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_version_pins_the_image_of_its_release() {
        crate::server_version::tests::check_releases::<ScyllaVersion>("scylladb/scylla");
        for &version in ScyllaVersion::ALL {
            let (year, release) = version.reported();
            assert_eq!(version.image().tag, format!("{year}.{release}"));
            assert_eq!(version.name(), version.image().tag);
        }
        assert_eq!(ScyllaVersion::default().image(), FixtureImage::SCYLLA);
    }
}
