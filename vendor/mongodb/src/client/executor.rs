pub(super) mod retry;

use std::{
    borrow::{BorrowMut, Cow},
    collections::HashSet,
    sync::{atomic::Ordering, Arc, LazyLock},
    time::Instant,
};

#[cfg(feature = "in-use-encryption")]
use futures_core::future::BoxFuture;
use serde::de::DeserializeOwned;

use crate::{
    bson::{Document, RawBsonRef, RawDocument, RawDocumentBuf, Timestamp},
    change_stream::{
        common::{ChangeStreamData, WatchArgs},
        event::ChangeStreamEvent,
        session::SessionChangeStream,
        ChangeStream,
    },
    cmap::{
        conn::{
            pooled::PooledConnection,
            wire::{next_request_id, Message},
            PinnedConnectionHandle,
        },
        ConnectionPool,
        RawCommandResponse,
        StreamDescription,
    },
    cursor::{
        common::{CursorInformation, CursorSpecification},
        session::SessionCursor,
        Cursor,
        NewCursor,
    },
    error::{
        Error,
        ErrorKind,
        Result,
        RETRYABLE_WRITE_ERROR,
        SYSTEM_OVERLOADED_ERROR,
        TRANSIENT_TRANSACTION_ERROR,
        UNKNOWN_TRANSACTION_COMMIT_RESULT,
    },
    event::command::{
        raw::{RawCommandEvent, RawCommandStartedEvent, RawCommandSucceededEvent},
        CommandFailedEvent,
    },
    hello::LEGACY_HELLO_COMMAND_NAME_LOWERCASE,
    operation::{
        aggregate::change_stream::ChangeStreamAggregate,
        is_commit_or_abort,
        AbortTransaction,
        CommandErrorBody,
        CommitTransaction,
        ExecutionContext,
        Feature,
        Operation,
        OperationTarget,
        Retryability,
    },
    options::{ChangeStreamOptions, SelectionCriteria},
    sdam::{HandshakePhase, ServerType, TopologyType, TransactionSupportStatus},
    selection_criteria::ReadPreference,
    tracking_arc::TrackingArc,
    ClusterTime,
};

use super::{session::TransactionState, Client, ClientSession};
use retry::Retry;

pub(crate) static REDACTED_COMMANDS: LazyLock<HashSet<&'static str>> = LazyLock::new(|| {
    let mut hash_set = HashSet::new();
    hash_set.insert("authenticate");
    hash_set.insert("saslstart");
    hash_set.insert("saslcontinue");
    hash_set.insert("getnonce");
    hash_set.insert("createuser");
    hash_set.insert("updateuser");
    hash_set.insert("copydbgetnonce");
    hash_set.insert("copydbsaslstart");
    hash_set.insert("copydb");
    hash_set
});
pub(crate) static HELLO_COMMAND_NAMES: LazyLock<HashSet<&'static str>> = LazyLock::new(|| {
    let mut hash_set = HashSet::new();
    hash_set.insert("hello");
    hash_set.insert(LEGACY_HELLO_COMMAND_NAME_LOWERCASE);
    hash_set
});

/// Details regarding the execution of an operation.
struct ExecutionDetails<T: Operation> {
    output: T::O,
    connection: PooledConnection,
}

/// The session used in the execution of an operation.
enum ExecutionSession<'a> {
    Explicit(&'a mut ClientSession),
    Implicit(Box<ClientSession>),
    None,
}

impl<'a> ExecutionSession<'a> {
    fn explicit(session: impl Into<Option<&'a mut ClientSession>>) -> Self {
        match session.into() {
            Some(session) => Self::Explicit(session),
            None => Self::None,
        }
    }

    fn implicit(session: impl Into<Option<ClientSession>>) -> Self {
        match session.into() {
            Some(session) => Self::Implicit(Box::new(session)),
            None => Self::None,
        }
    }

    fn set_implicit(&mut self, implicit_session: ClientSession) {
        *self = Self::Implicit(Box::new(implicit_session))
    }

    fn into_implicit(self) -> Option<ClientSession> {
        match self {
            Self::Implicit(implicit) => Some(*implicit),
            _ => None,
        }
    }

    fn as_ref_option(&self) -> Option<&ClientSession> {
        match self {
            Self::Explicit(explicit) => Some(*explicit),
            Self::Implicit(implicit) => Some(implicit),
            Self::None => None,
        }
    }

    fn as_ref_mut_option(&mut self) -> Option<&mut ClientSession> {
        match self {
            Self::Explicit(explicit) => Some(explicit),
            Self::Implicit(ref mut implicit) => Some(implicit),
            Self::None => None,
        }
    }

