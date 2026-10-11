mod abort_transaction;
pub(crate) mod aggregate;
pub(crate) mod bulk_write;
mod commit_transaction;
pub(crate) mod count;
pub(crate) mod count_documents;
pub(crate) mod create;
mod create_indexes;
mod delete;
mod distinct;
pub(crate) mod drop_collection;
pub(crate) mod drop_database;
mod drop_indexes;
mod find;
pub(crate) mod find_and_modify;
mod get_more;
mod insert;
pub(crate) mod list_collections;
pub(crate) mod list_databases;
mod list_indexes;
#[cfg(feature = "in-use-encryption")]
pub(crate) mod raw_output;
pub(crate) mod run_command;
pub(crate) mod run_cursor_command;
mod search_index;
mod update;

use std::{borrow::Cow, fmt::Debug};

use bson::{RawBsonRef, RawDocument, RawDocumentBuf, Timestamp};
use futures_util::FutureExt;
use serde::{de::DeserializeOwned, Deserialize, Serialize};

use crate::{
    bson::{self, Bson, Document},
    bson_compat::CStr,
    bson_util::{self, extend_raw_document_buf},
    client::{ClusterTime, Retry, HELLO_COMMAND_NAMES, REDACTED_COMMANDS},
    cmap::{
        conn::{pooled::PooledConnection, PinnedConnectionHandle},
        Command,
        RawCommandResponse,
        StreamDescription,
    },
    error::{CommandError, Error, ErrorKind, Result},
    options::{ClientOptions, ReadConcern, WriteConcern},
    selection_criteria::SelectionCriteria,
    BoxFuture,
    ClientSession,
    Collection,
    Database,
    Namespace,
};

pub(crate) use abort_transaction::AbortTransaction;
pub(crate) use commit_transaction::CommitTransaction;
pub(crate) use create_indexes::CreateIndexes;
pub(crate) use delete::Delete;
pub(crate) use distinct::Distinct;
pub(crate) use drop_indexes::DropIndexes;
pub(crate) use find::Find;
pub(crate) use find_and_modify::FindAndModify;
pub(crate) use get_more::GetMore;
pub(crate) use insert::Insert;
pub(crate) use list_indexes::ListIndexes;
pub(crate) use search_index::{CreateSearchIndexes, DropSearchIndex, UpdateSearchIndex};
pub(crate) use update::{Update, UpdateOrReplace};

const SERVER_5_0_0_WIRE_VERSION: i32 = 13;
const SERVER_8_0_0_WIRE_VERSION: i32 = 25;
// The maximum number of bytes that may be included in a write payload when auto-encryption is
// enabled.
const MAX_ENCRYPTED_WRITE_SIZE: usize = 2_097_152;
// The amount of message overhead (OP_MSG bytes and command-agnostic fields) to account for when
// building a multi-write operation using document sequences.
const OP_MSG_OVERHEAD_BYTES: usize = 1_000;

/// Context about the execution of the operation.
pub(crate) struct ExecutionContext<'a> {
    pub(crate) connection: &'a mut PooledConnection,
    pub(crate) session: Option<&'a mut ClientSession>,
    pub(crate) effective_criteria: SelectionCriteria,
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub(crate) enum Retryability {
    Write,
    Read,
    None,
}

impl Retryability {
    pub(crate) fn write(options: &ClientOptions) -> Self {
        if options.retry_writes != Some(false) {
            Self::Write
        } else {
            Self::None
        }
    }

    pub(crate) fn read(options: &ClientOptions) -> Self {
        if options.retry_reads != Some(false) {
            Self::Read
        } else {
            Self::None
        }
    }

    /// Whether this level of retryability can retry the given error.
    pub(crate) fn can_retry_error(&self, error: &Error) -> bool {
        match self {
            Self::Write => error.is_write_retryable(),
            Self::Read => error.is_read_retryable(),
            Self::None => false,
        }
    }
}

/// A trait modeling the behavior of a server side operation.  This should not be implemented
/// directly; use either the `BaseOperation` or `WrappedOperation` traits.
pub(crate) trait Operation {
    /// The output type of this operation.
    type O;

    /// The name of the server side command associated with this operation.
    const NAME: &'static CStr;

