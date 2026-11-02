use testcontainers::GenericImage;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FixtureImage {
    pub name: &'static str,
    pub tag: &'static str,
}

impl FixtureImage {
    pub const POSTGRES: Self = Self {
        name: "postgres",
        tag: "17-alpine",
    };
    pub const POSTGRES_13: Self = Self {
        name: "postgres",
        tag: "13-alpine",
    };
    pub const POSTGRES_14: Self = Self {
        name: "postgres",
        tag: "14-alpine",
    };
    pub const POSTGRES_18: Self = Self {
        name: "postgres",
        tag: "18-alpine",
    };
    pub const MYSQL: Self = Self {
        name: "mysql",
        tag: "8.4",
    };
    pub const MYSQL_8_0: Self = Self {
        name: "mysql",
        tag: "8.0",
    };
    pub const MYSQL_9_7: Self = Self {
        name: "mysql",
        tag: "9.7",
    };
    pub const MARIADB: Self = Self {
        name: "mariadb",
        tag: "11.4",
    };
    pub const MARIADB_10_11: Self = Self {
        name: "mariadb",
        tag: "10.11",
    };
    pub const MARIADB_12_3: Self = Self {
        name: "mariadb",
        tag: "12.3",
    };
    pub const MSSQL: Self = Self {
        name: "mcr.microsoft.com/mssql/server",
        tag: "2022-CU14-ubuntu-22.04",
    };
    pub const MSSQL_2017: Self = Self {
        name: "mcr.microsoft.com/mssql/server",
        tag: "2017-CU31-GDR19-ubuntu-18.04",
    };
    pub const MSSQL_2019: Self = Self {
        name: "mcr.microsoft.com/mssql/server",
        tag: "2019-CU32-GDR12-ubuntu-20.04",
    };
    pub const MSSQL_2025: Self = Self {
        name: "mcr.microsoft.com/mssql/server",
        tag: "2025-CU9-GDR1-ubuntu-22.04",
    };
    pub const CLICKHOUSE: Self = Self {
        name: "clickhouse/clickhouse-server",
        tag: "26.8",
    };
    pub const CLICKHOUSE_26_3: Self = Self {
        name: "clickhouse/clickhouse-server",
        tag: "26.3",
    };
    pub const CASSANDRA: Self = Self {
        name: "cassandra",
        tag: "5.0",
    };
    pub const CASSANDRA_4_0: Self = Self {
        name: "cassandra",
        tag: "4.0",
    };
    pub const SCYLLA: Self = Self {
        name: "scylladb/scylla",
        tag: "2026.1",
    };
    pub const SCYLLA_2025_1: Self = Self {
        name: "scylladb/scylla",
        tag: "2025.1",
    };
    pub const REDIS: Self = Self {
        name: "redis",
        tag: "8.10-alpine",
    };
    pub const REDIS_7_4: Self = Self {
        name: "redis",
        tag: "7.4-alpine",
    };
    pub const MONGO: Self = Self {
        name: "mongo",
        tag: "8.0",
    };
    pub const MONGO_7_0: Self = Self {
        name: "mongo",
        tag: "7.0",
    };
    pub const PGBOUNCER: Self = Self {
        name: "edoburu/pgbouncer",
        tag: "v1.25.2-p0",
    };
    pub const OPENSSH: Self = Self {
        name: "linuxserver/openssh-server",
        tag: "version-10.3_p1-r1",
    };
    pub const OPENSSH_9_9: Self = Self {
        name: "linuxserver/openssh-server",
        tag: "version-9.9_p2-r0",
    };

    pub fn generic(self) -> GenericImage {
        GenericImage::new(self.name, self.tag)
    }
}
