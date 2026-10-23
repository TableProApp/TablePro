use crate::{FixtureImage, ServerVersion};

/// The MongoDB release a fixture runs: the newest, and the oldest MongoDB
/// still ships fixes for.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum MongoVersion {
    V7_0,
    #[default]
    V8_0,
}

impl MongoVersion {
    /// The major and minor version `buildInfo` reports.
    pub fn reported(self) -> (u32, u32) {
        match self {
            Self::V7_0 => (7, 0),
            Self::V8_0 => (8, 0),
        }
    }
}

impl ServerVersion for MongoVersion {
    const VARIABLE: &'static str = "TABLEPRO_TEST_MONGO";
    const ALL: &'static [Self] = &[Self::V7_0, Self::V8_0];

    fn name(self) -> &'static str {
        match self {
            Self::V7_0 => "7.0",
            Self::V8_0 => "8.0",
        }
    }

    fn image(self) -> FixtureImage {
        match self {
            Self::V7_0 => FixtureImage::MONGO_7_0,
            Self::V8_0 => FixtureImage::MONGO,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_version_pins_the_image_of_its_release() {
        crate::server_version::tests::check_releases::<MongoVersion>("mongo");
        for &version in MongoVersion::ALL {
            let (major, minor) = version.reported();
            assert!(version.image().tag.starts_with(&format!("{major}.{minor}")));
        }
        assert_eq!(MongoVersion::default().image(), FixtureImage::MONGO);
    }
}