    /// Whether this operation prefers to take ownership of the server response body for
    /// zero-copy handling.
    const ZERO_COPY: bool;

    /// Returns the command that should be sent to the server as part of this operation.
    /// The operation may store some additional state that is required for handling the response.
    fn build(&mut self, description: &StreamDescription) -> Result<Command>;

    /// Parse the response for the atClusterTime field.
    /// Depending on the operation, this may be found in different locations.
    fn extract_at_cluster_time(&self, _response: &RawDocument) -> Result<Option<Timestamp>>;

    /// Interprets the server response to the command.
    fn handle_response<'a>(
        &'a self,
        response: Cow<'a, RawCommandResponse>,
        context: ExecutionContext<'a>,
    ) -> BoxFuture<'a, Result<Self::O>>;

    /// Interpret an error encountered while sending the built command to the server, potentially
    /// recovering.
    fn handle_error(&self, error: Error) -> Result<Self::O>;

    /// Criteria to use for selecting the server that this operation will be executed on.
    fn selection_criteria(&self) -> Feature<&SelectionCriteria>;

    /// The read concern to use for this operation, if any.
    fn read_concern(&self) -> Feature<&ReadConcern>;

    /// The write concern to use for this operation, if any.
    fn write_concern(&self) -> Feature<&WriteConcern>;

    /// Whether this operation supports sessions or not.
    fn supports_sessions(&self) -> bool;

    /// The level of retryability the operation supports.
    fn retryability(&self, options: &ClientOptions) -> Retryability;

    fn is_backpressure_retryable(&self, options: &ClientOptions) -> bool;

    /// Updates this operation as needed for a retry.
    fn update_for_retry(&mut self, retry: Option<&Retry>);

    /// Returns a function handle to potentially override selection criteria based on server
    /// topology.
    fn override_criteria(&self) -> OverrideCriteriaFn;

    fn pinned_connection(&self) -> Option<&PinnedConnectionHandle>;

    /// The name of the server side command associated with this operation.
    fn name(&self) -> &CStr;

    /// The noun to this operation's verb.
    fn target(&self) -> OperationTarget;

    /// Whether this is a write operation that needs `afterClusterTime` set.
    fn is_after_cluster_time_write(&self) -> bool;

    #[cfg(feature = "opentelemetry")]
    type Otel: crate::otel::OtelWitness<Op = Self>;

    #[cfg(feature = "opentelemetry")]
    fn otel(&self) -> &impl crate::otel::OtelInfo {
        <Self::Otel as crate::otel::OtelWitness>::otel(self)
    }
}

#[derive(Debug, Copy, Clone)]
pub(crate) enum Feature<T> {
    Set(T),
    Inherit,
    NotSupported,
}

impl<T> From<Option<T>> for Feature<T> {
    fn from(value: Option<T>) -> Self {
        match value {
            Some(c) => Self::Set(c),
            None => Self::Inherit,
        }
    }
}

impl<T> Feature<T> {
    pub(crate) fn is_set(&self) -> bool {
        matches!(self, Self::Set(_))
    }

    pub(crate) fn supported(&self) -> bool {
        match self {
            Self::NotSupported => false,
            _ => true,
        }
    }
}

pub(crate) type OverrideCriteriaFn =
    fn(&SelectionCriteria, &crate::sdam::TopologyDescription) -> Option<SelectionCriteria>;

#[derive(Debug, Clone)]
pub(crate) enum OperationTarget {
    Database(Database),
    Collection(crate::Collection<Document>),
    Namespace(Namespace),
}

impl OperationTarget {
    pub(crate) fn admin(client: &crate::Client) -> Self {
        Self::Database(client.database("admin"))
    }

    pub(crate) fn db_name(&self) -> &str {
        match self {
            Self::Database(db) => db.name(),
            Self::Collection(coll) => coll.db().name(),
            Self::Namespace(ns) => &ns.db,
        }
    }

    pub(crate) fn selection_criteria(&self) -> Option<&SelectionCriteria> {
        match self {
            Self::Database(db) => db.selection_criteria(),
            Self::Collection(coll) => coll.selection_criteria(),
            Self::Namespace(_) => None,
        }
    }

    pub(crate) fn read_concern(&self) -> Option<&ReadConcern> {
        match self {
            Self::Database(db) => db.read_concern(),
            Self::Collection(coll) => coll.read_concern(),
            Self::Namespace(_) => None,
        }
    }

