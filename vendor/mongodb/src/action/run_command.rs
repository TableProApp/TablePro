use std::time::Duration;

use crate::bson::{Bson, Document, RawDocumentBuf};

use crate::{
    bson_compat::RawResult,
    client::session::TransactionState,
    coll::options::CursorType,
    db::options::{RunCommandOptions, RunCursorCommandOptions},
    error::{ErrorKind, Result},
    operation::{run_command, run_cursor_command},
    selection_criteria::SelectionCriteria,
    ClientSession,
    Cursor,
    Database,
    SessionCursor,
};

use super::{
    action_impl,
    deeplink,
    export_doc,
    option_setters,
    options_doc,
    ExplicitSession,
    ImplicitSession,
};

impl Database {
    /// Runs a database-level command.
    ///
    /// Note that no inspection is done on `doc`, so the command will not use the database's default
    /// read concern or write concern. If specific read concern or write concern is desired, it must
    /// be specified manually.
    /// Please note that run_command doesn't validate WriteConcerns passed into the body of the
    /// command document.
    ///
    /// `await` will return d[`Result<Document>`].
    #[deeplink]
    #[options_doc(run_command)]
    pub fn run_command(&self, command: Document) -> RunCommand<'_> {
        RunCommand {
            db: self,
            command: RawDocumentBuf::try_from(&command),
            options: None,
            session: None,
        }
    }

    /// Runs a database-level command.
    ///
    /// Note that no inspection is done on `doc`, so the command will not use the database's default
    /// read concern or write concern. If specific read concern or write concern is desired, it must
    /// be specified manually.
    /// Please note that run_raw_command doesn't validate WriteConcerns passed into the body of the
    /// command document.
    ///
    /// `await` will return d[`Result<Document>`].
    #[deeplink]
    #[options_doc(run_command)]
    pub fn run_raw_command(&self, command: RawDocumentBuf) -> RunCommand<'_> {
        RunCommand {
            db: self,
            command: Ok(command),
            options: None,
            session: None,
        }
    }

    /// Runs a database-level command and returns a cursor to the response.
    ///
    /// `await` will return d[`Result<Cursor<Document>>`] or a
    /// d[`Result<SessionCursor<Document>>`] if a [`ClientSession`] is provided.
    #[deeplink]
    #[options_doc(run_cursor_command)]
    pub fn run_cursor_command(&self, command: Document) -> RunCursorCommand<'_> {
        RunCursorCommand {
            db: self,
            command: RawDocumentBuf::try_from(&command),
            options: None,
            session: ImplicitSession,
        }
    }

    /// Runs a database-level command and returns a cursor to the response.
    ///
    /// `await` will return d[`Result<Cursor<Document>>`] or a
    /// d[`Result<SessionCursor<Document>>`] if a [`ClientSession`] is provided.
    #[deeplink]
    #[options_doc(run_cursor_command)]
    pub fn run_raw_cursor_command(&self, command: RawDocumentBuf) -> RunCursorCommand<'_> {
        RunCursorCommand {
            db: self,
            command: Ok(command),
            options: None,
            session: ImplicitSession,
        }
    }
}

#[cfg(feature = "sync")]
impl crate::sync::Database {
    /// Runs a database-level command.
    ///
    /// Note that no inspection is done on `doc`, so the command will not use the database's default
    /// read concern or write concern. If specific read concern or write concern is desired, it must
    /// be specified manually.
    /// Please note that run_command doesn't validate WriteConcerns passed into the body of the
    /// command document.
    ///
    /// [`run`](RunCommand::run) will return d[`Result<Document>`].
    #[deeplink]
    #[options_doc(run_command, "run")]
    pub fn run_command(&self, command: Document) -> RunCommand<'_> {
        self.async_database.run_command(command)
    }

    /// Runs a database-level command.
    ///
    /// Note that no inspection is done on `doc`, so the command will not use the database's default
    /// read concern or write concern. If specific read concern or write concern is desired, it must
    /// be specified manually.
    /// Please note that run_raw_command doesn't validate WriteConcerns passed into the body of the
    /// command document.
    ///
    /// [`run`](RunCommand::run) will return d[`Result<Document>`].
    #[deeplink]
    #[options_doc(run_command, "run")]
    pub fn run_raw_command(&self, command: RawDocumentBuf) -> RunCommand<'_> {
        self.async_database.run_raw_command(command)
    }

    /// Runs a database-level command and returns a cursor to the response.
    ///
    /// [`run`](RunCursorCommand::run) will return d[`Result<crate::sync::Cursor<Document>>`] or a
    /// d[`Result<crate::sync::SessionCursor<Document>>`] if a [`ClientSession`] is provided.
    #[deeplink]
    #[options_doc(run_cursor_command, "run")]
    pub fn run_cursor_command(&self, command: Document) -> RunCursorCommand<'_> {
        self.async_database.run_cursor_command(command)
    }

    /// Runs a database-level command and returns a cursor to the response.
    ///
    /// [`run`](RunCursorCommand::run) will return d[`Result<crate::sync::Cursor<Document>>`] or a
    /// d[`Result<crate::sync::SessionCursor<Document>>`] if a [`ClientSession`] is provided.
    #[deeplink]
    #[options_doc(run_cursor_command, "run")]
    pub fn run_raw_cursor_command(&self, command: RawDocumentBuf) -> RunCursorCommand<'_> {
        self.async_database.run_raw_cursor_command(command)
    }
}

