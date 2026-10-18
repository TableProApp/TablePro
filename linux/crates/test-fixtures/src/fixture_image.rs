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
    pub const PGBOUNCER: Self = Self {
        name: "edoburu/pgbouncer",
        tag: "v1.25.2-p0",
    };
    pub const OPENSSH: Self = Self {
        name: "linuxserver/openssh-server",
        tag: "version-10.3_p1-r1",
    };

    pub fn generic(self) -> GenericImage {
        GenericImage::new(self.name, self.tag)
    }
}
