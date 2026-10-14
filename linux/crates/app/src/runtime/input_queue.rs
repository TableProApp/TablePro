use gtk4::glib;
use gtk4::glib::prelude::*;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};

use super::{DeliverInput, Delivery};

/// What a widget's actions, signal handlers and background work send it.
/// It is `Send`, so a task on the runtime can answer through it.
pub type InputSender<M> = UnboundedSender<M>;

pub fn input_queue<M>() -> (InputSender<M>, UnboundedReceiver<M>) {
    tokio::sync::mpsc::unbounded_channel()
}

/// Hand each message `object` receives to `handle`, one at a time and in
/// order, on the GTK thread, until the returned handle is aborted or
/// `object` is gone.
///
/// Handling waits for the main loop rather than running inside whatever
/// sent the message, so a signal handler or an action never re-enters
/// the widget while it is in the middle of handling another message.
pub fn pump_inputs<T, M>(
    object: &T,
    receiver: UnboundedReceiver<M>,
    handle: impl Fn(&T, M) + 'static,
) -> glib::JoinHandle<()>
where
    T: IsA<glib::Object>,
    M: 'static,
{
    pump_inputs_with_leftovers(object, receiver, handle, drop)
}

/// As [`pump_inputs`], and once the pump stops, aborted or with `object`
/// gone, every message still queued goes to `leftover` rather than being
/// dropped, for one that owns something that has to be closed.
pub fn pump_inputs_with_leftovers<T, M>(
    object: &T,
    receiver: UnboundedReceiver<M>,
    handle: impl Fn(&T, M) + 'static,
    leftover: impl FnMut(M) + 'static,
) -> glib::JoinHandle<()>
where
    T: IsA<glib::Object>,
    M: 'static,
{
    let weak = object.downgrade();
    let mut queue = Leftovers { receiver, leftover };
    glib::spawn_future_local(async move {
        while let Some(message) = queue.receiver.recv().await {
            let Some(object) = weak.upgrade() else {
                (queue.leftover)(message);
                return;
            };
            handle(&object, message);
        }
    })
}

/// The pump's end of the queue. It drains when the pump's future drops.
struct Leftovers<M, F: FnMut(M)> {
    receiver: UnboundedReceiver<M>,
    leftover: F,
}

impl<M, F: FnMut(M)> Drop for Leftovers<M, F> {
    fn drop(&mut self) {
        // Closed first, so a sender gets its message back instead of
        // adding to a queue nobody reads.
        self.receiver.close();
        while let Ok(message) = self.receiver.try_recv() {
            (self.leftover)(message);
        }
    }
}

/// A relm4 sender whose messages land in `input`, for a relm4 child that
/// can only forward its output to one. Abort the handle with the widget
/// that owns `input`.
pub fn relm4_bridge<M: 'static>(input: InputSender<M>) -> (relm4::Sender<M>, glib::JoinHandle<()>) {
    let (sender, receiver) = relm4::channel::<M>();
    let forwarding = glib::spawn_future_local(async move {
        while let Some(message) = receiver.recv().await {
            if input.try_deliver(message) == Delivery::ReceiverGone {
                return;
            }
        }
    });
    (sender, forwarding)
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use super::*;
    use crate::test_support::drain_main_context;

    #[gtk4::test]
    fn messages_are_handled_in_order_after_the_sender_returns() {
        let object = glib::Object::new::<glib::Object>();
        let (sender, receiver) = input_queue::<u8>();
        let seen = Rc::new(RefCell::new(Vec::new()));
        let sink = seen.clone();
        let pump = pump_inputs(&object, receiver, move |_, message| sink.borrow_mut().push(message));

        sender.deliver(1);
        sender.deliver(2);
        assert!(seen.borrow().is_empty(), "handled inside the send");
        drain_main_context();

        assert_eq!(*seen.borrow(), [1, 2]);
        pump.abort();
    }

    #[gtk4::test]
    fn an_aborted_pump_leaves_the_sender_with_no_receiver() {
        let object = glib::Object::new::<glib::Object>();
        let (sender, receiver) = input_queue::<u8>();
        let pump = pump_inputs(&object, receiver, |_, _| {});

        // The handle holds the task's source, and with it the receiver,
        // until it is dropped too.
        pump.abort();
        drop(pump);
        drain_main_context();

        assert_eq!(sender.try_deliver(1), Delivery::ReceiverGone);
    }

    #[gtk4::test]
    fn messages_still_queued_when_the_pump_stops_go_to_leftover() {
        let object = glib::Object::new::<glib::Object>();
        let (sender, receiver) = input_queue::<u8>();
        let (handled, left) = (Rc::new(RefCell::new(Vec::new())), Rc::new(RefCell::new(Vec::new())));
        let (handled_sink, left_sink) = (handled.clone(), left.clone());
        let pump = pump_inputs_with_leftovers(
            &object,
            receiver,
            move |_, message| handled_sink.borrow_mut().push(message),
            move |message| left_sink.borrow_mut().push(message),
        );
        sender.deliver(1);
        drain_main_context();

        sender.deliver(2);
        sender.deliver(3);
        pump.abort();
        drop(pump);
        drain_main_context();

        assert_eq!(*handled.borrow(), [1]);
        assert_eq!(*left.borrow(), [2, 3]);
        assert_eq!(sender.try_deliver(4), Delivery::ReceiverGone);
        assert_eq!(
            *left.borrow(),
            [2, 3],
            "a message sent after the pump stopped was taken"
        );
    }

    #[gtk4::test]
    fn a_bridge_forwards_until_its_target_is_gone() {
        let (input, mut receiver) = input_queue::<u8>();
        let (bridge, _forwarding) = relm4_bridge(input);

        bridge.deliver(3);
        drain_main_context();
        assert_eq!(receiver.try_recv().ok(), Some(3));

        drop(receiver);
        bridge.deliver(4);
        drain_main_context();
        assert_eq!(bridge.try_deliver(5), Delivery::ReceiverGone);
    }
}
