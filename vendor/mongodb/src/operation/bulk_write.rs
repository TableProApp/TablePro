mod server_responses;

use std::{collections::HashMap, marker::PhantomData};

use futures_core::TryStream;
use futures_util::{FutureExt, TryStreamExt};

use crate::{
    bson::{rawdoc, Bson, RawArrayBuf, RawDocumentBuf},
    bson_compat::{cstr, CStr},
    bson_util::{self, RawDocumentCollection},
    checked::Checked,
    client::session::TransactionState,
    cmap::{conn::WriteErrorBody, Command, RawCommandResponse, StreamDescription},
    cursor::{common::CursorSpecification, NewCursor},
    error::{BulkWriteError, Error, ErrorKind, Result},
    operation::{
        run_command::RunCommand,
        Base,
        BaseOperation,
        GetMore,
        OperationImpl,
        MAX_ENCRYPTED_WRITE_SIZE,
    },
    options::{BulkWriteOptions, ClientOptions, OperationType, WriteModel},
    results::{BulkWriteResult, DeleteResult, InsertOneResult, UpdateResult},
    BoxFuture,
    Client,
    Cursor,
    Namespace,
    SessionCursor,
};

use super::{ExecutionContext, Retryability, OP_MSG_OVERHEAD_BYTES, SERVER_8_0_0_WIRE_VERSION};

use server_responses::*;

const NS_INFO: &CStr = cstr!("nsInfo");
const OPS: &CStr = cstr!("ops");

pub(crate) struct BulkWrite<'a, R>
where
    R: BulkWriteResult,
{
    client: Client,
    encrypted: bool,
    models: &'a [WriteModel],
    offset: usize,
    options: Option<&'a BulkWriteOptions>,
    /// The _ids of the inserted documents. This value is populated in `build`.
    inserted_ids: HashMap<usize, Bson>,
    /// The number of writes that were sent to the server. This value is populated in `build`.
    pub(crate) n_attempted: usize,
    _phantom: PhantomData<R>,
}

