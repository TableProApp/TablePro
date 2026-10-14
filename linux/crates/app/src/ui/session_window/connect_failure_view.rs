use tablepro_session::ConnectSource;

use super::session_window_command::ConnectFailure;

/// What the failed page says, and whether it offers Edit Connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ConnectFailureView {
    /// Built from the error's kind, never from what the request carried,
    /// so no password reaches the page or the screen reader.
    pub message: String,
    pub can_edit: bool,
}

impl ConnectFailureView {
    pub(crate) fn new(failure: &ConnectFailure, source: &ConnectSource) -> Self {
        Self {
            message: failure.message.clone(),
            can_edit: can_edit(source),
        }
    }
}

/// Only what the connect dialog shows can be edited: a saved connection,
/// or one typed into the dialog. A file opened from the file manager was
/// never in it.
fn can_edit(source: &ConnectSource) -> bool {
    match source {
        ConnectSource::Saved(_) => true,
        ConnectSource::Intent(intent) => intent.pending_save.is_some(),
        ConnectSource::File(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use secrecy::SecretString;
    use tablepro_core::{AuthMode, Credentials, DriverError, NetworkEndpoint, ServerDiagnostics, TlsConfig};
    use tablepro_session::registry::FileIdentity;
    use tablepro_session::{ConnectError, ConnectIntent, ConnectRequest, PendingSave, RequestTarget, SessionKey};
    use tablepro_storage::{KeyringError, SavedConnection};
    use uuid::Uuid;

    use super::*;

    const PASSWORD: &str = "hunter2-correct-horse";

    fn saved() -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "Prod".to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db.example.com".to_owned(),
            port: 5432,
            database: "shop".to_owned(),
            username: "app".to_owned(),
            tls: TlsConfig::verify_full(),
            read_only: false,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
        }
    }

    /// A connect typed into the dialog, carrying the password typed.
    fn typed() -> ConnectSource {
        let connection = saved();
        let mut request: ConnectRequest = tablepro_session::fakes::FakeConnector::request().expect("a request");
        request.target = RequestTarget::Network {
            endpoint: NetworkEndpoint::new("db.example.com", 5432).expect("an endpoint"),
            ssh: None,
            credentials: Credentials::Password {
                username: "app".to_owned(),
                password: SecretString::from(PASSWORD),
            },
            database: Some("shop".to_owned()),
            tls: TlsConfig::verify_full(),
        };
        ConnectSource::Intent(Box::new(ConnectIntent {
            key: SessionKey::Saved(connection.id),
            request,
            pending_save: Some(PendingSave {
                connection,
                secrets: Vec::new(),
                forget: Vec::new(),
                is_new: true,
            }),
        }))
    }

    fn file() -> ConnectSource {
        ConnectSource::File(FileIdentity::new(None, "file:///srv/app.db".to_owned()))
    }

    #[test]
    fn edit_hidden_for_file_source() {
        let failure = ConnectFailure::new("gone".to_owned());

        assert!(!ConnectFailureView::new(&failure, &file()).can_edit);
        assert!(ConnectFailureView::new(&failure, &ConnectSource::Saved(Box::new(saved()))).can_edit);
        assert!(ConnectFailureView::new(&failure, &typed()).can_edit);
    }

    #[test]
    fn failure_message_never_contains_password() {
        let errors = [
            ConnectError::Driver(DriverError::auth(Some(ServerDiagnostics::new(
                None,
                "password authentication failed for user \"app\"",
            )))),
            ConnectError::Driver(DriverError::auth(None)),
            ConnectError::Keyring(KeyringError::SecretNotStored {
                kind: tablepro_core::credentials::SecretKind::DatabasePassword,
            }),
            ConnectError::Cancelled,
        ];
        for source in [typed(), ConnectSource::Saved(Box::new(saved())), file()] {
            for error in &errors {
                let failure = super::super::attempt_error(error);
                let super::super::AttemptError::Failed(failure) = failure else {
                    continue;
                };

                let view = ConnectFailureView::new(&failure, &source);

                assert!(!view.message.is_empty(), "{error:?}");
                assert!(!view.message.contains(PASSWORD), "{error:?}: {}", view.message);
            }
        }
    }
}
