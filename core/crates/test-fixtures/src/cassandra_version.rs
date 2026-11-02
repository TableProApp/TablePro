use crate::{FixtureImage, ServerVersion};

/// The Apache Cassandra release a fixture runs: the oldest and the
/// newest the project maintains.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CassandraVersion {
    V4_0,
    #[default]
    V5_0,
}

impl CassandraVersion {
    /// The major and minor version `release_version` reports.
    pub fn reported(self) -> (u32, u32) {
        match self {
            Self::V4_0 => (4, 0),
            Self::V5_0 => (5, 0),
        }
    }
}

impl ServerVersion for CassandraVersion {
    const VARIABLE: &'static str = "TABLEPRO_TEST_CASSANDRA";
    const ALL: &'static [Self] = &[Self::V4_0, Self::V5_0];

    fn name(self) -> &'static str {
        match self {
            Self::V4_0 => "4.0",
            Self::V5_0 => "5.0",
        }
    }

    fn image(self) -> FixtureImage {
        match self {
            Self::V4_0 => FixtureImage::CASSANDRA_4_0,
            Self::V5_0 => FixtureImage::CASSANDRA,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_version_pins_the_image_of_its_release() {
        crate::server_version::tests::check_releases::<CassandraVersion>("cassandra");
        for &version in CassandraVersion::ALL {
            let (major, minor) = version.reported();
            assert_eq!(version.image().tag, format!("{major}.{minor}"));
            assert_eq!(version.name(), version.image().tag);
        }
        assert_eq!(CassandraVersion::default().image(), FixtureImage::CASSANDRA);
    }
}
