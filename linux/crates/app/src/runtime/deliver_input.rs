/// Send a component its input without panicking once it has shut down.
///
/// relm4's `ComponentSender::input` and `FactorySender::input` call
/// `expect` on a closed channel, and a window can close while a read or
/// a save it started is still on its way back, which would take every
/// other window down with it. The message is dropped instead.
pub trait DeliverInput<M> {
    fn deliver(&self, message: M);
}

impl<M> DeliverInput<M> for relm4::Sender<M> {
    fn deliver(&self, message: M) {
        if self.send(message).is_err() {
            tracing::debug!(target: "component", "message dropped after component shutdown");
        }
    }
}

impl<C: relm4::Component> DeliverInput<C::Input> for relm4::ComponentSender<C> {
    fn deliver(&self, message: C::Input) {
        self.input_sender().deliver(message);
    }
}

impl<C: relm4::factory::FactoryComponent> DeliverInput<C::Input> for relm4::FactorySender<C> {
    fn deliver(&self, message: C::Input) {
        self.input_sender().deliver(message);
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
}
