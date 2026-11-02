use tablepro_core::ServerInfo;

/// What `INFO server` says the server is. Valkey answers with its own
/// name and version beside the Redis version it is compatible with.
pub(crate) fn server_info(info: &str) -> ServerInfo {
    let field = |name: &str| {
        info.lines()
            .find_map(|line| line.trim().strip_prefix(name)?.strip_prefix(':'))
            .map(str::trim)
    };
    let (product, version) = match (field("server_name"), field("valkey_version")) {
        (Some("valkey"), Some(version)) => ("Valkey", version),
        _ => ("Redis", field("redis_version").unwrap_or_default()),
    };
    let mut parts = version.split('.').map(|part| part.parse::<u32>().unwrap_or(0));
    let mut next = || parts.next().unwrap_or(0);
    let (major, minor, patch) = (next(), next(), next());
    ServerInfo::new(product, version, major, minor, patch)
}

/// When the login may not run `INFO`, the server is named without a
/// version.
pub(crate) fn unknown() -> ServerInfo {
    ServerInfo::new("Redis", "", 0, 0, 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redis_reads_its_version() {
        let info = server_info("# Server\r\nredis_version:7.4.1\r\nredis_mode:standalone\r\n");

        assert_eq!(info, ServerInfo::new("Redis", "7.4.1", 7, 4, 1));
    }

    #[test]
    fn valkey_reads_its_own_version() {
        let info = server_info("# Server\r\nredis_version:7.2.4\r\nserver_name:valkey\r\nvalkey_version:8.1.0\r\n");

        assert_eq!(info, ServerInfo::new("Valkey", "8.1.0", 8, 1, 0));
    }
}