    pub(crate) fn write_concern(&self) -> Option<&WriteConcern> {
        match self {
            Self::Database(db) => db.write_concern(),
            Self::Collection(coll) => coll.write_concern(),
            Self::Namespace(_) => None,
        }
    }
}

impl From<&Database> for OperationTarget {
    fn from(value: &Database) -> Self {
        Self::Database(value.clone())
    }
}

impl<T: Send + Sync> From<&Collection<T>> for OperationTarget {
    fn from(value: &Collection<T>) -> Self {
        Self::Collection(value.clone_with_type())
    }
}

// A mirror of the `Operation` trait, with default behavior where appropriate.  Should be
// implemented by operation types that do not delegate to other operations.
pub(crate) trait BaseOperation: Send + Sync {
    /// The output type of this operation.
    type O;

    /// The name of the server side command associated with this operation.
    const NAME: &'static CStr;

    /// Whether this operation prefers to take ownership of the server response body for
    /// zero-copy handling.
    const ZERO_COPY: bool = false;

    /// Returns the command that should be sent to the server as part of this operation.
    /// The operation may store some additional state that is required for handling the response.
    fn build(&mut self, description: &StreamDescription) -> Result<Command>;

    /// Parse the response for the atClusterTime field.
    /// Depending on the operation, this may be found in different locations.
    fn extract_at_cluster_time(&self, _response: &RawDocument) -> Result<Option<Timestamp>> {
        Ok(None)
    }

    /// Interprets the server response to the command.
    fn handle_response<'a>(
        &'a self,
        _response: &'a RawCommandResponse,
        _context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        Err(ErrorKind::Internal {
            message: format!("response handling not implemented for {}", Self::NAME),
        }
        .into())
    }

    /// Interprets the server response taking ownership of the body to enable zero-copy handling.
    ///
    /// Default behavior delegates to the borrowed [`handle_response`]; operations that set
    /// [`ZERO_COPY`] to `true` should override this to consume the response.
    fn handle_response_cow<'a>(
        &'a self,
        response: Cow<'a, RawCommandResponse>,
        context: ExecutionContext<'a>,
    ) -> Result<Self::O> {
        self.handle_response(&response, context)
    }

    /// Interprets the server response to the command. This method should only be implemented when
    /// async code is required to handle the response.
    fn handle_response_async<'a>(
        &'a self,
        response: Cow<'a, RawCommandResponse>,
        context: ExecutionContext<'a>,
    ) -> BoxFuture<'a, Result<Self::O>> {
        async move { self.handle_response_cow(response, context) }.boxed()
    }

    /// Interpret an error encountered while sending the built command to the server, potentially
    /// recovering.
    fn handle_error(&self, error: Error) -> Result<Self::O> {
        Err(error)
    }

    /// Criteria to use for selecting the server that this operation will be executed on.
    fn selection_criteria(&self) -> Feature<&SelectionCriteria> {
        Feature::NotSupported
    }

    /// The read concern to use for this operation, if any.
    fn read_concern(&self) -> Feature<&ReadConcern> {
        Feature::NotSupported
    }

    /// The write concern to use for this operation, if any.
    fn write_concern(&self) -> Feature<&WriteConcern> {
        Feature::NotSupported
    }

    /// Whether this operation supports sessions or not.
    fn supports_sessions(&self) -> bool {
        true
    }

    /// The level of retryability the operation supports.
    fn retryability(&self, _options: &ClientOptions) -> Retryability {
        Retryability::None
    }

    /// Whether this operation is retryable when retrying system overloaded errors. For read/write
    /// operations, the operation is retryable if retryReads/retryWrites was not set to false.
    /// Operations with special behavior defined in the backpressure specification should
    /// override this method.
    fn is_backpressure_retryable(&self, options: &ClientOptions) -> bool {
        self.retryability(options) != Retryability::None
    }

    /// Updates this operation as needed for a retry.
    fn update_for_retry(&mut self, _retry: Option<&Retry>) {}

    /// Returns a function handle to potentially override selection criteria based on server
    /// topology.
    fn override_criteria(&self) -> OverrideCriteriaFn {
        |_, _| None
    }

    fn pinned_connection(&self) -> Option<&PinnedConnectionHandle> {
        None
    }

    /// The name of the server side command associated with this operation.
    fn name(&self) -> &CStr {
        Self::NAME
    }

    fn target(&self) -> OperationTarget;

    fn is_after_cluster_time_write(&self) -> bool {
        self.write_concern().supported()
    }

    #[cfg(feature = "opentelemetry")]
    type Otel: crate::otel::OtelWitness<Op = Self>;
}