    fn is_set(&self) -> bool {
        !matches!(self, Self::None)
    }

    fn in_transaction(&self) -> bool {
        self.as_ref_option()
            .map(|s| s.in_transaction())
            .unwrap_or(false)
    }

    fn transaction_selection_criteria(&self) -> Option<&SelectionCriteria> {
        let session = self.as_ref_option()?;
        if !session.in_transaction() {
            return None;
        }
        session
            .transaction
            .options
            .as_ref()
            .and_then(|o| o.selection_criteria.as_ref())
    }
}

impl Client {
    /// Execute the given operation.
    ///
    /// Server selection will performed using the criteria specified on the operation, if any, and
    /// an implicit session will be created if the operation and write concern are compatible with
    /// sessions and an explicit session is not provided.
    pub(crate) async fn execute_operation<T: Operation>(
        &self,
        mut op: impl BorrowMut<T>,
        session: impl Into<Option<&mut ClientSession>>,
    ) -> Result<T::O> {
        let mut session = ExecutionSession::explicit(session.into());
        self.execute_operation_with_details(op.borrow_mut(), &mut session)
            .await
            .map(|details| details.output)
    }

    /// Execute the given operation, returning the cursor created by the operation.
    ///
    /// Server selection be will performed using the criteria specified on the operation, if any.
    pub(crate) async fn execute_cursor_operation<Op, C>(
        &self,
        op: &mut Op,
        session: Option<&mut ClientSession>,
    ) -> Result<C>
    where
        Op: Operation<O = CursorSpecification>,
        C: crate::cursor::NewCursor,
    {
        Box::pin(async {
            let mut session = ExecutionSession::explicit(session);
            let mut details = self
                .execute_operation_with_details(op, &mut session)
                .await?;
            let pinned = self.pin_connection_for_cursor(
                &details.output.info,
                &mut details.connection,
                session.as_ref_mut_option(),
            )?;
            C::generic_new(
                self.clone(),
                details.output,
                session.into_implicit(),
                pinned,
            )
        })
        .await
    }

    pub(crate) async fn execute_watch<T>(
        &self,
        pipeline: impl IntoIterator<Item = Document>,
        options: Option<ChangeStreamOptions>,
        target: OperationTarget,
        mut resume_data: Option<ChangeStreamData>,
    ) -> Result<ChangeStream<ChangeStreamEvent<T>>>
    where
        T: DeserializeOwned + Unpin + Send + Sync,
    {
        Box::pin(async {
            let pipeline: Vec<_> = pipeline.into_iter().collect();
            let args = WatchArgs {
                pipeline,
                target,
                options,
            };

            let implicit_session = resume_data
                .as_mut()
                .and_then(|rd| rd.implicit_session.take());
            let mut session = ExecutionSession::implicit(implicit_session);

            let mut op = ChangeStreamAggregate::new(&args, resume_data)?;

            let mut details = self
                .execute_operation_with_details(&mut op, &mut session)
                .await?;
            let (cursor_spec, cs_data) = details.output;
            let pinned =
                self.pin_connection_for_cursor(&cursor_spec.info, &mut details.connection, None)?;
            let cursor =
                Cursor::generic_new(self.clone(), cursor_spec, session.into_implicit(), pinned)?;

            Ok(ChangeStream::new(cursor, args, cs_data))
        })
        .await
    }

    pub(crate) async fn execute_watch_with_session<T>(
        &self,
        pipeline: impl IntoIterator<Item = Document>,
        options: Option<ChangeStreamOptions>,
        target: OperationTarget,
        resume_data: Option<ChangeStreamData>,
        session: &mut ClientSession,
    ) -> Result<SessionChangeStream<ChangeStreamEvent<T>>>
    where
        T: DeserializeOwned + Unpin + Send + Sync,
    {
        Box::pin(async {
            let pipeline: Vec<_> = pipeline.into_iter().collect();
            let args = WatchArgs {
                pipeline,
                target,
                options,
            };
            let mut session = ExecutionSession::explicit(session);

            let mut op = ChangeStreamAggregate::new(&args, resume_data)?;
            let mut details = self
                .execute_operation_with_details(&mut op, &mut session)
                .await?;

            let (cursor_spec, cs_data) = details.output;
            let pinned = self.pin_connection_for_cursor(
                &cursor_spec.info,
                &mut details.connection,
                session.as_ref_mut_option(),
            )?;
            let cursor = SessionCursor::generic_new(self.clone(), cursor_spec, None, pinned)?;
            Ok(SessionChangeStream::new(cursor, args, cs_data))
        })
        .await
    }

