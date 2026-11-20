use tablepro_core::ServerInfo;

// A cluster node is told apart since SELECT there reaches only the databases the cluster serves.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ServerReport {
    pub(crate) info: ServerInfo,
    pub(crate) cluster: bool,
}

pub(crate) fn server_report(info: &str) -> ServerReport {
    ServerReport {
        info: server_info(info),
        cluster: field(info, "redis_mode") == Some("cluster"),
    }
}

fn field<'a>(info: &'a str, name: &str) -> Option<&'a str> {
    info.lines()
        .find_map(|line| line.trim().strip_prefix(name)?.strip_prefix(':'))
        .map(str::trim)
}

// Valkey answers with its own name and version beside the Redis version it is compatible with.
fn server_info(info: &str) -> ServerInfo {
    let (product, version) = match (field(info, "server_name"), field(info, "valkey_version")) {
        (Some("valkey"), Some(version)) => ("Valkey", version),
        _ => ("Redis", field(info, "redis_version").unwrap_or_default()),
    };
    let mut parts = version.split('.').map(|part| part.parse::<u32>().unwrap_or(0));
    let mut next = || parts.next().unwrap_or(0);
    let (major, minor, patch) = (next(), next(), next());
    ServerInfo::new(product, version, major, minor, patch)
}

// A login that may not run INFO connects without a version, taken for a server of its own.
pub(crate) fn unknown() -> ServerReport {
    ServerReport {
        info: ServerInfo::new("Redis", "", 0, 0, 0),
        cluster: false,
    }
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

    #[test]
    fn a_cluster_node_says_so_in_its_mode() {
        let node = server_report("# Server\r\nredis_version:7.4.1\r\nredis_mode:cluster\r\n");
        let alone = server_report("# Server\r\nredis_version:7.4.1\r\nredis_mode:standalone\r\n");

        assert!(node.cluster);
        assert!(!alone.cluster);
        assert!(!server_report("# Server\r\nredis_version:2.8.0\r\n").cluster);
    }
}
