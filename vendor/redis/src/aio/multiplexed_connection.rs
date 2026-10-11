use super::{AsyncPushSender, ConnectionLike, Runtime, SharedHandleContainer, TaskHandle};
#[cfg(feature = "cache-aio")]
use crate::caching::{CacheManager, CacheStatistics, PrepCacheItem};
use crate::{
    AsyncConnectionConfig, ProtocolVersion, PushInfo, RedisConnectionInfo, ServerError,
    ToRedisArgs,
    aio::setup_connection,
    check_resp3, cmd,
    cmd::Cmd,
    errors::{ErrorKind, RedisError, closed_connection_error},
    parser::ValueCodec,
    types::{RedisFuture, RedisResult, Value},
};
use ::tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::{mpsc, oneshot},
};
#[cfg(feature = "token-based-authentication")]
use {
    arcstr::ArcStr,
    log::{debug, error, warn},
};

use futures_util::{
    future::{Future, FutureExt},
    ready,
    sink::Sink,
    stream::{self, Stream, StreamExt},
};
use pin_project_lite::pin_project;
use std::collections::VecDeque;
use std::fmt;
use std::fmt::Debug;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{self, Poll};
use std::time::Duration;
use tokio_util::codec::Decoder;

// Senders which the result of a single request are sent through
type PipelineOutput = oneshot::Sender<RedisResult<Value>>;

enum ErrorOrErrors {
    Errors(Vec<(usize, ServerError)>),
    // only set if we receive a transmission error
    FirstError(RedisError),
}

enum ResponseAggregate {
    SingleCommand,
    Pipeline {
        buffer: Vec<Value>,
        error_or_errors: ErrorOrErrors,
        expectation: PipelineResponseExpectation,
    },
}

// TODO - this is a really bad name.
struct PipelineResponseExpectation {
    // The number of responses to skip before starting to save responses in the buffer.
    skipped_response_count: usize,
    // The number of responses to keep in the buffer
    expected_response_count: usize,
    // whether the pipelined request is a transaction
    is_transaction: bool,
    seen_responses: usize,
}

impl ResponseAggregate {
    fn new(expectation: Option<PipelineResponseExpectation>) -> Self {
        match expectation {
            Some(expectation) => Self::Pipeline {
                buffer: Vec::new(),
                error_or_errors: ErrorOrErrors::Errors(Vec::new()),
                expectation,
            },
            None => Self::SingleCommand,
        }
    }
}

struct InFlight {
    output: Option<PipelineOutput>,
    response_aggregate: ResponseAggregate,
}

// A single message sent through the pipeline
struct PipelineMessage {
    input: Vec<u8>,
    // If `output` is None, then the caller doesn't expect to receive an answer.
    output: Option<PipelineOutput>,
    // If `None`, this is a single request, not a pipeline of multiple requests.
    // If `Some`, the first value is the number of responses to skip,
    // the second is the number of responses to keep, and the third is whether the pipeline is a transaction.
    expectation: Option<PipelineResponseExpectation>,
}

/// Wrapper around a `Stream + Sink` where each item sent through the `Sink` results in one or more
/// items being output by the `Stream` (the number is specified at time of sending). With the
/// interface provided by `Pipeline` an easy interface of request to response, hiding the `Stream`
/// and `Sink`.
#[derive(Clone)]
struct Pipeline {
    sender: mpsc::Sender<PipelineMessage>,
}

impl Debug for Pipeline {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Pipeline").field(&self.sender).finish()
    }
}

#[cfg(feature = "cache-aio")]
pin_project! {
    struct PipelineSink<T> {
        #[pin]
        sink_stream: T,
        in_flight: VecDeque<InFlight>,
        error: Option<RedisError>,
        push_sender: Option<Arc<dyn AsyncPushSender>>,
        cache_manager: Option<CacheManager>,
    }
}

#[cfg(not(feature = "cache-aio"))]
pin_project! {
    struct PipelineSink<T> {
        #[pin]
        sink_stream: T,
        in_flight: VecDeque<InFlight>,
        error: Option<RedisError>,
        push_sender: Option<Arc<dyn AsyncPushSender>>,
    }
}

fn send_push(push_sender: &Option<Arc<dyn AsyncPushSender>>, info: PushInfo) {
    if let Some(sender) = push_sender {
        let _ = sender.send(info);
    }
}

fn send_disconnect(push_sender: &mut Option<Arc<dyn AsyncPushSender>>) {
    send_push(push_sender, PushInfo::disconnect());
    // we don't want to send the same request twice, so if the connection is disconnected we can just stop sending push messages
    push_sender.take();
}