    #[cfg(not(feature = "opentelemetry"))]
    async fn execute_operation_with_details<T: Operation>(
        &self,
        op: &mut T,
        session: &mut ExecutionSession<'_>,
    ) -> Result<ExecutionDetails<T>> {
        self.execute_operation_with_details_inner(op, session).await
    }

    #[cfg(feature = "opentelemetry")]
    async fn execute_operation_with_details<T: Operation>(
        &self,
        op: &mut T,
        session: &mut ExecutionSession<'_>,
    ) -> Result<ExecutionDetails<T>> {
        use crate::otel::FutureExt as _;

        let span = self.start_operation_span(op, session.as_ref_option());
        let result = self
            .execute_operation_with_details_inner(op, session)
            .with_span(&span)
            .await;
        span.record_error(&result);

        result
    }

    async fn execute_operation_with_details_inner<T: Operation>(
        &self,
        op: &mut T,
        session: &mut ExecutionSession<'_>,
    ) -> Result<ExecutionDetails<T>> {
        // Validate inputs that can be checked before server selection and connection
        // checkout.
        if self.inner.shutdown.executed.load(Ordering::SeqCst) {
            return Err(ErrorKind::Shutdown.into());
        }

        if session.in_transaction() {
            if op.read_concern().is_set() {
                return Err(Error::invalid_argument(
                    "Cannot set read concern after starting a transaction",
                ));
            }
            if op.write_concern().is_set() {
                return Err(Error::invalid_argument(
                    "Cannot set write concern after starting a transaction",
                ));
            }
        }

        let op_target = op.target();

        let write_concern = match op.write_concern() {
            Feature::Set(write_concern) => Some(write_concern),
            Feature::Inherit if !session.in_transaction() => op_target.write_concern(),
            _ => None,
        };
        if let Some(write_concern) = write_concern {
            if !write_concern.is_acknowledged() {
                return Err(ErrorKind::InvalidArgument {
                    message: "Unacknowledged write concerns are not supported".to_string(),
                }
                .into());
            }
            write_concern.validate()?;
        }

        let selection_criteria = match op.selection_criteria() {
            Feature::Set(s) => Some(s),
            Feature::NotSupported => None,
            Feature::Inherit => session
                .transaction_selection_criteria()
                .or_else(|| op_target.selection_criteria()),
        }
        .cloned();

        // Validate the session and update its transaction status if needed.
        if let Some(session) = session.as_ref_mut_option() {
            if !TrackingArc::ptr_eq(&self.inner, &session.client().inner) {
                return Err(Error::invalid_argument(
                    "the session provided to an operation must be created from the same client as \
                     the collection/database on which the operation is being performed",
                ));
            }
            if session.in_transaction()
                && selection_criteria
                    .as_ref()
                    .and_then(|sc| sc.as_read_pref())
                    .is_some_and(|rp| rp != &ReadPreference::Primary)
            {
                return Err(ErrorKind::Transaction {
                    message: "read preference in a transaction must be primary".into(),
                }
                .into());
            }
            // If the current transaction has been committed/aborted and it is not being
            // re-committed/re-aborted, reset the transaction's state to None.
            if matches!(
                session.transaction.state,
                TransactionState::Committed { .. }
            ) && op.name() != CommitTransaction::NAME
                || session.transaction.state == TransactionState::Aborted
                    && op.name() != AbortTransaction::NAME
            {
                session.transaction.reset();
            }
        }

        let result = Box::pin(async {
            self.execute_operation_with_retry(op, selection_criteria, session)
                .await
        })
        .await;

        if let Some(session) = session.as_ref_mut_option() {
            if session.transaction.state == TransactionState::Starting {
                session.transaction.state = TransactionState::InProgress;
            }
        }

        result
    }

