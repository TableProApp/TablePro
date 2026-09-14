use testcontainers::core::WaitFor;

use crate::FixtureImage;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MysqlFlavour {
    Mysql,
    Mariadb,
}

impl MysqlFlavour {
    pub fn image(self) -> FixtureImage {
        match self {
            Self::Mysql => FixtureImage::MYSQL,
            Self::Mariadb => FixtureImage::MARIADB,
        }
    }

    pub fn environment_prefix(self) -> &'static str {
        match self {
            Self::Mysql => "MYSQL",
            Self::Mariadb => "MARIADB",
        }
    }

    pub fn client_program(self) -> &'static str {
        match self {
            Self::Mysql => "mysql",
            Self::Mariadb => "mariadb",
        }
    }

    pub(crate) fn ready_conditions(self) -> [WaitFor; 2] {
        match self {
            Self::Mysql => [
                WaitFor::message_on_stderr("X Plugin ready for connections. Bind-address"),
                WaitFor::message_on_stderr("/usr/sbin/mysqld: ready for connections."),
            ],
            Self::Mariadb => [
                WaitFor::message_on_stderr("mariadbd: ready for connections."),
                WaitFor::message_on_stderr("port: 3306"),
            ],
        }
    }
}
