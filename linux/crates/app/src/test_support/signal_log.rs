use std::cell::RefCell;
use std::rc::Rc;

use gtk4::glib;
use gtk4::glib::prelude::*;

pub(crate) struct SignalLog<T: 'static> {
    entries: Rc<RefCell<Vec<T>>>,
    object: glib::WeakRef<glib::Object>,
    handler: Option<glib::SignalHandlerId>,
}

impl<T: 'static> SignalLog<T> {
    pub fn connect(
        object: &impl IsA<glib::Object>,
        name: &str,
        extract: impl Fn(&[glib::Value]) -> T + 'static,
    ) -> Self {
        let entries = Rc::new(RefCell::new(Vec::new()));
        let sink = Rc::clone(&entries);
        let handler = object.connect_local(name, false, move |values| {
            sink.borrow_mut().push(extract(values));
            None
        });
        Self {
            entries,
            object: object.upcast_ref::<glib::Object>().downgrade(),
            handler: Some(handler),
        }
    }

    pub fn count(&self) -> usize {
        self.entries.borrow().len()
    }

    pub fn take(&self) -> Vec<T> {
        std::mem::take(&mut *self.entries.borrow_mut())
    }
}

impl<T: 'static> Drop for SignalLog<T> {
    fn drop(&mut self) {
        if let (Some(object), Some(handler)) = (self.object.upgrade(), self.handler.take()) {
            object.disconnect(handler);
        }
    }
}
