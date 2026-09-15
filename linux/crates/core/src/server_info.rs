/// What the server said it is.
///
/// The product name is separate from the version string because
/// MariaDB reports itself through MySQL's own version field, and the
/// two need different SQL for the same question.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerInfo {
    pub product: String,
    pub version: String,
    pub major: u32,
    pub minor: u32,
}

impl ServerInfo {
    pub fn new(product: impl Into<String>, version: impl Into<String>, major: u32, minor: u32) -> Self {
        Self {
            product: product.into(),
            version: version.into(),
            major,
            minor,
        }
    }

    /// Whether the server is at least this version, for a feature that
    /// arrived in one.
    pub fn at_least(&self, major: u32, minor: u32) -> bool {
        (self.major, self.minor) >= (major, minor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_version_gate_compares_minor_versions_too() {
        let server = ServerInfo::new("PostgreSQL", "16.2", 16, 2);

        assert!(server.at_least(13, 0));
        assert!(server.at_least(16, 2));
        assert!(!server.at_least(16, 3));
        assert!(!server.at_least(17, 0));
    }
}