/// We'd like both `BaseOperation` and `WrappedOperation` to automatically implement `Operation`.
/// However, Rust only allows one blanket impl per trait, so we can't do both
/// `impl<T: BaseOperation> Operation for T` and `impl<T: WrappedOperation> Operation for T`.
///
/// To work around this, `OperationDispatch` provides an indirection: the one blanket impl for
/// `Operation` is a generic `OperationDispatch<K>`, and each specialized version of the trait
/// has a blanket impl for `OperationDispatch` with a specific type parameter.
///
/// `OperationImpl` is a helper trait for this setup that binds specific impls to the appropriate
/// dispatch type.
pub(crate) trait OperationDispatch<Kind> {
    type O;
    const NAME: &'static CStr;
    const ZERO_COPY: bool;
    fn build(&mut self, description: &StreamDescription) -> Result<Command>;
    fn extract_at_cluster_time(&self, response: &RawDocument) -> Result<Option<Timestamp>>;
    fn handle_response<'a>(
        &'a self,
        response: Cow<'a, RawCommandResponse>,
        context: ExecutionContext<'a>,
    ) -> BoxFuture<'a, Result<Self::O>>;
    fn handle_error(&self, error: Error) -> Result<Self::O>;
    fn selection_criteria(&self) -> Feature<&SelectionCriteria>;
    fn read_concern(&self) -> Feature<&ReadConcern>;
    fn write_concern(&self) -> Feature<&WriteConcern>;
    fn supports_sessions(&self) -> bool;
    fn retryability(&self, options: &ClientOptions) -> Retryability;
    fn is_backpressure_retryable(&self, options: &ClientOptions) -> bool;
    fn update_for_retry(&mut self, retry: Option<&Retry>);
    fn override_criteria(&self) -> OverrideCriteriaFn;
    fn pinned_connection(&self) -> Option<&PinnedConnectionHandle>;
    fn name(&self) -> &CStr;
    fn target(&self) -> OperationTarget;
    fn is_after_cluster_time_write(&self) -> bool;
    #[cfg(feature = "opentelemetry")]
    type Otel: crate::otel::OtelWitness<Op = Self>;
}

macro_rules! operation_dispatch {
    ($trait:path, $tag:ty, $handle_response:ident) => {
        impl<T: $trait> OperationDispatch<$tag> for T {
            operation_dispatch_body! { $trait, $handle_response }
        }
    };
}

macro_rules! operation_dispatch_body {
    ($trait:path, $handle_response:ident) => {
        type O = <T as $trait>::O;
        const NAME: &'static CStr = <T as $trait>::NAME;
        const ZERO_COPY: bool = <T as $trait>::ZERO_COPY;
        fn build(&mut self, description: &StreamDescription) -> Result<Command> {
            <T as $trait>::build(self, description)
        }
        fn extract_at_cluster_time(&self, response: &RawDocument) -> Result<Option<Timestamp>> {
            <T as $trait>::extract_at_cluster_time(self, response)
        }
        fn handle_response<'a>(
            &'a self,
            response: Cow<'a, RawCommandResponse>,
            context: ExecutionContext<'a>,
        ) -> BoxFuture<'a, Result<Self::O>> {
            <T as $trait>::$handle_response(self, response, context)
        }
        fn handle_error(&self, error: Error) -> Result<Self::O> {
            <T as $trait>::handle_error(self, error)
        }
        fn selection_criteria(&self) -> Feature<&SelectionCriteria> {
            <T as $trait>::selection_criteria(self)
        }
        fn read_concern(&self) -> Feature<&ReadConcern> {
            <T as $trait>::read_concern(self)
        }
        fn write_concern(&self) -> Feature<&WriteConcern> {
            <T as $trait>::write_concern(self)
        }
        fn supports_sessions(&self) -> bool {
            <T as $trait>::supports_sessions(self)
        }
        fn retryability(&self, options: &ClientOptions) -> Retryability {
            <T as $trait>::retryability(self, options)
        }
        fn is_backpressure_retryable(&self, options: &ClientOptions) -> bool {
            <T as $trait>::is_backpressure_retryable(self, options)
        }
        fn update_for_retry(&mut self, retry: Option<&Retry>) {
            <T as $trait>::update_for_retry(self, retry)
        }
        fn override_criteria(&self) -> OverrideCriteriaFn {
            <T as $trait>::override_criteria(self)
        }
        fn pinned_connection(&self) -> Option<&PinnedConnectionHandle> {
            <T as $trait>::pinned_connection(self)
        }
        fn name(&self) -> &CStr {
            <T as $trait>::name(self)
        }
        fn target(&self) -> OperationTarget {
            <T as $trait>::target(self)
        }
        fn is_after_cluster_time_write(&self) -> bool {
            <T as $trait>::is_after_cluster_time_write(self)
        }
        #[cfg(feature = "opentelemetry")]
        type Otel = <T as $trait>::Otel;
    };
}

