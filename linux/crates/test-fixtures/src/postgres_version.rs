use crate::FixtureImage;

/// The PostgreSQL major a fixture runs.
///
/// The catalog and the decoders have to hold on the oldest and the
/// newest server the app supports, so those two ends are the choices
/// beside the default.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum PostgresVersion {
    V13,
    #[default]
    V17,
    V18,
}

impl PostgresVersion {
    pub fn image(self) -> FixtureImage {
        match self {
            Self::V13 => FixtureImage::POSTGRES_13,
            Self::V17 => FixtureImage::POSTGRES,
            Self::V18 => FixtureImage::POSTGRES_18,
        }
    }

    pub fn major(self) -> u32 {
        match self {
            Self::V13 => 13,
            Self::V17 => 17,
            Self::V18 => 18,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_version_pins_the_image_of_its_major() {
        for version in [PostgresVersion::V13, PostgresVersion::V17, PostgresVersion::V18] {
            let image = version.image();

            assert_eq!(image.name, "postgres");
            assert_eq!(image.tag, format!("{}-alpine", version.major()));
        }
        assert_eq!(PostgresVersion::default().image(), FixtureImage::POSTGRES);
    }
}
