use std::{pin::Pin, task::Poll};

use futures_core::Future;

/// A message type that includes an acknowledgement mechanism.
/// When this is dropped or `acknowledge` is called, the sender will be notified.
#[derive(Debug)]
pub(crate) struct AcknowledgedMessage<M, R = ()> {
    acknowledger: AcknowledgmentSender<R>,
    message: M,
}

impl<M, R> AcknowledgedMessage<M, R> {
    /// Create a new message and return it along with the AcknowledgmentReceiver that will
    /// be notified when the message is received or when it is dropped.
    pub(crate) fn package(message: M) -> (Self, AcknowledgmentReceiver<R>) {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        (
            Self {
                message,
                acknowledger: AcknowledgmentSender { sender },
            },
            AcknowledgmentReceiver { receiver },
        )
    }

    /// Send acknowledgement to the receiver.
    pub(crate) fn acknowledge(self, result: impl Into<R>) {
        self.acknowledger.acknowledge(result)
    }

    pub(crate) fn into_parts(self) -> (M, AcknowledgmentSender<R>) {
        (self.message, self.acknowledger)
    }
}

impl<M, R> std::ops::Deref for AcknowledgedMessage<M, R> {
    type Target = M;

    fn deref(&self) -> &Self::Target {
        &self.message
    }
}

#[derive(Debug)]
pub(crate) struct AcknowledgmentSender<R> {
    sender: tokio::sync::oneshot::Sender<R>,
}

impl<R> AcknowledgmentSender<R> {
    /// Send acknowledgement to the receiver.
    pub(crate) fn acknowledge(self, result: impl Into<R>) {
        // returns an error when the other end hangs up e.g. due to a timeout.
        let _: std::result::Result<_, _> = self.sender.send(result.into());
    }
}

/// Receiver for the acknowledgement that the message was received or dropped.
pub(crate) struct AcknowledgmentReceiver<R> {
    receiver: tokio::sync::oneshot::Receiver<R>,
}

impl<R> AcknowledgmentReceiver<R> {
    /// Wait for the message to be acknowledged. If this returns None, that means the message
    /// was dropped without the receiving end explicitly sending anything back.
    pub(crate) async fn wait_for_acknowledgment(self) -> Option<R> {
        self.receiver.await.ok()
    }
}

impl<R> Future for AcknowledgmentReceiver<R> {
    type Output = Option<R>;

    fn poll(self: std::pin::Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> Poll<Self::Output> {
        Pin::new(&mut self.get_mut().receiver)
            .poll(cx)
            .map(Result::ok)
    }
}
