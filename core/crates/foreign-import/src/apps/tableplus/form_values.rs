use crate::ForeignSslMode::{self, Disabled, Preferred, Required, VerifyCa, VerifyIdentity};

// The index of TablePlus's password popup, as it saves it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PasswordMode {
    StoreInKeychain,
    AskEveryTime,
    NoPassword,
    CommandLine,
}

impl PasswordMode {
    pub(super) fn from_index(index: Option<i64>) -> Self {
        match index {
            Some(1) => Self::AskEveryTime,
            Some(2) => Self::NoPassword,
            Some(3) => Self::CommandLine,
            _ => Self::StoreInKeychain,
        }
    }

    pub(super) fn stores_password_in_keychain(self) -> bool {
        self == Self::StoreInKeychain
    }

    pub(super) fn prompts_for_password(self) -> bool {
        matches!(self, Self::AskEveryTime | Self::CommandLine)
    }
}

// Which entry of `TlsKeyPaths` each file picker of a driver's form writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct TlsKeySlots {
    pub client_key: Option<usize>,
    pub client_certificate: Option<usize>,
    pub certificate_authority: Option<usize>,
}

const KEY_CERTIFICATE_AUTHORITY: TlsKeySlots = TlsKeySlots {
    client_key: Some(0),
    client_certificate: Some(1),
    certificate_authority: Some(2),
};
const CERTIFICATE_KEY_AUTHORITY: TlsKeySlots = TlsKeySlots {
    client_key: None,
    client_certificate: Some(0),
    certificate_authority: Some(1),
};
const AUTHORITY_ONLY: TlsKeySlots = TlsKeySlots {
    client_key: None,
    client_certificate: None,
    certificate_authority: Some(0),
};
const NO_SLOTS: TlsKeySlots = TlsKeySlots {
    client_key: None,
    client_certificate: None,
    certificate_authority: None,
};

#[derive(Debug, PartialEq, Eq)]
pub(super) struct TlsForm {
    // `tLSMode` is an index into the driver's own popup.
    pub modes: &'static [ForeignSslMode],
    pub slots: TlsKeySlots,
}

const MYSQL: TlsForm = TlsForm {
    modes: &[Preferred, Disabled, Required, VerifyCa, VerifyIdentity],
    slots: KEY_CERTIFICATE_AUTHORITY,
};
const MARIADB: TlsForm = TlsForm {
    modes: &[Preferred, Required, VerifyIdentity],
    slots: KEY_CERTIFICATE_AUTHORITY,
};
const POSTGRES: TlsForm = TlsForm {
    modes: &[Preferred, Disabled, Required, Preferred, VerifyCa, VerifyIdentity],
    slots: KEY_CERTIFICATE_AUTHORITY,
};
const CASSANDRA: TlsForm = TlsForm {
    modes: &[Disabled, Required, VerifyCa, VerifyIdentity, VerifyIdentity],
    slots: KEY_CERTIFICATE_AUTHORITY,
};
const REDIS: TlsForm = TlsForm {
    modes: &[Disabled, Required, VerifyCa],
    slots: KEY_CERTIFICATE_AUTHORITY,
};
const CLICKHOUSE: TlsForm = TlsForm {
    modes: &[Disabled, VerifyIdentity, Required],
    slots: AUTHORITY_ONLY,
};
const MONGO: TlsForm = TlsForm {
    modes: &[Disabled, VerifyIdentity, Required],
    slots: CERTIFICATE_KEY_AUTHORITY,
};
const ELASTICSEARCH: TlsForm = TlsForm {
    modes: &[Disabled, VerifyIdentity, VerifyCa, Required],
    slots: AUTHORITY_ONLY,
};
const ORACLE: TlsForm = TlsForm {
    modes: &[Disabled, Required],
    slots: NO_SLOTS,
};
const WITHOUT_PICKER: TlsForm = TlsForm {
    modes: &[Preferred],
    slots: NO_SLOTS,
};

pub(super) fn tls_form(driver: &str) -> &'static TlsForm {
    match driver {
        "MySQL" => &MYSQL,
        "MariaDB" => &MARIADB,
        "PostgreSQL" | "Cockroach" | "Greenplum" | "Redshift" | "Vertica" => &POSTGRES,
        "Cassandra" => &CASSANDRA,
        "Redis" => &REDIS,
        "ClickHouse" => &CLICKHOUSE,
        "Mongo" => &MONGO,
        "ElasticSearch" => &ELASTICSEARCH,
        "Oracle" => &ORACLE,
        _ => &WITHOUT_PICKER,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unknown_password_mode_index_means_the_keychain() {
        assert_eq!(PasswordMode::from_index(None), PasswordMode::StoreInKeychain);
        assert_eq!(PasswordMode::from_index(Some(47)), PasswordMode::StoreInKeychain);
        assert_eq!(PasswordMode::from_index(Some(-1)), PasswordMode::StoreInKeychain);
        assert_eq!(PasswordMode::from_index(Some(3)), PasswordMode::CommandLine);
        assert!(PasswordMode::AskEveryTime.prompts_for_password());
        assert!(PasswordMode::CommandLine.prompts_for_password());
        assert!(!PasswordMode::NoPassword.prompts_for_password());
        assert!(!PasswordMode::NoPassword.stores_password_in_keychain());
    }

    #[test]
    fn a_driver_without_its_own_popup_offers_preferred_only() {
        assert_eq!(tls_form("MicrosoftSQLServer"), &WITHOUT_PICKER);
        assert_eq!(tls_form("Snowflake").modes, &[Preferred]);
        assert_eq!(tls_form("mysql"), &WITHOUT_PICKER);
        assert_eq!(tls_form("Greenplum"), &POSTGRES);
        assert_eq!(tls_form("Mongo").slots, CERTIFICATE_KEY_AUTHORITY);
    }
}
