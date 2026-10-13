//! The work behind a connect the window starts, run off the GTK thread.
//!
//! Every step stops at the attempt's cancel: a cancelled connect asks
//! for nothing more, keeps no secret and saves no entry.

use tablepro_core::DriverRegistry;
use tablepro_core::credentials::{CredentialInteraction, SecretError, SecretKind, SecretVault};
use tablepro_session::connect::ConnectionWrites;
use tablepro_session::{
    ConnectError, ConnectRequest, Connector, CredentialSource, PendingSave, PendingSession, PersistReport,
};
use tablepro_storage::{CredentialDemand, KeyringCredentials, SavedConnection, StorageError};
use tokio_util::sync::CancellationToken;

/// Why a submitted connection did not open.
#[derive(Debug)]
pub(super) enum SubmitError {
    Connect(ConnectError),
    Save(StorageError),
}

/// Connect to what the dialog was filled in with, then save it. The
/// entry is only written once the connect works, so a typo never lands
/// in the connection list.
pub(super) async fn connect_then_save(
    connector: &dyn Connector,
    request: ConnectRequest,
    interaction: CredentialInteraction,
    cancel: CancellationToken,
    secrets: &dyn SecretVault,
    writes: &dyn ConnectionWrites,
    save: PendingSave,
) -> Result<(PendingSession, PersistReport), SubmitError> {
    let pending = connector
        .establish(request, interaction, cancel.clone())
        .await
        .map_err(SubmitError::Connect)?;
    let pending = unless_cancelled(pending, &cancel).await.map_err(SubmitError::Connect)?;
    match tablepro_session::persist_pending_save(secrets, writes, save).await {
        Ok(report) => Ok((pending, report)),
        Err(error) => {
            let report = pending.discard().await;
            tracing::debug!(?report, "closed a connection whose entry could not be saved");
            Err(SubmitError::Save(error))
        }
    }
}

/// Open a saved connection: read its secrets, ask for what the keyring
/// lacks, connect, then keep what the user typed with Remember on.
/// Returns the secrets the keyring refused to keep.
pub(super) async fn connect_saved(
    saved: &SavedConnection,
    drivers: &DriverRegistry,
    credentials: &KeyringCredentials,
    connector: &dyn Connector,
    interaction: CredentialInteraction,
    cancel: CancellationToken,
) -> Result<(PendingSession, Vec<(SecretKind, SecretError)>), ConnectError> {
    // Dropping the resolve on a cancel drops its prompt too, which is
    // what takes a password dialog still on screen down with it.
    let resolving = tablepro_session::resolve_saved(
        saved,
        drivers,
        credentials,
        interaction.clone(),
        CredentialDemand::default(),
    );
    let refreshed = cancel
        .run_until_cancelled(resolving)
        .await
        .ok_or(ConnectError::Cancelled)??;
    let pending = connector
        .establish(refreshed.request, interaction, cancel.clone())
        .await?;
    let pending = unless_cancelled(pending, &cancel).await?;
    let refused = credentials.remember(refreshed.remember).await;
    Ok((pending, refused))
}

