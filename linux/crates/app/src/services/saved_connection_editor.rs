use std::sync::Arc;

use tablepro_core::credentials::{SecretError, SecretKind, SecretLookup, SecretVault};
use tablepro_session::runtime::Tasks;
use tablepro_storage::{ConnectionColor, ConnectionGroupName, ConnectionStore, SavedConnection};
use uuid::Uuid;

use super::duplicate_name::duplicate_name;
use super::saved_connection_error::SavedConnectionError;
use super::secret_change::SecretChange;
use super::secret_changes::SecretChanges;
use super::secret_labels::secret_label;

/// Changes a saved connection together with its keyring secrets: an
/// edit from the connect dialog, a copy, a move to another group.
///
/// The keyring goes first, as in a delete: a refusal there stops before
/// the list changes, so the user can try again. When the entry does not
/// land, each secret the edit changed is put back as it was, and a copy's
/// secrets are deleted. Every write publishes the list, which every
/// picker follows.
///
/// Run it on the app runtime, which the Secret Service client needs.
#[derive(Clone)]
pub struct SavedConnectionEditor {
    store: ConnectionStore,
    secrets: Arc<dyn SecretVault>,
    tasks: Tasks,
}

impl SavedConnectionEditor {
    pub fn new(store: ConnectionStore, secrets: Arc<dyn SecretVault>, tasks: Tasks) -> Self {
        Self { store, secrets, tasks }
    }

    /// Save `connection` over the entry with its id, applying `changes`
    /// to its secrets. The id stays, so a rename or a new host keeps
    /// every secret the edit does not change. Colour, group and the
    /// last-opened time are taken from the list as it is at the write,
    /// since the connect dialog shows none of them.
    pub async fn update(
        &self,
        connection: SavedConnection,
        changes: SecretChanges,
    ) -> Result<SavedConnection, SavedConnectionError> {
        let id = connection.id;
        let original = self.find(id).await?;
        let mut connection = connection;
        changes.settle_passphrase(&mut connection, &original);
        let mut changed = Vec::new();
        for kind in SecretKind::ALL {
            if let Err(error) = self
                .change_secret(&original, &connection, kind, changes.get(kind), &mut changed)
                .await
            {
                self.put_back(&original, changed).await;
                return Err(error.into());
            }
        }
        let written = self
            .write(id, move |entry| {
                *entry = SavedConnection {
                    last_opened_at: entry.last_opened_at,
                    color: entry.color,
                    group: entry.group.take(),
                    ..connection
                };
            })
            .await;
        match written {
            Ok(Some(saved)) => Ok(saved),
            // Deleted while the dialog was open: what the edit just
            // stored has no entry left to belong to.
            Ok(None) => {
                self.forget_secrets(id).await;
                Err(SavedConnectionError::NotFound(id))
            }
            Err(error) => {
                self.put_back(&original, changed).await;
                Err(error)
            }
        }
    }

    /// Apply `change` to the secret of `kind`, recording in `changed`
    /// what the keyring held before, to put back if the entry does not
    /// land.
    async fn change_secret(
        &self,
        original: &SavedConnection,
        connection: &SavedConnection,
        kind: SecretKind,
        change: &SecretChange,
        changed: &mut Vec<(SecretKind, SecretLookup)>,
    ) -> Result<(), SecretError> {
        let id = connection.id;
        let label = secret_label(kind, connection);
        match change {
            SecretChange::Replace(secret) => {
                let before = self.secrets.load(id, kind).await?;
                self.secrets.store(id, kind, secret, &label).await?;
                changed.push((kind, before));
            }
            SecretChange::Remove => {
                let before = self.secrets.load(id, kind).await?;
                self.secrets.delete_kind(id, kind).await?;
                changed.push((kind, before));
            }
            // A label only names the secret in Seahorse, so one the
            // keyring will not rename is no reason to refuse the edit.
            SecretChange::Keep if label != secret_label(kind, original) => {
                if let Err(error) = self.secrets.relabel(id, kind, &label).await {
                    tracing::warn!(%error, ?kind, "a kept secret still has its old label");
                }
            }
            SecretChange::Keep => {}
        }
        Ok(())
    }

