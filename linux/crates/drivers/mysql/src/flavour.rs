use tablepro_core::ServerInfo;

/// Which of the two servers speaking the MySQL protocol is on the other
/// end. They share the wire and most of the SQL, but name their timeouts,
/// error numbers and catalogue columns differently.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MySqlFlavour {
    MySql,
    MariaDb,
}

impl MySqlFlavour {
    /// MariaDB says so in `VERSION()`, as in `11.4.5-MariaDB-ubu2404`.
    pub fn detect(version: &str) -> Self {
        match version.to_ascii_lowercase().contains("mariadb") {
            true => Self::MariaDb,
            false => Self::MySql,
        }
    }

    pub fn product(self) -> &'static str {
        match self {
            Self::MySql => "MySQL",
            Self::MariaDb => "MariaDB",
        }
    }

    /// What the server reported, with its major and minor version read
    /// from the leading `major.minor`.
    pub fn server_info(self, version: &str) -> ServerInfo {
        let mut parts = version
            .split(|character: char| !character.is_ascii_digit())
            .filter(|part| !part.is_empty())
            .map(|part| part.parse::<u32>().unwrap_or(0));
        let major = parts.next().unwrap_or(0);
        let minor = parts.next().unwrap_or(0);
        ServerInfo::new(self.product(), version, major, minor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_mariadb_from_version_string() {
        assert_eq!(MySqlFlavour::detect("11.4.5-MariaDB-ubu2404"), MySqlFlavour::MariaDb);
        assert_eq!(MySqlFlavour::detect("10.6.18-mariadb-log"), MySqlFlavour::MariaDb);
        assert_eq!(MySqlFlavour::detect("8.4.3"), MySqlFlavour::MySql);
        assert_eq!(MySqlFlavour::detect("8.0.40-0ubuntu0.24.04.1"), MySqlFlavour::MySql);

        let info = MySqlFlavour::MariaDb.server_info("11.4.5-MariaDB-ubu2404");
        assert_eq!((info.product.as_str(), info.major, info.minor), ("MariaDB", 11, 4));
        let info = MySqlFlavour::MySql.server_info("8.4.3");
        assert_eq!((info.product.as_str(), info.major, info.minor), ("MySQL", 8, 4));
    }
}
