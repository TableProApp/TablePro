use std::sync::Arc;

use tablepro_core::SafeModeLevel;
use tablepro_core::credentials::{SecretError, SecretKind, SecretLookup, SecretVault};
use tablepro_foreign_import::review::{
    AppliedImport, ImportPlan, ImportReview, QueryImportOutcome, apply_blocking, save_queries,
};
use tablepro_session::runtime::Tasks;
use tablepro_storage::saved_queries::SavedQueries;
use tablepro_storage::{
    ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionIcon, ConnectionStore, ConnectionTag,
    ConnectionTagName, SavedConnection, StorageError,
};
use uuid::Uuid;

use super::duplicate_name::duplicate_name;
use super::library_outline::LibraryMove;
use super::saved_connection_error::SavedConnectionError;
use super::secret_change::SecretChange;
use super::secret_changes::SecretChanges;
use super::secret_labels::secret_label;

// What an import from another app wrote: the connections, and how many of their secrets the
// keyring refused, which the user then types at connect.
pub struct ImportedFromApp {
    pub applied: AppliedImport,
    pub secrets_not_kept: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GroupChoice {
    None,
    Existing(Uuid),
}

/// Changes a saved connection together with its keyring secrets: an
/// edit from the connect dialog, a copy, a move to another group.
///
/// The keyring goes first, as in a delete: a refusal there stops before
/// the list changes, so the user can try again. When the entry does not
/// land, each secret the edit changed is put back as it was, and a copy's
/// secrets are deleted. Every write publishes the list, which every
/// picker follows.
///
/// An edit and a copy run one at a time, since each writes the keyring
/// and the list in turn: two edits of one connection from two windows
/// would otherwise leave the endpoint of one with the password of the
/// other.
///
/// Run it on the app runtime, which the Secret Service client needs.
#[derive(Clone)]
pub struct SavedConnectionEditor {
    store: ConnectionStore,
    secrets: Arc<dyn SecretVault>,
    tasks: Tasks,
    turn: Arc<futures::lock::Mutex<()>>,
}

impl SavedConnectionEditor {
    pub fn new(store: ConnectionStore, secrets: Arc<dyn SecretVault>, tasks: Tasks) -> Self {
        Self {
            store,
            secrets,
            tasks,
            turn: Arc::default(),
        }
    }

