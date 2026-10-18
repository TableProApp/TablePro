#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HbaMode {
    Password,
    HostSslOnly,
    ClientCertificate,
}

impl HbaMode {
    pub fn uses_tls(self) -> bool {
        !matches!(self, Self::Password)
    }

    pub fn pg_hba(self) -> Option<&'static str> {
        match self {
            Self::Password => None,
            Self::HostSslOnly => Some(
                "local all all trust\n\
                 hostssl all all all scram-sha-256\n\
                 hostnossl all all all reject\n",
            ),
            Self::ClientCertificate => Some(
                "local all all trust\n\
                 hostssl all tablepro_client all cert\n\
                 hostssl all all all scram-sha-256\n\
                 hostnossl all all all reject\n",
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line_index(hba: &str, line: &str) -> usize {
        hba.lines().position(|candidate| candidate == line).unwrap()
    }

    #[test]
    fn client_certificate_hba_puts_cert_before_scram_and_rejects_plaintext() {
        let hba = HbaMode::ClientCertificate.pg_hba().unwrap();

        let certificate = line_index(hba, "hostssl all tablepro_client all cert");
        let password = line_index(hba, "hostssl all all all scram-sha-256");
        let plaintext = line_index(hba, "hostnossl all all all reject");

        assert!(certificate < password);
        assert!(password < plaintext);
        assert_eq!(line_index(hba, "local all all trust"), 0);
    }

    #[test]
    fn host_ssl_only_hba_rejects_plaintext() {
        let hba = HbaMode::HostSslOnly.pg_hba().unwrap();

        assert!(line_index(hba, "hostssl all all all scram-sha-256") < line_index(hba, "hostnossl all all all reject"));
        assert!(!hba.contains(" cert"));
    }

    #[test]
    fn password_mode_keeps_the_image_defaults() {
        assert_eq!(HbaMode::Password.pg_hba(), None);
        assert!(!HbaMode::Password.uses_tls());
    }
}