    /// Give back the secrets an edit changed before its entry failed to
    /// land, so the entry still logs in the way it did.
    async fn put_back(&self, original: &SavedConnection, changed: Vec<(SecretKind, SecretLookup)>) {
        for (kind, before) in changed.into_iter().rev() {
            let restored = match before {
                SecretLookup::Found(secret) => {
                    self.secrets
                        .store(original.id, kind, &secret, &secret_label(kind, original))
                        .await
                }
                SecretLookup::NotStored => self.secrets.delete_kind(original.id, kind).await,
            };
            if let Err(error) = restored {
                tracing::warn!(%error, ?kind, "a secret of an edit that was not saved was not put back");
            }
        }
    }

    /// Copy the connection `id` under a name of its own, with copies of
    /// its secrets. The copy is a connection of its own: a new id, so
    /// deleting either leaves the other able to connect. It has never
    /// been opened, so it does not claim the original's place at the top.
    pub async fn duplicate(&self, id: Uuid) -> Result<SavedConnection, SavedConnectionError> {
        let list = self.list().await?;
        let source = list
            .iter()
            .find(|saved| saved.id == id)
            .cloned()
            .ok_or(SavedConnectionError::NotFound(id))?;
        let names: Vec<String> = list.iter().map(|saved| saved.name.clone()).collect();
        let copy = SavedConnection {
            id: Uuid::new_v4(),
            name: duplicate_name(&source.name, &names),
            last_opened_at: None,
            ..source.clone()
        };
        if let Err(error) = self.copy_secrets(&source, &copy).await {
            self.forget_secrets(copy.id).await;
            return Err(error.into());
        }
        let store = self.store.clone();
        let entry = copy.clone();
        let written = self
            .tasks
            .spawn_blocking_task(move || store.upsert_blocking(entry))
            .await
            .map_err(SavedConnectionError::from)
            .and_then(|written| written.map_err(SavedConnectionError::from));
        if let Err(error) = written {
            self.forget_secrets(copy.id).await;
            return Err(error);
        }
        Ok(copy)
    }

    /// File the connection `id` under `group`, or under none.
    pub async fn move_to_group(
        &self,
        id: Uuid,
        group: Option<ConnectionGroupName>,
    ) -> Result<(), SavedConnectionError> {
        self.write(id, move |entry| entry.group = group)
            .await?
            .map(drop)
            .ok_or(SavedConnectionError::NotFound(id))
    }

    /// Put `color` on the connection `id`, or take its colour off.
    pub async fn set_color(&self, id: Uuid, color: Option<ConnectionColor>) -> Result<(), SavedConnectionError> {
        self.write(id, move |entry| entry.color = color)
            .await?
            .map(drop)
            .ok_or(SavedConnectionError::NotFound(id))
    }

    async fn list(&self) -> Result<Arc<[SavedConnection]>, SavedConnectionError> {
        let store = self.store.clone();
        Ok(self.tasks.spawn_blocking_task(move || store.load_blocking()).await??)
    }

    async fn find(&self, id: Uuid) -> Result<SavedConnection, SavedConnectionError> {
        self.list()
            .await?
            .iter()
            .find(|saved| saved.id == id)
            .cloned()
            .ok_or(SavedConnectionError::NotFound(id))
    }

    async fn write(
        &self,
        id: Uuid,
        change: impl FnOnce(&mut SavedConnection) + Send + 'static,
    ) -> Result<Option<SavedConnection>, SavedConnectionError> {
        let store = self.store.clone();
        Ok(self
            .tasks
            .spawn_blocking_task(move || store.update_blocking(id, change))
            .await??)
    }

    async fn copy_secrets(&self, source: &SavedConnection, copy: &SavedConnection) -> Result<(), SecretError> {
        for kind in SecretKind::ALL {
            if let SecretLookup::Found(secret) = self.secrets.load(source.id, kind).await? {
                self.secrets
                    .store(copy.id, kind, &secret, &secret_label(kind, copy))
                    .await?;
            }
        }
        Ok(())
    }

    async fn forget_secrets(&self, id: Uuid) {
        if let Err(error) = self.secrets.delete_connection(id).await {
            tracing::warn!(%error, "secrets of a connection that was not saved are still in the keyring");
        }
    }
}

