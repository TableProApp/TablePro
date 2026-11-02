use crate::{FixtureImage, ServerVersion};

/// The ClickHouse release a fixture runs: the long-term releases
/// ClickHouse still supports.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ClickHouseVersion {
    V26_3,
    #[default]
    V26_8,
}

impl ClickHouseVersion {
    /// The major and minor version `version()` reports.
    pub fn reported(self) -> (u32, u32) {
        match self {
            Self::V26_3 => (26, 3),
            Self::V26_8 => (26, 8),
        }
    }
}

impl ServerVersion for ClickHouseVersion {
    const VARIABLE: &'static str = "TABLEPRO_TEST_CLICKHOUSE";
    const ALL: &'static [Self] = &[Self::V26_3, Self::V26_8];

    fn name(self) -> &'static str {
        match self {
            Self::V26_3 => "26.3",
            Self::V26_8 => "26.8",
        }
    }

    fn image(self) -> FixtureImage {
        match self {
            Self::V26_3 => FixtureImage::CLICKHOUSE_26_3,
            Self::V26_8 => FixtureImage::CLICKHOUSE,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_version_pins_the_image_of_its_release() {
        crate::server_version::tests::check_releases::<ClickHouseVersion>("clickhouse/clickhouse-server");
        for &version in ClickHouseVersion::ALL {
            let (major, minor) = version.reported();
            assert_eq!(version.image().tag, format!("{major}.{minor}"));
            assert_eq!(version.name(), version.image().tag);
        }
        assert_eq!(ClickHouseVersion::default().image(), FixtureImage::CLICKHOUSE);
    }
}