/// A driver blocked in a C call can still connect after the user
/// cancelled. That connection is closed here rather than saved or kept.
async fn unless_cancelled(pending: PendingSession, cancel: &CancellationToken) -> Result<PendingSession, ConnectError> {
    if !cancel.is_cancelled() {
        return Ok(pending);
    }
    let report = pending.discard().await;
    tracing::debug!(
        ?report,
        "closed a connection that arrived after its connect was cancelled"
    );
    Err(ConnectError::Cancelled)
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use secrecy::SecretString;
    use tablepro_core::credentials::{CredentialPrompter, SecretSave};
    use tablepro_core::{AuthMode, TlsConfig};
    use tablepro_session::connect::StoreConnectionWrites;
    use tablepro_session::fakes::{FakeConnector, FakeEstablish};
    use tablepro_storage::{ConnectionStore, StoragePaths};
    use tablepro_test_support::{ConnectionScript, FakeDriver, FakeSecretVault};
    use uuid::Uuid;

    use super::*;
    use crate::ui::credential_prompt::GtkCredentialPrompter;

    const LATE: Duration = Duration::from_secs(5);

    fn connection(id: Uuid) -> SavedConnection {
        SavedConnection {
            id,
            name: "Prod".to_owned(),
            driver_id: "fake".to_owned(),
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

    fn save(id: Uuid) -> PendingSave {
        PendingSave {
            connection: connection(id),
            secrets: vec![SecretSave {
                kind: SecretKind::DatabasePassword,
                secret: SecretString::from("s3cret"),
                label: "Prod".to_owned(),
            }],
            forget: Vec::new(),
            is_new: true,
        }
    }

    fn late_connector() -> FakeConnector {
        FakeConnector::new([FakeEstablish::Late {
            after: LATE,
            script: ConnectionScript::default(),
        }])
    }

    fn drivers() -> DriverRegistry {
        let mut drivers = DriverRegistry::new();
        drivers.register(Arc::new(FakeDriver::connecting(
            &FakeDriver::NETWORK_CAPABILITIES,
            ConnectionScript::default(),
        )));
        drivers
    }

    #[tokio::test(start_paused = true)]
    async fn a_connect_that_lands_after_its_cancel_saves_nothing() {
        let root = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.Test"));
        let writes = StoreConnectionWrites::new(store.clone(), crate::test_support::paused_tasks());
        let vault = FakeSecretVault::new();
        let connector = late_connector();
        let cancel = CancellationToken::new();
        let request = FakeConnector::request().expect("a request");

        let connecting = connect_then_save(
            &connector,
            request,
            CredentialInteraction::Unattended,
            cancel.clone(),
            &vault,
            &writes,
            save(Uuid::new_v4()),
        );
        cancel.cancel();
        let outcome = connecting.await;

        assert!(
            matches!(outcome, Err(SubmitError::Connect(ConnectError::Cancelled))),
            "{outcome:?}"
        );
        assert!(vault.is_empty(), "a cancelled connect stored its secrets");
        assert!(
            store.load_blocking().expect("the list").is_empty(),
            "a cancelled connect saved its entry"
        );
        let built = connector.connections();
        assert_eq!(built.len(), 1);
        assert!(built[0].is_closed(), "the late connection was left open");
    }

    #[tokio::test(start_paused = true)]
    async fn a_connect_that_is_not_cancelled_saves_its_entry_and_secrets() {
        let root = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.Test"));
        let writes = StoreConnectionWrites::new(store.clone(), crate::test_support::paused_tasks());
        let vault = FakeSecretVault::new();
        let connector = late_connector();
        let id = Uuid::new_v4();

        let (pending, report) = connect_then_save(
            &connector,
            FakeConnector::request().expect("a request"),
            CredentialInteraction::Unattended,
            CancellationToken::new(),
            &vault,
            &writes,
            save(id),
        )
        .await
        .expect("a saved connection");

        assert_eq!(report.saved.id, id);
        assert!(!vault.is_empty());
        assert_eq!(store.load_blocking().expect("the list").len(), 1);
        let _closed = pending.discard().await;
    }

    #[tokio::test(start_paused = true)]
    async fn cancelling_while_a_password_is_asked_for_ends_the_prompt() {
        let saved = connection(Uuid::new_v4());
        let credentials = KeyringCredentials::for_saved(Arc::new(FakeSecretVault::new()), &saved);
        let (prompter, mut queue) = GtkCredentialPrompter::new();
        let prompter: Arc<dyn CredentialPrompter> = Arc::new(prompter);
        let connector = FakeConnector::new([FakeEstablish::Connect(ConnectionScript::default())]);
        let cancel = CancellationToken::new();
        let drivers = drivers();

        let connecting = connect_saved(
            &saved,
            &drivers,
            &credentials,
            &connector,
            CredentialInteraction::Attended(prompter),
            cancel.clone(),
        );
        let asking = async {
            let shown = queue.next().await.expect("the password prompt");
            cancel.cancel();
            shown
        };
        let (outcome, shown) = tokio::time::timeout(LATE, async { tokio::join!(connecting, asking) })
            .await
            .expect("the cancel did not end the connect while its prompt was up");

        assert!(matches!(outcome, Err(ConnectError::Cancelled)), "{outcome:?}");
        assert!(shown.reply.is_closed(), "the prompt is still waited on");
        assert!(connector.calls().is_empty(), "a cancelled attempt still connected");
    }

    #[tokio::test(start_paused = true)]
    async fn a_saved_connect_that_lands_after_its_cancel_keeps_no_typed_secret() {
        let saved = connection(Uuid::new_v4());
        let vault = Arc::new(FakeSecretVault::new());
        let credentials = KeyringCredentials::for_saved(vault.clone(), &saved);
        let (prompter, mut queue) = GtkCredentialPrompter::new();
        let prompter: Arc<dyn CredentialPrompter> = Arc::new(prompter);
        let connector = late_connector();
        let cancel = CancellationToken::new();
        let drivers = drivers();

        let connecting = connect_saved(
            &saved,
            &drivers,
            &credentials,
            &connector,
            CredentialInteraction::Attended(prompter),
            cancel.clone(),
        );
        let answering = async {
            let shown = queue.next().await.expect("the password prompt");
            shown
                .reply
                .send(tablepro_core::credentials::PromptReply::Submitted {
                    values: vec![SecretString::from("typed")],
                    remember: true,
                })
                .expect("the connect is waiting");
            tokio::time::sleep(LATE / 2).await;
            cancel.cancel();
        };
        let (outcome, ()) = tokio::join!(connecting, answering);

        assert!(matches!(outcome, Err(ConnectError::Cancelled)), "{outcome:?}");
        assert!(vault.is_empty(), "a cancelled connect remembered the typed password");
        let built = connector.connections();
        assert_eq!(built.len(), 1);
        assert!(built[0].is_closed(), "the late connection was left open");
    }
}