pub(crate) trait OperationImpl {
    type Kind;
}

impl<K, T> Operation for T
where
    T: OperationImpl<Kind = K> + OperationDispatch<K> + Send + Sync,
{
    operation_dispatch_body! { OperationDispatch<K>, handle_response }
}

pub(crate) struct Base;

operation_dispatch! { BaseOperation, Base, handle_response_async }

/// A trait for operations that delegate most behavior to another wrapped operation.
pub(crate) trait WrappedOperation {
    // Required
    type Wrapped: Operation;
    type O;
    #[cfg(feature = "opentelemetry")]
    type Otel: crate::otel::OtelWitness<Op = Self>;

    fn wrapped(&self) -> &Self::Wrapped;
    fn wrapped_mut(&mut self) -> &mut Self::Wrapped;

    fn handle_response<'a>(
        &'a self,
        response: Cow<'a, RawCommandResponse>,
        context: ExecutionContext<'a>,
    ) -> BoxFuture<'a, Result<Self::O>>;

    // Delegated to wrapped
    const NAME: &'static CStr = Self::Wrapped::NAME;
    const ZERO_COPY: bool = Self::Wrapped::ZERO_COPY;
    fn build(&mut self, description: &StreamDescription) -> Result<Command> {
        self.wrapped_mut().build(description)
    }
    fn handle_error(&self, error: Error) -> Result<Self::O> {
        Err(error)
    }
    fn extract_at_cluster_time(&self, response: &RawDocument) -> Result<Option<Timestamp>> {
        self.wrapped().extract_at_cluster_time(response)
    }
    fn selection_criteria(&self) -> Feature<&SelectionCriteria> {
        self.wrapped().selection_criteria()
    }
    fn read_concern(&self) -> Feature<&ReadConcern> {
        self.wrapped().read_concern()
    }
    fn write_concern(&self) -> Feature<&WriteConcern> {
        self.wrapped().write_concern()
    }
    fn supports_sessions(&self) -> bool {
        self.wrapped().supports_sessions()
    }
    fn retryability(&self, options: &ClientOptions) -> Retryability {
        self.wrapped().retryability(options)
    }
    fn is_backpressure_retryable(&self, options: &ClientOptions) -> bool {
        self.wrapped().is_backpressure_retryable(options)
    }
    fn update_for_retry(&mut self, retry: Option<&Retry>) {
        self.wrapped_mut().update_for_retry(retry);
    }
    fn override_criteria(&self) -> OverrideCriteriaFn {
        self.wrapped().override_criteria()
    }
    fn pinned_connection(&self) -> Option<&PinnedConnectionHandle> {
        self.wrapped().pinned_connection()
    }
    fn name(&self) -> &CStr {
        self.wrapped().name()
    }
    fn target(&self) -> OperationTarget {
        self.wrapped().target()
    }
    fn is_after_cluster_time_write(&self) -> bool {
        self.wrapped().is_after_cluster_time_write()
    }
}

pub(crate) struct Wrapped;

operation_dispatch! { WrappedOperation, Wrapped, handle_response }

