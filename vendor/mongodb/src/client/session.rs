mod action;
mod cluster_time;
mod pool;
#[cfg(test)]
mod test;

use std::{
    collections::HashSet,
    sync::Arc,
    time::{Duration, Instant},
};

use std::sync::LazyLock;
use uuid::Uuid;

use crate::{
    bson::{doc, spec::BinarySubtype, Binary, Bson, Document, Timestamp},
    cmap::conn::PinnedConnectionHandle,
    operation::Retryability,
    options::{SessionOptions, TransactionOptions},
    sdam::ServerInfo,
    selection_criteria::SelectionCriteria,
    Client,
};
pub use cluster_time::ClusterTime;
pub(super) use pool::ServerSessionPool;

use super::{options::ServerAddress, AsyncDropToken};

pub(crate) static SESSIONS_UNSUPPORTED_COMMANDS: LazyLock<HashSet<&'static str>> =
    LazyLock::new(|| {
        let mut hash_set = HashSet::new();
        hash_set.insert("killcursors");
        hash_set.insert("parallelcollectionscan");
        hash_set
    });

/// A MongoDB client session. This struct represents a logical session used for ordering sequential
/// operations. To create a `ClientSession`, call `start_session` on a `Client`.
///
/// `ClientSession` instances are not thread safe or fork safe. They can only be used by one thread
/// or process at a time.
///
/// ## Transactions
/// Transactions are used to execute a series of operations across multiple documents and
/// collections atomically. For more information about when and how to use transactions in MongoDB,
/// see the [manual](https://www.mongodb.com/docs/manual/core/transactions/).
///
/// Transactions are associated with a `ClientSession`. To begin a transaction, call
/// [`ClientSession::start_transaction`] on a `ClientSession`. The `ClientSession` must be passed to
/// operations to be executed within the transaction.
///
/// ```rust
/// use mongodb::{
///     bson::{doc, Document},
///     error::{Result, TRANSIENT_TRANSACTION_ERROR, UNKNOWN_TRANSACTION_COMMIT_RESULT},
///     options::{Acknowledgment, ReadConcern, TransactionOptions, WriteConcern},
/// #   Client,
///     ClientSession,
///     Collection,
/// };
///
/// # async fn do_stuff() -> Result<()> {
/// # let client = Client::with_uri_str("mongodb://example.com").await?;
/// # let coll: Collection<Document> = client.database("foo").collection("bar");
/// let mut session = client.start_session().await?;
/// session
///     .start_transaction()
///     .read_concern(ReadConcern::majority())
///     .write_concern(WriteConcern::majority())
///     .await?;
/// // A "TransientTransactionError" label indicates that the entire transaction can be retried
/// // with a reasonable expectation that it will succeed.
/// while let Err(error) = execute_transaction(&coll, &mut session).await {
///     if !error.contains_label(TRANSIENT_TRANSACTION_ERROR) {
///         break;
///     }
/// }
/// # Ok(())
/// # }
///
/// async fn execute_transaction(coll: &Collection<Document>, session: &mut ClientSession) -> Result<()> {
///     coll.insert_one(doc! { "x": 1 }).session(&mut *session).await?;
///     coll.delete_one(doc! { "y": 2 }).session(&mut *session).await?;
///     // An "UnknownTransactionCommitResult" label indicates that it is unknown whether the
///     // commit has satisfied the write concern associated with the transaction. If an error
///     // with this label is returned, it is safe to retry the commit until the write concern is
///     // satisfied or an error without the label is returned.
///     loop {
///         let result = session.commit_transaction().await;
///         if let Err(ref error) = result {
///             if error.contains_label(UNKNOWN_TRANSACTION_COMMIT_RESULT) {
///                 continue;
///             }
///         }
///         result?
///     }
/// }
/// ```
#[derive(Debug)]
pub struct ClientSession {
    cluster_time: Option<ClusterTime>,
    server_session: ServerSession,
    client: Client,
    is_implicit: bool,
    options: Option<SessionOptions>,
    drop_token: AsyncDropToken,
    pub(crate) transaction: Transaction,
    pub(crate) snapshot_time: Option<Timestamp>,
    pub(crate) operation_time: Option<Timestamp>,
    #[cfg(test)]
    pub(crate) convenient_transaction_timeout: Option<Duration>,
    #[cfg(test)]
    pub(crate) convenient_transaction_jitter: Option<f64>,
}

