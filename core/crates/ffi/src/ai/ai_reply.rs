use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use tablepro_ai::{ReplyEnd, ReplyEvent};
use tokio_util::sync::CancellationToken;

use super::AiStopTag;
use crate::error::{BoxedErrorInfo, CoreError};

// In order: text as it arrives, then one of Finished, Failed or Stopped.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AiReplyEvent {
    // `part` and not `text`, since C# cannot give a record a member of its own name.
    Text {
        part: String,
    },
    Finished {
        stop: AiStopTag,
        input_tokens: Option<u64>,
        output_tokens: Option<u64>,
    },
    Failed {
        error: BoxedErrorInfo,
    },
    // Cancelled before it ended.
    Stopped,
}

impl From<ReplyEnd> for AiReplyEvent {
    fn from(end: ReplyEnd) -> Self {
        Self::Finished {
            stop: end.stop.into(),
            input_tokens: end.usage.input_tokens,
            output_tokens: end.usage.output_tokens,
        }
    }
}

impl From<ReplyEvent> for AiReplyEvent {
    fn from(event: ReplyEvent) -> Self {
        match event {
            ReplyEvent::Text(part) => Self::Text { part },
            ReplyEvent::Finished(end) => end.into(),
            ReplyEvent::Failed(error) => Self::failed(error.into()),
        }
    }
}

impl AiReplyEvent {
    pub(crate) fn failed(error: CoreError) -> Self {
        Self::Failed {
            error: error.into_info(),
        }
    }

    fn ends(&self) -> bool {
        !matches!(self, Self::Text { .. })
    }
}

// Told that events are waiting, on a runtime thread. It only schedules a drain on the app's own thread.
#[uniffi::export(callback_interface)]
pub trait AiReplyListener: Send + Sync {
    fn events_pending(&self);
}

// The app's handle on a reply on its way. Dropping it stops the reply.
#[derive(uniffi::Object)]
pub struct AiReply {
    state: Arc<ReplyState>,
}

// What the reply's task posts into and the app drains. A drain clears the pending wake before it takes the queue,
// so no event is lost and a busy app is woken once.
pub(crate) struct ReplyState {
    listener: Box<dyn AiReplyListener>,
    queue: Mutex<Queue>,
    wake_pending: AtomicBool,
    pub(crate) cancel: CancellationToken,
}

#[derive(Default)]
struct Queue {
    events: Vec<AiReplyEvent>,
    ended: bool,
}

impl AiReply {
    pub(crate) fn new(listener: Box<dyn AiReplyListener>) -> Self {
        Self {
            state: Arc::new(ReplyState {
                listener,
                queue: Mutex::new(Queue::default()),
                wake_pending: AtomicBool::new(false),
                cancel: CancellationToken::new(),
            }),
        }
    }

    pub(crate) fn state(&self) -> Arc<ReplyState> {
        self.state.clone()
    }
}

impl ReplyState {
    // Called on a runtime thread. Text that arrives while the app is busy joins the text it has not read.
    pub(crate) fn post(&self, event: AiReplyEvent) {
        {
            let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
            if queue.ended {
                return;
            }
            queue.ended = event.ends();
            match (queue.events.last_mut(), event) {
                (Some(AiReplyEvent::Text { part }), AiReplyEvent::Text { part: more }) => part.push_str(&more),
                (_, event) => queue.events.push(event),
            }
        }
        self.wake();
    }

    // Outside the lock. UniFFI panics when the app's callback throws, which loses this wake and not the reply.
    fn wake(&self) {
        if self.wake_pending.swap(true, Ordering::AcqRel) {
            return;
        }
        if catch_unwind(AssertUnwindSafe(|| self.listener.events_pending())).is_err() {
            tracing::warn!("the app's reply listener failed, so it was not told about waiting events");
        }
    }

    fn drain(&self) -> Vec<AiReplyEvent> {
        self.wake_pending.store(false, Ordering::Release);
        std::mem::take(&mut self.queue.lock().unwrap_or_else(PoisonError::into_inner).events)
    }
}

#[uniffi::export]
impl AiReply {
    // Every event since the last drain, which also acknowledges the wake.
    pub fn drain_events(&self) -> Vec<AiReplyEvent> {
        self.state.drain()
    }

    pub fn cancel(&self) {
        self.state.cancel.cancel();
    }
}

impl Drop for AiReply {
    fn drop(&mut self) {
        self.state.cancel.cancel();
    }
}

impl std::fmt::Debug for AiReply {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AiReply").finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicUsize;

    use super::*;

    #[derive(Default)]
    struct Count(Arc<AtomicUsize>);

    impl AiReplyListener for Count {
        fn events_pending(&self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn text(text: &str) -> AiReplyEvent {
        AiReplyEvent::Text { part: text.to_owned() }
    }

    #[test]
    fn text_the_app_has_not_read_comes_as_one_event_and_wakes_it_once() {
        let wakes = Arc::new(AtomicUsize::new(0));
        let reply = AiReply::new(Box::new(Count(wakes.clone())));
        let state = reply.state();

        state.post(text("SELECT "));
        state.post(text("1"));
        let first = reply.drain_events();
        state.post(text(";"));
        state.post(AiReplyEvent::Stopped);
        let second = reply.drain_events();

        assert_eq!(first, [text("SELECT 1")]);
        assert_eq!(second, [text(";"), AiReplyEvent::Stopped]);
        assert_eq!(wakes.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn nothing_follows_the_event_that_ends_a_reply() {
        let reply = AiReply::new(Box::new(Count::default()));
        let state = reply.state();

        state.post(AiReplyEvent::Stopped);
        state.post(text("late"));
        state.post(AiReplyEvent::Stopped);

        assert_eq!(reply.drain_events(), [AiReplyEvent::Stopped]);
    }

    #[test]
    fn dropping_the_handle_stops_the_reply() {
        let reply = AiReply::new(Box::new(Count::default()));
        let state = reply.state();

        drop(reply);

        assert!(state.cancel.is_cancelled());
    }
}