impl<'a, R> BulkWrite<'a, R>
where
    R: BulkWriteResult,
{
    pub(crate) async fn new(
        client: Client,
        models: &'a [WriteModel],
        offset: usize,
        options: Option<&'a BulkWriteOptions>,
    ) -> BulkWrite<'a, R> {
        let encrypted = client.should_auto_encrypt().await;
        Self {
            client,
            encrypted,
            models,
            offset,
            options,
            n_attempted: 0,
            inserted_ids: HashMap::new(),
            _phantom: PhantomData,
        }
    }

    async fn iterate_results_cursor(
        &self,
        mut stream: impl TryStream<Ok = SingleOperationResponse, Error = Error> + Unpin,
        result: &mut impl BulkWriteResult,
        error: &mut BulkWriteError,
    ) -> Result<()> {
        while let Some(response) = stream.try_next().await? {
            self.handle_individual_response(response, result, error)?;
        }
        Ok(())
    }

    async fn do_get_mores(
        &self,
        context: &mut ExecutionContext<'_>,
        cursor_specification: CursorSpecification,
        result: &mut impl BulkWriteResult,
        error: &mut BulkWriteError,
    ) -> Result<()> {
        let mut responses =
            crate::cursor::common::reply_batch(&cursor_specification.initial_reply)?;
        let mut more_responses = cursor_specification.info.id != 0;
        let mut namespace = cursor_specification.info.ns.clone();
        loop {
            for response_document in &responses {
                let response: SingleOperationResponse =
                    crate::bson_compat::deserialize_from_slice(response_document.as_bytes())?;
                self.handle_individual_response(response, result, error)?;
            }

            if !more_responses {
                return Ok(());
            }

            let mut get_more = GetMore::new(cursor_specification.info.clone(), None);
            let txn_number = context
                .session
                .as_mut()
                .and_then(|s| s.get_txn_number_for_operation(Retryability::None));
            let get_more_result = self
                .client
                .execute_operation_on_connection(
                    &mut get_more,
                    context.connection,
                    &mut context.session,
                    txn_number,
                    Retryability::None,
                    context.effective_criteria.clone(),
                )
                .await;

            let get_more_response = match get_more_result {
                Ok(response) => response,
                Err(error) => {
                    if !error.is_network_error() {
                        let kill_cursors = rawdoc! {
                            "killCursors": namespace.db.clone(),
                            "cursors": [cursor_specification.info.id],
                        };
                        let mut run_command = RunCommand::new(
                            self.client.database(&namespace.db),
                            kill_cursors,
                            None,
                            None,
                        );
                        let _ = self
                            .client
                            .execute_operation_on_connection(
                                &mut run_command,
                                context.connection,
                                &mut context.session,
                                txn_number,
                                Retryability::None,
                                context.effective_criteria.clone(),
                            )
                            .await;
                    }
                    return Err(error);
                }
            };

            responses = crate::cursor::common::reply_batch(&get_more_response.raw_reply)?;
            more_responses = get_more_response.id != 0;
            namespace = get_more_response.ns;
        }
    }

    fn handle_individual_response(
        &self,
        response: SingleOperationResponse,
        result: &mut impl BulkWriteResult,
        error: &mut BulkWriteError,
    ) -> Result<()> {
        let index = response.index + self.offset;
        match response.result {
            SingleOperationResult::Success {
                n,
                n_modified,
                upserted,
            } => {
                // small optimization for SERVER-113344: if the server unexpectedly returns a
                // success response for an errors-only bulk write, skip deserializing the individual
                // response, as the call to add_*_result will be a no-op
                if R::errors_only() {
                    return Ok(());
                }
                let model = self.get_model(response.index)?;
                match model.operation_type() {
                    OperationType::Insert => {
                        let inserted_id = self.get_inserted_id(index)?;
                        let insert_result = InsertOneResult { inserted_id };
                        result.add_insert_result(index, insert_result);
                    }
                    OperationType::Update => {
                        // default to 0 as a workaround for SERVER-113026
                        let modified_count = n_modified.unwrap_or(0);
                        let update_result = UpdateResult {
                            matched_count: n,
                            modified_count,
                            upserted_id: upserted.map(|upserted| upserted.id),
                        };
                        result.add_update_result(index, update_result);
                    }
                    OperationType::Delete => {
                        let delete_result = DeleteResult { deleted_count: n };
                        result.add_delete_result(index, delete_result);
                    }
                }
            }
            SingleOperationResult::Error(write_error) => {
                error.write_errors.insert(index, write_error);
            }
        }
        Ok(())
    }

    fn get_model(&self, index: usize) -> Result<&WriteModel> {
        self.models.get(index).ok_or_else(|| {
            ErrorKind::InvalidResponse {
                message: format!("invalid operation index returned from bulkWrite: {index}"),
            }
            .into()
        })
    }

    fn get_inserted_id(&self, index: usize) -> Result<Bson> {
        match self.inserted_ids.get(&index) {
            Some(inserted_id) => Ok(inserted_id.clone()),
            None => Err(ErrorKind::InvalidResponse {
                message: format!("invalid index returned for insert operation: {index}"),
            }
            .into()),
        }
    }

    fn ordered(&self) -> bool {
        self.options
            .and_then(|options| options.ordered)
            .unwrap_or(true)
    }

    fn batch_split_models<T: RawDocumentCollection>(
        &mut self,
        command_body: RawDocumentBuf,
        max_size: usize,
        max_operations: usize,
        max_bson_object_size: usize,
    ) -> Result<Command> {
        // For single-batch writes, ignore the lower maximum size defined by
        // MAX_ENCRYPTED_WRITE_SIZE.
        let first_write_max_encrypted_size = max_bson_object_size - command_body.as_bytes().len();

        let mut namespace_info: NamespaceInfo<T> = NamespaceInfo::new();
        let mut ops = T::default();
        let mut current_size = Checked::new(0);

        for (i, model) in self.models.iter().take(max_operations).enumerate() {
            let (namespace_index, namespace_size) =
                namespace_info.get_index_and_size(model.namespace())?;
            let (model_document, inserted_id) = model.get_ops_document(namespace_index)?;

            let operation_size = T::bytes_added(i, &model_document)?;
            current_size += namespace_size + operation_size;
            let current_size = current_size.get()?;

            if current_size <= max_size
                || self.encrypted && i == 0 && current_size <= first_write_max_encrypted_size
            {
                self.n_attempted += 1;
                if let Some(inserted_id) = inserted_id {
                    self.inserted_ids.insert(self.offset + i, inserted_id);
                }
                namespace_info.add_pending();
                ops.push(model_document);
            } else {
                break;
            }
        }

        if self.n_attempted == 0 {
            return Err(Error::invalid_argument(format!(
                "operation at index {} exceeds the maximum size",
                self.offset
            )));
        }

        let mut command = Command::from_operation(self, command_body);
        namespace_info
            .namespaces
            .add_to_command(NS_INFO, &mut command);
        ops.add_to_command(OPS, &mut command);
        Ok(command)
    }
}

