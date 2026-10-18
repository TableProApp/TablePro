use secrecy::SecretString;

use crate::auth_mode::AuthMode;

/// What a network connection logs in with.
///
/// The password is a `SecretString`, so a `Debug` print of a connect
/// request never shows it.
#[derive(Debug, Clone)]
pub enum Credentials {
    Password {
        username: String,
        password: SecretString,
    },
    /// The operating system's own login, so nothing is sent from here.
    Integrated,
}

impl Credentials {
    pub fn mode(&self) -> AuthMode {
        match self {
            Self::Password { .. } => AuthMode::Password,
            Self::Integrated => AuthMode::Kerberos,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integrated_credentials_log_in_with_kerberos() {
        let password = Credentials::Password {
            username: "deploy".to_owned(),
            password: SecretString::from("hunter2"),
        };

        assert_eq!(password.mode(), AuthMode::Password);
        assert_eq!(Credentials::Integrated.mode(), AuthMode::Kerberos);
    }

    #[test]
    fn a_debug_print_never_shows_the_password() {
        let credentials = Credentials::Password {
            username: "deploy".to_owned(),
            password: SecretString::from("hunter2"),
        };

        let printed = format!("{credentials:?}");

        assert!(printed.contains("deploy"));
        assert!(!printed.contains("hunter2"), "the password leaked: {printed}");
    }
}
