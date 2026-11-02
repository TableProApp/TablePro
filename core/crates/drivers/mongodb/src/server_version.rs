use tablepro_core::ServerInfo;

/// What `buildInfo` says the server is. A login that may not ask is
/// named without a version.
pub(crate) fn server_info(version: &str) -> ServerInfo {
    let mut parts = version.split(['.', '-']).map(|part| part.parse::<u32>().unwrap_or(0));
    let mut next = || parts.next().unwrap_or(0);
    let (major, minor, patch) = (next(), next(), next());
    ServerInfo::new("MongoDB", version, major, minor, patch)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mongodb_reads_its_version() {
        assert_eq!(server_info("8.0.4"), ServerInfo::new("MongoDB", "8.0.4", 8, 0, 4));
        assert_eq!(
            server_info("7.0.0-rc1"),
            ServerInfo::new("MongoDB", "7.0.0-rc1", 7, 0, 0)
        );
        assert_eq!(server_info(""), ServerInfo::new("MongoDB", "", 0, 0, 0));
    }
}
