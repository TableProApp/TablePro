//! An index of the draft, as the Indexes list holds it.

use std::cell::OnceCell;

use gtk4::glib;
use gtk4::subclass::prelude::*;
use tablepro_core::IndexInfo;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct IndexObject {
        pub info: OnceCell<IndexInfo>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for IndexObject {
        const NAME: &'static str = "TableProIndexObject";
        type Type = super::IndexObject;
    }

    impl ObjectImpl for IndexObject {}
}

glib::wrapper! {
    /// The tab finds the index by this object rather than by position.
    pub struct IndexObject(ObjectSubclass<imp::IndexObject>);
}

/// What an object made by `glib::Object::new` rather than
/// `IndexObject::new` reads as: an index of nothing.
static UNSET: IndexInfo = IndexInfo {
    name: String::new(),
    keys: Vec::new(),
    unique: false,
    primary: false,
    predicate: None,
};

impl IndexObject {
    pub(crate) fn new(info: IndexInfo) -> Self {
        let object: Self = glib::Object::new();
        let _ = object.imp().info.set(info);
        object
    }

    pub(crate) fn info(&self) -> &IndexInfo {
        self.imp().info.get().unwrap_or(&UNSET)
    }
}