impl<T> PipelineSink<T>
where
    T: Stream<Item = RedisResult<Value>> + 'static,
{
    fn new(
        sink_stream: T,
        push_sender: Option<Arc<dyn AsyncPushSender>>,
        #[cfg(feature = "cache-aio")] cache_manager: Option<CacheManager>,
    ) -> Self
    where
        T: Sink<Vec<u8>, Error = RedisError> + Stream<Item = RedisResult<Value>> + 'static,
    {
        Self {
            sink_stream,
            in_flight: VecDeque::new(),
            error: None,
            push_sender,
            #[cfg(feature = "cache-aio")]
            cache_manager,
        }
    }

    // Read messages from the stream and send them back to the caller
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut task::Context) -> Poll<Result<(), ()>> {
        loop {
            let item = ready!(self.as_mut().project().sink_stream.poll_next(cx));
            let item = match item {
                Some(result) => result,
                // The redis response stream is not going to produce any more items so we simulate a disconnection error to break out of the loop.
                None => Err(closed_connection_error()),
            };

            let is_unrecoverable = item.as_ref().is_err_and(|err| err.is_unrecoverable_error());
            self.as_mut().send_result(item);
            if is_unrecoverable {
                let self_ = self.project();
                send_disconnect(self_.push_sender);
                return Poll::Ready(Err(()));
            }
        }
    }

    fn send_result(self: Pin<&mut Self>, result: RedisResult<Value>) {
        let self_ = self.project();
        let result = match result {
            // If this push message isn't a reply, we'll pass it as-is to the push manager and stop iterating
            Ok(Value::Push { kind, data }) if !kind.has_reply() => {
                #[cfg(feature = "cache-aio")]
                if let Some(cache_manager) = &self_.cache_manager {
                    cache_manager.handle_push_value(&kind, &data);
                }
                send_push(self_.push_sender, PushInfo { kind, data });

                return;
            }
            // If this push message is a reply to a query, we'll clone it to the push manager and continue with sending the reply
            Ok(Value::Push { kind, data }) if kind.has_reply() => {
                send_push(
                    self_.push_sender,
                    PushInfo {
                        kind: kind.clone(),
                        data: data.clone(),
                    },
                );
                Ok(Value::Push { kind, data })
            }
            _ => result,
        };

        let mut entry = match self_.in_flight.pop_front() {
            Some(entry) => entry,
            None => return,
        };

        match &mut entry.response_aggregate {
            ResponseAggregate::SingleCommand => {
                if let Some(output) = entry.output.take() {
                    _ = output.send(result);
                }
            }
            ResponseAggregate::Pipeline {
                buffer,
                error_or_errors,
                expectation:
                    PipelineResponseExpectation {
                        expected_response_count,
                        skipped_response_count,
                        is_transaction,
                        seen_responses,
                    },
            } => {
                *seen_responses += 1;
                if *skipped_response_count > 0 {
                    // server errors in skipped values are still counted for errors in transactions, since they're errors that will cause the transaction to fail,
                    // and we only skip values in transaction.
                    if *is_transaction && let ErrorOrErrors::Errors(errs) = error_or_errors {
                        match result {
                            Ok(Value::ServerError(err)) => {
                                errs.push((*seen_responses - 2, err)); // - 1 to offset the early increment, and -1 to offset the added MULTI call.
                            }
                            Err(err) => *error_or_errors = ErrorOrErrors::FirstError(err),
                            _ => {}
                        }
                    }

                    *skipped_response_count -= 1;
                    self_.in_flight.push_front(entry);
                    return;
                }

                match result {
                    Ok(item) => {
                        buffer.push(item);
                    }
                    Err(err) => {
                        if matches!(error_or_errors, ErrorOrErrors::Errors(_)) {
                            *error_or_errors = ErrorOrErrors::FirstError(err);
                        }
                    }
                }

                if buffer.len() < *expected_response_count {
                    // Need to gather more response values
                    self_.in_flight.push_front(entry);
                    return;
                }

                let response =
                    match std::mem::replace(error_or_errors, ErrorOrErrors::Errors(Vec::new())) {
                        ErrorOrErrors::Errors(errors) => {
                            if errors.is_empty() {
                                Ok(Value::Array(std::mem::take(buffer)))
                            } else {
                                Err(RedisError::make_aborted_transaction(errors))
                            }
                        }
                        ErrorOrErrors::FirstError(redis_error) => Err(redis_error),
                    };

                // `Err` means that the receiver was dropped in which case it does not
                // care about the output and we can continue by just dropping the value
                // and sender
                if let Some(output) = entry.output.take() {
                    _ = output.send(response);
                }
            }
        }
    }

    fn send_disconnect_if_needed(self: Pin<&mut Self>, err: &RedisError) {
        if err.is_unrecoverable_error() {
            let self_ = self.project();
            send_disconnect(self_.push_sender);
        }
    }
}

impl<T> Sink<PipelineMessage> for PipelineSink<T>
where
    T: Sink<Vec<u8>, Error = RedisError> + Stream<Item = RedisResult<Value>> + 'static,
{
    type Error = ();

    // Retrieve incoming messages and write them to the sink
    fn poll_ready(
        mut self: Pin<&mut Self>,
        cx: &mut task::Context,
    ) -> Poll<Result<(), Self::Error>> {
        // It is crucial that we always try to advance both the read and the write side together.
        // If we do not, we are susceptible to TCP deadlock.
        // Here, we do this by advancing reads and then moving on to advance writes regardless of
        // whether the read was pending or not. This ensures that we are registered to be woken
        // if either reads or writes become available.
        // See https://github.com/redis-rs/redis-rs/issues/1955.
        if matches!(self.as_mut().poll_read(cx), Poll::Ready(Err(()))) {
            return Poll::Ready(Err(()));
        }
        match ready!(self.as_mut().project().sink_stream.poll_ready(cx)) {
            Ok(()) => Ok(()).into(),
            Err(err) => {
                self.as_mut().send_disconnect_if_needed(&err);
                *self.project().error = Some(err);
                Ok(()).into()
            }
        }
    }

    fn start_send(
        mut self: Pin<&mut Self>,
        PipelineMessage {
            input,
            mut output,
            expectation,
        }: PipelineMessage,
    ) -> Result<(), Self::Error> {
        // If initially a receiver was created, but then dropped, there is nothing to receive our output we do not need to send the message as it is
        // ambiguous whether the message will be sent anyway. Helps shed some load on the
        // connection.
        if output.as_ref().is_some_and(|output| output.is_closed()) {
            return Ok(());
        }

        let self_ = self.as_mut().project();

        if let Some(err) = self_.error.take() {
            if let Some(output) = output.take() {
                _ = output.send(Err(err));
            }
            return Err(());
        }

        match self_.sink_stream.start_send(input) {
            Ok(()) => {
                let response_aggregate = ResponseAggregate::new(expectation);
                let entry = InFlight {
                    output,
                    response_aggregate,
                };

                self_.in_flight.push_back(entry);
                Ok(())
            }
            Err(err) => {
                if let Some(output) = output.take() {
                    _ = output.send(Err(err));
                }
                Err(())
            }
        }
    }

    fn poll_flush(
        mut self: Pin<&mut Self>,
        cx: &mut task::Context,
    ) -> Poll<Result<(), Self::Error>> {
        // It is crucial that we always try to advance both the read and the write side together.
        // If we do not, we are susceptible to TCP deadlock.
        // Here, we do this by advancing reads and then moving on to advance writes regardless of
        // whether the read was pending or not. This ensures that we are registered to be woken
        // if either reads or writes become available.
        // See https://github.com/redis-rs/redis-rs/issues/1955.
        if matches!(self.as_mut().poll_read(cx), Poll::Ready(Err(()))) {
            return Poll::Ready(Err(()));
        }
        self.as_mut()
            .project()
            .sink_stream
            .poll_flush(cx)
            .map_err(|err| {
                self.as_mut().send_disconnect_if_needed(&err);
                self.send_result(Err(err));
            })
    }

    fn poll_close(
        mut self: Pin<&mut Self>,
        cx: &mut task::Context,
    ) -> Poll<Result<(), Self::Error>> {
        // No new requests will come in after the first call to `close` but we need to complete any
        // in progress requests before closing
        if !self.in_flight.is_empty() {
            ready!(self.as_mut().poll_flush(cx))?;
        }
        let this = self.as_mut().project();
        this.sink_stream.poll_close(cx).map_err(|err| {
            self.send_result(Err(err));
        })
    }
}

