use std::{collections::VecDeque, task::Poll};

use derive_where::derive_where;
use futures_core::Stream as AsyncStream;
use futures_util::{stream::StreamExt, FutureExt};
use serde::{de::DeserializeOwned, Deserialize};

use crate::{
    bson::{RawDocument, RawDocumentBuf},
    error::{Error, Result},
};

use super::{poll_state::PollState, raw_batch::RawBatch};

/// `Stream` represents an "introspectable" cursor stream - an implementation of an async `Stream`
/// with a buffer that's available for external use when the stream isn't actively being polled.
///
/// If the buffer *is* queried during a poll, it will cause a panic.  This will only happen if a
/// future is dropped without being fully polled, which is documented as unsupported by the driver.
#[derive_where(Debug)]
pub(super) struct Stream<'a, Raw, T> {
    state: PollState<'a, BatchBuffer<Raw>, Result<bool>>,
    _phantom: std::marker::PhantomData<fn() -> T>,
}

impl<'a, Raw, T> Stream<'a, Raw, T> {
    pub(super) fn new(raw: Raw) -> Self {
        Self::from_cursor(BatchBuffer::new(raw))
    }

    pub(super) fn from_cursor(cs: BatchBuffer<Raw>) -> Self {
        Self {
            state: PollState::new(cs),
            _phantom: std::marker::PhantomData,
        }
    }

    pub(super) fn buffer(&self) -> Result<&BatchBuffer<Raw>> {
        self.state.state()
    }

    pub(super) fn buffer_mut(&mut self) -> Result<&mut BatchBuffer<Raw>> {
        self.state.state_mut()
    }

    pub(super) fn take_buffer(&mut self) -> Option<BatchBuffer<Raw>> {
        self.state.take_state()
    }

    pub(super) fn with_type<D>(self) -> Stream<'a, Raw, D> {
        Stream {
            state: self.state,
            _phantom: std::marker::PhantomData,
        }
    }
}

#[derive_where(Debug)]
pub(super) struct BatchBuffer<Raw> {
    #[derive_where(skip)]
    pub(super) raw: Raw,
    batch: VecDeque<RawDocumentBuf>,
}

impl<Raw> BatchBuffer<Raw> {
    pub(super) fn new(raw: Raw) -> Self {
        Self {
            raw,
            batch: VecDeque::new(),
        }
    }

    pub(super) fn current(&self) -> &RawDocument {
        self.batch.front().unwrap()
    }

    pub(super) fn deserialize_current<'a, V>(&'a self) -> Result<V>
    where
        V: Deserialize<'a>,
    {
        crate::bson_compat::deserialize_from_slice(self.current().as_bytes()).map_err(Error::from)
    }

    pub(super) fn map<G>(self, f: impl FnOnce(Raw) -> G) -> BatchBuffer<G> {
        BatchBuffer {
            raw: f(self.raw),
            batch: self.batch,
        }
    }

    pub(crate) fn batch(&self) -> &VecDeque<RawDocumentBuf> {
        &self.batch
    }
}

impl<Raw: AsyncStream<Item = Result<RawBatch>> + Unpin> BatchBuffer<Raw> {
    /// Attempt to advance the cursor forward to the next item. If there are no items cached
    /// locally, perform getMores until the cursor is exhausted or the buffer has been refilled.
    /// Return whether or not the cursor has been advanced.
    pub(super) async fn advance(&mut self) -> Result<bool> {
        loop {
            match self.try_advance().await? {
                AdvanceResult::Advanced(_) => return Ok(true),
                AdvanceResult::Exhausted => return Ok(false),
                AdvanceResult::Waiting => continue,
            }
        }
    }

    /// Attempt to advance the cursor forward to the next item. If there are no items cached
    /// locally, perform a single getMore to attempt to retrieve more.
    pub(crate) async fn try_advance(&mut self) -> Result<AdvanceResult> {
        // Next stored batch item
        self.batch.pop_front();
        if !self.batch.is_empty() {
            return Ok(AdvanceResult::Advanced(()));
        }

        // Batch is empty, need a new one
        let Some(raw_batch) = self.raw.next().await else {
            return Ok(AdvanceResult::Exhausted);
        };
        let raw_batch = raw_batch?;
        for item in raw_batch.doc_slices()? {
            self.batch.push_back(
                item?
                    .as_document()
                    .ok_or_else(|| Error::invalid_response("invalid cursor batch item"))?
                    .to_owned(),
            );
        }
        Ok(if self.batch.is_empty() {
            AdvanceResult::Waiting
        } else {
            AdvanceResult::Advanced(())
        })
    }
}

/// The result of one attempt to advance a cursor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AdvanceResult<T = ()> {
    /// The cursor was successfully advanced and the buffer has at least one item.
    Advanced(T),
    /// The cursor does not have any more items and will not return any more in the future.
    Exhausted,
    /// The cursor does not currently have any items, but future calls to getMore may yield more.
    Waiting,
}

impl<T> AdvanceResult<T> {
    pub(crate) fn map<U>(self, f: impl FnOnce(T) -> U) -> AdvanceResult<U> {
        match self {
            Self::Advanced(t) => AdvanceResult::Advanced(f(t)),
            Self::Exhausted => AdvanceResult::Exhausted,
            Self::Waiting => AdvanceResult::Waiting,
        }
    }

    pub(crate) fn into_option(self) -> Option<T> {
        match self {
            Self::Advanced(t) => Some(t),
            Self::Exhausted | Self::Waiting => None,
        }
    }
}

impl<T, E> AdvanceResult<std::result::Result<T, E>> {
    pub(crate) fn transpose(self) -> std::result::Result<AdvanceResult<T>, E> {
        match self {
            Self::Advanced(rt) => rt.map(AdvanceResult::Advanced),
            Self::Exhausted => Ok(AdvanceResult::Exhausted),
            Self::Waiting => Ok(AdvanceResult::Waiting),
        }
    }
}

impl<'a, Raw: 'a + AsyncStream<Item = Result<RawBatch>> + Send + Unpin, T: DeserializeOwned>
    AsyncStream for Stream<'a, Raw, T>
{
    type Item = Result<T>;

    fn poll_next(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> Poll<Option<Self::Item>> {
        self.state.poll_next_step(
            cx,
            |mut buffer| {
                async move {
                    let out = buffer.advance().await;
                    (buffer, out)
                }
                .boxed()
            },
            |buffer, out| match out {
                Err(e) => Some(Err(e)),
                Ok(false) => None,
                Ok(true) => Some(buffer.deserialize_current()),
            },
        )
    }
}