    async fn execute_operation_with_retry<T: Operation>(
        &self,
        op: &mut T,
        selection_criteria: Option<SelectionCriteria>,
        session: &mut ExecutionSession<'_>,
    ) -> Result<ExecutionDetails<T>> {
        let mut retry: Option<Retry> = None;
        loop {
            match retry {
                Some(retry) if retry.max_retries_reached() => {
                    return Err(retry.last_error());
                }
                Some(retry) if retry.overloaded && !self.consume_from_token_bucket().await => {
                    return Err(retry.last_error());
                }
                Some(ref retry) => {
                    op.update_for_retry(Some(retry));
                    if retry.overloaded {
                        let backoff = retry.calculate_backoff(
                            #[cfg(test)]
                            self.options().test_options.as_ref(),
                        );
                        tokio::time::sleep(backoff).await;
                    }
                }
                None => {}
            }

            let selection_criteria = session
                .as_ref_option()
                .and_then(|s| s.transaction.pinned_mongos())
                .or(selection_criteria.as_ref());

            let (server, effective_criteria) = match self
                .select_server(
                    selection_criteria,
                    retry.as_ref().map(|r| &r.deprioritized_servers),
                    (&*op).into(),
                )
                .await
            {
                Ok(selected) => selected,
                Err(mut error) => {
                    retry::return_last_error(&mut retry)?;
                    error
                        .add_labels_and_update_pin(Retryability::None, session.as_ref_mut_option());
                    return Err(error);
                }
            };

            let is_transaction_op = session.in_transaction() && !is_commit_or_abort(op);

            let mut connection =
                match get_connection(session.as_ref_option(), op, &server.pool).await {
                    Ok(connection) => connection,
                    Err(mut error) => {
                        error.add_labels_and_update_pin(
                            op.retryability(self.options()),
                            session.as_ref_mut_option(),
                        );
                        retry = Some(Retry::for_connection_establishment_failure(
                            retry,
                            error,
                            op,
                            self,
                            server.address.clone(),
                            is_transaction_op,
                        )?);
                        continue;
                    }
                };

            if !connection.supports_sessions() && session.is_set() {
                return Err(ErrorKind::SessionsNotSupported.into());
            }

            if connection.supports_sessions() && !session.is_set() && op.supports_sessions() {
                session.set_implicit(ClientSession::new(self.clone(), None, true).await);
            }

            let retryability = self.get_retryability(
                op,
                &session.as_ref_mut_option(),
                connection.stream_description()?,
            );
            let overloaded = retry.as_ref().map(|r| r.overloaded).unwrap_or(false);
            if overloaded && !op.is_backpressure_retryable(self.options())
                || !overloaded && retryability == Retryability::None
            {
                retry::return_last_error(&mut retry)?;
            }

            let txn_number = retry::txn_number(&retry).or_else(|| {
                session
                    .as_ref_mut_option()
                    .and_then(|s| s.get_txn_number_for_operation(retryability))
            });

            let execution_result = self
                .execute_operation_on_connection(
                    op,
                    &mut connection,
                    &mut session.as_ref_mut_option(),
                    txn_number,
                    retryability,
                    effective_criteria,
                )
                .await;
            match execution_result {
                Ok(output) => {
                    self.deposit_success_in_token_bucket(retry.is_some()).await;
                    return Ok(ExecutionDetails { output, connection });
                }
                Err(mut error) => {
                    if retry.is_some() && !error.contains_label(SYSTEM_OVERLOADED_ERROR) {
                        self.deposit_retry_error_in_token_bucket().await;
                    }

                    error.wire_version = connection.stream_description()?.max_wire_version;

                    // Retryable writes are only supported by storage engines with document-level
                    // locking, so users need to disable retryable writes if using mmapv1.
                    if let ErrorKind::Command(ref mut command_error) = *error.kind {
                        if command_error.code == 20
                            && command_error.message.starts_with("Transaction numbers")
                        {
                            command_error.message = "This MongoDB deployment does not support \
                                                     retryable writes. Please add \
                                                     retryWrites=false to your connection string."
                                .to_string();
                        }
                    }

                    self.inner
                        .topology
                        .updater()
                        .handle_application_error(
                            server.address.clone(),
                            error.clone(),
                            HandshakePhase::after_completion(&connection),
                        )
                        .await;

                    drop(connection);
                    let server_address = server.address.clone();
                    drop(server);

                    retry = Some(Retry::for_execution_failure(
                        retry,
                        error,
                        op,
                        self,
                        server_address,
                        is_transaction_op,
                        txn_number,
                    )?);
                    continue;
                }
            }
        }
    }