impl std::fmt::Debug for SavedConnectionEditor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SavedConnectionEditor")
            .field("store", &self.store)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use secrecy::SecretString;
    use tablepro_core::{AuthMode, TlsConfig};
    use tablepro_storage::{ConnectionListState, StoragePaths};
    use tablepro_test_support::{Call, FakeSecretVault};

    use super::*;
    use crate::test_support::paused_tasks;

    struct Fixture {
        editor: SavedConnectionEditor,
        store: ConnectionStore,
        vault: Arc<FakeSecretVault>,
        saved: SavedConnection,
        _root: tempfile::TempDir,
    }

    fn connection() -> SavedConnection {
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
            last_opened_at: Some(chrono::Utc::now()),
            color: Some(ConnectionColor::Red),
            group: Some(ConnectionGroupName::new("Work").expect("a name")),
        }
    }

    /// One saved connection with its database password in the keyring.
    async fn fixture() -> Fixture {
        let root = tempfile::tempdir().expect("tempdir");
        let store = ConnectionStore::new(&StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.Test"));
        let vault = Arc::new(FakeSecretVault::new());
        let saved = connection();
        store.upsert_blocking(saved.clone()).expect("the entry");
        vault
            .store(
                saved.id,
                SecretKind::DatabasePassword,
                &SecretString::from("s3cret"),
                &secret_label(SecretKind::DatabasePassword, &saved),
            )
            .await
            .expect("the password");
        Fixture {
            editor: SavedConnectionEditor::new(store.clone(), vault.clone(), paused_tasks()),
            store,
            vault,
            saved,
            _root: root,
        }
    }

    fn stored(store: &ConnectionStore) -> Vec<SavedConnection> {
        store.load_blocking().expect("the list").to_vec()
    }

    fn writes(vault: &FakeSecretVault) -> Vec<Call> {
        vault
            .calls()
            .into_iter()
            .filter(|call| !matches!(call, Call::Load(..)))
            .collect()
    }

    #[tokio::test]
    async fn duplicate_copies_secrets_to_new_id() {
        let fixture = fixture().await;

        let copy = fixture.editor.duplicate(fixture.saved.id).await.expect("the copy");

        assert_ne!(copy.id, fixture.saved.id);
        assert_eq!(copy.name, "Prod (Copy)");
        assert_eq!(copy.last_opened_at, None, "the copy claimed the original's recency");
        assert_eq!(copy.group, fixture.saved.group);
        assert_eq!(copy.color, fixture.saved.color);
        assert_eq!(copy.host, fixture.saved.host);
        assert_eq!(
            fixture
                .vault
                .stored_secret(copy.id, SecretKind::DatabasePassword)
                .as_deref(),
            Some("s3cret")
        );
        assert_eq!(
            fixture.vault.stored_label(copy.id, SecretKind::DatabasePassword),
            Some(secret_label(SecretKind::DatabasePassword, &copy))
        );
        assert!(stored(&fixture.store).contains(&copy));
    }

    #[tokio::test]
    async fn duplicate_rolls_back_entry_when_secret_copy_fails() {
        let fixture = fixture().await;
        fixture
            .vault
            .fail_store(SecretKind::DatabasePassword, SecretError::Locked);

        let refused = fixture.editor.duplicate(fixture.saved.id).await;

        assert!(
            matches!(refused, Err(SavedConnectionError::Secret(SecretError::Locked))),
            "{refused:?}"
        );
        assert_eq!(stored(&fixture.store), vec![fixture.saved.clone()], "a copy was left");
        let copied: Vec<Call> = writes(&fixture.vault)
            .into_iter()
            .filter(|call| !matches!(call, Call::Store(id, _) if *id == fixture.saved.id))
            .collect();
        assert!(
            matches!(copied.last(), Some(Call::DeleteConnection(id)) if *id != fixture.saved.id),
            "the copy's secrets were not taken back: {copied:?}"
        );
    }

    #[tokio::test]
    async fn duplicate_of_a_deleted_connection_writes_nothing() {
        let fixture = fixture().await;
        let gone = Uuid::new_v4();

        let refused = fixture.editor.duplicate(gone).await;

        assert!(matches!(refused, Err(SavedConnectionError::NotFound(id)) if id == gone));
        assert_eq!(stored(&fixture.store).len(), 1);
    }

    #[tokio::test]
    async fn update_with_keep_does_not_store_secrets() {
        let fixture = fixture().await;
        let before = fixture.vault.calls().len();
        let edited = SavedConnection {
            read_only: true,
            ..fixture.saved.clone()
        };

        fixture
            .editor
            .update(edited, SecretChanges::default())
            .await
            .expect("the edit");

        let after = fixture.vault.calls().split_off(before);
        assert!(
            after.iter().all(|call| matches!(call, Call::Load(..))),
            "the keyring was written: {after:?}"
        );
        assert!(stored(&fixture.store)[0].read_only);
    }

    #[tokio::test]
    async fn a_rename_keeps_every_secret_and_the_entry_id() {
        let fixture = fixture().await;
        let renamed = SavedConnection {
            name: "Production".to_owned(),
            ..fixture.saved.clone()
        };

        let saved = fixture
            .editor
            .update(renamed, SecretChanges::default())
            .await
            .expect("the rename");

        assert_eq!(saved.id, fixture.saved.id);
        assert_eq!(saved.name, "Production");
        assert_eq!(
            fixture
                .vault
                .stored_secret(fixture.saved.id, SecretKind::DatabasePassword)
                .as_deref(),
            Some("s3cret")
        );
        assert_eq!(stored(&fixture.store), vec![saved]);
    }

    #[tokio::test]
    async fn update_keeps_colour_group_and_recency_from_the_list() {
        let fixture = fixture().await;
        let edited = SavedConnection {
            host: "db2.example.com".to_owned(),
            last_opened_at: None,
            color: None,
            group: None,
            ..fixture.saved.clone()
        };

        let saved = fixture
            .editor
            .update(edited, SecretChanges::default())
            .await
            .expect("the edit");

        assert_eq!(saved.host, "db2.example.com");
        assert_eq!(saved.last_opened_at, fixture.saved.last_opened_at);
        assert_eq!(saved.color, fixture.saved.color);
        assert_eq!(saved.group, fixture.saved.group);
    }

    #[tokio::test]
    async fn a_new_target_relabels_the_kept_secrets() {
        let fixture = fixture().await;
        let moved = SavedConnection {
            host: "db2.example.com".to_owned(),
            ..fixture.saved.clone()
        };

        fixture
            .editor
            .update(moved.clone(), SecretChanges::default())
            .await
            .expect("the edit");

        assert_eq!(
            fixture
                .vault
                .stored_label(fixture.saved.id, SecretKind::DatabasePassword),
            Some(secret_label(SecretKind::DatabasePassword, &moved))
        );
    }

    #[tokio::test]
    async fn replaced_and_removed_secrets_reach_the_keyring() {
        let fixture = fixture().await;
        let id = fixture.saved.id;
        let changes = SecretChanges {
            database_password: SecretChange::Replace(SecretString::from("n3w")),
            ssh_password: SecretChange::Remove,
            ssh_passphrase: SecretChange::Keep,
        };

        fixture
            .editor
            .update(fixture.saved.clone(), changes)
            .await
            .expect("the edit");

        assert_eq!(
            fixture.vault.stored_secret(id, SecretKind::DatabasePassword).as_deref(),
            Some("n3w")
        );
        assert!(
            fixture
                .vault
                .calls()
                .contains(&Call::DeleteKind(id, SecretKind::SshPassword))
        );
    }

    #[tokio::test]
    async fn a_refused_secret_leaves_the_entry_as_it_was() {
        let fixture = fixture().await;
        fixture
            .vault
            .fail_store(SecretKind::DatabasePassword, SecretError::UnlockDismissed);
        let revision = fixture.store.snapshot().revision;
        let edited = SavedConnection {
            host: "db2.example.com".to_owned(),
            ..fixture.saved.clone()
        };
        let changes = SecretChanges {
            database_password: SecretChange::Replace(SecretString::from("n3w")),
            ..SecretChanges::default()
        };

        let refused = fixture.editor.update(edited, changes).await;

        assert!(matches!(refused, Err(SavedConnectionError::Secret(_))), "{refused:?}");
        assert_eq!(stored(&fixture.store), vec![fixture.saved.clone()]);
        assert_eq!(fixture.store.snapshot().revision, revision);
    }

    #[tokio::test]
    async fn a_refused_second_secret_puts_the_first_back() {
        let fixture = fixture().await;
        let id = fixture.saved.id;
        fixture.vault.fail_store(SecretKind::SshPassword, SecretError::Locked);
        let changes = SecretChanges {
            database_password: SecretChange::Replace(SecretString::from("n3w")),
            ssh_password: SecretChange::Replace(SecretString::from("tunnel")),
            ssh_passphrase: SecretChange::Keep,
        };

        let refused = fixture.editor.update(fixture.saved.clone(), changes).await;

        assert!(
            matches!(refused, Err(SavedConnectionError::Secret(SecretError::Locked))),
            "{refused:?}"
        );
        assert_eq!(
            fixture.vault.stored_secret(id, SecretKind::DatabasePassword).as_deref(),
            Some("s3cret"),
            "the refused edit kept its new password"
        );
        assert_eq!(fixture.vault.stored_secret(id, SecretKind::SshPassword), None);
    }

    #[tokio::test]
    async fn a_list_that_cannot_be_written_puts_the_secrets_back() {
        let fixture = fixture().await;
        let id = fixture.saved.id;
        let list_file =
            StoragePaths::under(fixture._root.path(), "tablepro-test", "app.tablepro.Test").connections_file();
        std::fs::remove_file(&list_file).expect("the list file");
        std::fs::create_dir(&list_file).expect("a directory where the list goes");
        let edited = SavedConnection {
            host: "db2.example.com".to_owned(),
            ..fixture.saved.clone()
        };
        let changes = SecretChanges {
            database_password: SecretChange::Replace(SecretString::from("n3w")),
            ..SecretChanges::default()
        };

        let refused = fixture.editor.update(edited, changes).await;

        assert!(matches!(refused, Err(SavedConnectionError::Storage(_))), "{refused:?}");
        assert_eq!(
            fixture.vault.stored_secret(id, SecretKind::DatabasePassword).as_deref(),
            Some("s3cret"),
            "the unsaved edit kept its new password"
        );
        assert_eq!(
            fixture.vault.stored_label(id, SecretKind::DatabasePassword),
            Some(secret_label(SecretKind::DatabasePassword, &fixture.saved))
        );
    }

    #[tokio::test]
    async fn an_edit_of_a_deleted_connection_stores_no_secret() {
        let fixture = fixture().await;
        let id = fixture.saved.id;
        fixture.store.remove_blocking(id).expect("the delete");
        let before = writes(&fixture.vault).len();
        let changes = SecretChanges {
            database_password: SecretChange::Replace(SecretString::from("n3w")),
            ..SecretChanges::default()
        };

        let refused = fixture.editor.update(fixture.saved.clone(), changes).await;

        assert!(matches!(refused, Err(SavedConnectionError::NotFound(gone)) if gone == id));
        assert_eq!(writes(&fixture.vault).len(), before, "the keyring was written");
        assert!(stored(&fixture.store).is_empty(), "the edit brought the entry back");
    }

    #[tokio::test]
    async fn move_to_group_publishes_a_revision() {
        let fixture = fixture().await;
        let mut receiver = fixture.store.subscribe();
        receiver.borrow_and_update();
        let archive = ConnectionGroupName::new("Archive").expect("a name");

        fixture
            .editor
            .move_to_group(fixture.saved.id, Some(archive.clone()))
            .await
            .expect("the move");

        assert!(receiver.has_changed().expect("the store is alive"));
        let ConnectionListState::Ready(list) = receiver.borrow_and_update().state.clone() else {
            panic!("expected a ready list");
        };
        assert_eq!(list[0].group, Some(archive));
        fixture
            .editor
            .move_to_group(fixture.saved.id, None)
            .await
            .expect("out of the group");
        assert_eq!(stored(&fixture.store)[0].group, None);
    }
}
