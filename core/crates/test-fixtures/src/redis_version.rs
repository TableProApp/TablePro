use crate::{FixtureImage, ServerVersion};

/// The Redis release a fixture runs: the newest, and the oldest Redis
/// still ships fixes for.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum RedisVersion {
    V7_4,
    #[default]
    V8_10,
}

impl RedisVersion {
    /// The major and minor version `INFO server` reports.
    pub fn reported(self) -> (u32, u32) {
        match self {
            Self::V7_4 => (7, 4),
            Self::V8_10 => (8, 10),
        }
    }
}

impl ServerVersion for RedisVersion {
    const VARIABLE: &'static str = "TABLEPRO_TEST_REDIS";
    const ALL: &'static [Self] = &[Self::V7_4, Self::V8_10];

    fn name(self) -> &'static str {
        match self {
            Self::V7_4 => "7.4",
            Self::V8_10 => "8.10",
        }
    }

    fn image(self) -> FixtureImage {
        match self {
            Self::V7_4 => FixtureImage::REDIS_7_4,
            Self::V8_10 => FixtureImage::REDIS,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_version_pins_the_image_of_its_release() {
        crate::server_version::tests::check_releases::<RedisVersion>("redis");
        for &version in RedisVersion::ALL {
            let (major, minor) = version.reported();
            assert_eq!(version.image().tag, format!("{major}.{minor}-alpine"));
            assert_eq!(format!("{}-alpine", version.name()), version.image().tag);
        }
        assert_eq!(RedisVersion::default().image(), FixtureImage::REDIS);
    }
}