    /// Executes an operation on a given connection, optionally using a provided session.
    pub(crate) async fn execute_operation_on_connection<Op: Operation>(
        &self,
        op: &mut Op,
        connection: &mut PooledConnection,
        session: &mut Option<&mut ClientSession>,
        txn_number: Option<i64>,
        retryability: Retryability,
        effective_criteria: SelectionCriteria,
    ) -> Result<Op::O> {
        loop {
            let cmd = self.build_command(
                op,
                connection,
                session,
                txn_number,
                effective_criteria.clone(),
            )?;

            let connection_info = connection.info();
            let service_id = connection.service_id();
            let request_id = next_request_id();
            let should_redact = cmd.should_redact();
            let cmd_name = cmd.name.clone();
            let target_db = cmd.target_db.clone();
            #[cfg(feature = "opentelemetry")]
            let cmd_attrs = crate::otel::CommandAttributes::new(&cmd);

            let mut message = Message::try_from(cmd)?;
            message.request_id = Some(request_id);

            #[cfg(feature = "opentelemetry")]
            let span = self.start_command_span(
                op,
                &connection_info,
                connection.stream_description()?,
                &message,
                cmd_attrs,
            );

            #[cfg(feature = "in-use-encryption")]
            {
                let guard = self.inner.csfle.read().await;
                if let Some(ref csfle) = *guard {
                    if csfle.opts().bypass_auto_encryption != Some(true) {
                        let encrypted_payload = self
                            .auto_encrypt(csfle, &message.document_payload, &target_db)
                            .await?;
                        message.document_payload = encrypted_payload;
                    }
                }
            }

            self.emit_command_event(|| {
                let command_body = if should_redact {
                    RawDocumentBuf::new()
                } else {
                    message.get_raw_command_document()
                };
                RawCommandEvent::Started(RawCommandStartedEvent {
                    command: command_body,
                    db: target_db.clone(),
                    command_name: cmd_name.clone(),
                    request_id,
                    connection: connection_info.clone(),
                    service_id,
                })
            })
            .await;

            let start_time = Instant::now();
            let command_result = match connection.send_message(message).await {
                Ok(response) => {
                    match self
                        .parse_response(op, session, connection.is_sharded()?, &response)
                        .await
                    {
                        Ok(()) => Ok(response),
                        Err(error) => Err(error.with_server_response(&response)),
                    }
                }
                Err(err) => Err(err),
            };

            let duration = start_time.elapsed();

            let result = match command_result {
                Err(mut err) => {
                    self.emit_command_event(|| {
                        let mut err = err.clone();
                        if should_redact {
                            err.redact();
                        }

                        RawCommandEvent::Failed(CommandFailedEvent {
                            duration,
                            command_name: cmd_name.clone(),
                            failure: err,
                            request_id,
                            connection: connection_info.clone(),
                            service_id,
                        })
                    })
                    .await;

                    if let Some(ref mut session) = session {
                        if err.is_network_error() {
                            session.mark_dirty();
                        }
                    }

                    err.add_labels_and_update_pin(retryability, session.as_deref_mut());
                    op.handle_error(err)
                }
                Ok(response) => {
                    self.emit_command_event(|| {
                        let reply = if should_redact {
                            RawDocumentBuf::new()
                        } else {
                            response.raw_body().to_owned()
                        };

                        RawCommandEvent::Succeeded(RawCommandSucceededEvent {
                            duration,
                            reply,
                            command_name: cmd_name.clone(),
                            request_id,
                            connection: connection_info.clone(),
                            service_id,
                        })
                    })
                    .await;

                    #[cfg(feature = "in-use-encryption")]
                    let response = {
                        let guard = self.inner.csfle.read().await;
                        if let Some(ref csfle) = *guard {
                            let new_body = self.auto_decrypt(csfle, response.raw_body()).await?;
                            RawCommandResponse::new_raw(response.source, new_body)
                        } else {
                            response
                        }
                    };

                    let context = ExecutionContext {
                        connection,
                        session: session.as_deref_mut(),
                        effective_criteria: effective_criteria.clone(),
                    };

                    let handle_result = match Op::ZERO_COPY {
                        true => op.handle_response(Cow::Owned(response), context).await,
                        false => op
                            .handle_response(Cow::Borrowed(&response), context)
                            .await
                            .map_err(|e| e.with_server_response(&response)),
                    };
                    match handle_result {
                        Ok(op_out) => Ok(op_out),
                        Err(mut err) => {
                            err.add_labels_and_update_pin(retryability, session.as_deref_mut());
                            Err(err)
                        }
                    }
                }
            };
            #[cfg(feature = "opentelemetry")]
            span.record_command_result::<Op>(&result);

            if result
                .as_ref()
                .err()
                .is_some_and(|e| e.is_reauthentication_required())
            {
                // This retry is done outside of the normal retry loop because all operations,
                // regardless of retryability, should be retried after reauthentication.
                self.reauthenticate_connection(connection).await?;
                continue;
            } else {
                return result;
            }
        }
    }