/// A helper struct for tracking namespace information.
struct NamespaceInfo<'a, T: RawDocumentCollection> {
    namespaces: T,
    pending_namespace: Option<(&'a Namespace, RawDocumentBuf)>,
    // Cache the namespaces and their indexes to avoid traversing the namespaces array each time a
    // namespace is looked up or added.
    cache: HashMap<&'a Namespace, usize>,
}

impl<'a, T> NamespaceInfo<'a, T>
where
    T: RawDocumentCollection,
{
    fn new() -> Self {
        Self {
            namespaces: Default::default(),
            pending_namespace: None,
            cache: HashMap::new(),
        }
    }

    /// Gets the index for the given namespace in the nsInfo list and the number of bytes it would
    /// add to the nsInfo list. Stores the namespace as a pending entry.
    fn get_index_and_size(&mut self, namespace: &'a Namespace) -> Result<(usize, usize)> {
        match self.cache.get(namespace) {
            Some(index) => Ok((*index, 0)),
            None => {
                if namespace.db.contains(".") {
                    return Err(Error::invalid_argument(format!(
                        "invalid database name {}: name cannot contain period",
                        namespace.db
                    )));
                }

                let namespace_doc = rawdoc! { "ns": namespace.to_string() };
                let next_index = self.cache.len();
                let bytes_added = T::bytes_added(next_index, &namespace_doc)?;
                self.pending_namespace = Some((namespace, namespace_doc));
                Ok((next_index, bytes_added))
            }
        }
    }

    /// Adds the pending namespace to the list, if any.
    fn add_pending(&mut self) {
        if let Some((namespace, namespace_doc)) = self.pending_namespace.take() {
            self.cache.insert(namespace, self.cache.len());
            self.namespaces.push(namespace_doc);
        }
    }
}

