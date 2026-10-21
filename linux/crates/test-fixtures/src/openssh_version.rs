use crate::{FixtureImage, ServerVersion};

// 9.9 is the last release before 10.0 dropped DSA and made ML-KEM the default key exchange.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum OpenSshVersion {
    V9_9,
    #[default]
    V10_3,
}

impl OpenSshVersion {
    pub fn banner_prefix(self) -> String {
        format!("SSH-2.0-OpenSSH_{}", self.name())
    }
}

impl ServerVersion for OpenSshVersion {
    const VARIABLE: &'static str = "TABLEPRO_TEST_OPENSSH";
    const ALL: &'static [Self] = &[Self::V9_9, Self::V10_3];

    fn name(self) -> &'static str {
        match self {
            Self::V9_9 => "9.9",
            Self::V10_3 => "10.3",
        }
    }

    fn image(self) -> FixtureImage {
        match self {
            Self::V9_9 => FixtureImage::OPENSSH_9_9,
            Self::V10_3 => FixtureImage::OPENSSH,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_version_pins_the_image_of_its_release() {
        crate::server_version::tests::check_releases::<OpenSshVersion>("linuxserver/openssh-server");
        for &version in OpenSshVersion::ALL {
            assert!(
                version
                    .image()
                    .tag
                    .starts_with(&format!("version-{}_p", version.name())),
                "{version:?}"
            );
        }
        assert_eq!(OpenSshVersion::default().image(), FixtureImage::OPENSSH);
    }
}