    fn build_command<T: Operation>(
        &self,
        op: &mut T,
        connection: &mut PooledConnection,
        session: &mut Option<&mut ClientSession>,
        txn_number: Option<i64>,
        effective_criteria: SelectionCriteria,
    ) -> Result<crate::cmap::Command> {
        let stream_description = connection.stream_description()?;
        let is_sharded = stream_description.initial_server_type == ServerType::Mongos;
        let mut cmd = op.build(stream_description)?;
        // Clear inherited read/writeconcern when in a transaction
        if session.as_ref().is_some_and(|s| s.in_transaction()) {
            cmd.clear_concerns();
        }
        self.inner.topology.watcher().update_command_with_read_pref(
            connection.address(),
            &mut cmd,
            &effective_criteria,
        );

        match session {
            Some(ref mut session) if op.supports_sessions() => {
                cmd.set_session(session);
                if let Some(txn_number) = txn_number {
                    cmd.set_txn_number(txn_number);
                }
                if session
                    .options()
                    .and_then(|opts| opts.snapshot)
                    .unwrap_or(false)
                {
                    if connection
                        .stream_description()?
                        .max_wire_version
                        .unwrap_or(0)
                        < 13
                    {
                        let labels: Option<Vec<_>> = None;
                        return Err(Error::new(
                            ErrorKind::IncompatibleServer {
                                message: "Snapshot reads require MongoDB 5.0 or later".into(),
                            },
                            labels,
                        ));
                    }
                    cmd.set_snapshot_read_concern(session);
                }
                // If this is a causally consistent session, set `readConcern.afterClusterTime`.
                // Causal consistency defaults to true, unless snapshot is true.
                else if session.causal_consistency()
                    && matches!(
                        session.transaction.state,
                        TransactionState::None | TransactionState::Starting
                    )
                    && (op.read_concern().supported() || op.is_after_cluster_time_write())
                {
                    cmd.set_after_cluster_time(session);
                }

                match session.transaction.state {
                    TransactionState::Starting => {
                        cmd.set_start_transaction();
                        cmd.set_autocommit();
                        if session.causal_consistency() {
                            cmd.set_after_cluster_time(session);
                        }

                        if let Some(ref options) = session.transaction.options {
                            if let Some(ref read_concern) = options.read_concern {
                                cmd.set_read_concern_level(read_concern.level.clone());
                            }
                        }
                        if self.is_load_balanced() {
                            // The connection is already pinned if a retry is being performed.
                            if !connection.is_pinned() {
                                session.pin_connection(connection.pin()?);
                            }
                        } else if is_sharded {
                            session.pin_mongos(connection.address().clone());
                        }
                    }
                    TransactionState::InProgress => cmd.set_autocommit(),
                    TransactionState::Committed { .. } | TransactionState::Aborted => {
                        cmd.set_autocommit();
                        // Append the recovery token to the command if we are committing or aborting
                        // on a sharded transaction.
                        if is_sharded {
                            if let Some(ref recovery_token) = session.transaction.recovery_token {
                                cmd.set_recovery_token(recovery_token);
                            }
                        }
                    }
                    _ => {}
                }
                session.update_last_use();
            }
            Some(ref session) if !op.supports_sessions() && !session.is_implicit() => {
                return Err(ErrorKind::InvalidArgument {
                    message: format!("{} does not support sessions", cmd.name),
                }
                .into());
            }
            _ => {}
        }

        let session_cluster_time = session.as_ref().and_then(|session| session.cluster_time());
        let client_cluster_time = self.inner.topology.watcher().cluster_time();
        let max_cluster_time = std::cmp::max(session_cluster_time, client_cluster_time.as_ref());
        if let Some(cluster_time) = max_cluster_time {
            cmd.set_cluster_time(cluster_time);
        }

        if let Some(ref server_api) = self.inner.options.server_api {
            cmd.set_server_api(server_api);
        }

        Ok(cmd)
    }

