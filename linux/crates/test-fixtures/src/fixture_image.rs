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
    pub const MYSQL: Self = Self {
        name: "mysql",
        tag: "8.4",
    };
    pub const MARIADB: Self = Self {
        name: "mariadb",
        tag: "11.4",
    };
    pub const MSSQL: Self = Self {
        name: "mcr.microsoft.com/mssql/server",
        tag: "2022-CU14-ubuntu-22.04",
    };
    pub const CLICKHOUSE: Self = Self {
        name: "clickhouse/clickhouse-server",
        tag: "25.8",
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
