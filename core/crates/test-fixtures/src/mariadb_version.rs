use crate::{FixtureImage, ServerVersion};

/// The MariaDB release a fixture runs: long-term releases only.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum MariadbVersion {
    V10_11,
    #[default]
    V11_4,
    V12_3,
}

impl MariadbVersion {
    /// The major and minor version `VERSION()` reports.
    pub fn reported(self) -> (u32, u32) {
        match self {
            Self::V10_11 => (10, 11),
            Self::V11_4 => (11, 4),
            Self::V12_3 => (12, 3),
        }
    }
}

impl ServerVersion for MariadbVersion {
    const VARIABLE: &'static str = "TABLEPRO_TEST_MARIADB";
    const ALL: &'static [Self] = &[Self::V10_11, Self::V11_4, Self::V12_3];

    fn name(self) -> &'static str {
        match self {
            Self::V10_11 => "10.11",
            Self::V11_4 => "11.4",
            Self::V12_3 => "12.3",
        }
    }

    fn image(self) -> FixtureImage {
        match self {
            Self::V10_11 => FixtureImage::MARIADB_10_11,
            Self::V11_4 => FixtureImage::MARIADB,
            Self::V12_3 => FixtureImage::MARIADB_12_3,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_version_pins_the_image_of_its_release() {
        crate::server_version::tests::check_releases::<MariadbVersion>("mariadb");
        for &version in MariadbVersion::ALL {
            let (major, minor) = version.reported();
            assert_eq!(version.image().tag, format!("{major}.{minor}"));
            assert_eq!(version.name(), version.image().tag);
        }
        assert_eq!(MariadbVersion::default().image(), FixtureImage::MARIADB);
    }
}