impl Pipeline {
    const DEFAULT_BUFFER_SIZE: usize = 50;

    fn resolve_buffer_size(size: Option<usize>) -> usize {
        size.unwrap_or(Self::DEFAULT_BUFFER_SIZE)
    }

    fn new<T>(
        sink_stream: T,
        push_sender: Option<Arc<dyn AsyncPushSender>>,
        #[cfg(feature = "cache-aio")] cache_manager: Option<CacheManager>,
        buffer_size: usize,
    ) -> (Self, impl Future<Output = ()>)
    where
        T: Sink<Vec<u8>, Error = RedisError>,
        T: Stream<Item = RedisResult<Value>>,
        T: Unpin + Send + 'static,
    {
        let (sender, mut receiver) = mpsc::channel(buffer_size);

        let sink = PipelineSink::new(
            sink_stream,
            push_sender,
            #[cfg(feature = "cache-aio")]
            cache_manager,
        );
        let f = stream::poll_fn(move |cx| receiver.poll_recv(cx))
            .map(Ok)
            .forward(sink)
            .map(|_| ());
        (Self { sender }, f)
    }

    async fn send_recv(
        &mut self,
        input: Vec<u8>,
        // If `None`, this is a single request, not a pipeline of multiple requests.
        // If `Some`, the value inside defines how the response should look like
        expectation: Option<PipelineResponseExpectation>,
        timeout: Option<Duration>,
        skip_response: bool,
    ) -> Result<Value, RedisError> {
        if input.is_empty() {
            return Err(RedisError::make_empty_command());
        }

        let request = async {
            if skip_response {
                self.sender
                    .send(PipelineMessage {
                        input,
                        expectation,
                        output: None,
                    })
                    .await
                    .map_err(|_| None)?;

                return Ok(Value::Nil);
            }

            let (sender, receiver) = oneshot::channel();

            self.sender
                .send(PipelineMessage {
                    input,
                    expectation,
                    output: Some(sender),
                })
                .await
                .map_err(|_| None)?;

            receiver.await
            // The `sender` was dropped which likely means that the stream part
            // failed for one reason or another
            .map_err(|_| None)
            .and_then(|res| res.map_err(Some))
        };

        match timeout {
            Some(timeout) => match Runtime::locate().timeout(timeout, request).await {
                Ok(res) => res,
                Err(elapsed) => Err(Some(elapsed.into())),
            },
            None => request.await,
        }
        .map_err(|err| err.unwrap_or_else(closed_connection_error))
    }
}

/// Semaphore plus the `limit` it was created with, so the limit stays readable.
#[derive(Clone, Debug)]
struct ConcurrencyLimiter {
    limit: usize,
    semaphore: Arc<async_lock::Semaphore>,
}

/// Permits a single pipeline can hold: capped at the connection `limit`.
/// At least one is always acquired.
fn permit_vec_capacity(count: usize, limit: usize) -> usize {
    count.min(limit).max(1)
}

/// Builds the optional concurrency limiter from the configured limit. A limit of `0` is rejected.
fn build_concurrency_limiter(limit: Option<usize>) -> RedisResult<Option<ConcurrencyLimiter>> {
    match limit {
        Some(0) => Err(RedisError::from((
            ErrorKind::InvalidClientConfig,
            "concurrency limit must be greater than 0",
        ))),
        Some(n) => Ok(Some(ConcurrencyLimiter {
            limit: n,
            semaphore: Arc::new(async_lock::Semaphore::new(n)),
        })),
        None => Ok(None),
    }
}

/// A connection object which can be cloned, allowing requests to be be sent concurrently
/// on the same underlying connection (tcp/unix socket).
///
/// This connection object is cancellation-safe, and the user can drop request future without polling them to completion,
/// but this doesn't mean that the actual request sent to the server is cancelled.
/// A side-effect of this is that the underlying connection won't be closed until all sent requests have been answered,
/// which means that in case of blocking commands, the underlying connection resource might not be released,
/// even when all clones of the multiplexed connection have been dropped (see <https://github.com/redis-rs/redis-rs/issues/1236>).
/// This isn't an issue in a connection that was created in a canonical way, which ensures that `_task_handle` is set, so that
/// once all of the connection's clones are dropped, the task will also be dropped. If the user creates the connection in
/// another way and `_task_handle` isn't set, they should manually spawn the returned driver function, keep the spawned task's
/// handle and abort the task whenever they want, at the risk of effectively closing the clones of the multiplexed connection.
#[derive(Clone)]
pub struct MultiplexedConnection {
    pipeline: Pipeline,
    db: i64,
    response_timeout: Option<Duration>,
    protocol: ProtocolVersion,
    concurrency_limiter: Option<ConcurrencyLimiter>,
    // This handle ensures that once all the clones of the connection will be dropped, the underlying task will stop.
    // This handle is only set for connection whose task was spawned by the crate, not for users who spawned their own
    // task.
    _task_handle: Option<SharedHandleContainer>,
    #[cfg(feature = "cache-aio")]
    pub(crate) cache_manager: Option<CacheManager>,
    #[cfg(feature = "token-based-authentication")]
    // This handle ensures that once all the clones of the connection will be dropped, the underlying task will stop.
    // It is only set for connections that use a credentials provider for token-based authentication.
    _credentials_subscription_task_handle: Option<SharedHandleContainer>,
}

