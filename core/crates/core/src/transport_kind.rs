use std::path::PathBuf;

use crate::TransportClass;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TransportKind {
    DirectTcp,
    SshForward { destination: String },
    LocalSocket { path: PathBuf },
}

impl TransportKind {
    pub fn class(&self) -> TransportClass {
        match self {
            Self::DirectTcp => TransportClass::DirectTcp,
            Self::SshForward { .. } => TransportClass::SshForward,
            Self::LocalSocket { .. } => TransportClass::LocalSocket,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssh_forward_class_is_ssh_forward() {
        let forward = TransportKind::SshForward {
            destination: "bastion".to_owned(),
        };
        assert_eq!(forward.class(), TransportClass::SshForward);
        assert_eq!(TransportKind::DirectTcp.class(), TransportClass::DirectTcp);
        let socket = TransportKind::LocalSocket {
            path: PathBuf::from("/run/postgresql/.s.PGSQL.5432"),
        };
        assert_eq!(socket.class(), TransportClass::LocalSocket);
    }
}
