use tablepro_core::connection_url::ConnectionUrlError;

// Never echoes the URL, which may hold a password.
pub fn connection_url_message(error: &ConnectionUrlError) -> String {
    match error {
        ConnectionUrlError::Invalid => crate::i18n::gettext("This is not a connection URL."),
        ConnectionUrlError::UnknownScheme { scheme } => {
            crate::i18n::gettext_f("No driver opens {scheme} URLs.", &[("scheme", scheme)])
        }
        ConnectionUrlError::NoHost => crate::i18n::gettext("The URL names no host."),
        ConnectionUrlError::SeveralHosts => {
            crate::i18n::gettext("The URL lists several hosts, which only a MongoDB connection takes.")
        }
        ConnectionUrlError::InvalidPort => crate::i18n::gettext("The URL's port is not a number from 1 to 65535."),
        ConnectionUrlError::SeedListHost => crate::i18n::gettext("A mongodb+srv URL names one host and no port."),
        ConnectionUrlError::DatabaseNumber => {
            crate::i18n::gettext("A Redis URL ends with the database's number, such as /0.")
        }
        ConnectionUrlError::RelativePath => {
            crate::i18n::gettext("A path in the URL must be a full path, starting with /.")
        }
        ConnectionUrlError::InstanceName => crate::i18n::gettext(
            "SQL Server instance names are not supported. Put the instance's port in the URL instead.",
        ),
        ConnectionUrlError::DirectConnection => crate::i18n::gettext(
            "directConnection=true takes one host and no DNS seed list, and false takes a replicaSet or several hosts.",
        ),
        ConnectionUrlError::AuthMechanism { mechanism } => crate::i18n::gettext_f(
            "The URL logs in with {mechanism}, and TablePro logs in to MongoDB with a password only.",
            &[("mechanism", mechanism)],
        ),
    }
}
