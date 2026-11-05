use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ConnectionUrlError {
    #[error("this is not a connection URL")]
    Invalid,

    #[error("no engine reads {scheme} URLs")]
    UnknownScheme { scheme: String },

    #[error("the URL names no host")]
    NoHost,

    #[error("only a MongoDB URL lists several hosts")]
    SeveralHosts,

    #[error("the port is not a number from 1 to 65535")]
    InvalidPort,

    #[error("a mongodb+srv URL names one host and no port")]
    SeedListHost,

    #[error("a Redis URL's path is the database number")]
    DatabaseNumber,

    #[error("a path in the URL must be absolute")]
    RelativePath,

    #[error("a SQL Server instance name needs its port instead")]
    InstanceName,

    #[error("the {mechanism} login is not supported")]
    AuthMechanism { mechanism: String },

    #[error("directConnection=true takes one host and no seed list, and false a replica set or several hosts")]
    DirectConnection,

    #[error("the {name} protection is not supported")]
    UnsupportedParameter { name: String },
}

impl ConnectionUrlError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Invalid => "url.invalid",
            Self::UnknownScheme { .. } => "url.unknown_scheme",
            Self::NoHost => "url.no_host",
            Self::SeveralHosts => "url.several_hosts",
            Self::InvalidPort => "url.invalid_port",
            Self::SeedListHost => "url.seed_list_host",
            Self::DatabaseNumber => "url.database_number",
            Self::RelativePath => "url.relative_path",
            Self::InstanceName => "url.instance_name",
            Self::AuthMechanism { .. } => "url.auth_mechanism",
            Self::DirectConnection => "url.direct_connection",
            Self::UnsupportedParameter { .. } => "url.unsupported_parameter",
        }
    }
}