impl Debug for MultiplexedConnection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let Self {
            pipeline,
            db,
            response_timeout,
            protocol,
            concurrency_limiter: _,
            _task_handle,
            #[cfg(feature = "cache-aio")]
                cache_manager: _,
            #[cfg(feature = "token-based-authentication")]
                _credentials_subscription_task_handle: _,
        } = self;

        f.debug_struct("MultiplexedConnection")
            .field("pipeline", &pipeline)
            .field("db", &db)
            .field("response_timeout", &response_timeout)
            .field("protocol", &protocol)
            .finish()
    }
}

impl MultiplexedConnection {
    /// Constructs a new `MultiplexedConnection` out of a `AsyncRead + AsyncWrite` object
    /// and a `RedisConnectionInfo`
    pub async fn new<C>(
        connection_info: &RedisConnectionInfo,
        stream: C,
    ) -> RedisResult<(Self, impl Future<Output = ()>)>
    where
        C: Unpin + AsyncRead + AsyncWrite + Send + 'static,
    {
        Self::new_with_config(connection_info, stream, AsyncConnectionConfig::default()).await
    }

    /// Constructs a new `MultiplexedConnection` out of a `AsyncRead + AsyncWrite` object
    /// , a `RedisConnectionInfo` and a `AsyncConnectionConfig`.
    pub async fn new_with_config<C>(
        connection_info: &RedisConnectionInfo,
        stream: C,
        config: AsyncConnectionConfig,
    ) -> RedisResult<(Self, impl Future<Output = ()> + 'static)>
    where
        C: Unpin + AsyncRead + AsyncWrite + Send + 'static,
    {
        let mut codec = ValueCodec::default().framed(stream);
        if let Some(boundary) = config.write_backpressure_boundary {
            codec.set_backpressure_boundary(boundary);
        }
        if config.push_sender.is_some() {
            check_resp3!(
                connection_info.protocol,
                "Can only pass push sender to a connection using RESP3"
            );
        }

        #[cfg(feature = "cache-aio")]
        let cache_config = config.cache.as_ref().map(|cache| match cache {
            crate::client::Cache::Config(cache_config) => *cache_config,
            #[cfg(any(feature = "connection-manager", feature = "cluster-async"))]
            crate::client::Cache::Manager(cache_manager) => cache_manager.cache_config,
        });
        #[cfg(feature = "cache-aio")]
        let cache_manager_opt = config
            .cache
            .map(|cache| {
                check_resp3!(
                    connection_info.protocol,
                    "Can only enable client side caching in a connection using RESP3"
                );
                match cache {
                    crate::client::Cache::Config(cache_config) => {
                        Ok(CacheManager::new(cache_config))
                    }
                    #[cfg(any(feature = "connection-manager", feature = "cluster-async"))]
                    crate::client::Cache::Manager(cache_manager) => Ok(cache_manager),
                }
            })
            .transpose()?;

        #[cfg(feature = "token-based-authentication")]
        let mut connection_info = connection_info.clone();
        #[cfg(not(feature = "token-based-authentication"))]
        let connection_info = connection_info.clone();

        #[cfg(feature = "token-based-authentication")]
        if let Some(ref credentials_provider) = config.credentials_provider {
            // Retrieve the initial credentials from the provider and apply them to the connection info
            match credentials_provider.subscribe().next().await {
                Some(Ok(credentials)) => {
                    connection_info.username = Some(ArcStr::from(credentials.username));
                    connection_info.password = Some(ArcStr::from(credentials.password));
                }
                Some(Err(err)) => {
                    error!("Error while receiving credentials from stream: {err}");
                    return Err(err);
                }
                None => {
                    let err = RedisError::from((
                        ErrorKind::AuthenticationFailed,
                        "Credentials stream closed unexpectedly before yielding credentials!",
                    ));
                    error!("{err}");
                    return Err(err);
                }
            }
        }

        setup_connection(
            &mut codec,
            &connection_info,
            #[cfg(feature = "cache-aio")]
            cache_config,
        )
        .await?;
        if config.push_sender.is_some() {
            check_resp3!(
                connection_info.protocol,
                "Can only pass push sender to a connection using RESP3"
            );
        }

        let (pipeline, driver) = Pipeline::new(
            codec,
            config.push_sender,
            #[cfg(feature = "cache-aio")]
            cache_manager_opt.clone(),
            Pipeline::resolve_buffer_size(config.pipeline_buffer_size),
        );

        let concurrency_limiter = build_concurrency_limiter(config.concurrency_limit)?;

        let con = Self {
            pipeline,
            db: connection_info.db,
            response_timeout: config.response_timeout,
            protocol: connection_info.protocol,
            concurrency_limiter,
            _task_handle: None,
            #[cfg(feature = "cache-aio")]
            cache_manager: cache_manager_opt,
            #[cfg(feature = "token-based-authentication")]
            _credentials_subscription_task_handle: None,
        };

        // Set up streaming credentials subscription if provider is available
        #[cfg(feature = "token-based-authentication")]
        if let Some(streaming_provider) = config.credentials_provider {
            let mut inner_connection = con.clone();
            let mut stream = streaming_provider.subscribe();

            let subscription_task_handle = Runtime::locate().spawn(async move {
                while let Some(result) = stream.next().await {
                    match result {
                        Ok(credentials) => {
                            if let Err(err) = inner_connection
                                .re_authenticate_with_credentials(&credentials)
                                .await
                            {
                                if err.is_connection_dropped() {
                                    warn!(
                                        "Re-authentication task ended, connection is dead: {err}"
                                    );
                                    return;
                                }
                                error!("Failed to re-authenticate async connection: {err}.");
                                return;
                            } else {
                                debug!("Re-authenticated async connection");
                            }
                        }
                        Err(err) => {
                            error!("Credentials stream error for async connection: {err}.");
                        }
                    }
                }
                warn!("Credentials stream ended; no further re-authentication will occur.");
            });
            return Ok((
                Self {
                    _credentials_subscription_task_handle: Some(SharedHandleContainer::new(
                        subscription_task_handle,
                    )),
                    ..con
                },
                driver,
            ));
        }

        Ok((con, driver))
    }

    /// This should be called strictly before the multiplexed connection is cloned - that is, before it is returned to the user.
    /// Otherwise some clones will be able to kill the backing task, while other clones are still alive.
    pub(crate) fn set_task_handle(&mut self, handle: TaskHandle) {
        self._task_handle = Some(SharedHandleContainer::new(handle));
    }

    /// Sets the time that the multiplexer will wait for responses on operations before failing.
    pub fn set_response_timeout(&mut self, timeout: std::time::Duration) {
        self.response_timeout = Some(timeout);
    }

    /// Sends an already encoded (packed) command into the TCP socket and
    /// reads the single response from it.
    pub async fn send_packed_command(&mut self, cmd: &Cmd) -> RedisResult<Value> {
        let _permit = if cmd.skip_concurrency_limit {
            None
        } else if let Some(limiter) = &self.concurrency_limiter {
            Some(limiter.semaphore.acquire().await)
        } else {
            None
        };
        #[cfg(feature = "cache-aio")]
        if let Some(cache_manager) = &self.cache_manager {
            match cache_manager.get_cached_cmd(cmd) {
                PrepCacheItem::Cached(value) => return Ok(value),
                PrepCacheItem::NotCached(cacheable_command) => {
                    let mut pipeline = crate::Pipeline::new();
                    cacheable_command.pack_command(cache_manager, &mut pipeline);

                    let result = self
                        .pipeline
                        .send_recv(
                            pipeline.get_packed_pipeline(),
                            Some(PipelineResponseExpectation {
                                skipped_response_count: 0,
                                expected_response_count: pipeline.commands.len(),
                                is_transaction: false,
                                seen_responses: 0,
                            }),
                            self.response_timeout,
                            cmd.is_no_response(),
                        )
                        .await?;
                    let replies: Vec<Value> = crate::types::from_redis_value(result)?;
                    return cacheable_command.resolve(cache_manager, replies.into_iter());
                }
                PrepCacheItem::NotCacheable => (),
            }
        }
        self.pipeline
            .send_recv(
                cmd.get_packed_command(),
                None,
                self.response_timeout,
                cmd.is_no_response(),
            )
            .await
    }

    /// Sends multiple already encoded (packed) command into the TCP socket
    /// and reads `count` responses from it.  This is used to implement
    /// pipelining.
    pub async fn send_packed_commands(
        &mut self,
        cmd: &crate::Pipeline,
        offset: usize,
        count: usize,
    ) -> RedisResult<Vec<Value>> {
        // Try to acquire 1 permit per command in the pipeline: block on the first to guarantee
        // progress, then grab as many more as are immediately available without blocking.
        // This roughly reflects the pipeline's load on the server while avoiding deadlock --
        // a large pipeline can always proceed even if it can't acquire all permits.
        let _permits = if let Some(limiter) = &self.concurrency_limiter {
            let capacity = permit_vec_capacity(count, limiter.limit);
            let mut permits = Vec::with_capacity(capacity);
            permits.push(limiter.semaphore.acquire().await);
            for _ in 1..capacity {
                match limiter.semaphore.try_acquire() {
                    Some(permit) => permits.push(permit),
                    None => break,
                }
            }
            permits
        } else {
            Vec::new()
        };
        #[cfg(feature = "cache-aio")]
        if let Some(cache_manager) = &self.cache_manager {
            let (cacheable_pipeline, pipeline, (skipped_response_count, expected_response_count)) =
                cache_manager.get_cached_pipeline(cmd);
            if pipeline.is_empty() {
                return cacheable_pipeline.resolve(cache_manager, Value::Array(Vec::new()));
            }
            let result = self
                .pipeline
                .send_recv(
                    pipeline.get_packed_pipeline(),
                    Some(PipelineResponseExpectation {
                        skipped_response_count,
                        expected_response_count,
                        is_transaction: cacheable_pipeline.transaction_mode,
                        seen_responses: 0,
                    }),
                    self.response_timeout,
                    false,
                )
                .await?;

            return cacheable_pipeline.resolve(cache_manager, result);
        }
        let value = self
            .pipeline
            .send_recv(
                cmd.get_packed_pipeline(),
                Some(PipelineResponseExpectation {
                    skipped_response_count: offset,
                    expected_response_count: count,
                    is_transaction: cmd.is_transaction(),
                    seen_responses: 0,
                }),
                self.response_timeout,
                false,
            )
            .await?;
        match value {
            Value::Array(values) => Ok(values),
            _ => Ok(vec![value]),
        }
    }

    /// Gets [`CacheStatistics`] for current connection if caching is enabled.
    #[cfg(feature = "cache-aio")]
    #[cfg_attr(docsrs, doc(cfg(feature = "cache-aio")))]
    pub fn get_cache_statistics(&self) -> Option<CacheStatistics> {
        self.cache_manager.as_ref().map(|cm| cm.statistics())
    }
}

impl ConnectionLike for MultiplexedConnection {
    fn req_packed_command<'a>(&'a mut self, cmd: &'a Cmd) -> RedisFuture<'a, Value> {
        (async move { self.send_packed_command(cmd).await }).boxed()
    }

