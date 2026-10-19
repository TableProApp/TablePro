use crate::{FixtureImage, ServerVersion};

/// The MySQL release a fixture runs.
///
/// 8.0 is past Oracle's end of life, but Amazon RDS keeps it under
/// Extended Support until 2029-07-31 and enrols every 8.0 instance.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum MysqlVersion {
    V8_0,
    #[default]
    V8_4,
    V9_7,
}

impl MysqlVersion {
    /// The major and minor version `VERSION()` reports.
    pub fn reported(self) -> (u32, u32) {
        match self {
            Self::V8_0 => (8, 0),
            Self::V8_4 => (8, 4),
            Self::V9_7 => (9, 7),
        }
    }
}

impl ServerVersion for MysqlVersion {
    const VARIABLE: &'static str = "TABLEPRO_TEST_MYSQL";
    const ALL: &'static [Self] = &[Self::V8_0, Self::V8_4, Self::V9_7];

    fn name(self) -> &'static str {
        match self {
            Self::V8_0 => "8.0",
            Self::V8_4 => "8.4",
            Self::V9_7 => "9.7",
        }
    }

    fn image(self) -> FixtureImage {
        match self {
            Self::V8_0 => FixtureImage::MYSQL_8_0,
            Self::V8_4 => FixtureImage::MYSQL,
            Self::V9_7 => FixtureImage::MYSQL_9_7,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_version_pins_the_image_of_its_release() {
        crate::server_version::tests::check_releases::<MysqlVersion>("mysql");
        for &version in MysqlVersion::ALL {
            let (major, minor) = version.reported();
            assert_eq!(version.image().tag, format!("{major}.{minor}"));
            assert_eq!(version.name(), version.image().tag);
        }
        assert_eq!(MysqlVersion::default().image(), FixtureImage::MYSQL);
    }
}
