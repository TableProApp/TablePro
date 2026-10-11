use std::future::Future;

use relm4::ComponentSender;
use relm4::gtk::prelude::FileExt;

use tablepro_storage::{
    BundleError, BundleExport, ImportDisposition, ImportItem, ImportPlan, ParsedBundle, SavedConnection,
};
use uuid::Uuid;

use crate::ui::connection_bundle::{
    ExportChoice, ImportChoice, present_export_dialog, present_import_passphrase_dialog, present_import_plan_dialog,
    selected_connections,
};

use super::{App, AppMsg};

/// A bundle the user opened but has not confirmed. Held between the
/// preview dialog and the write, so nothing reaches disk before the
/// plan has been shown.
pub(crate) struct PendingImport {
    pub(crate) plan: ImportPlan,
    pub(crate) secrets: Vec<tablepro_storage::BundleSecrets>,
}

impl std::fmt::Debug for PendingImport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PendingImport")
            .field("items", &self.plan.items.len())
            .field("secrets", &self.secrets.len())
            .finish()
    }
}

impl App {
    pub(super) fn on_export_connections(&self, sender: ComponentSender<Self>) {
        if self.saved_connections.is_empty() {
            self.show_toast(&crate::tr!("There are no saved connections to export."));
            return;
        }
        let input = sender.input_sender().clone();
        present_export_dialog(
            &self.window,
            &self.saved_connections,
            today_stamp(),
            move |choice: ExportChoice| {
                let _ = input.send(AppMsg::ExportConnectionsTo(choice));
            },
        );
    }