    fn req_packed_commands<'a>(
        &'a mut self,
        pipeline: &'a crate::Pipeline,
        offset: usize,
        count: usize,
    ) -> RedisFuture<'a, Vec<Value>> {
        (async move { self.send_packed_commands(pipeline, offset, count).await }).boxed()
    }

    fn get_db(&self) -> i64 {
        self.db
    }
}

impl MultiplexedConnection {
    /// Subscribes to a new channel(s).    
    ///
    /// Updates from the sender will be sent on the push sender that was passed to the connection.
    /// If the connection was configured without a push sender, the connection won't be able to pass messages back to the user.
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    ///
    /// ```rust,no_run
    /// # async fn func() -> redis::RedisResult<()> {
    /// let client = redis::Client::open("redis://127.0.0.1/?protocol=resp3").unwrap();
    /// let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    /// let config = redis::AsyncConnectionConfig::new().set_push_sender(tx);
    /// let mut con = client.get_multiplexed_async_connection_with_config(&config).await?;
    /// con.subscribe(&["channel_1", "channel_2"]).await?;
    /// # Ok(()) }
    /// ```
    pub async fn subscribe(&mut self, channel_name: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.protocol);
        let mut cmd = cmd("SUBSCRIBE");
        cmd.arg(channel_name);
        cmd.exec_async(self).await?;
        Ok(())
    }

    /// Unsubscribes from channel(s).
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    ///
    /// ```rust,no_run
    /// # async fn func() -> redis::RedisResult<()> {
    /// let client = redis::Client::open("redis://127.0.0.1/?protocol=resp3").unwrap();
    /// let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    /// let config = redis::AsyncConnectionConfig::new().set_push_sender(tx);
    /// let mut con = client.get_multiplexed_async_connection_with_config(&config).await?;
    /// con.subscribe(&["channel_1", "channel_2"]).await?;
    /// con.unsubscribe(&["channel_1", "channel_2"]).await?;
    /// # Ok(()) }
    /// ```
    pub async fn unsubscribe(&mut self, channel_name: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.protocol);
        let mut cmd = cmd("UNSUBSCRIBE");
        cmd.arg(channel_name);
        cmd.exec_async(self).await?;
        Ok(())
    }

    /// Subscribes to new channel(s) with pattern(s).
    ///
    /// Updates from the sender will be sent on the push sender that was passed to the connection.
    /// If the connection was configured without a push sender, the connection won't be able to pass messages back to the user.
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    ///
    /// ```rust,no_run
    /// # async fn func() -> redis::RedisResult<()> {
    /// let client = redis::Client::open("redis://127.0.0.1/?protocol=resp3").unwrap();
    /// let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    /// let config = redis::AsyncConnectionConfig::new().set_push_sender(tx);
    /// let mut con = client.get_multiplexed_async_connection_with_config(&config).await?;
    /// con.psubscribe("channel*_1").await?;
    /// con.psubscribe(&["channel*_2", "channel*_3"]).await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn psubscribe(&mut self, channel_pattern: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.protocol);
        let mut cmd = cmd("PSUBSCRIBE");
        cmd.arg(channel_pattern);
        cmd.exec_async(self).await?;
        Ok(())
    }

    /// Unsubscribes from channel pattern(s).
    ///
    /// This method is only available when the connection is using RESP3 protocol, and will return an error otherwise.
    pub async fn punsubscribe(&mut self, channel_pattern: impl ToRedisArgs) -> RedisResult<()> {
        check_resp3!(self.protocol);
        let mut cmd = cmd("PUNSUBSCRIBE");
        cmd.arg(channel_pattern);
        cmd.exec_async(self).await?;
        Ok(())
    }
}

