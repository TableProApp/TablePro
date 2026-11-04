use testcontainers::core::WaitFor;

use crate::{FixtureError, FixtureImage, MariadbVersion, MysqlVersion, ServerVersion};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MysqlFlavour {
    Mysql,
    Mariadb,
}

impl MysqlFlavour {
    /// The image of the release the flavour's variable picks, and the
    /// major and minor version that release reports.
    pub fn selected(self) -> Result<(FixtureImage, (u32, u32)), FixtureError> {
        Ok(match self {
            Self::Mysql => {
                let version = MysqlVersion::selected()?;
                (version.image(), version.reported())
            }
            Self::Mariadb => {
                let version = MariadbVersion::selected()?;
                (version.image(), version.reported())
            }
        })
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
