use gtk4::glib;
use gtk4::glib::prelude::*;

/// A handler on an object that outlives the widget that connected it,
/// such as the style manager or the settings. The object never drops
/// the handler on its own, so the widget holds this and the handler
/// goes with it.
pub(crate) struct HandlerGuard {
    object: glib::WeakRef<glib::Object>,
    handler: Option<glib::SignalHandlerId>,
}

impl HandlerGuard {
    pub(crate) fn new(object: &impl IsA<glib::Object>, handler: glib::SignalHandlerId) -> Self {
        Self {
            object: object.upcast_ref::<glib::Object>().downgrade(),
            handler: Some(handler),
        }
    }
}

impl Drop for HandlerGuard {
    fn drop(&mut self) {
        if let (Some(object), Some(handler)) = (self.object.upgrade(), self.handler.take()) {
            object.disconnect(handler);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use gtk4::gio;
    use gtk4::gio::prelude::*;

    use super::*;

    #[test]
    fn dropping_the_guard_disconnects_the_handler() {
        let action = gio::SimpleAction::new("probe", None);
        let calls = Rc::new(Cell::new(0));
        let counter = calls.clone();
        let guard = HandlerGuard::new(
            &action,
            action.connect_enabled_notify(move |_| counter.set(counter.get() + 1)),
        );
        action.set_enabled(false);
        assert_eq!(calls.get(), 1);

        drop(guard);
        action.set_enabled(true);

        assert_eq!(calls.get(), 1, "the handler ran after its guard dropped");
    }

    #[test]
    fn a_guard_outliving_its_object_drops_quietly() {
        let action = gio::SimpleAction::new("probe", None);
        let guard = HandlerGuard::new(&action, action.connect_enabled_notify(|_| {}));

        drop(action);
        drop(guard);
    }
}