/// Run a database-level command.  Create with [`Database::run_command`].
#[must_use]
pub struct RunCommand<'a> {
    db: &'a Database,
    command: RawResult<RawDocumentBuf>,
    options: Option<RunCommandOptions>,
    session: Option<&'a mut ClientSession>,
}

#[option_setters(crate::db::options::RunCommandOptions)]
#[export_doc(run_command)]
impl<'a> RunCommand<'a> {
    /// Run the command using the provided [`ClientSession`].
    pub fn session(mut self, value: impl Into<&'a mut ClientSession>) -> Self {
        self.session = Some(value.into());
        self
    }
}

#[action_impl]
impl<'a> Action for RunCommand<'a> {
    type Future = RunCommandFuture;

    async fn execute(self) -> Result<Document> {
        let mut selection_criteria = self.options.and_then(|o| o.selection_criteria);
        let command = self.command?;
        if let Some(session) = &self.session {
            match session.transaction.state {
                TransactionState::Starting | TransactionState::InProgress => {
                    if command.get("readConcern").is_ok_and(|rc| rc.is_some()) {
                        return Err(ErrorKind::InvalidArgument {
                            message: "Cannot set read concern after starting a transaction".into(),
                        }
                        .into());
                    }
                    selection_criteria = match selection_criteria {
                        Some(selection_criteria) => Some(selection_criteria),
                        None => {
                            if let Some(ref options) = session.transaction.options {
                                options.selection_criteria.clone()
                            } else {
                                None
                            }
                        }
                    };
                }
                _ => {}
            }
        }

        let operation =
            run_command::RunCommand::new(self.db.clone(), command, selection_criteria, None);
        self.db
            .client()
            .execute_operation(operation, self.session)
            .await
    }
}

/// Runs a database-level command and returns a cursor to the response.  Create with
/// [`Database::run_cursor_command`].
#[must_use]
pub struct RunCursorCommand<'a, Session = ImplicitSession> {
    db: &'a Database,
    command: RawResult<RawDocumentBuf>,
    options: Option<RunCursorCommandOptions>,
    session: Session,
}

#[option_setters(crate::db::options::RunCursorCommandOptions)]
#[export_doc(run_cursor_command, extra = [session, batch])]
impl<Session> RunCursorCommand<'_, Session> {}

impl<'a> RunCursorCommand<'a, ImplicitSession> {
    /// Run the command using the provided [`ClientSession`].
    pub fn session(
        self,
        value: impl Into<&'a mut ClientSession>,
    ) -> RunCursorCommand<'a, ExplicitSession<'a>> {
        RunCursorCommand {
            db: self.db,
            command: self.command,
            options: self.options,
            session: ExplicitSession(value.into()),
        }
    }
}

#[action_impl(sync = crate::sync::Cursor<Document>)]
impl<'a> Action for RunCursorCommand<'a, ImplicitSession> {
    type Future = RunCursorCommandFuture;

    async fn execute(self) -> Result<Cursor<Document>> {
        self.exec_generic().await
    }
}

impl<'a> RunCursorCommand<'a, ImplicitSession> {
    async fn exec_generic<C: crate::cursor::NewCursor>(self) -> Result<C> {
        let selection_criteria = self
            .options
            .as_ref()
            .and_then(|options| options.selection_criteria.clone());
        let rcc =
            run_command::RunCommand::new(self.db.clone(), self.command?, selection_criteria, None);
        let mut rc_command = run_cursor_command::RunCursorCommand::new(rcc, self.options)?;
        let client = self.db.client();
        client.execute_cursor_operation(&mut rc_command, None).await
    }

    /// Execute this command, returning a cursor that provides results in zero-copy raw batches.
    pub async fn batch(self) -> Result<crate::raw_batch_cursor::RawBatchCursor> {
        self.exec_generic().await
    }
}

#[action_impl(sync = crate::sync::SessionCursor<Document>)]
impl<'a> Action for RunCursorCommand<'a, ExplicitSession<'a>> {
    type Future = RunCursorCommandSessionFuture;

    async fn execute(mut self) -> Result<SessionCursor<Document>> {
        self.exec_generic().await
    }
}

impl<'a> RunCursorCommand<'a, ExplicitSession<'a>> {
    async fn exec_generic<C: crate::cursor::NewCursor>(self) -> Result<C> {
        let selection_criteria = self
            .options
            .as_ref()
            .and_then(|options| options.selection_criteria.clone());
        let rcc =
            run_command::RunCommand::new(self.db.clone(), self.command?, selection_criteria, None);
        let mut rc_command = run_cursor_command::RunCursorCommand::new(rcc, self.options)?;
        let client = self.db.client();
        client
            .execute_cursor_operation(&mut rc_command, Some(self.session.0))
            .await
    }

    /// Execute this command, returning a cursor that provides results in zero-copy raw batches.
    pub async fn batch(self) -> Result<crate::raw_batch_cursor::SessionRawBatchCursor> {
        self.exec_generic().await
    }
}
