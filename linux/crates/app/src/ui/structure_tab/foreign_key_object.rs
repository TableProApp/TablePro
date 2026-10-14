//! A foreign key of the draft, as the Foreign Keys list holds it.

use std::cell::OnceCell;

use gtk4::glib;
use gtk4::subclass::prelude::*;
use tablepro_core::ForeignKeyInfo;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct ForeignKeyObject {
        pub info: OnceCell<ForeignKeyInfo>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ForeignKeyObject {
        const NAME: &'static str = "TableProForeignKeyObject";
        type Type = super::ForeignKeyObject;
    }

    impl ObjectImpl for ForeignKeyObject {}
}

glib::wrapper! {
    /// The tab finds the key by this object rather than by position.
    pub struct ForeignKeyObject(ObjectSubclass<imp::ForeignKeyObject>);
}

/// What an object made by `glib::Object::new` rather than
/// `ForeignKeyObject::new` reads as: a key of nothing.
static UNSET: ForeignKeyInfo = ForeignKeyInfo {
    name: String::new(),
    columns: Vec::new(),
    ref_schema: None,
    ref_table: String::new(),
    ref_columns: Vec::new(),
    on_delete: None,
    on_update: None,
};

impl ForeignKeyObject {
    pub(crate) fn new(info: ForeignKeyInfo) -> Self {
        let object: Self = glib::Object::new();
        let _ = object.imp().info.set(info);
        object
    }

    pub(crate) fn info(&self) -> &ForeignKeyInfo {
        self.imp().info.get().unwrap_or(&UNSET)
    }
}