impl<R> BaseOperation for BulkWrite<'_, R>
where
    R: BulkWriteResult,
{
    type O = R;

    const NAME: &'static CStr = cstr!("bulkWrite");

    const ZERO_COPY: bool = true;

    fn build(&mut self, description: &StreamDescription) -> Result<Command> {
        if description.max_wire_version.unwrap_or(0) < SERVER_8_0_0_WIRE_VERSION {
            return Err(ErrorKind::IncompatibleServer {
                message: "the bulk write feature is only supported on MongoDB 8.0+".to_string(),
            }
            .into());
        }

        let max_operations: usize = Checked::new(description.max_write_batch_size).try_into()?;
        let max_bson_object_size: usize =
            Checked::new(description.max_bson_object_size).try_into()?;

        let mut command_body = rawdoc! { Self::NAME: 1 };
        let mut options = match self.options {
            Some(options) => crate::bson_compat::serialize_to_raw_document_buf(options),
            None => crate::bson_compat::serialize_to_raw_document_buf(&BulkWriteOptions::default()),
        }?;
        options.append(cstr!("errorsOnly"), R::errors_only());
        bson_util::extend_raw_document_buf(&mut command_body, options)?;

        // Auto-encryption does not support document sequences.
        if self.encrypted {
            let max_size =
                (Checked::new(MAX_ENCRYPTED_WRITE_SIZE) - command_body.as_bytes().len()).get()?;
            self.batch_split_models::<RawArrayBuf>(
                command_body,
                max_size,
                max_operations,
                max_bson_object_size,
            )
        } else {
            let max_message_size: usize =
                Checked::new(description.max_message_size_bytes).try_into()?;
            let max_size = (Checked::new(max_message_size)
                - OP_MSG_OVERHEAD_BYTES
                - command_body.as_bytes().len())
            .get()?;
            self.batch_split_models::<Vec<RawDocumentBuf>>(
                command_body,
                max_size,
                max_operations,
                max_bson_object_size,
            )
        }
    }

    fn handle_response_async<'b>(
        &'b self,
        raw_response: std::borrow::Cow<'b, RawCommandResponse>,
        mut context: ExecutionContext<'b>,
    ) -> BoxFuture<'b, Result<Self::O>> {
        async move {
            let write_error: WriteErrorBody = raw_response.body()?;
            let summary_info: SummaryInfo = raw_response.body()?;
            let n_errors: usize = Checked::new(summary_info.n_errors).try_into()?;

            let mut error: BulkWriteError = Default::default();
            let mut result: R = Default::default();

            result.populate_summary_info(
                summary_info.n_inserted,
                summary_info.n_matched,
                summary_info.n_modified,
                summary_info.n_upserted,
                summary_info.n_deleted,
            );

            if let Some(write_concern_error) = write_error.write_concern_error {
                error.write_concern_errors.push(write_concern_error.0);
            }

            let specification = CursorSpecification::new(
                raw_response.into_owned(),
                context
                    .connection
                    .stream_description()?
                    .server_address
                    .clone(),
                None,
                None,
                self.options.and_then(|options| options.comment.clone()),
            )?;

            // The transaction state needs to be transitioned here to avoid adding
            // startTransaction:true to getMore commands.
            if let Some(ref mut session) = context.session {
                if session.transaction.state == TransactionState::Starting {
                    session.transaction.state = TransactionState::InProgress;
                }
            }

            let iteration_result = if self.client.is_load_balanced() {
                // Using a cursor with a pinned connection is not feasible here; see RUST-2131 for
                // more details.
                self.do_get_mores(&mut context, specification, &mut result, &mut error)
                    .await
            } else {
                match context.session {
                    Some(session) => {
                        let mut session_cursor = SessionCursor::generic_new(
                            self.client.clone(),
                            specification,
                            None,
                            None,
                        )?;
                        self.iterate_results_cursor(
                            session_cursor.stream(session),
                            &mut result,
                            &mut error,
                        )
                        .await
                    }
                    None => {
                        let cursor =
                            Cursor::generic_new(self.client.clone(), specification, None, None)?;
                        self.iterate_results_cursor(cursor, &mut result, &mut error)
                            .await
                    }
                }
            };

            if iteration_result.is_ok()
                && error.write_errors.is_empty()
                && error.write_concern_errors.is_empty()
            {
                Ok(result)
            } else {
                // The partial result should only be populated if the response indicates that at
                // least one write succeeded.
                let write_succeeded = if self.ordered() {
                    error
                        .write_errors
                        .iter()
                        .next()
                        .map(|(index, _)| *index != self.offset)
                        .unwrap_or(true)
                } else {
                    n_errors < self.n_attempted
                };
                if write_succeeded {
                    error.partial_result = Some(result.into_partial_result());
                }

                let error = Error::new(ErrorKind::BulkWrite(error), write_error.labels)
                    .with_source(iteration_result.err());
                Err(error)
            }
        }
        .boxed()
    }

    fn retryability(&self, options: &ClientOptions) -> Retryability {
        if self.models.iter().any(|model| model.multi() == Some(true)) {
            Retryability::None
        } else {
            Retryability::write(options)
        }
    }

    fn is_backpressure_retryable(&self, options: &ClientOptions) -> bool {
        options.retry_writes != Some(false)
    }

    fn write_concern(&self) -> super::Feature<&crate::options::WriteConcern> {
        self.options
            .as_ref()
            .and_then(|o| o.write_concern.as_ref())
            .into()
    }

    fn target(&self) -> super::OperationTarget {
        super::OperationTarget::admin(&self.client)
    }

    #[cfg(feature = "opentelemetry")]
    type Otel = crate::otel::Witness<Self>;
}

impl<R: BulkWriteResult> OperationImpl for BulkWrite<'_, R> {
    type Kind = Base;
}

#[cfg(feature = "opentelemetry")]
impl<R: BulkWriteResult> crate::otel::OtelInfoDefaults for BulkWrite<'_, R> {}