    #[cfg(feature = "in-use-encryption")]
    fn auto_encrypt<'a>(
        &'a self,
        csfle: &'a super::csfle::ClientState,
        command: &'a RawDocument,
        target_db: &'a str,
    ) -> BoxFuture<'a, Result<RawDocumentBuf>> {
        Box::pin(async move {
            let ctx = csfle
                .crypt()
                .ctx_builder()
                .build_encrypt(target_db, command)?;
            csfle.exec().run_ctx(ctx, Some(target_db)).await
        })
    }

    #[cfg(feature = "in-use-encryption")]
    fn auto_decrypt<'a>(
        &'a self,
        csfle: &'a super::csfle::ClientState,
        response: &'a RawDocument,
    ) -> BoxFuture<'a, Result<RawDocumentBuf>> {
        Box::pin(async move {
            let ctx = csfle.crypt().ctx_builder().build_decrypt(response)?;
            csfle.exec().run_ctx(ctx, None).await
        })
    }

    async fn reauthenticate_connection(&self, connection: &mut PooledConnection) -> Result<()> {
        let credential =
            self.inner
                .options
                .credential
                .as_ref()
                .ok_or_else(|| ErrorKind::Authentication {
                    message: "the connection requires reauthentication but no credential was set"
                        .to_string(),
                })?;
        let server_api = self.inner.options.server_api.as_ref();

        credential
            .mechanism
            .as_ref()
            .ok_or(ErrorKind::Authentication {
                message: "the connection requires reauthentication but no authentication \
                          mechanism was set"
                    .to_string(),
            })?
            .reauthenticate_stream(connection, credential, server_api)
            .await
    }

    async fn parse_response<T: Operation>(
        &self,
        op: &T,
        session: &mut Option<&mut ClientSession>,
        is_sharded: bool,
        response: &RawCommandResponse,
    ) -> Result<()> {
        let raw_doc = RawDocument::from_bytes(response.as_bytes())?;

        let ok = match raw_doc.get("ok")? {
            Some(b) => {
                crate::bson_util::get_int_raw(b).ok_or_else(|| ErrorKind::InvalidResponse {
                    message: format!("expected ok value to be a number, instead got {b:?}"),
                })?
            }
            None => {
                return Err(ErrorKind::InvalidResponse {
                    message: "missing 'ok' value in response".to_string(),
                }
                .into());
            }
        };

        let cluster_time: Option<ClusterTime> = raw_doc
            .get("$clusterTime")?
            .and_then(RawBsonRef::as_document)
            .map(|d| crate::bson_compat::deserialize_from_slice(d.as_bytes()))
            .transpose()?;

        let at_cluster_time = op.extract_at_cluster_time(raw_doc)?;

        self.update_cluster_time(cluster_time, at_cluster_time, session)
            .await;

        if let (Some(session), Some(ts)) = (
            session.as_mut(),
            raw_doc
                .get("operationTime")?
                .and_then(RawBsonRef::as_timestamp),
        ) {
            session.advance_operation_time(ts);
        }

        if ok == 1 {
            if let Some(ref mut session) = session {
                if is_sharded && session.in_transaction() {
                    let recovery_token = raw_doc
                        .get("recoveryToken")?
                        .and_then(RawBsonRef::as_document)
                        .map(|d| crate::bson_compat::deserialize_from_slice(d.as_bytes()))
                        .transpose()?;
                    session.transaction.recovery_token = recovery_token;
                }
            }

            Ok(())
        } else {
            Err(response
                .body::<CommandErrorBody>()
                .map(|error_response| error_response.into())
                .unwrap_or_else(|e| {
                    Error::from(ErrorKind::InvalidResponse {
                        message: format!("error deserializing command error: {e}"),
                    })
                }))
        }
    }

    pub(crate) fn is_load_balanced(&self) -> bool {
        self.inner.options.load_balanced.unwrap_or(false)
    }

    pub(crate) fn pin_connection_for_cursor(
        &self,
        info: &CursorInformation,
        conn: &mut PooledConnection,
        session: Option<&mut ClientSession>,
    ) -> Result<Option<PinnedConnectionHandle>> {
        if let Some(handle) = session.and_then(|s| s.transaction.pinned_connection()) {
            // Cursor operations on a transaction share the same pinned connection.
            Ok(Some(handle.replicate()))
        } else if self.is_load_balanced() && info.id != 0 {
            // Cursor operations on load balanced topologies always pin connections.
            Ok(Some(conn.pin()?))
        } else {
            Ok(None)
        }
    }

    async fn select_data_bearing_server(&self, operation_name: &str) -> Result<()> {
        let topology_type = self.inner.topology.watcher().topology_type();
        let criteria = SelectionCriteria::Predicate(Arc::new(move |server_info| {
            let server_type = server_info.server_type();
            (matches!(topology_type, TopologyType::Single) && server_type.is_available())
                || server_type.is_data_bearing()
        }));
        let _ = self
            .select_server(
                Some(&criteria),
                None,
                crate::client::OpSelectionInfo::new(operation_name),
            )
            .await?;
        Ok(())
    }

    /// Gets whether the topology supports transactions. If it has yet to be determined if the
    /// topology supports transactions, this method will perform a server selection that will force
    /// that determination to be made.
    pub(crate) async fn transaction_support_status(&self) -> Result<TransactionSupportStatus> {
        let initial_status = self.inner.topology.watcher().transaction_support_status();

        // Need to guarantee that we're connected to at least one server that can determine if
        // sessions are supported or not.
        match initial_status {
            TransactionSupportStatus::Undetermined => {
                self.select_data_bearing_server("Check transactions support status")
                    .await?;
                Ok(self.inner.topology.watcher().transaction_support_status())
            }
            _ => Ok(initial_status),
        }
    }

    /// Returns the retryability level for the execution of this operation with the given session
    /// and connection stream description.
    fn get_retryability<T: Operation>(
        &self,
        op: &T,
        session: &Option<&mut ClientSession>,
        stream_description: &StreamDescription,
    ) -> Retryability {
        if session
            .as_ref()
            .is_some_and(|session| session.in_transaction())
        {
            return Retryability::None;
        }

        match op.retryability(self.options()) {
            Retryability::Write if stream_description.supports_retryable_writes() => {
                Retryability::Write
            }
            // All servers compatible with the driver support retryable reads.
            Retryability::Read => Retryability::Read,
            _ => Retryability::None,
        }
    }

    async fn update_cluster_time(
        &self,
        cluster_time: Option<ClusterTime>,
        at_cluster_time: Option<Timestamp>,
        session: &mut Option<&mut ClientSession>,
    ) {
        if let Some(ref cluster_time) = cluster_time {
            self.inner
                .topology
                .updater()
                .advance_cluster_time(cluster_time.clone())
                .await;
            if let Some(ref mut session) = session {
                session.advance_cluster_time(cluster_time)
            }
        }

        if let Some(timestamp) = at_cluster_time {
            if let Some(ref mut session) = session {
                session.snapshot_time = Some(timestamp);
            }
        }
    }
}