    pub(super) fn on_export_connections_to(&self, choice: ExportChoice, sender: ComponentSender<Self>) {
        let chosen = selected_connections(&self.saved_connections, &choice.connections);
        let organization: Vec<(Uuid, tablepro_storage::ConnectionOrganization)> = chosen
            .iter()
            .map(|connection| (connection.id, self.connection_organization.get(connection.id)))
            .collect();
        let operation_id = Uuid::new_v4();
        let affected_count = chosen.len();
        let database = self.database.clone();
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    if database
                        .audit_administrative_action(
                            operation_id,
                            tablepro_policy::AuditAdministrativeAction::ConnectionBundleExport,
                            tablepro_policy::AuditRecordPhase::Intent,
                            tablepro_policy::AuditTerminalStatus::Pending,
                            affected_count,
                            None,
                        )
                        .await
                        .is_err()
                    {
                        sender_clone.input(AppMsg::BundleFailed(crate::tr!(
                            "The export was cancelled because its audit record could not be saved."
                        )));
                        return;
                    }
                    let started = std::time::Instant::now();
                    let outcome = write_bundle(choice, chosen, organization).await;
                    let status = if outcome.is_ok() {
                        tablepro_policy::AuditTerminalStatus::Succeeded
                    } else {
                        tablepro_policy::AuditTerminalStatus::Failed
                    };
                    if database
                        .audit_administrative_action(
                            operation_id,
                            tablepro_policy::AuditAdministrativeAction::ConnectionBundleExport,
                            tablepro_policy::AuditRecordPhase::Outcome,
                            status,
                            affected_count,
                            Some(started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64),
                        )
                        .await
                        .is_err()
                    {
                        sender_clone.input(AppMsg::BundleFailed(crate::tr!(
                            "The export finished, but its audit outcome could not be saved."
                        )));
                        return;
                    }
                    match outcome {
                        Ok(count) => sender_clone.input(AppMsg::ExportConnectionsSucceeded(count)),
                        Err(error) => sender_clone.input(AppMsg::BundleFailed(error.to_string())),
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_export_connections_succeeded(&self, count: usize) {
        self.show_toast(&crate::tr!("Exported {n} connections.").replace("{n}", &count.to_string()));
    }

    pub(super) fn on_bundle_failed(&self, message: &str) {
        self.show_toast(message);
    }

    pub(super) fn on_import_bundle(&self, sender: ComponentSender<Self>) {
        let filter = crate::ui::connection_bundle::bundle_file_filter();
        let dialog = relm4::gtk::FileDialog::builder()
            .title(crate::tr!("Import connections"))
            .modal(true)
            .default_filter(&filter)
            .filters(&crate::ui::connection_bundle::bundle_file_filters(&filter))
            .build();
        let input = sender.input_sender().clone();
        dialog.open(Some(&self.window), relm4::gtk::gio::Cancellable::NONE, move |outcome| {
            let Ok(file) = outcome else {
                return;
            };
            let Some(path) = file.path() else {
                return;
            };
            let _ = input.send(AppMsg::ImportBundleFile(path));
        });
    }

    /// Read and parse off the GTK thread, then either plan straight away
    /// or ask for the passphrase.
    pub(super) fn on_import_bundle_file(&self, path: std::path::PathBuf, sender: ComponentSender<Self>) {
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    match read_bundle_at(&path).await {
                        Ok(ParsedBundle::Plaintext(body)) => match plan_from_body(&body).await {
                            Ok(pending) => sender_clone.input(AppMsg::ImportBundlePlanned(pending)),
                            Err(message) => sender_clone.input(AppMsg::BundleFailed(message)),
                        },
                        Ok(ParsedBundle::Encrypted(sealed)) => {
                            sender_clone.input(AppMsg::ImportBundleEncrypted(sealed));
                        }
                        Err(error) => sender_clone.input(AppMsg::BundleFailed(error.to_string())),
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_import_bundle_encrypted(
        &mut self,
        sealed: tablepro_storage::EncryptedBundle,
        sender: ComponentSender<Self>,
    ) {
        self.pending_bundle = Some(sealed);
        self.on_import_bundle_needs_passphrase(sender);
    }

    pub(super) fn on_import_bundle_unlock(&mut self, passphrase: String, sender: ComponentSender<Self>) {
        let body = match self.pending_bundle.as_ref().map(|sealed| sealed.unlock(&passphrase)) {
            Some(Ok(body)) => body,
            Some(Err(error)) => {
                self.show_toast(&error.to_string());
                self.on_import_bundle_needs_passphrase(sender);
                return;
            }
            None => return,
        };
        self.pending_bundle.take();
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    match plan_from_body(&body).await {
                        Ok(pending) => sender_clone.input(AppMsg::ImportBundlePlanned(pending)),
                        Err(message) => sender_clone.input(AppMsg::BundleFailed(message)),
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_import_bundle_needs_passphrase(&self, sender: ComponentSender<Self>) {
        let input = sender.input_sender().clone();
        present_import_passphrase_dialog(&self.window, move |passphrase| {
            let _ = input.send(AppMsg::ImportBundleUnlock(passphrase));
        });
    }

    pub(super) fn on_import_bundle_planned(&mut self, pending: PendingImport, sender: ComponentSender<Self>) {
        if pending.plan.items.is_empty() {
            self.show_toast(&crate::tr!("That file holds no connections."));
            return;
        }
        let carries_secrets = !pending.secrets.is_empty();
        let input = sender.input_sender().clone();
        present_import_plan_dialog(
            &self.window,
            &pending.plan.items,
            carries_secrets,
            move |choice: ImportChoice| {
                let _ = input.send(AppMsg::ImportBundleConfirmed(choice));
            },
        );
        self.pending_import = Some(Box::new(pending));
    }

    pub(super) fn on_import_bundle_confirmed(&mut self, choice: ImportChoice, sender: ComponentSender<Self>) {
        let Some(pending) = self.pending_import.take() else {
            return;
        };
        let plan = ImportPlan {
            items: accepted_items(&pending.plan, &choice.accepted),
        };
        if plan.items.is_empty() {
            self.show_toast(&crate::tr!("No connections were selected for import."));
            return;
        }
        let operation_id = Uuid::new_v4();
        let secrets = pending.secrets;
        let replace = choice.replace_saved_passwords;
        let database = self.database.clone();
        let sender_clone = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    match apply_import_with_audit(database, operation_id, plan, secrets, replace).await {
                        Ok((imported, planned)) => {
                            sender_clone.input(AppMsg::ImportBundleFinished(imported, planned));
                            sender_clone.input(AppMsg::ReloadConnections);
                        }
                        Err(message) => sender_clone.input(AppMsg::BundleFailed(message)),
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_import_bundle_finished(&self, imported: usize, planned: usize) {
        self.show_toast(&crate::ui::connection_bundle::import_outcome_message(imported, planned));
    }
}

async fn apply_import_with_audit(
    database: std::sync::Arc<crate::services::database_service::DatabaseService>,
    operation_id: Uuid,
    plan: ImportPlan,
    secrets: Vec<tablepro_storage::BundleSecrets>,
    replace: bool,
) -> Result<(usize, usize), String> {
    let planned_count = plan.items.len();
    if database
        .audit_administrative_action(
            operation_id,
            tablepro_policy::AuditAdministrativeAction::ConnectionBundleImport,
            tablepro_policy::AuditRecordPhase::Intent,
            tablepro_policy::AuditTerminalStatus::Pending,
            planned_count,
            None,
        )
        .await
        .is_err()
    {
        return Err(crate::tr!("The import was cancelled because its audit record could not be saved.").to_string());
    }

    let started = std::time::Instant::now();
    let outcome = apply_plan(plan, secrets, replace).await;
    let (status, affected_count) = match &outcome {
        Ok((imported, planned)) if imported == planned => (tablepro_policy::AuditTerminalStatus::Succeeded, *imported),
        Ok((imported, _)) => (tablepro_policy::AuditTerminalStatus::Failed, *imported),
        Err(_) => (tablepro_policy::AuditTerminalStatus::Failed, 0),
    };
    if database
        .audit_administrative_action(
            operation_id,
            tablepro_policy::AuditAdministrativeAction::ConnectionBundleImport,
            tablepro_policy::AuditRecordPhase::Outcome,
            status,
            affected_count,
            Some(started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64),
        )
        .await
        .is_err()
    {
        return Err(crate::tr!("The import finished, but its audit outcome could not be saved.").to_string());
    }

    outcome
}

fn today_stamp() -> String {
    chrono::Utc::now().format("%Y-%m-%d").to_string()
}

/// Keep the plan's order while dropping whatever the user unticked.
pub(super) fn accepted_items(plan: &ImportPlan, accepted: &[Uuid]) -> Vec<ImportItem> {
    plan.items
        .iter()
        .filter(|item| accepted.contains(&item.source_id))
        .cloned()
        .collect()
}

async fn write_bundle(
    choice: ExportChoice,
    connections: Vec<SavedConnection>,
    organization: Vec<(Uuid, tablepro_storage::ConnectionOrganization)>,
) -> Result<usize, BundleError> {
    let count = connections.len();
    let secrets = if choice.passphrase.is_empty() {
        Vec::new()
    } else {
        tablepro_storage::collect_bundle_secrets(&connections).await?
    };
    let export = BundleExport {
        producer: format!("bookie {}", env!("CARGO_PKG_VERSION")),
        exported_at: chrono::Utc::now().to_rfc3339(),
        connections,
        organization,
        secrets,
    };
    let bytes = if choice.passphrase.is_empty() {
        tablepro_storage::export_plaintext(&export)?
    } else {
        tablepro_storage::export_encrypted(&export, &choice.passphrase)?
    };
    tokio::fs::write(&choice.path, &bytes)
        .await
        .map_err(|_| BundleError::Field("destination"))?;
    Ok(count)
}

pub(super) fn read_bundle_file(bytes: &[u8]) -> Result<ParsedBundle, BundleError> {
    tablepro_storage::parse_bundle(bytes)
}

async fn read_bundle_at(path: &std::path::Path) -> Result<ParsedBundle, BundleError> {
    let bytes = read_bounded(path, tablepro_storage::MAX_BUNDLE_BYTES).await?;
    read_bundle_file(&bytes)
}

async fn read_bounded(path: &std::path::Path, limit: usize) -> Result<Vec<u8>, BundleError> {
    use tokio::io::AsyncReadExt;
    let file = tokio::fs::File::open(path).await.map_err(|_| BundleError::NotABundle)?;
    let metadata = file.metadata().await.map_err(|_| BundleError::NotABundle)?;
    if !metadata.is_file() {
        return Err(BundleError::NotABundle);
    }
    let too_large = |got: u64| BundleError::TooLarge {
        got: usize::try_from(got).unwrap_or(usize::MAX),
        limit,
    };
    if metadata.len() > limit as u64 {
        return Err(too_large(metadata.len()));
    }
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .await
        .map_err(|_| BundleError::NotABundle)?;
    if bytes.len() > limit {
        return Err(too_large(bytes.len() as u64));
    }
    Ok(bytes)
}

async fn plan_from_body(body: &tablepro_storage::BundleBody) -> Result<PendingImport, String> {
    let local = tablepro_storage::load_connections()
        .await
        .map_err(|_| crate::tr!("The saved connections could not be read."))?;
    let plan = tablepro_storage::plan_import(&local, body).map_err(|error| error.to_string())?;
    Ok(PendingImport {
        plan,
        secrets: body.secrets.clone(),
    })
}

async fn apply_plan(
    plan: ImportPlan,
    secrets: Vec<tablepro_storage::BundleSecrets>,
    replace_saved_passwords: bool,
) -> Result<(usize, usize), String> {
    let planned = plan.items.len();
    let (imported, failure) = apply_items(
        plan.items,
        secrets,
        replace_saved_passwords,
        |item, carried, replace| async move {
            let single_item = ImportPlan {
                items: vec![item.clone()],
            };
            if tablepro_storage::apply_import(&single_item).await.is_err() {
                return Err(ItemApplyFailure::ConnectionSave);
            }
            if apply_item_secrets(&item, carried.as_ref(), replace).await.is_err() {
                if let Some(carried) = carried.as_ref() {
                    roll_back(&item, carried).await;
                } else {
                    let restored = tablepro_storage::restore_connection(item.previous.as_ref(), item.connection.id)
                        .await
                        .is_ok();
                    if !restored {
                        tracing::warn!("rolling back an imported connection failed");
                    }
                }
                return Err(ItemApplyFailure::CredentialStore);
            }
            Ok(())
        },
    )
    .await;
    if imported == 0 && failure == Some(ItemApplyFailure::ConnectionSave) {
        return Err(crate::tr!("The connections could not be saved."));
    }
    Ok((imported, planned))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ItemApplyFailure {
    ConnectionSave,
    CredentialStore,
}

async fn apply_items<F, Fut>(
    items: Vec<ImportItem>,
    secrets: Vec<tablepro_storage::BundleSecrets>,
    replace_saved_passwords: bool,
    mut apply: F,
) -> (usize, Option<ItemApplyFailure>)
where
    F: FnMut(ImportItem, Option<tablepro_storage::BundleSecrets>, bool) -> Fut,
    Fut: Future<Output = Result<(), ItemApplyFailure>>,
{
    let mut imported = 0;
    for item in items {
        let carried = secrets
            .iter()
            .find(|entry| entry.connection_id == item.source_id)
            .cloned();
        if let Err(failure) = apply(item, carried, replace_saved_passwords).await {
            return (imported, Some(failure));
        }
        imported += 1;
    }
    (imported, None)
}

async fn apply_item_secrets(
    item: &ImportItem,
    secrets: Option<&tablepro_storage::BundleSecrets>,
    replace_saved_passwords: bool,
) -> Result<(), tablepro_storage::StorageError> {
    let Some(secrets) = secrets else {
        return Ok(());
    };
    tablepro_storage::store_bundle_secrets(
        item.connection.id,
        secrets,
        &item.connection.name,
        replace_saved_passwords,
    )
    .await
}

/// Undo one item after a failed credential write. An entry that existed
/// before the import is restored from its snapshot; one this import
/// created is removed along with whatever it managed to store.
async fn roll_back(item: &ImportItem, secrets: &tablepro_storage::BundleSecrets) {
    let restored = match tablepro_storage::restore_connection(item.previous.as_ref(), item.connection.id).await {
        Ok(()) => true,
        Err(error) => {
            tracing::warn!(error = %error, "rolling back an imported connection failed");
            false
        }
    };
    if should_forget_imported_secrets(item, restored) {
        tablepro_storage::forget_imported_bundle_secrets(item.connection.id, secrets).await;
    }
}

fn should_forget_imported_secrets(item: &ImportItem, restored: bool) -> bool {
    restored && matches!(item.disposition, ImportDisposition::New | ImportDisposition::Remapped)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::{AuthMode, Environment, TlsMode};

    fn saved(name: &str) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: name.into(),
            driver_id: "postgres".into(),
            host: "localhost".into(),
            port: 5432,
            socket_dir: None,
            database: "app".into(),
            username: "app".into(),
            use_tls: false,
            tls_mode: Some(TlsMode::Disabled),
            tls_root_cert: None,
            tls_client_cert: None,
            tls_client_key: None,
            read_only: false,
            auth_mode: AuthMode::Password,
            environment: Environment::Local,
            ssh: None,
            last_opened_at: None,
            connect_timeout_secs: None,
            query_timeout_secs: None,
        }
    }

    fn item(name: &str) -> ImportItem {
        let connection = saved(name);
        ImportItem {
            disposition: ImportDisposition::New,
            source_id: connection.id,
            connection,
            previous: None,
            organization: None,
        }
    }

    #[test]
    fn unticked_entries_are_dropped_and_the_order_survives() {
        let first = item("a");
        let second = item("b");
        let third = item("c");
        let plan = ImportPlan {
            items: vec![first.clone(), second.clone(), third.clone()],
        };

        let kept = accepted_items(&plan, &[third.source_id, first.source_id]);

        assert_eq!(
            kept.iter().map(|i| i.source_id).collect::<Vec<_>>(),
            vec![first.source_id, third.source_id]
        );
    }

    #[test]
    fn ticking_nothing_imports_nothing() {
        let plan = ImportPlan { items: vec![item("a")] };
        assert!(accepted_items(&plan, &[]).is_empty());
    }

    #[tokio::test]
    async fn an_import_failure_stops_before_saving_later_connections() {
        let items = vec![item("first"), item("failed"), item("later")];
        let attempted = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let imported = apply_items(items.clone(), Vec::new(), false, {
            let attempted = attempted.clone();
            move |item, _, _| {
                let attempted = attempted.clone();
                async move {
                    attempted.lock().unwrap().push(item.connection.name.clone());
                    if item.connection.name == "failed" {
                        Err(ItemApplyFailure::CredentialStore)
                    } else {
                        Ok(())
                    }
                }
            }
        })
        .await;

        assert_eq!(imported, (1, Some(ItemApplyFailure::CredentialStore)));
        assert_eq!(*attempted.lock().unwrap(), ["first", "failed"]);
    }

    #[test]
    fn a_failed_record_restore_keeps_imported_credentials() {
        let mut item = item("new");
        assert!(!should_forget_imported_secrets(&item, false));
        assert!(should_forget_imported_secrets(&item, true));
        item.disposition = ImportDisposition::UpdateInPlace;
        assert!(!should_forget_imported_secrets(&item, true));
    }

    #[test]
    fn a_file_that_is_not_a_bundle_is_reported_rather_than_parsed() {
        assert!(read_bundle_file(b"nonsense").is_err());
    }

    #[test]
    fn the_export_file_stamp_is_a_plain_date() {
        let stamp = today_stamp();
        assert_eq!(stamp.len(), 10);
        assert_eq!(stamp.matches('-').count(), 2);
    }

    #[tokio::test]
    async fn a_file_over_the_limit_is_refused_before_it_is_read() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("big.bundle");
        std::fs::File::create(&path).unwrap().set_len(17).unwrap();
        let error = read_bounded(&path, 16).await.unwrap_err();
        assert!(
            matches!(error, BundleError::TooLarge { got: 17, limit: 16 }),
            "{error:?}"
        );
    }

    #[tokio::test]
    async fn a_directory_or_missing_path_is_not_a_bundle() {
        let directory = tempfile::tempdir().unwrap();
        assert!(matches!(
            read_bounded(directory.path(), 16).await,
            Err(BundleError::NotABundle)
        ));
        assert!(matches!(
            read_bounded(&directory.path().join("missing"), 16).await,
            Err(BundleError::NotABundle)
        ));
    }

    #[tokio::test]
    async fn a_file_at_the_limit_is_read_whole() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("ok.bundle");
        std::fs::write(&path, [7u8; 16]).unwrap();
        assert_eq!(read_bounded(&path, 16).await.unwrap(), vec![7u8; 16]);
    }
}