#[derive(Debug)]
pub(crate) struct Transaction {
    pub(crate) state: TransactionState,
    pub(crate) options: Option<TransactionOptions>,
    pub(crate) pinned: Option<TransactionPin>,
    pub(crate) recovery_token: Option<Document>,
    #[cfg(feature = "opentelemetry")]
    pub(crate) otel_span: Option<crate::otel::TxnSpan>,
}

impl Transaction {
    pub(crate) fn start(
        &mut self,
        options: Option<TransactionOptions>,
        #[cfg(feature = "opentelemetry")] otel_span: crate::otel::TxnSpan,
    ) {
        self.state = TransactionState::Starting;
        self.options = options;
        self.recovery_token = None;
        #[cfg(feature = "opentelemetry")]
        {
            self.otel_span = Some(otel_span);
        }
    }

    pub(crate) fn commit(&mut self, data_committed: bool) {
        self.state = TransactionState::Committed { data_committed };
    }

    pub(crate) fn abort(&mut self) {
        self.state = TransactionState::Aborted;
        self.options = None;
        self.pinned = None;
    }

    pub(crate) fn reset(&mut self) {
        self.state = TransactionState::None;
        self.options = None;
        self.pinned = None;
        self.recovery_token = None;
        self.drop_span();
    }

    pub(crate) fn drop_span(&mut self) {
        #[cfg(feature = "opentelemetry")]
        {
            self.otel_span = None;
        }
    }

    #[cfg(test)]
    pub(crate) fn is_pinned(&self) -> bool {
        self.pinned.is_some()
    }

    pub(crate) fn pinned_mongos(&self) -> Option<&SelectionCriteria> {
        match &self.pinned {
            Some(TransactionPin::Mongos(s)) => Some(s),
            _ => None,
        }
    }

    pub(crate) fn pinned_connection(&self) -> Option<&PinnedConnectionHandle> {
        match &self.pinned {
            Some(TransactionPin::Connection(c)) => Some(c),
            _ => None,
        }
    }

    fn take(&mut self) -> Self {
        Transaction {
            state: self.state.clone(),
            options: self.options.take(),
            pinned: self.pinned.take(),
            recovery_token: self.recovery_token.take(),
            #[cfg(feature = "opentelemetry")]
            otel_span: self.otel_span.take(),
        }
    }
}