    /// Save `connection` over the entry with its id, applying `changes`
    /// to its secrets. The id stays, so a rename or a new host keeps
    /// every secret the edit does not change. Its tags and icon are the
    /// dialog's. Colour, group and the last-opened time are taken from
    /// the list as it is at the write, since the connect dialog shows
    /// none of them.
    pub async fn update(
        &self,
        connection: SavedConnection,
        changes: SecretChanges,
    ) -> Result<SavedConnection, SavedConnectionError> {
        let _turn = self.turn.lock().await;
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
                    group_id: entry.group_id,
                    order: entry.order,
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

    // A new id, so deleting either leaves the other able to connect. Never opened, so it stays out of Recent.
    pub async fn duplicate(&self, id: Uuid) -> Result<SavedConnection, SavedConnectionError> {
        let _turn = self.turn.lock().await;
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
            .spawn_blocking_task(move || {
                let id = entry.id;
                store.insert_after_blocking(entry, source.id)?;
                // The store gives the copy its place in the group.
                let stored = store
                    .load_blocking()
                    .ok()
                    .and_then(|list| list.iter().find(|saved| saved.id == id).cloned());
                Ok::<_, StorageError>(stored)
            })
            .await
            .map_err(SavedConnectionError::from)
            .and_then(|written| written.map_err(SavedConnectionError::from));
        match written {
            Ok(stored) => Ok(stored.unwrap_or(copy)),
            Err(error) => {
                self.forget_secrets(copy.id).await;
                Err(error)
            }
        }
    }

    // The list must still be the one reviewed; a refused secret leaves its connection saved.
    pub async fn add_imported(
        &self,
        review: ImportReview,
        plan: ImportPlan,
    ) -> Result<ImportedFromApp, SavedConnectionError> {
        let _turn = self.turn.lock().await;
        let store = self.store.clone();
        let applied = self
            .tasks
            .spawn_blocking_task(move || apply_blocking(&review, &plan, &store))
            .await??;
        let mut secrets_not_kept = 0;
        for imported in &applied.connections {
            for secret in &imported.secrets {
                let label = secret_label(secret.kind, &imported.connection);
                if let Err(error) = self
                    .secrets
                    .store(imported.connection.id, secret.kind, &secret.secret, &label)
                    .await
                {
                    tracing::warn!(%error, kind = ?secret.kind, "a secret of an imported connection was not kept");
                    secrets_not_kept += 1;
                }
            }
        }
        // A delete from another window can land between the write and the keyring, and its own
        // clean-up ran before these secrets existed.
        if let Ok(list) = self.list().await {
            for imported in &applied.connections {
                let id = imported.connection.id;
                if !imported.secrets.is_empty() && !list.iter().any(|saved| saved.id == id) {
                    self.forget_secrets(id).await;
                }
            }
        }
        Ok(ImportedFromApp {
            applied,
            secrets_not_kept,
        })
    }

    // A delete from another window purges a connection's queries once; any this import saves for
    // it afterwards are removed again here.
    pub async fn save_imported_queries(&self, applied: &AppliedImport, store: &SavedQueries) -> QueryImportOutcome {
        let outcome = save_queries(applied, store).await;
        if let Ok(list) = self.list().await {
            let mut gone: Vec<Uuid> = applied
                .queries
                .iter()
                .map(|query| query.query.connection_id)
                .filter(|id| !list.iter().any(|saved| saved.id == *id))
                .collect();
            gone.sort_unstable();
            gone.dedup();
            for id in gone {
                if let Err(error) = store.delete_for_connection(id).await {
                    tracing::warn!(%error, "queries imported for a deleted connection are still saved");
                }
            }
        }
        outcome
    }

    /// A pick of the group it is already in writes nothing.
    pub async fn move_to_group(&self, id: Uuid, choice: GroupChoice) -> Result<(), SavedConnectionError> {
        let store = self.store.clone();
        let moved = self
            .tasks
            .spawn_blocking_task(move || {
                let current = store
                    .load_blocking()?
                    .iter()
                    .find(|saved| saved.id == id)
                    .map(|saved| saved.group_id);
                match (choice, current) {
                    (_, None) => Err(StorageError::ConnectionNotFound { id }),
                    (GroupChoice::None, Some(None)) => Ok(()),
                    (GroupChoice::Existing(group), Some(Some(current))) if group == current => Ok(()),
                    (GroupChoice::None, Some(_)) => store.move_connections_blocking(&[id], None, None),
                    (GroupChoice::Existing(group), Some(_)) => {
                        store.move_connections_blocking(&[id], Some(group), None)
                    }
                }
            })
            .await?;
        match moved {
            Err(StorageError::ConnectionNotFound { .. }) => Err(SavedConnectionError::NotFound(id)),
            moved => Ok(moved?),
        }
    }

    // `with` is filed in the new group, so New Group from a connection's menu takes the same path as New Group.
    pub async fn create_group(
        &self,
        parent: Option<Uuid>,
        name: ConnectionGroupName,
        with: Option<Uuid>,
    ) -> Result<ConnectionGroup, SavedConnectionError> {
        let store = self.store.clone();
        let created = self
            .tasks
            .spawn_blocking_task(move || {
                // One write, so a connection deleted meanwhile leaves no empty group behind.
                match with {
                    Some(id) => store.move_connections_to_group_named_blocking(&[id], parent, name),
                    None => store.create_group_blocking(ConnectionGroup::new(name, parent)),
                }
            })
            .await?;
        match created {
            Err(StorageError::ConnectionNotFound { id }) => Err(SavedConnectionError::NotFound(id)),
            created => Ok(created?),
        }
    }

    // The core would refuse a group its own name when a version 2 list left it a case-only sibling.
    pub async fn rename_group(&self, id: Uuid, name: ConnectionGroupName) -> Result<(), SavedConnectionError> {
        let store = self.store.clone();
        self.tasks
            .spawn_blocking_task(move || {
                let unchanged = store
                    .list_blocking()?
                    .group_tree()
                    .get(id)
                    .is_some_and(|group| group.name == name);
                if unchanged {
                    return Ok(());
                }
                store.rename_group_blocking(id, name)
            })
            .await??;
        Ok(())
    }

    // A group already gone is what the user asked for.
    pub async fn delete_group(&self, id: Uuid) -> Result<(), SavedConnectionError> {
        let store = self.store.clone();
        self.tasks
            .spawn_blocking_task(move || store.delete_group_blocking(id))
            .await??;
        Ok(())
    }

    pub(crate) async fn change_library(&self, change: LibraryMove) -> Result<(), SavedConnectionError> {
        let store = self.store.clone();
        self.tasks
            .spawn_blocking_task(move || match change {
                LibraryMove::Connections { ids, group, before } => store.move_connections_blocking(&ids, group, before),
                LibraryMove::Groups { ids, parent, before } => store.move_groups_blocking(&ids, parent, before),
                LibraryMove::Favourites { ids, before } => store.add_favorites_blocking(&ids, before),
            })
            .await??;
        Ok(())
    }

    // Adding a favourite again would move it to the end, since adding is how favourites reorder.
    pub async fn set_favourite(&self, id: Uuid, favourite: bool) -> Result<(), SavedConnectionError> {
        let store = self.store.clone();
        let set = self
            .tasks
            .spawn_blocking_task(move || {
                if !favourite {
                    return store.remove_favorites_blocking(&[id]);
                }
                if store.list_blocking()?.is_favorite(id) {
                    return Ok(());
                }
                store.add_favorites_blocking(&[id], None)
            })
            .await?;
        match set {
            Err(StorageError::ConnectionNotFound { .. }) => Err(SavedConnectionError::NotFound(id)),
            set => Ok(set?),
        }
    }

    /// Put `color` on the connection `id`, or take its colour off.
    pub async fn set_color(&self, id: Uuid, color: Option<ConnectionColor>) -> Result<(), SavedConnectionError> {
        self.write(id, move |entry| entry.color = color)
            .await?
            .map(drop)
            .ok_or(SavedConnectionError::NotFound(id))
    }

    pub async fn set_icon(&self, id: Uuid, icon: Option<ConnectionIcon>) -> Result<(), SavedConnectionError> {
        self.write(id, move |entry| entry.icon = icon)
            .await?
            .map(drop)
            .ok_or(SavedConnectionError::NotFound(id))
    }

    /// Put the tag `tag` on the connection `id`, or take it off.
    pub async fn set_tag(&self, id: Uuid, tag: Uuid, carried: bool) -> Result<(), SavedConnectionError> {
        self.write(id, move |entry| {
            if !carried {
                entry.tags.retain(|held| *held != tag);
            } else if !entry.tags.contains(&tag) {
                entry.tags.push(tag);
            }
        })
        .await?
        .map(drop)
        .ok_or(SavedConnectionError::NotFound(id))
    }

    /// A new tag, put on the connection `on` when there is one.
    pub async fn create_tag(
        &self,
        name: ConnectionTagName,
        color: ConnectionColor,
        on: Option<Uuid>,
    ) -> Result<ConnectionTag, SavedConnectionError> {
        let store = self.store.clone();
        let tag = self
            .tasks
            .spawn_blocking_task(move || store.create_tag_blocking(name, color))
            .await??;
        if let Some(id) = on {
            self.set_tag(id, tag.id, true).await?;
        }
        Ok(tag)
    }

    /// Rename or recolour a tag on every connection that has it.
    pub async fn update_tag(&self, tag: ConnectionTag) -> Result<(), SavedConnectionError> {
        let id = tag.id;
        let store = self.store.clone();
        match self
            .tasks
            .spawn_blocking_task(move || store.update_tag_blocking(tag))
            .await?
        {
            Err(StorageError::NotFound) => Err(SavedConnectionError::TagNotFound(id)),
            written => Ok(written?),
        }
    }

    /// Delete a tag and take it off every connection. One already gone
    /// is what the user asked for.
    pub async fn delete_tag(&self, id: Uuid) -> Result<(), SavedConnectionError> {
        let store = self.store.clone();
        self.tasks
            .spawn_blocking_task(move || store.delete_tag_blocking(id))
            .await??;
        Ok(())
    }

    /// Give the connection `id` another Safe Mode level.
    pub async fn set_safe_mode(&self, id: Uuid, level: SafeModeLevel) -> Result<(), SavedConnectionError> {
        self.write(id, move |entry| entry.safe_mode = level)
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
    use tablepro_storage::{ConnectionList, ConnectionListState, StoragePaths};
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
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            query_timeout_secs: None,
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: Some(chrono::Utc::now()),
            color: Some(ConnectionColor::Red),
            group_id: Some(crate::test_support::group_id("Work")),
            order: 0,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    /// One saved connection with its database password in the keyring.
    async fn fixture() -> Fixture {
        let root = tempfile::tempdir().expect("tempdir");
        let store = ConnectionStore::new(&StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.Test"));
        let vault = Arc::new(FakeSecretVault::new());
        let saved = connection();
        crate::test_support::save_filed(&store, saved.clone());
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

    /// A vault whose first SSH password store waits until the test lets
    /// it go, so an edit can be held between two of its secrets.
    struct HeldVault {
        inner: Arc<FakeSecretVault>,
        held: futures::lock::Mutex<Option<tokio::sync::oneshot::Receiver<()>>>,
        reached: tokio::sync::Notify,
    }

    #[async_trait::async_trait]
    impl SecretVault for HeldVault {
        async fn store(
            &self,
            id: Uuid,
            kind: SecretKind,
            secret: &SecretString,
            label: &str,
        ) -> Result<(), SecretError> {
            if kind == SecretKind::SshPassword {
                let gate = self.held.lock().await.take();
                if let Some(gate) = gate {
                    self.reached.notify_one();
                    gate.await.expect("the test lets the store go");
                }
            }
            self.inner.store(id, kind, secret, label).await
        }

        async fn load(&self, id: Uuid, kind: SecretKind) -> Result<SecretLookup, SecretError> {
            self.inner.load(id, kind).await
        }

        async fn relabel(&self, id: Uuid, kind: SecretKind, label: &str) -> Result<(), SecretError> {
            self.inner.relabel(id, kind, label).await
        }

        async fn delete_kind(&self, id: Uuid, kind: SecretKind) -> Result<(), SecretError> {
            self.inner.delete_kind(id, kind).await
        }

        async fn delete_connection(&self, id: Uuid) -> Result<(), SecretError> {
            self.inner.delete_connection(id).await
        }
    }

    #[tokio::test]
    async fn two_edits_of_one_connection_do_not_mix() {
        let fixture = fixture().await;
        let (release, gate) = tokio::sync::oneshot::channel();
        let vault = Arc::new(HeldVault {
            inner: fixture.vault.clone(),
            held: futures::lock::Mutex::new(Some(gate)),
            reached: tokio::sync::Notify::new(),
        });
        let editor = SavedConnectionEditor::new(fixture.store.clone(), vault.clone(), paused_tasks());
        let edit = |host: &str, password: &str| {
            let connection = SavedConnection {
                host: host.to_owned(),
                ..fixture.saved.clone()
            };
            let changes = SecretChanges {
                database_password: SecretChange::Replace(SecretString::from(password.to_owned())),
                ssh_password: SecretChange::Replace(SecretString::from(password.to_owned())),
                ssh_passphrase: SecretChange::Keep,
            };
            (connection, changes)
        };
        let (first, first_changes) = edit("first.example.com", "first");
        let (second, second_changes) = edit("second.example.com", "second");

        let held = editor.update(first, first_changes);
        let racing = async {
            vault.reached.notified().await;
            let second = editor.update(second, second_changes);
            let letting_go = async {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                release.send(()).expect("the held store is waiting");
            };
            futures::future::join(second, letting_go).await.0
        };
        let (first, second) = futures::future::join(held, racing).await;
        first.expect("the first edit");
        second.expect("the second edit");

        let saved = stored(&fixture.store);
        let password = fixture
            .vault
            .stored_secret(fixture.saved.id, SecretKind::DatabasePassword);
        assert_eq!(saved[0].host, "second.example.com");
        assert_eq!(
            password.as_deref(),
            Some("second"),
            "the endpoint and password come from different edits"
        );
    }

    #[tokio::test]
    async fn duplicate_copies_secrets_to_new_id() {
        let fixture = fixture().await;

        let copy = fixture.editor.duplicate(fixture.saved.id).await.expect("the copy");

        assert_ne!(copy.id, fixture.saved.id);
        assert_eq!(copy.name, "Prod (Copy)");
        assert_eq!(copy.last_opened_at, None, "the copy claimed the original's recency");
        assert_eq!(copy.group_id, fixture.saved.group_id);
        let list = fixture.store.list_blocking().expect("the list");
        assert!(!list.is_favorite(copy.id), "the copy became a favourite");
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
            safe_mode: tablepro_core::SafeModeLevel::ReadOnly,
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
        assert_eq!(
            stored(&fixture.store)[0].safe_mode,
            tablepro_core::SafeModeLevel::ReadOnly
        );
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
            group_id: None,
            order: 0,
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
        assert_eq!(saved.group_id, fixture.saved.group_id);
    }

    #[tokio::test]
    async fn update_takes_the_tags_and_icon_the_dialog_shows() {
        let fixture = fixture().await;
        let tag = fixture
            .editor
            .create_tag(
                ConnectionTagName::new("production").expect("a name"),
                ConnectionColor::Red,
                None,
            )
            .await
            .expect("the tag");
        let edited = SavedConnection {
            tags: vec![tag.id],
            icon: Some(ConnectionIcon::Shield),
            ..fixture.saved.clone()
        };

        let saved = fixture
            .editor
            .update(edited, SecretChanges::default())
            .await
            .expect("the edit");

        assert_eq!(saved.tags, [tag.id]);
        assert_eq!(saved.icon, Some(ConnectionIcon::Shield));
        assert_eq!(stored(&fixture.store)[0], saved);
    }

    #[tokio::test]
    async fn tags_go_on_and_off_and_follow_a_rename_and_a_delete() {
        let fixture = fixture().await;
        let id = fixture.saved.id;
        let name = |name: &str| ConnectionTagName::new(name).expect("a name");
        let production = fixture
            .editor
            .create_tag(name("production"), ConnectionColor::Red, Some(id))
            .await
            .expect("the tag");
        let acme = fixture
            .editor
            .create_tag(name("acme"), ConnectionColor::Blue, None)
            .await
            .expect("the tag");
        fixture.editor.set_tag(id, acme.id, true).await.expect("on");
        fixture.editor.set_tag(id, acme.id, true).await.expect("on again");
        assert_eq!(stored(&fixture.store)[0].tags, [production.id, acme.id]);

        let renamed = ConnectionTag {
            name: name("prod"),
            color: ConnectionColor::Orange,
            ..production.clone()
        };
        fixture.editor.update_tag(renamed.clone()).await.expect("the rename");
        let tags = fixture.store.tags_blocking().expect("the tags");
        assert!(tags.contains(&renamed), "{tags:?}");

        let taken = fixture
            .editor
            .create_tag(name("ACME"), ConnectionColor::Green, None)
            .await
            .expect_err("a name another tag holds");
        assert!(
            matches!(taken, SavedConnectionError::Storage(StorageError::TagNameTaken)),
            "{taken:?}"
        );

        fixture.editor.set_tag(id, production.id, false).await.expect("off");
        assert_eq!(stored(&fixture.store)[0].tags, [acme.id]);
        fixture.editor.delete_tag(acme.id).await.expect("the delete");
        assert!(stored(&fixture.store)[0].tags.is_empty());
        fixture.editor.delete_tag(acme.id).await.expect("gone already");
        assert!(matches!(
            fixture.editor.update_tag(acme).await,
            Err(SavedConnectionError::TagNotFound(_))
        ));
    }

    #[tokio::test]
    async fn an_icon_goes_on_and_off() {
        let fixture = fixture().await;

        fixture
            .editor
            .set_icon(fixture.saved.id, Some(ConnectionIcon::Cloud))
            .await
            .expect("the icon");
        assert_eq!(stored(&fixture.store)[0].icon, Some(ConnectionIcon::Cloud));
        fixture.editor.set_icon(fixture.saved.id, None).await.expect("no icon");
        assert_eq!(stored(&fixture.store)[0].icon, None);
        assert!(matches!(
            fixture.editor.set_icon(Uuid::new_v4(), None).await,
            Err(SavedConnectionError::NotFound(_))
        ));
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

    fn group_name(name: &str) -> ConnectionGroupName {
        ConnectionGroupName::new(name).expect("a group name")
    }

    fn library(store: &ConnectionStore) -> ConnectionList {
        store.list_blocking().expect("the list")
    }

    fn another(name: &str) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: name.to_owned(),
            ..connection()
        }
    }

    #[tokio::test]
    async fn move_to_group_publishes_a_revision() {
        let fixture = fixture().await;
        let archive = fixture
            .store
            .create_group_blocking(ConnectionGroup::new(group_name("Archive"), None))
            .expect("the group");
        let mut receiver = fixture.store.subscribe();
        receiver.borrow_and_update();

        fixture
            .editor
            .move_to_group(fixture.saved.id, GroupChoice::Existing(archive.id))
            .await
            .expect("the move");

        assert!(receiver.has_changed().expect("the store is alive"));
        let ConnectionListState::Ready(list) = receiver.borrow_and_update().state.clone() else {
            panic!("expected a ready list");
        };
        assert_eq!(list.connections[0].group_id, Some(archive.id));
        fixture
            .editor
            .move_to_group(fixture.saved.id, GroupChoice::None)
            .await
            .expect("out of the group");
        assert_eq!(stored(&fixture.store)[0].group_id, None);
    }

    #[tokio::test]
    async fn an_existing_group_takes_the_connection_and_a_repeat_writes_nothing() {
        let fixture = fixture().await;
        let work = fixture.saved.group_id.expect("the fixture's group");
        fixture
            .editor
            .move_to_group(fixture.saved.id, GroupChoice::None)
            .await
            .expect("out of the group");

        fixture
            .editor
            .move_to_group(fixture.saved.id, GroupChoice::Existing(work))
            .await
            .expect("back in");
        let revision = fixture.store.snapshot().revision;
        fixture
            .editor
            .move_to_group(fixture.saved.id, GroupChoice::Existing(work))
            .await
            .expect("the same group");

        assert_eq!(stored(&fixture.store)[0].group_id, Some(work));
        assert_eq!(
            fixture.store.snapshot().revision,
            revision,
            "a pick of its own group was written"
        );
        let gone = fixture
            .editor
            .move_to_group(fixture.saved.id, GroupChoice::Existing(Uuid::new_v4()))
            .await;
        assert!(
            matches!(
                gone,
                Err(SavedConnectionError::Storage(StorageError::GroupNotFound { .. }))
            ),
            "{gone:?}"
        );
        let missing = fixture.editor.move_to_group(Uuid::new_v4(), GroupChoice::None).await;
        assert!(matches!(missing, Err(SavedConnectionError::NotFound(_))), "{missing:?}");
    }

    #[tokio::test]
    async fn a_new_group_goes_where_it_is_asked_and_takes_the_connection_with_it() {
        let fixture = fixture().await;
        let work = fixture.saved.group_id.expect("the fixture's group");

        let staging = fixture
            .editor
            .create_group(Some(work), group_name("Staging"), None)
            .await
            .expect("the subgroup");
        let archive = fixture
            .editor
            .create_group(None, group_name("Archive"), Some(fixture.saved.id))
            .await
            .expect("the group");

        let list = library(&fixture.store);
        assert_eq!(list.group_tree().label(staging.id).as_deref(), Some("Work / Staging"));
        let top: Vec<Uuid> = list.group_tree().children(None).iter().map(|group| group.id).collect();
        assert_eq!(top, [work, archive.id], "a new group was not made last");
        assert_eq!(
            stored(&fixture.store)[0].group_id,
            Some(archive.id),
            "the connection was left out"
        );
        let taken = fixture.editor.create_group(None, group_name("archive"), None).await;
        assert!(
            matches!(
                taken,
                Err(SavedConnectionError::Storage(StorageError::GroupNameTaken { .. }))
            ),
            "{taken:?}"
        );
        let eu = fixture
            .editor
            .create_group(Some(staging.id), group_name("EU"), None)
            .await
            .expect("a third level");
        let deep = fixture.editor.create_group(Some(eu.id), group_name("Zone"), None).await;
        assert!(
            matches!(
                deep,
                Err(SavedConnectionError::Storage(StorageError::GroupTooDeep { .. }))
            ),
            "{deep:?}"
        );
        let gone = Uuid::new_v4();
        let missing = fixture.editor.create_group(None, group_name("Spare"), Some(gone)).await;
        assert!(
            matches!(missing, Err(SavedConnectionError::NotFound(id)) if id == gone),
            "{missing:?}"
        );
        assert!(
            !library(&fixture.store)
                .groups
                .iter()
                .any(|group| group.name.as_str() == "Spare"),
            "a refused move left its new group behind"
        );
    }

    #[tokio::test]
    async fn a_rename_takes_a_new_name_or_case_and_refuses_a_siblings_name() {
        let fixture = fixture().await;
        let work = fixture.saved.group_id.expect("the fixture's group");
        let home = fixture
            .editor
            .create_group(None, group_name("Home"), None)
            .await
            .expect("a sibling");

        fixture
            .editor
            .rename_group(work, group_name("WORK"))
            .await
            .expect("a case change");
        fixture
            .editor
            .rename_group(home.id, group_name("Office"))
            .await
            .expect("a new name");

        let list = library(&fixture.store);
        assert_eq!(list.group_tree().label(work).as_deref(), Some("WORK"));
        assert_eq!(list.group_tree().label(home.id).as_deref(), Some("Office"));
        let taken = fixture.editor.rename_group(home.id, group_name("work")).await;
        assert!(
            matches!(
                taken,
                Err(SavedConnectionError::Storage(StorageError::GroupNameTaken { .. }))
            ),
            "{taken:?}"
        );
        let gone = fixture.editor.rename_group(Uuid::new_v4(), group_name("Gone")).await;
        assert!(
            matches!(
                gone,
                Err(SavedConnectionError::Storage(StorageError::GroupNotFound { .. }))
            ),
            "{gone:?}"
        );
    }

    #[tokio::test]
    async fn a_group_keeps_its_own_name_beside_a_case_only_sibling() {
        let root = tempfile::tempdir().expect("tempdir");
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.Test");
        let work = crate::test_support::group_id("Work");
        let filed = |group: Uuid| SavedConnection {
            group_id: Some(group),
            ..another("Prod")
        };
        crate::test_support::seed_library(&paths, &[filed(work), filed(crate::test_support::group_id("work"))]);
        let store = ConnectionStore::new(&paths);
        let editor = SavedConnectionEditor::new(store.clone(), Arc::new(FakeSecretVault::new()), paused_tasks());
        store.load_blocking().expect("the list");
        let revision = store.snapshot().revision;

        editor
            .rename_group(work, group_name("Work"))
            .await
            .expect("its own name");

        assert_eq!(store.snapshot().revision, revision, "an unchanged name was written");
        let clash = editor.rename_group(work, group_name("WORK")).await;
        assert!(
            matches!(
                clash,
                Err(SavedConnectionError::Storage(StorageError::GroupNameTaken { .. }))
            ),
            "{clash:?}"
        );
    }

    #[tokio::test]
    async fn a_deleted_group_frees_its_connections_and_a_repeat_is_done() {
        let fixture = fixture().await;
        let work = fixture.saved.group_id.expect("the fixture's group");
        fixture
            .editor
            .create_group(Some(work), group_name("Staging"), None)
            .await
            .expect("a subgroup");

        fixture.editor.delete_group(work).await.expect("the delete");

        assert_eq!(stored(&fixture.store)[0].group_id, None);
        assert!(
            library(&fixture.store).groups.is_empty(),
            "the subgroup outlived its parent"
        );
        let revision = fixture.store.snapshot().revision;
        fixture.editor.delete_group(work).await.expect("gone already");
        assert_eq!(fixture.store.snapshot().revision, revision);
    }

    #[tokio::test]
    async fn each_library_change_reaches_the_store() {
        let fixture = fixture().await;
        let (id, work) = (fixture.saved.id, fixture.saved.group_id.expect("the fixture's group"));
        let stage = another("Stage");
        crate::test_support::save_filed(&fixture.store, stage.clone());
        let home = fixture
            .editor
            .create_group(None, group_name("Home"), None)
            .await
            .expect("a group");
        let apply = |change: LibraryMove| fixture.editor.change_library(change);

        apply(LibraryMove::Connections {
            ids: vec![stage.id],
            group: Some(work),
            before: Some(id),
        })
        .await
        .expect("the reorder");
        apply(LibraryMove::Groups {
            ids: vec![home.id],
            parent: None,
            before: Some(work),
        })
        .await
        .expect("the group move");
        apply(LibraryMove::Favourites {
            ids: vec![id, stage.id],
            before: None,
        })
        .await
        .expect("the favourites");
        apply(LibraryMove::Favourites {
            ids: vec![stage.id],
            before: Some(id),
        })
        .await
        .expect("the favourites reorder");

        let list = library(&fixture.store);
        let in_work: Vec<Uuid> = list.connections_in(Some(work)).iter().map(|saved| saved.id).collect();
        assert_eq!(in_work, [stage.id, id]);
        let top: Vec<Uuid> = list.group_tree().children(None).iter().map(|group| group.id).collect();
        assert_eq!(top, [home.id, work]);
        assert_eq!(list.favorites.to_vec(), [stage.id, id]);
        let cycle = apply(LibraryMove::Groups {
            ids: vec![work],
            parent: Some(work),
            before: None,
        })
        .await;
        assert!(
            matches!(
                cycle,
                Err(SavedConnectionError::Storage(StorageError::GroupCycle { .. }))
            ),
            "{cycle:?}"
        );
        let gone = apply(LibraryMove::Favourites {
            ids: vec![Uuid::new_v4()],
            before: None,
        })
        .await;
        assert!(
            matches!(
                gone,
                Err(SavedConnectionError::Storage(StorageError::ConnectionNotFound { .. }))
            ),
            "{gone:?}"
        );
    }

    #[tokio::test]
    async fn a_favourite_goes_last_once_and_comes_off() {
        let fixture = fixture().await;
        let id = fixture.saved.id;
        let stage = another("Stage");
        crate::test_support::save_filed(&fixture.store, stage.clone());
        let favourites = || library(&fixture.store).favorites.to_vec();

        fixture.editor.set_favourite(stage.id, true).await.expect("a favourite");
        fixture
            .editor
            .set_favourite(id, true)
            .await
            .expect("a second favourite");
        assert_eq!(favourites(), [stage.id, id]);
        let revision = fixture.store.snapshot().revision;
        fixture
            .editor
            .set_favourite(stage.id, true)
            .await
            .expect("a favourite again");
        assert_eq!(favourites(), [stage.id, id], "a favourite again moved to the end");
        assert_eq!(fixture.store.snapshot().revision, revision);

        fixture.editor.set_favourite(stage.id, false).await.expect("off");
        assert_eq!(favourites(), [id]);
        fixture.editor.set_favourite(stage.id, false).await.expect("off again");
        assert_eq!(favourites(), [id]);
        let gone = Uuid::new_v4();
        let missing = fixture.editor.set_favourite(gone, true).await;
        assert!(
            matches!(missing, Err(SavedConnectionError::NotFound(at)) if at == gone),
            "{missing:?}"
        );
    }

    #[tokio::test]
    async fn a_copy_lands_right_after_its_original() {
        let fixture = fixture().await;
        let work = fixture.saved.group_id.expect("the fixture's group");
        crate::test_support::save_filed(&fixture.store, another("Stage"));
        crate::test_support::save_filed(&fixture.store, another("Test"));

        let copy = fixture.editor.duplicate(fixture.saved.id).await.expect("the copy");

        let names: Vec<String> = library(&fixture.store)
            .connections_in(Some(work))
            .iter()
            .map(|saved| saved.name.clone())
            .collect();
        assert_eq!(names, ["Prod", "Prod (Copy)", "Stage", "Test"]);
        assert_eq!(copy.order, 1);
    }
}
