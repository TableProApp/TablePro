use gtk4::glib;
use gtk4::subclass::prelude::*;
use tablepro_storage::saved_queries::SavedQuery;

use super::saved_query_object_imp as imp;

glib::wrapper! {
    pub struct SavedQueryObject(ObjectSubclass<imp::SavedQueryObject>);
}

impl SavedQueryObject {
    // `group` ranks the connection's section in the list.
    pub(super) fn new(saved: SavedQuery, group: u32) -> Self {
        let object: Self = glib::Object::new();
        let imp = object.imp();
        let _ = imp.saved.set(saved);
        imp.group.set(group);
        object
    }

    fn saved(&self) -> Option<&SavedQuery> {
        self.imp().saved.get()
    }

    pub(super) fn id(&self) -> Option<i64> {
        self.saved().map(|saved| saved.id)
    }

    pub(super) fn name(&self) -> Option<&str> {
        self.saved().map(|saved| saved.name.as_str())
    }

    pub(super) fn summary(&self) -> Option<&str> {
        self.saved().map(SavedQuery::summary)
    }

    pub(super) fn connection_name(&self) -> Option<&str> {
        self.saved().map(|saved| saved.connection_name.as_str())
    }

    pub(super) fn query(&self) -> Option<&str> {
        self.saved().map(|saved| saved.query.as_str())
    }

    pub(super) fn group(&self) -> u32 {
        self.imp().group.get()
    }
}