impl Default for Transaction {
    fn default() -> Self {
        Self {
            state: TransactionState::None,
            options: None,
            pinned: None,
            recovery_token: None,
            #[cfg(feature = "opentelemetry")]
            otel_span: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum TransactionState {
    None,
    Starting,
    InProgress,
    Committed {
        /// Whether any data was committed when commit_transaction was initially called. This is
        /// required to determine whether a commitTransaction command should be run if the user
        /// calls commit_transaction again.
        data_committed: bool,
    },
    Aborted,
}

#[derive(Debug)]
pub(crate) enum TransactionPin {
    Mongos(SelectionCriteria),
    Connection(PinnedConnectionHandle),
}

impl ClientSession {
    /// Creates a new `ClientSession` by checking out a corresponding `ServerSession` from the
    /// provided client's session pool.
    pub(crate) async fn new(
        client: Client,
        options: Option<SessionOptions>,
        is_implicit: bool,
    ) -> Self {
        let timeout = client.inner.topology.watcher().logical_session_timeout();
        let server_session = client.inner.session_pool.check_out(timeout).await;
        let snapshot_time = options.as_ref().and_then(|o| o.snapshot_time);
        Self {
            drop_token: client.register_async_drop(),
            client,
            server_session,
            cluster_time: None,
            is_implicit,
            options,
            transaction: Default::default(),
            snapshot_time,
            operation_time: None,
            #[cfg(test)]
            convenient_transaction_timeout: None,
            #[cfg(test)]
            convenient_transaction_jitter: None,
        }
    }

    /// The client used to create this session.
    pub fn client(&self) -> Client {
        self.client.clone()
    }

    /// The id of this session.
    pub fn id(&self) -> &Document {
        &self.server_session.id
    }

    /// Whether this session was created implicitly by the driver or explcitly by the user.
    pub(crate) fn is_implicit(&self) -> bool {
        self.is_implicit
    }

    /// Whether this session is currently in a transaction.
    pub(crate) fn in_transaction(&self) -> bool {
        matches!(
            self.transaction.state,
            TransactionState::Starting | TransactionState::InProgress
        )
    }

    /// The highest seen cluster time this session has seen so far.
    /// This will be `None` if this session has not been used in an operation yet.
    pub fn cluster_time(&self) -> Option<&ClusterTime> {
        self.cluster_time.as_ref()
    }

    /// The options used to create this session.
    pub(crate) fn options(&self) -> Option<&SessionOptions> {
        self.options.as_ref()
    }

    /// Set the cluster time to the provided one if it is greater than this session's highest seen
    /// cluster time or if this session's cluster time is `None`.
    pub fn advance_cluster_time(&mut self, to: &ClusterTime) {
        if self.cluster_time().map(|ct| ct < to).unwrap_or(true) {
            self.cluster_time = Some(to.clone());
        }
    }

    /// Advance operation time for this session. If the provided timestamp is earlier than this
    /// session's current operation time, then the operation time is unchanged.
    pub fn advance_operation_time(&mut self, ts: Timestamp) {
        self.operation_time = match self.operation_time {
            Some(current_op_time) if current_op_time < ts => Some(ts),
            None => Some(ts),
            _ => self.operation_time,
        }
    }

    /// The operation time returned by the last operation executed in this session.
    pub fn operation_time(&self) -> Option<Timestamp> {
        self.operation_time
    }

    /// The snapshot time for a snapshot session. This will return `None` if this session is not a
    /// snapshot session or if [`snapshot_time`](SessionOptions::snapshot_time) was not set and the
    /// server has not yet responded with a snapshot time.
    pub fn snapshot_time(&self) -> Option<Timestamp> {
        self.snapshot_time
    }

    pub(crate) fn causal_consistency(&self) -> bool {
        self.options()
            .and_then(|opts| opts.causal_consistency)
            .unwrap_or(!self.is_implicit())
    }

    /// Mark this session (and the underlying server session) as dirty.
    pub(crate) fn mark_dirty(&mut self) {
        self.server_session.dirty = true;
    }

    /// Updates the date that the underlying server session was last used as part of an operation
    /// sent to the server.
    pub(crate) fn update_last_use(&mut self) {
        self.server_session.last_use = Instant::now();
    }

    /// Gets the current txn_number.
    pub(crate) fn txn_number(&self) -> i64 {
        self.server_session.txn_number
    }

    /// Increments the txn_number.
    pub(crate) fn increment_txn_number(&mut self) {
        self.server_session.txn_number += 1;
    }

    /// Gets the txn_number to use for an operation based on the current transaction status and the
    /// operation's retryability.
    pub(crate) fn get_txn_number_for_operation(
        &mut self,
        retryability: Retryability,
    ) -> Option<i64> {
        if self.transaction.state != TransactionState::None {
            Some(self.txn_number())
        } else if retryability == Retryability::Write {
            self.increment_txn_number();
            Some(self.txn_number())
        } else {
            None
        }
    }

    /// Pin mongos to session.
    pub(crate) fn pin_mongos(&mut self, address: ServerAddress) {
        self.transaction.pinned = Some(TransactionPin::Mongos(SelectionCriteria::Predicate(
            Arc::new(move |server_info: &ServerInfo| *server_info.address() == address),
        )));
    }

    /// Pin the connection to the session.
    pub(crate) fn pin_connection(&mut self, handle: PinnedConnectionHandle) {
        self.transaction.pinned = Some(TransactionPin::Connection(handle));
    }

    pub(crate) fn unpin(&mut self) {
        self.transaction.pinned = None;
    }

    /// Whether this session is dirty.
    #[cfg(test)]
    pub(crate) fn is_dirty(&self) -> bool {
        self.server_session.dirty
    }

    fn default_transaction_options(&self) -> Option<&TransactionOptions> {
        self.options
            .as_ref()
            .and_then(|options| options.default_transaction_options.as_ref())
    }
}

struct DroppedClientSession {
    cluster_time: Option<ClusterTime>,
    server_session: ServerSession,
    client: Client,
    is_implicit: bool,
    options: Option<SessionOptions>,
    transaction: Transaction,
    snapshot_time: Option<Timestamp>,
    operation_time: Option<Timestamp>,
}

impl From<DroppedClientSession> for ClientSession {
    fn from(dropped_session: DroppedClientSession) -> Self {
        Self {
            cluster_time: dropped_session.cluster_time,
            server_session: dropped_session.server_session,
            drop_token: dropped_session.client.register_async_drop(),
            client: dropped_session.client,
            is_implicit: dropped_session.is_implicit,
            options: dropped_session.options,
            transaction: dropped_session.transaction,
            snapshot_time: dropped_session.snapshot_time,
            operation_time: dropped_session.operation_time,
            #[cfg(test)]
            convenient_transaction_timeout: None,
            #[cfg(test)]
            convenient_transaction_jitter: None,
        }
    }
}

impl Drop for ClientSession {
    fn drop(&mut self) {
        if self.transaction.state == TransactionState::InProgress {
            let dropped_session = DroppedClientSession {
                cluster_time: self.cluster_time.clone(),
                server_session: self.server_session.clone(),
                client: self.client.clone(),
                is_implicit: self.is_implicit,
                options: self.options.clone(),
                transaction: self.transaction.take(),
                snapshot_time: self.snapshot_time,
                operation_time: self.operation_time,
            };
            self.drop_token.spawn(async move {
                let mut session: ClientSession = dropped_session.into();
                let _result = session.abort_transaction().await;
            });
        } else {
            let client = self.client.clone();
            let server_session = self.server_session.clone();
            self.drop_token.spawn(async move {
                client.check_in_server_session(server_session).await;
            });
        }
    }
}

/// Client side abstraction of a server session. These are pooled and may be associated with
/// multiple `ClientSession`s over the course of their lifetime.
#[derive(Clone, Debug)]
pub(crate) struct ServerSession {
    /// The id of the server session to which this corresponds.
    pub(crate) id: Document,

    /// The last time an operation was executed with this session.
    last_use: std::time::Instant,

    /// Whether a network error was encountered while using this session.
    dirty: bool,

    /// A monotonically increasing transaction number for this session.
    txn_number: i64,
}

impl ServerSession {
    /// Creates a new session, generating the id client side.
    fn new() -> Self {
        let binary = Bson::Binary(Binary {
            subtype: BinarySubtype::Uuid,
            bytes: Uuid::new_v4().as_bytes().to_vec(),
        });

        Self {
            id: doc! { "id": binary },
            last_use: Instant::now(),
            dirty: false,
            txn_number: 0,
        }
    }

    /// Determines if this server session is about to expire in a short amount of time (1 minute).
    fn is_about_to_expire(&self, logical_session_timeout: Option<Duration>) -> bool {
        let timeout = match logical_session_timeout {
            Some(t) => t,
            None => return false,
        };
        let expiration_date = self.last_use + timeout;
        expiration_date < Instant::now() + Duration::from_secs(60)
    }
}
