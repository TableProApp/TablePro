use crate::{FixtureImage, ServerVersion};

/// The SQL Server release a fixture runs.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum MssqlVersion {
    V2017,
    V2019,
    #[default]
    V2022,
    V2025,
}

impl MssqlVersion {
    /// The major version `SERVERPROPERTY('ProductVersion')` reports,
    /// which is not the year in the release's name.
    pub fn major(self) -> u32 {
        match self {
            Self::V2017 => 14,
            Self::V2019 => 15,
            Self::V2022 => 16,
            Self::V2025 => 17,
        }
    }
}

impl ServerVersion for MssqlVersion {
    const VARIABLE: &'static str = "TABLEPRO_TEST_MSSQL";
    const ALL: &'static [Self] = &[Self::V2017, Self::V2019, Self::V2022, Self::V2025];

    fn name(self) -> &'static str {
        match self {
            Self::V2017 => "2017",
            Self::V2019 => "2019",
            Self::V2022 => "2022",
            Self::V2025 => "2025",
        }
    }

    fn image(self) -> FixtureImage {
        match self {
            Self::V2017 => FixtureImage::MSSQL_2017,
            Self::V2019 => FixtureImage::MSSQL_2019,
            Self::V2022 => FixtureImage::MSSQL,
            Self::V2025 => FixtureImage::MSSQL_2025,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_version_pins_the_image_of_its_year() {
        crate::server_version::tests::check_releases::<MssqlVersion>("mcr.microsoft.com/mssql/server");
        for &version in MssqlVersion::ALL {
            assert!(version.image().tag.starts_with(&format!("{}-", version.name())));
        }
        assert_eq!(MssqlVersion::default().image(), FixtureImage::MSSQL);
    }
}
