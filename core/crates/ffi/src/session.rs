use std::sync::Arc;

use tablepro_core::EditorSessionOptions;
use tablepro_session::Session;
use tablepro_session::runtime::Tasks;

use crate::cancel_token::{CancelToken, token};
use crate::catalog::{ColumnEntry, ObjectEntry, ObjectScopeArg, SchemaEntry, TableName};
use crate::editor::QueryEditor;
use crate::error::CoreError;
use crate::runtime::on_runtime;

/// One open database: its connection, the health monitor that keeps it
/// and the catalog the sidebar reads. Each catalog level is read when
/// first asked for and shared by every caller.
#[derive(uniffi::Object)]
pub struct DatabaseSession {
    session: Arc<Session>,
    tasks: Tasks,
}

impl DatabaseSession {
    pub(crate) fn new(session: Arc<Session>, tasks: Tasks) -> Self {
        Self { session, tasks }
    }
}

#[uniffi::export]
impl DatabaseSession {
    pub fn id(&self) -> String {
        self.session.id().to_string()
    }

    pub fn name(&self) -> String {
        self.session.metadata().name.clone()
    }

    pub fn driver_id(&self) -> String {
        self.session.metadata().driver_id.clone()
    }

    pub fn read_only(&self) -> bool {
        self.session.read_only()
    }

    pub async fn schemas(&self, cancel: Option<Arc<CancelToken>>) -> Result<Vec<SchemaEntry>, CoreError> {
        let session = self.session.clone();
        self.cancellable(cancel, async move {
            Ok(session.schemas().await?.iter().map(SchemaEntry::from).collect())
        })
        .await
    }

    pub async fn objects(
        &self,
        scope: ObjectScopeArg,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Vec<ObjectEntry>, CoreError> {
        let session = self.session.clone();
        self.cancellable(cancel, async move {
            Ok(session
                .objects(scope.into())
                .await?
                .iter()
                .map(ObjectEntry::from)
                .collect())
        })
        .await
    }

    /// Reads the scope's objects again, after a change the catalog did
    /// not see, such as a table the editor created.
    pub async fn refresh_objects(
        &self,
        scope: ObjectScopeArg,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Vec<ObjectEntry>, CoreError> {
        let session = self.session.clone();
        self.cancellable(cancel, async move {
            Ok(session
                .refresh_objects(scope.into())
                .await?
                .iter()
                .map(ObjectEntry::from)
                .collect())
        })
        .await
    }

    pub async fn columns(
        &self,
        table: TableName,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Vec<ColumnEntry>, CoreError> {
        let session = self.session.clone();
        self.cancellable(cancel, async move {
            Ok(session
                .columns(table.into())
                .await?
                .iter()
                .map(ColumnEntry::from)
                .collect())
        })
        .await
    }

    /// An editor tab's own connection.
    pub async fn open_editor(&self, cancel: Option<Arc<CancelToken>>) -> Result<Arc<QueryEditor>, CoreError> {
        let session = self.session.clone();
        let tasks = self.tasks.clone();
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            let editor = session
                .open_editor_session(EditorSessionOptions::default(), &cancel)
                .await?;
            Ok(Arc::new(QueryEditor::new(editor, tasks)))
        })
        .await
    }

    /// Stops every call and closes the connection. Editors opened from
    /// it close on their own.
    pub async fn close(&self) -> Result<(), CoreError> {
        let closing = self.session.begin_shutdown();
        on_runtime(&self.tasks, async move {
            closing
                .await
                .map(|_| ())
                .map_err(|failure| CoreError::failed("ffi.close_failed", failure.to_string()))
        })
        .await
    }
}

impl DatabaseSession {
    /// A catalog read is shared, so a cancel abandons this caller's wait
    /// and leaves the read to finish for the others.
    async fn cancellable<T, F>(&self, cancel: Option<Arc<CancelToken>>, work: F) -> Result<T, CoreError>
    where
        T: Send + 'static,
        F: Future<Output = Result<T, CoreError>> + Send + 'static,
    {
        let cancel = token(cancel);
        on_runtime(&self.tasks, async move {
            tokio::select! {
                biased;
                () = cancel.cancelled() => Err(CoreError::Cancelled),
                done = work => done,
            }
        })
        .await
    }
}

impl std::fmt::Debug for DatabaseSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DatabaseSession")
            .field("session", &self.session)
            .finish_non_exhaustive()
    }
}