#[cfg(feature = "token-based-authentication")]
impl MultiplexedConnection {
    /// Re-authenticate the connection with new credentials
    ///
    /// This method allows existing async connections to update their authentication
    /// when tokens are refreshed, enabling streaming credential updates.
    async fn re_authenticate_with_credentials(
        &mut self,
        credentials: &crate::auth::BasicAuth,
    ) -> RedisResult<()> {
        let mut auth_cmd =
            crate::connection::authenticate_cmd(Some(&credentials.username), &credentials.password);
        auth_cmd.skip_concurrency_limit = true;
        self.send_packed_command(&auth_cmd)
            .await?
            .extract_error()
            .map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pipeline_resolve_buffer_size_default() {
        assert_eq!(Pipeline::resolve_buffer_size(None), 50);
    }

    #[test]
    fn test_pipeline_resolve_buffer_size_custom() {
        assert_eq!(Pipeline::resolve_buffer_size(Some(100)), 100);
    }

    #[test]
    fn test_permit_vec_capacity_is_bounded_by_limit() {
        // Capacity tracks the limit, never the (unbounded) pipeline length.
        assert_eq!(permit_vec_capacity(1_000_000, 4), 4);
        assert_eq!(permit_vec_capacity(10, 10), 10);
        assert_eq!(permit_vec_capacity(2, 4), 2);
        assert_eq!(permit_vec_capacity(0, 4), 1);
        assert_eq!(permit_vec_capacity(5, 0), 1);
    }

    #[test]
    fn test_build_concurrency_limiter_rejects_zero() {
        // A zero-permit semaphore would deadlock every command on acquire.
        let err = build_concurrency_limiter(Some(0)).unwrap_err();
        assert_eq!(err.kind(), ErrorKind::InvalidClientConfig);
    }

    #[test]
    fn test_build_concurrency_limiter_allows_none_and_positive() {
        assert!(build_concurrency_limiter(None).unwrap().is_none());
        let limiter = build_concurrency_limiter(Some(4)).unwrap().unwrap();
        assert_eq!(limiter.limit, 4);
    }

    fn mock_conn_info() -> RedisConnectionInfo {
        RedisConnectionInfo {
            skip_set_lib_name: true,
            ..Default::default()
        }
    }

    async fn create_mock_connection(
        concurrency_limit: usize,
    ) -> (
        MultiplexedConnection,
        tokio::sync::mpsc::Receiver<()>,
        tokio::sync::mpsc::Sender<()>,
    ) {
        use futures_util::StreamExt;
        use tokio::io::AsyncWriteExt;
        use tokio_util::codec::FramedRead;

        let (client_half, server_half) = tokio::io::duplex(4096);
        let (cmd_received_tx, cmd_received_rx) = tokio::sync::mpsc::channel::<()>(10);
        let (send_response_tx, mut send_response_rx) = tokio::sync::mpsc::channel::<()>(10);

        let (server_read, mut server_write) = tokio::io::split(server_half);

        tokio::spawn(async move {
            let mut reader = FramedRead::new(server_read, ValueCodec::default());
            while let Some(Ok(_)) = reader.next().await {
                let _ = cmd_received_tx.send(()).await;
            }
        });

        tokio::spawn(async move {
            while send_response_rx.recv().await.is_some() {
                let _ = server_write.write_all(b"+OK\r\n").await;
                let _ = server_write.flush().await;
            }
        });

        let config = AsyncConnectionConfig::new()
            .set_concurrency_limit(concurrency_limit)
            .set_response_timeout(None)
            .set_connection_timeout(None);

        let (conn, driver) =
            MultiplexedConnection::new_with_config(&mock_conn_info(), client_half, config)
                .await
                .unwrap();
        tokio::spawn(driver);

        (conn, cmd_received_rx, send_response_tx)
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn test_concurrency_limit_enforced() {
        let (conn, mut cmd_received_rx, send_response_tx) = create_mock_connection(2).await;

        let h1 = tokio::spawn({
            let mut c = conn.clone();
            async move { c.send_packed_command(&cmd("PING")).await }
        });
        let h2 = tokio::spawn({
            let mut c = conn.clone();
            async move { c.send_packed_command(&cmd("PING")).await }
        });
        let h3 = tokio::spawn({
            let mut c = conn.clone();
            async move { c.send_packed_command(&cmd("PING")).await }
        });

        cmd_received_rx.recv().await.unwrap();
        cmd_received_rx.recv().await.unwrap();

        let third = tokio::time::timeout(Duration::from_millis(100), cmd_received_rx.recv()).await;
        assert!(
            third.is_err(),
            "3rd request should be blocked by concurrency limit"
        );

        send_response_tx.send(()).await.unwrap();

        cmd_received_rx.recv().await.unwrap();

        send_response_tx.send(()).await.unwrap();
        send_response_tx.send(()).await.unwrap();

        h1.await.unwrap().unwrap();
        h2.await.unwrap().unwrap();
        h3.await.unwrap().unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn test_no_limit_bypasses_concurrency_limit() {
        let (conn, mut cmd_received_rx, send_response_tx) = create_mock_connection(1).await;

        let h1 = tokio::spawn({
            let mut c = conn.clone();
            async move { c.send_packed_command(&cmd("PING")).await }
        });

        cmd_received_rx.recv().await.unwrap();

        let h2 = tokio::spawn({
            let mut c = conn.clone();
            async move {
                let mut ping = cmd("PING");
                ping.skip_concurrency_limit = true;
                c.send_packed_command(&ping).await
            }
        });

        let received =
            tokio::time::timeout(Duration::from_millis(100), cmd_received_rx.recv()).await;
        assert!(
            received.is_ok(),
            "no_limit request should bypass concurrency limit"
        );

        send_response_tx.send(()).await.unwrap();
        send_response_tx.send(()).await.unwrap();

        h1.await.unwrap().unwrap();
        h2.await.unwrap().unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn test_pipeline_acquires_multiple_permits() {
        let (conn, mut cmd_received_rx, send_response_tx) = create_mock_connection(3).await;

        let pipeline_handle = tokio::spawn({
            let mut c = conn.clone();
            async move {
                let mut pipe = crate::Pipeline::new();
                pipe.cmd("SET").arg("a").arg("1");
                pipe.cmd("SET").arg("b").arg("2");
                pipe.cmd("SET").arg("c").arg("3");
                c.send_packed_commands(&pipe, 0, 3).await
            }
        });

        for _ in 0..3 {
            cmd_received_rx.recv().await.unwrap();
        }

        let single_handle = tokio::spawn({
            let mut c = conn.clone();
            async move { c.send_packed_command(&cmd("PING")).await }
        });

        let blocked =
            tokio::time::timeout(Duration::from_millis(100), cmd_received_rx.recv()).await;
        assert!(
            blocked.is_err(),
            "single command should be blocked while pipeline holds all permits"
        );

        for _ in 0..3 {
            send_response_tx.send(()).await.unwrap();
        }

        cmd_received_rx.recv().await.unwrap();
        send_response_tx.send(()).await.unwrap();

        pipeline_handle.await.unwrap().unwrap();
        single_handle.await.unwrap().unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn test_pipeline_proceeds_with_partial_permits() {
        let (conn, mut cmd_received_rx, send_response_tx) = create_mock_connection(2).await;

        let single_handle = tokio::spawn({
            let mut c = conn.clone();
            async move { c.send_packed_command(&cmd("PING")).await }
        });
        cmd_received_rx.recv().await.unwrap();

        let pipeline_handle = tokio::spawn({
            let mut c = conn.clone();
            async move {
                let mut pipe = crate::Pipeline::new();
                for i in 0..5 {
                    pipe.cmd("SET").arg(format!("k{i}")).arg(i);
                }
                c.send_packed_commands(&pipe, 0, 5).await
            }
        });

        let received =
            tokio::time::timeout(Duration::from_millis(100), cmd_received_rx.recv()).await;
        assert!(
            received.is_ok(),
            "pipeline should proceed even with only partial permits"
        );

        for _ in 1..5 {
            cmd_received_rx.recv().await.unwrap();
        }

        for _ in 0..6 {
            send_response_tx.send(()).await.unwrap();
        }

        single_handle.await.unwrap().unwrap();
        pipeline_handle.await.unwrap().unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn test_permit_released_on_cancellation() {
        let (conn, mut cmd_received_rx, send_response_tx) = create_mock_connection(1).await;

        let h1 = tokio::spawn({
            let mut c = conn.clone();
            async move { c.send_packed_command(&cmd("PING")).await }
        });
        cmd_received_rx.recv().await.unwrap();

        // Start a second request that will block on the semaphore, then cancel it
        let h2 = tokio::spawn({
            let mut c = conn.clone();
            async move { c.send_packed_command(&cmd("PING")).await }
        });
        tokio::time::sleep(Duration::from_millis(50)).await;
        h2.abort();
        let _ = h2.await;

        // Complete the first request
        send_response_tx.send(()).await.unwrap();
        h1.await.unwrap().unwrap();

        // The permit from the cancelled request should have been released,
        // so a new request should proceed
        let h3 = tokio::spawn({
            let mut c = conn.clone();
            async move { c.send_packed_command(&cmd("PING")).await }
        });

        let received =
            tokio::time::timeout(Duration::from_millis(100), cmd_received_rx.recv()).await;
        assert!(
            received.is_ok(),
            "request after cancellation should acquire the permit"
        );

        send_response_tx.send(()).await.unwrap();
        h3.await.unwrap().unwrap();
    }

    /// Regression test for the TCP buffer deadlock reported in
    /// <https://github.com/redis-rs/redis-rs/issues/1955>.
    ///
    /// # Why this can deadlock
    ///
    /// A TCP buffer deadlock is a property of *both* peers — neither can
    /// produce it alone.
    ///
    /// **Client side (this bug):** `PipelineSink::poll_flush` polled the read
    /// half only *after* the underlying writer's flush returned Ready. When
    /// our TCP send buffer fills, the codec's flush is Pending, and we
    /// returned Pending without ever registering a read waker — so response
    /// bytes already sitting in our recv buffer were never polled. The driver
    /// task parked indefinitely.
    ///
    /// **Server side:** any server that stops reading from a client's
    /// socket while its own pending write to that client can't make
    /// forward progress is enough to trigger the deadlock. Combined with
    /// the client bug, both directions wedge: the client's send buffer
    /// can't drain (server isn't reading), the server's send buffer can't
    /// drain (client isn't reading because of the bug), and the state is
    /// permanent.
    ///
    /// # What this test simulates
    ///
    /// `tokio::io::duplex` stands in for a TCP socket pair with tiny
    /// kernel buffers. The mini-server is a loop that reads a request,
    /// writes a response, repeats — awaiting the write makes the loop
    /// stop reading the instant a write becomes Pending, which is the
    /// general server-side behavior described above.
    ///
    /// The test issues a few large concurrent SETs whose request payloads
    /// (and pretend responses) each exceed the duplex buffer in both
    /// directions. With the bug, the client's codec backs up, the
    /// server's writes back up, and both sides park without enough wakers
    /// to escape — the test times out and panics. With the fix, the
    /// driver drains responses even while the writer is back-pressured,
    /// which keeps the duplex moving and lets the SETs complete.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn test_deadlock_when_writes_blocked_with_pending_response() {
        use futures_util::StreamExt;
        use tokio::io::AsyncWriteExt;
        use tokio_util::codec::FramedRead;

        // Small duplex buffer + ~4 KiB request/response sizes. The polling
        // pathology doesn't depend on scale; a real socket would see the
        // same shape with tens of KiB of buffer and MB-scale payloads.
        const BUFFER_SIZE: usize = 256;
        const PAYLOAD_SIZE: usize = 4096;
        const REQUEST_COUNT: usize = 3;

        let (client_half, server_half) = tokio::io::duplex(BUFFER_SIZE);
        let (server_read, mut server_write) = tokio::io::split(server_half);

        // Pretend response: a bulk string the same size as the request
        // payload, so server-bound writes also exceed the duplex buffer
        // (the server's write pends and its loop stops reading).
        let mut response = Vec::with_capacity(PAYLOAD_SIZE + 16);
        response.extend_from_slice(format!("${PAYLOAD_SIZE}\r\n").as_bytes());
        response.extend(std::iter::repeat_n(b'V', PAYLOAD_SIZE));
        response.extend_from_slice(b"\r\n");

        // Mini-server: read a request, write a response, loop. Awaiting
        // the write makes the loop stop reading the instant a write
        // becomes Pending — the general "server stops reading once its
        // own write is back-pressured" behavior the deadlock requires.
        let server_task = tokio::spawn(async move {
            let mut reader = FramedRead::new(server_read, ValueCodec::default());
            loop {
                match reader.next().await {
                    Some(Ok(_)) => {}
                    _ => return,
                }
                if server_write.write_all(&response).await.is_err() {
                    return;
                }
            }
        });

        let config = AsyncConnectionConfig::new()
            .set_response_timeout(None)
            .set_connection_timeout(None);
        let (conn, driver) =
            MultiplexedConnection::new_with_config(&mock_conn_info(), client_half, config)
                .await
                .unwrap();
        let driver_handle = tokio::spawn(driver);

        // A handful of concurrent large SETs. Each request exceeds the
        // duplex buffer (codec's flush stays backed up); each reply also
        // exceeds the duplex buffer (server's write stays backed up). Both
        // directions wedge.
        let mut handles = Vec::with_capacity(REQUEST_COUNT);
        for i in 0..REQUEST_COUNT {
            let mut c = conn.clone();
            handles.push(tokio::spawn(async move {
                let mut set = cmd("SET");
                set.arg(format!("k{i}")).arg(vec![b'X'; PAYLOAD_SIZE]);
                c.send_packed_command(&set).await
            }));
        }

        let join_all = async move {
            let mut results = Vec::with_capacity(handles.len());
            for h in handles {
                results.push(h.await);
            }
            results
        };

        let outcome = tokio::time::timeout(Duration::from_secs(5), join_all).await;

        // Clean up before asserting so a panic doesn't leak tasks.
        driver_handle.abort();
        server_task.abort();

        let results = outcome.expect(
            "DEADLOCK reproduced: client driver parked in poll_flush with no \
             read waker registered. Server has buffered responses in the duplex \
             and stopped reading once its own write became Pending; the client \
             cannot send the rest of its requests because the server is no \
             longer draining the link. Both sides wedged.",
        );
        for (i, res) in results.into_iter().enumerate() {
            let join = res.unwrap_or_else(|e| panic!("SET task {i} panicked: {e}"));
            join.unwrap_or_else(|e| panic!("SET task {i} returned an error: {e}"));
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn test_permit_released_on_response_timeout() {
        use futures_util::StreamExt;
        use tokio::io::AsyncWriteExt;
        use tokio_util::codec::FramedRead;

        let (client_half, server_half) = tokio::io::duplex(4096);
        let (cmd_received_tx, mut cmd_received_rx) = tokio::sync::mpsc::channel::<()>(10);

        let (server_read, mut server_write) = tokio::io::split(server_half);

        tokio::spawn(async move {
            let mut reader = FramedRead::new(server_read, ValueCodec::default());
            while let Some(Ok(_)) = reader.next().await {
                let _ = cmd_received_tx.send(()).await;
            }
        });

        tokio::spawn(async move {
            futures_util::future::pending::<()>().await;
            let _ = server_write.write_all(b"").await;
        });

        let config = AsyncConnectionConfig::new()
            .set_concurrency_limit(1)
            .set_response_timeout(Some(Duration::from_millis(100)))
            .set_connection_timeout(None);

        let (conn, driver) =
            MultiplexedConnection::new_with_config(&mock_conn_info(), client_half, config)
                .await
                .unwrap();
        tokio::spawn(driver);

        // First request times out since the mock never responds
        let mut c1 = conn.clone();
        let err = c1.send_packed_command(&cmd("PING")).await.unwrap_err();
        assert!(err.is_io_error(), "expected IO error from timeout");
        cmd_received_rx.recv().await.unwrap();

        // Second request should acquire the permit released by the first,
        // reach the server, and then also time out
        let mut c2 = conn.clone();
        let err = c2.send_packed_command(&cmd("PING")).await.unwrap_err();
        assert!(err.is_io_error(), "expected IO error from timeout");
        cmd_received_rx.recv().await.unwrap();
    }
}
