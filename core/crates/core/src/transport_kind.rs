use crate::TransportClass;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TransportKind {
    DirectTcp,
    SshForward { destination: String },
}

impl TransportKind {
    pub fn class(&self) -> TransportClass {
        match self {
            Self::DirectTcp => TransportClass::DirectTcp,
            Self::SshForward { .. } => TransportClass::SshForward,
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
    }
}