async fn get_connection<T: Operation>(
    session: Option<&ClientSession>,
    op: &T,
    pool: &ConnectionPool,
) -> Result<PooledConnection> {
    let session_pinned = session
        .as_ref()
        .and_then(|s| s.transaction.pinned_connection());
    match (session_pinned, op.pinned_connection()) {
        (Some(c), None) | (None, Some(c)) => c.take_connection().await,
        (Some(session_handle), Some(op_handle)) => {
            // An operation executing in a transaction should be sharing the same pinned connection.
            debug_assert_eq!(session_handle.id(), op_handle.id());
            session_handle.take_connection().await
        }
        (None, None) => pool.check_out().await,
    }
}

impl Error {
    /// Adds the necessary labels to this error, and unpins the session if needed.
    ///
    /// A "TransientTransactionError" label is added if a transaction is in progress and the error
    /// is a network or server selection error.
    ///
    /// A "RetryableWriteError" label is added to network errors if the `retry_writes` client option
    /// was not set to false, the operation during which the error occured is write-retryable,
    /// and a "TransientTransactionError" label has not already been added.
    ///
    /// If a "TransientTransactionError" or "UnknownTransactionCommitResult" label is added, the
    /// session should be unpinned.
    fn add_labels_and_update_pin(
        &mut self,
        retryability: Retryability,
        session: Option<&mut ClientSession>,
    ) {
        let transaction_state = session.as_ref().map_or(&TransactionState::None, |session| {
            &session.transaction.state
        });

        match transaction_state {
            TransactionState::Starting | TransactionState::InProgress => {
                if self.is_network_error() || self.is_server_selection_error() {
                    self.add_label(TRANSIENT_TRANSACTION_ERROR);
                }
            }
            TransactionState::Committed { .. } => {
                if self.should_add_retryable_write_label() {
                    self.add_label(RETRYABLE_WRITE_ERROR);
                }
                if self.should_add_unknown_transaction_commit_result_label() {
                    self.add_label(UNKNOWN_TRANSACTION_COMMIT_RESULT);
                }
            }
            TransactionState::Aborted => {
                if self.should_add_retryable_write_label() {
                    self.add_label(RETRYABLE_WRITE_ERROR);
                }
            }
            TransactionState::None => {
                if retryability == Retryability::Write && self.should_add_retryable_write_label() {
                    self.add_label(RETRYABLE_WRITE_ERROR);
                }
            }
        }

        if let Some(session) = session {
            if self.contains_label(TRANSIENT_TRANSACTION_ERROR)
                || self.contains_label(UNKNOWN_TRANSACTION_COMMIT_RESULT)
            {
                session.unpin();
            }
        }
    }
}
