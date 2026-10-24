//! The work behind a connect the window starts, run off the GTK thread.
//!
//! Every step stops at the attempt's cancel: a cancelled connect asks
//! for nothing more and adds no entry or secret.

use tablepro_core::DriverRegistry;
use tablepro_core::credentials::{CredentialInteraction, SecretError, SecretKind, SecretVault};
use tablepro_session::connect::ConnectionWrites;
use tablepro_session::{
    ConnectError, ConnectRequest, Connector, CredentialSource, PendingSave, PendingSession, PersistReport,
    RefreshedRequest,
};
use tablepro_storage::{CredentialDemand, SavedConnection, StorageError};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

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
    let is_new = save.is_new;
    let report = match tablepro_session::persist_pending_save(secrets, writes, save).await {
        Ok(report) => report,
        Err(error) => {
            let report = pending.discard().await;
            tracing::debug!(?report, "closed a connection whose entry could not be saved");
            return Err(SubmitError::Save(error));
        }
    };
    // A keyring unlock prompt can hold the save up long enough for the
    // user to cancel. An overwritten entry has no earlier version left
    // to restore, so only a new one is taken back.
    if is_new && cancel.is_cancelled() {
        unsave(secrets, writes, report.saved.id).await;
    }
    unless_cancelled(pending, &cancel)
        .await
        .map(|pending| (pending, report))
        .map_err(SubmitError::Connect)
}

async fn unsave(secrets: &dyn SecretVault, writes: &dyn ConnectionWrites, id: Uuid) {
    // A secret with no entry is orphaned in the keyring, while an
    // entry with no secrets only asks for them again.
    if let Err(error) = secrets.delete_connection(id).await {
        tracing::warn!(%error, "kept a cancelled connect's entry, whose secrets could not be deleted");
        return;
    }
    if let Err(error) = writes.remove(id).await {
        tracing::warn!(%error, "a cancelled connect's entry is still saved");
    }
}

/// A saved connection that connected, and what became of the secrets
/// typed for it.
#[derive(Debug)]
pub(super) struct SavedLogin {
    pub pending: PendingSession,
    /// Secrets the user asked to remember that the keyring refused.
    pub refused: Vec<(SecretKind, SecretError)>,
    /// Secrets typed for this login that the keyring does not hold,
    /// which the session's reconnects keep using.
    pub session_only: Vec<SecretKind>,
}

/// A secret typed into a prompt is kept only once the login it was
/// typed for has worked. `demand` names a secret the server refused,
/// which is asked for again rather than read from the keyring.
pub(super) async fn connect_saved(
    saved: &SavedConnection,
    drivers: &DriverRegistry,
    credentials: &dyn CredentialSource,
    connector: &dyn Connector,
    interaction: CredentialInteraction,
    demand: CredentialDemand,
    cancel: CancellationToken,
) -> Result<SavedLogin, ConnectError> {
    // Dropping the resolve on a cancel drops its prompt too, which is
    // what takes a password dialog still on screen down with it.
    let resolving = tablepro_session::resolve_saved(saved, drivers, credentials, interaction.clone(), demand);
    let RefreshedRequest {
        request,
        remember,
        typed,
    } = cancel
        .run_until_cancelled(resolving)
        .await
        .ok_or(ConnectError::Cancelled)??;
    let pending = connector.establish(request, interaction, cancel.clone()).await?;
    let pending = unless_cancelled(pending, &cancel).await?;
    let kept: Vec<SecretKind> = remember.iter().map(|save| save.kind).collect();
    let refused = credentials.remember(remember).await;
    for (kind, error) in &refused {
        tracing::warn!(?kind, %error, "the keyring did not keep a typed secret");
    }
    let session_only = typed
        .into_iter()
        .filter(|kind| !kept.contains(kind) || refused.iter().any(|(failed, _)| failed == kind))
        .collect();
    Ok(SavedLogin {
        pending,
        refused,
        session_only,
    })
}

