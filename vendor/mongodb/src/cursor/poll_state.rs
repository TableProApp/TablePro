use std::task::{Context, Poll};

use derive_where::derive_where;
use futures_util::FutureExt;

use crate::{
    error::{Error, Result},
    BoxFuture,
};

/// Message used if the state is accessed while a step is in progress.
const STREAMING_ERR: &str = "cursor state access while streaming";

/// The state of an "introspectable" async stream
#[derive_where(Debug; S)]
pub(crate) enum PollState<'a, S, O> {
    Idle(S),
    Running(#[derive_where(skip)] BoxFuture<'a, (S, O)>),
    Polling,
}

impl<'a, S, O> PollState<'a, S, O> {
    pub(crate) fn new(state: S) -> Self {
        Self::Idle(state)
    }

    pub(crate) fn state(&self) -> Result<&S> {
        match self {
            Self::Idle(state) => Ok(state),
            _ => Err(Error::internal(STREAMING_ERR)),
        }
    }

    pub(crate) fn state_mut(&mut self) -> Result<&mut S> {
        match self {
            Self::Idle(state) => Ok(state),
            _ => Err(Error::internal(STREAMING_ERR)),
        }
    }

    pub(crate) fn into_state(self) -> Result<S> {
        match self {
            Self::Idle(state) => Ok(state),
            _ => Err(Error::internal(STREAMING_ERR)),
        }
    }

    pub(crate) fn take_state(&mut self) -> Option<S> {
        match std::mem::replace(self, Self::Polling) {
            Self::Idle(state) => Some(state),
            _ => None,
        }
    }

    /// Drive the machine as a [`futures_core::Stream::poll_next`].
    /// * `start` builds the future for the Idle -> Running state transition.
    /// * `finish` turns that future's output into a stream item, with `None` ending the stream.
    pub(crate) fn poll_next_step<T>(
        &mut self,
        cx: &mut Context<'_>,
        mut start: impl FnMut(S) -> BoxFuture<'a, (S, O)>,
        mut finish: impl FnMut(&mut S, O) -> Option<Result<T>>,
    ) -> Poll<Option<Result<T>>> {
        loop {
            match std::mem::replace(self, Self::Polling) {
                Self::Idle(state) => {
                    *self = Self::Running(start(state));
                    continue;
                }
                Self::Running(mut future) => match future.poll_unpin(cx) {
                    Poll::Pending => {
                        *self = Self::Running(future);
                        return Poll::Pending;
                    }
                    Poll::Ready((mut state, out)) => {
                        let item = finish(&mut state, out);
                        *self = Self::Idle(state);
                        return Poll::Ready(item);
                    }
                },
                Self::Polling => {
                    return Poll::Ready(Some(Err(Error::internal(
                        "attempt to poll stream already in polling state",
                    ))))
                }
            }
        }
    }
}

/// Various public API methods downstream of `PollState` accessors require infallibility; this makes
/// them more searchable than a raw `unwrap`.
macro_rules! poll_panic {
    ($r:expr) => {
        $r.unwrap()
    };
}
pub(crate) use poll_panic;
