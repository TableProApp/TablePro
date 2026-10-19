use crate::{FixtureImage, ServerVersion};

/// The PostgreSQL major a fixture runs.
///
/// 13 is past its end of life, and stays for the catalog query the
/// driver keeps for servers before 14.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum PostgresVersion {
    V13,
    V14,
    #[default]
    V17,
    V18,
}

impl PostgresVersion {
    pub fn major(self) -> u32 {
        match self {
            Self::V13 => 13,
            Self::V14 => 14,
            Self::V17 => 17,
            Self::V18 => 18,
        }
    }
}

impl ServerVersion for PostgresVersion {
    const VARIABLE: &'static str = "TABLEPRO_TEST_POSTGRES";
    const ALL: &'static [Self] = &[Self::V13, Self::V14, Self::V17, Self::V18];

    fn name(self) -> &'static str {
        match self {
            Self::V13 => "13",
            Self::V14 => "14",
            Self::V17 => "17",
            Self::V18 => "18",
        }
    }

    fn image(self) -> FixtureImage {
        match self {
            Self::V13 => FixtureImage::POSTGRES_13,
            Self::V14 => FixtureImage::POSTGRES_14,
            Self::V17 => FixtureImage::POSTGRES,
            Self::V18 => FixtureImage::POSTGRES_18,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_version_pins_the_image_of_its_major() {
        crate::server_version::tests::check_releases::<PostgresVersion>("postgres");
        for &version in PostgresVersion::ALL {
            assert_eq!(version.image().tag, format!("{}-alpine", version.major()));
            assert_eq!(version.name(), version.major().to_string());
        }
        assert_eq!(PostgresVersion::default().image(), FixtureImage::POSTGRES);
    }
}
