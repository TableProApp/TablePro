use gtk4::glib;
use gtk4::subclass::prelude::*;
use tablepro_storage::query_history::Entry;

use super::history_entry_object_imp as imp;

glib::wrapper! {
    /// One history entry as the dialog's list model holds it. An entry
    /// never changes in place: a pin or a delete reloads the page.
    pub struct HistoryEntryObject(ObjectSubclass<imp::HistoryEntryObject>);
}

impl HistoryEntryObject {
    pub(crate) fn new(entry: Entry) -> Self {
        let object: Self = glib::Object::new();
        let _ = object.imp().entry.set(entry);
        object
    }

    /// Always set: `new` is the only way to build one.
    pub(crate) fn entry(&self) -> Option<&Entry> {
        self.imp().entry.get()
    }

    pub(crate) fn id(&self) -> Option<i64> {
        self.entry().map(|entry| entry.id)
    }

    pub(crate) fn is_pinned(&self) -> bool {
        self.entry().is_some_and(|entry| entry.pinned)
    }

    pub(crate) fn query(&self) -> Option<String> {
        self.entry().map(|entry| entry.query.clone())
    }
}