fn should_redact_body(body: &RawDocumentBuf) -> bool {
    if let Some(Ok((command_name, _))) = body.into_iter().next() {
        HELLO_COMMAND_NAMES.contains(command_name.to_lowercase().as_str())
            && body.get("speculativeAuthenticate").ok().flatten().is_some()
    } else {
        false
    }
}

impl Command {
    pub(crate) fn should_redact(&self) -> bool {
        let name = self.name.to_lowercase();
        REDACTED_COMMANDS.contains(name.as_str()) || should_redact_body(&self.body)
    }

    #[cfg(any(
        feature = "zstd-compression",
        feature = "zlib-compression",
        feature = "snappy-compression"
    ))]
    pub(crate) fn should_compress(&self) -> bool {
        let name = self.name.to_lowercase();
        !REDACTED_COMMANDS.contains(name.as_str()) && !HELLO_COMMAND_NAMES.contains(name.as_str())
    }
}

/// A response to a command with a body shaped deserialized to a `T`.
#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CommandResponse<T> {
    pub(crate) ok: Bson,

    #[serde(rename = "$clusterTime")]
    pub(crate) cluster_time: Option<ClusterTime>,

    #[serde(flatten)]
    pub(crate) body: T,
}

impl<T: DeserializeOwned> CommandResponse<T> {
    /// Whether the command succeeeded or not (i.e. if this response is ok: 1).
    pub(crate) fn is_success(&self) -> bool {
        bson_util::get_int(&self.ok) == Some(1)
    }

    pub(crate) fn cluster_time(&self) -> Option<&ClusterTime> {
        self.cluster_time.as_ref()
    }
}

/// A response body useful for deserializing command errors.
#[derive(Deserialize, Debug)]
pub(crate) struct CommandErrorBody {
    #[serde(rename = "errorLabels")]
    pub(crate) error_labels: Option<Vec<String>>,

    #[serde(flatten)]
    pub(crate) command_error: CommandError,
}

impl From<CommandErrorBody> for Error {
    fn from(command_error_response: CommandErrorBody) -> Error {
        Error::new(
            ErrorKind::Command(command_error_response.command_error),
            command_error_response.error_labels,
        )
    }
}

/// Appends a serializable struct to the input document. The serializable struct MUST serialize to a
/// Document; otherwise, an error will be thrown.
pub(crate) fn append_options<T: Serialize + Debug>(
    doc: &mut Document,
    options: Option<&T>,
) -> Result<()> {
    if let Some(options) = options {
        let options_doc = crate::bson_compat::serialize_to_document(options)?;
        doc.extend(options_doc);
    }
    Ok(())
}

pub(crate) fn append_options_to_raw_document<T: Serialize>(
    doc: &mut RawDocumentBuf,
    options: Option<&T>,
) -> Result<()> {
    if let Some(options) = options {
        let options_raw_doc = crate::bson_compat::serialize_to_raw_document_buf(options)?;
        extend_raw_document_buf(doc, options_raw_doc)?;
    }
    Ok(())
}

fn cursor_get_at_cluster_time(response: &RawDocument) -> Result<Option<Timestamp>> {
    Ok(response
        .get("cursor")?
        .and_then(RawBsonRef::as_document)
        .map(|d| d.get("atClusterTime"))
        .transpose()?
        .flatten()
        .and_then(RawBsonRef::as_timestamp))
}

/// Type used to deserialize just the first result from a cursor, if any.
#[derive(Debug, Clone)]
pub(crate) struct SingleCursorResult<T>(Option<T>);

impl<'de, T> Deserialize<'de> for SingleCursorResult<T>
where
    T: Deserialize<'de>,
{
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        #[derive(Deserialize)]
        struct FullCursorBody<T> {
            cursor: InteriorBody<T>,
        }

        #[derive(Deserialize)]
        struct InteriorBody<T> {
            #[serde(rename = "firstBatch")]
            first_batch: Vec<T>,
        }

        let mut full_body = FullCursorBody::deserialize(deserializer)?;
        Ok(SingleCursorResult(full_body.cursor.first_batch.pop()))
    }
}

pub(crate) fn is_commit_or_abort<T: Operation>(op: &T) -> bool {
    op.name() == <CommitTransaction as Operation>::NAME
        || op.name() == <AbortTransaction as Operation>::NAME
}
