use crate::{FixtureImage, ServerVersion};

/// The PostgreSQL major a fixture runs.
///
/// 10 to 13 are past their end of life. The driver still reads their
/// catalogs, and a test checks each of them.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum PostgresVersion {
    V10,
    V11,
    V12,
    V13,
    V14,
    V15,
    #[default]
    V17,
    V18,
}

impl PostgresVersion {
    pub fn major(self) -> u32 {
        match self {
            Self::V10 => 10,
            Self::V11 => 11,
            Self::V12 => 12,
            Self::V13 => 13,
            Self::V14 => 14,
            Self::V15 => 15,
            Self::V17 => 17,
            Self::V18 => 18,
        }
    }
}

impl ServerVersion for PostgresVersion {
    const VARIABLE: &'static str = "TABLEPRO_TEST_POSTGRES";
    const ALL: &'static [Self] = &[
        Self::V10,
        Self::V11,
        Self::V12,
        Self::V13,
        Self::V14,
        Self::V15,
        Self::V17,
        Self::V18,
    ];

    fn name(self) -> &'static str {
        match self {
            Self::V10 => "10",
            Self::V11 => "11",
            Self::V12 => "12",
            Self::V13 => "13",
            Self::V14 => "14",
            Self::V15 => "15",
            Self::V17 => "17",
            Self::V18 => "18",
        }
    }

    fn image(self) -> FixtureImage {
        match self {
            Self::V10 => FixtureImage::POSTGRES_10,
            Self::V11 => FixtureImage::POSTGRES_11,
            Self::V12 => FixtureImage::POSTGRES_12,
            Self::V13 => FixtureImage::POSTGRES_13,
            Self::V14 => FixtureImage::POSTGRES_14,
            Self::V15 => FixtureImage::POSTGRES_15,
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