/// Connect to a request that carries every secret it needs, such as a
/// file nobody saved.
pub(super) async fn connect_request(
    connector: &dyn Connector,
    request: ConnectRequest,
    interaction: CredentialInteraction,
    cancel: CancellationToken,
) -> Result<PendingSession, ConnectError> {
    let pending = connector.establish(request, interaction, cancel.clone()).await?;
    unless_cancelled(pending, &cancel).await
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

    use futures::future::BoxFuture;
    use secrecy::SecretString;
    use tablepro_core::credentials::{CredentialPrompter, SecretSave};
    use tablepro_core::{AuthMode, TlsConfig};
    use tablepro_session::connect::StoreConnectionWrites;
    use tablepro_session::fakes::{FakeConnector, FakeEstablish};
    use tablepro_storage::{ConnectionStore, KeyringCredentials, StoragePaths};
    use tablepro_test_support::{ConnectionScript, FakeDriver, FakeSecretVault};

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
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
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

    struct CancelledWhileSaving {
        writes: StoreConnectionWrites,
        cancel: CancellationToken,
    }

    impl ConnectionWrites for CancelledWhileSaving {
        fn upsert(&self, connection: SavedConnection) -> BoxFuture<'_, Result<(), StorageError>> {
            self.cancel.cancel();
            self.writes.upsert(connection)
        }

        fn remove(&self, id: Uuid) -> BoxFuture<'_, Result<(), StorageError>> {
            self.writes.remove(id)
        }
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
    async fn a_new_entry_saved_as_its_connect_is_cancelled_is_taken_back() {
        let root = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.Test"));
        let cancel = CancellationToken::new();
        let writes = CancelledWhileSaving {
            writes: StoreConnectionWrites::new(store.clone(), crate::test_support::paused_tasks()),
            cancel: cancel.clone(),
        };
        let vault = FakeSecretVault::new();
        let connector = FakeConnector::new([FakeEstablish::Connect(ConnectionScript::default())]);

        let outcome = connect_then_save(
            &connector,
            FakeConnector::request().expect("a request"),
            CredentialInteraction::Unattended,
            cancel,
            &vault,
            &writes,
            save(Uuid::new_v4()),
        )
        .await;

        assert!(
            matches!(outcome, Err(SubmitError::Connect(ConnectError::Cancelled))),
            "{outcome:?}"
        );
        assert!(vault.is_empty(), "the cancelled connect's secrets stayed");
        assert!(
            store.load_blocking().expect("the list").is_empty(),
            "the cancelled connect's entry stayed"
        );
        let built = connector.connections();
        assert_eq!(built.len(), 1);
        assert!(built[0].is_closed(), "the connection was left open");
    }

    #[tokio::test(start_paused = true)]
    async fn an_existing_entry_saved_as_its_connect_is_cancelled_keeps_the_edit() {
        let root = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.Test"));
        let id = Uuid::new_v4();
        store.upsert_blocking(connection(id)).expect("the saved entry");
        let cancel = CancellationToken::new();
        let writes = CancelledWhileSaving {
            writes: StoreConnectionWrites::new(store.clone(), crate::test_support::paused_tasks()),
            cancel: cancel.clone(),
        };
        let vault = FakeSecretVault::new();
        let connector = FakeConnector::new([FakeEstablish::Connect(ConnectionScript::default())]);
        let mut edit = save(id);
        edit.connection.name = "Prod (edited)".to_owned();
        edit.is_new = false;

        let outcome = connect_then_save(
            &connector,
            FakeConnector::request().expect("a request"),
            CredentialInteraction::Unattended,
            cancel,
            &vault,
            &writes,
            edit,
        )
        .await;

        assert!(
            matches!(outcome, Err(SubmitError::Connect(ConnectError::Cancelled))),
            "{outcome:?}"
        );
        let list = store.load_blocking().expect("the list");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "Prod (edited)");
        assert!(!vault.is_empty(), "the entry lost its secrets");
        assert!(connector.connections()[0].is_closed(), "the connection was left open");
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
            CredentialDemand::default(),
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
    async fn a_refused_password_is_asked_for_again_and_kept_once_it_works() {
        use tablepro_core::credentials::{PromptPurpose, PromptReason, PromptReply};
        use tablepro_test_support::Call;

        let saved = connection(Uuid::new_v4());
        let vault = Arc::new(FakeSecretVault::new());
        vault
            .store(
                saved.id,
                SecretKind::DatabasePassword,
                &SecretString::from("old"),
                "label",
            )
            .await
            .expect("the refused password");
        let credentials = KeyringCredentials::for_saved(vault.clone(), &saved);
        let (prompter, mut queue) = GtkCredentialPrompter::new();
        let prompter: Arc<dyn CredentialPrompter> = Arc::new(prompter);
        let connector = FakeConnector::new([FakeEstablish::Connect(ConnectionScript::default())]);
        let drivers = drivers();
        let loads_before = vault.calls().len();

        let connecting = connect_saved(
            &saved,
            &drivers,
            &credentials,
            &connector,
            CredentialInteraction::Attended(prompter),
            CredentialDemand::reenter(SecretKind::DatabasePassword),
            CancellationToken::new(),
        );
        let answering = async {
            let shown = queue.next().await.expect("the password prompt");
            assert_eq!(
                shown.prompt.purpose,
                PromptPurpose::DatabasePassword {
                    reason: PromptReason::Rejected
                }
            );
            shown
                .reply
                .send(PromptReply::Submitted {
                    values: vec![SecretString::from("new")],
                    remember: true,
                })
                .expect("the connect is waiting");
        };
        let (outcome, ()) = tokio::join!(connecting, answering);

        let login = outcome.expect("a connection");
        assert!(login.refused.is_empty());
        assert!(
            login.session_only.is_empty(),
            "a password the keyring now holds was kept for the session"
        );
        assert!(
            !vault.calls()[loads_before..].contains(&Call::Load(saved.id, SecretKind::DatabasePassword)),
            "the refused password was read again"
        );
        assert_eq!(
            vault.stored_secret(saved.id, SecretKind::DatabasePassword).as_deref(),
            Some("new")
        );
        let _closed = login.pending.discard().await;
    }

    #[tokio::test(start_paused = true)]
    async fn a_password_typed_but_not_kept_is_the_sessions_own() {
        use tablepro_core::credentials::PromptReply;

        let saved = connection(Uuid::new_v4());
        let vault = Arc::new(FakeSecretVault::new());
        vault
            .store(
                saved.id,
                SecretKind::DatabasePassword,
                &SecretString::from("old"),
                "label",
            )
            .await
            .expect("the refused password");
        let credentials = KeyringCredentials::for_saved(vault.clone(), &saved);
        let prompter: Arc<dyn CredentialPrompter> =
            Arc::new(tablepro_test_support::FakePrompter::new([PromptReply::Submitted {
                values: vec![SecretString::from("new")],
                remember: false,
            }]));
        let connector = FakeConnector::new([FakeEstablish::Connect(ConnectionScript::default())]);

        let login = connect_saved(
            &saved,
            &drivers(),
            &credentials,
            &connector,
            CredentialInteraction::Attended(prompter),
            CredentialDemand::reenter(SecretKind::DatabasePassword),
            CancellationToken::new(),
        )
        .await
        .expect("a connection");

        assert_eq!(login.session_only, [SecretKind::DatabasePassword]);
        assert_eq!(
            vault.stored_secret(saved.id, SecretKind::DatabasePassword).as_deref(),
            Some("old")
        );
        let _closed = login.pending.discard().await;
    }

    #[tokio::test(start_paused = true)]
    async fn a_password_the_keyring_refused_to_keep_is_the_sessions_own() {
        use tablepro_core::credentials::PromptReply;

        let lines = crate::test_support::LogLines::default();
        let _logging = tracing::subscriber::set_default(lines.subscriber(tracing::Level::WARN));
        let saved = connection(Uuid::new_v4());
        let vault = Arc::new(FakeSecretVault::new());
        vault.fail_store(SecretKind::DatabasePassword, SecretError::Locked);
        let credentials = KeyringCredentials::for_saved(vault.clone(), &saved);
        let prompter: Arc<dyn CredentialPrompter> =
            Arc::new(tablepro_test_support::FakePrompter::new([PromptReply::Submitted {
                values: vec![SecretString::from("typed")],
                remember: true,
            }]));
        let connector = FakeConnector::new([FakeEstablish::Connect(ConnectionScript::default())]);

        let login = connect_saved(
            &saved,
            &drivers(),
            &credentials,
            &connector,
            CredentialInteraction::Attended(prompter),
            CredentialDemand::default(),
            CancellationToken::new(),
        )
        .await
        .expect("a connection");

        assert_eq!(login.refused.len(), 1);
        assert_eq!(login.session_only, [SecretKind::DatabasePassword]);
        let logged = lines.text();
        assert!(
            logged.contains("the keyring did not keep a typed secret") && logged.contains("DatabasePassword"),
            "{logged}"
        );
        let _closed = login.pending.discard().await;
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
            CredentialDemand::default(),
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
