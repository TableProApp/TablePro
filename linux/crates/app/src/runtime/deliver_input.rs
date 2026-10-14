/// Whether a message reached the component it was sent to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Delivery {
    Delivered,
    /// The component has shut down, so the message was dropped.
    ReceiverGone,
}

/// Send a component its input without panicking once it has shut down.
///
/// relm4's `ComponentSender::input` and `FactorySender::input` call
/// `expect` on a closed channel, and a window can close while a read or
/// a save it started is still on its way back, which would take every
/// other window down with it. The message is dropped instead.
pub trait DeliverInput<M> {
    fn try_deliver(&self, message: M) -> Delivery;

    fn deliver(&self, message: M) {
        if self.try_deliver(message) == Delivery::ReceiverGone {
            tracing::debug!(target: "component", "message dropped after component shutdown");
        }
    }
}

impl<M> DeliverInput<M> for relm4::Sender<M> {
    fn try_deliver(&self, message: M) -> Delivery {
        match self.send(message) {
            Ok(()) => Delivery::Delivered,
            Err(_) => Delivery::ReceiverGone,
        }
    }
}

impl<C: relm4::Component> DeliverInput<C::Input> for relm4::ComponentSender<C> {
    fn try_deliver(&self, message: C::Input) -> Delivery {
        self.input_sender().try_deliver(message)
    }
}

impl<C: relm4::factory::FactoryComponent> DeliverInput<C::Input> for relm4::FactorySender<C> {
    fn try_deliver(&self, message: C::Input) -> Delivery {
        self.input_sender().try_deliver(message)
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
    fn a_message_to_a_live_receiver_arrives() {
        let (sender, receiver) = relm4::channel::<u8>();

        sender.deliver(7);

        assert_eq!(receiver.recv_sync(), Some(7));
    }

    #[test]
    fn a_message_after_shutdown_is_dropped_without_panicking() {
        let (sender, receiver) = relm4::channel::<u8>();
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
