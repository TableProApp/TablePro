/// Whether a message reached the component it was sent to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Delivery {
    Delivered,
    /// The component has shut down, so the message was dropped.
    ReceiverGone,
}

/// Send a view its input whether or not it has shut down: a window can
/// close while a read or a save it started is still on its way back.
pub trait DeliverInput<M> {
    fn try_deliver(&self, message: M) -> Delivery;

    fn deliver(&self, message: M) {
        if self.try_deliver(message) == Delivery::ReceiverGone {
            tracing::debug!(target: "component", "message dropped after component shutdown");
        }
    }
}

impl<M> DeliverInput<M> for tokio::sync::mpsc::UnboundedSender<M> {
    fn try_deliver(&self, message: M) -> Delivery {
        match self.send(message) {
            Ok(()) => Delivery::Delivered,
            Err(_) => Delivery::ReceiverGone,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_message_after_shutdown_is_dropped_without_panicking() {
        let (sender, receiver) = tokio::sync::mpsc::unbounded_channel::<u8>();
        drop(receiver);

        sender.deliver(7);
    }

    #[test]
    fn deliver_to_dropped_receiver_reports_receiver_gone() {
        let (sender, receiver) = tokio::sync::mpsc::unbounded_channel::<u8>();
        assert_eq!(sender.try_deliver(1), Delivery::Delivered);

        drop(receiver);

        assert_eq!(sender.try_deliver(2), Delivery::ReceiverGone);
    }
}
