use std::path::PathBuf;

use tablepro_storage::{SavedSshAuth, SavedSshConfig};

pub const SSH_AUTH_PASSWORD: u32 = 0;
pub const SSH_AUTH_KEY: u32 = 1;

#[derive(Debug, Clone, PartialEq)]
pub struct SshRowValues {
    pub host: String,
    pub port: f64,
    pub user: String,
    pub auth_index: u32,
    pub key_path: String,
    pub has_passphrase_text: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SshInputError {
    HostRequired,
    PortOutOfRange,
    UserRequired,
    KeyPathRequired,
    UnknownAuth,
}

impl SshInputError {
    pub fn message(self) -> String {
        match self {
            Self::HostRequired => crate::tr!("SSH host is required"),
            Self::PortOutOfRange => crate::tr!("SSH port must be a whole number from 1 to 65535"),
            Self::UserRequired => crate::tr!("SSH username is required"),
            Self::KeyPathRequired => crate::tr!("Private key path is required"),
            Self::UnknownAuth => crate::tr!("Choose an SSH authentication method"),
        }
    }
}

pub fn saved_ssh_from_rows(rows: &SshRowValues) -> Result<SavedSshConfig, SshInputError> {
    let host = rows.host.trim();
    if host.is_empty() {
        return Err(SshInputError::HostRequired);
    }
    if !(1.0..=65535.0).contains(&rows.port) || rows.port.fract() != 0.0 {
        return Err(SshInputError::PortOutOfRange);
    }
    let port = rows.port as u16;
    let user = rows.user.trim();
    if user.is_empty() {
        return Err(SshInputError::UserRequired);
    }
    let auth = match rows.auth_index {
        SSH_AUTH_PASSWORD => SavedSshAuth::Password,
        SSH_AUTH_KEY => {
            let path = rows.key_path.trim();
            if path.is_empty() {
                return Err(SshInputError::KeyPathRequired);
            }
            SavedSshAuth::PrivateKey {
                path: Some(PathBuf::from(path)),
                has_passphrase: rows.has_passphrase_text,
            }
        }
        _ => return Err(SshInputError::UnknownAuth),
    };
    Ok(SavedSshConfig {
        host: host.to_owned(),
        port: Some(port),
        username: Some(user.to_owned()),
        jump_hosts: Vec::new(),
        auth,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows(auth_index: u32) -> SshRowValues {
        SshRowValues {
            host: " bastion.example.com ".to_owned(),
            port: 2222.0,
            user: "deploy".to_owned(),
            auth_index,
            key_path: "/home/deploy/.ssh/id_ed25519".to_owned(),
            has_passphrase_text: true,
        }
    }

    #[test]
    fn saved_ssh_from_rows_password_and_key() {
        let password = saved_ssh_from_rows(&rows(SSH_AUTH_PASSWORD)).unwrap();
        assert_eq!(password.host, "bastion.example.com");
        assert_eq!(password.port, Some(2222));
        assert_eq!(password.username.as_deref(), Some("deploy"));
        assert!(password.jump_hosts.is_empty());
        assert_eq!(password.auth, SavedSshAuth::Password);

        let key = saved_ssh_from_rows(&rows(SSH_AUTH_KEY)).unwrap();
        assert_eq!(
            key.auth,
            SavedSshAuth::PrivateKey {
                path: Some(PathBuf::from("/home/deploy/.ssh/id_ed25519")),
                has_passphrase: true,
            }
        );

        let missing_key = SshRowValues {
            key_path: "  ".to_owned(),
            ..rows(SSH_AUTH_KEY)
        };
        assert_eq!(saved_ssh_from_rows(&missing_key), Err(SshInputError::KeyPathRequired));
        let missing_user = SshRowValues {
            user: String::new(),
            ..rows(SSH_AUTH_PASSWORD)
        };
        assert_eq!(saved_ssh_from_rows(&missing_user), Err(SshInputError::UserRequired));
        assert_eq!(saved_ssh_from_rows(&rows(7)), Err(SshInputError::UnknownAuth));
    }

    #[test]
    fn saved_ssh_from_rows_rejects_port_out_of_range() {
        for port in [0.0, 65536.0, 22.5, -1.0] {
            let invalid = SshRowValues {
                port,
                ..rows(SSH_AUTH_PASSWORD)
            };
            assert_eq!(
                saved_ssh_from_rows(&invalid),
                Err(SshInputError::PortOutOfRange),
                "{port}"
            );
        }
        let highest = SshRowValues {
            port: 65535.0,
            ..rows(SSH_AUTH_PASSWORD)
        };
        assert_eq!(saved_ssh_from_rows(&highest).unwrap().port, Some(65535));
    }
}
