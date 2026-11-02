use crate::MysqlFlavour;

/// How a MySQL or MariaDB fixture's server is started.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MysqlOptions {
    pub flavour: MysqlFlavour,
    /// Off lets the password user log in without TLS, which the RSA
    /// password exchange needs to be tested at all. The TLS suites keep
    /// it on, so a plaintext login is refused by the server itself.
    pub require_secure_transport: bool,
    /// On lets the password user create triggers and routines. MySQL's
    /// binary log is on, and without it only a login with SUPER may
    /// create one.
    pub trust_function_creators: bool,
    /// Passed to the server after the TLS arguments, so a test can set a
    /// global such as `--sql-mode` before any session exists.
    pub server_arguments: Vec<String>,
}

impl MysqlOptions {
    pub fn new(flavour: MysqlFlavour) -> Self {
        Self {
            flavour,
            require_secure_transport: true,
            trust_function_creators: false,
            server_arguments: Vec::new(),
        }
    }

    pub fn allowing_plaintext(self) -> Self {
        Self {
            require_secure_transport: false,
            ..self
        }
    }

    pub fn trusting_function_creators(self) -> Self {
        Self {
            trust_function_creators: true,
            ..self
        }
    }

    pub fn with_server_argument(mut self, argument: impl Into<String>) -> Self {
        self.server_arguments.push(argument.into());
        self
    }
}
