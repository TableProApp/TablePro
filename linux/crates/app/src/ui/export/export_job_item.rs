use std::cell::{Cell, OnceCell, RefCell};

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tokio_util::sync::CancellationToken;

use super::ExpectedRows;

mod imp {
    use super::*;

    #[derive(Default, glib::Properties)]
    #[properties(wrapper_type = super::ExportJobItem)]
    pub struct ExportJobItem {
        /// The file's name as the file manager shows it.
        #[property(get, set)]
        pub title: RefCell<String>,
        /// Rows written to the file so far.
        #[property(get, set)]
        pub rows: Cell<u64>,
        pub expected: Cell<Option<ExpectedRows>>,
        pub cancel: OnceCell<CancellationToken>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ExportJobItem {
        const NAME: &'static str = "TableProExportJobItem";
        type Type = super::ExportJobItem;
    }

    #[glib::derived_properties]
    impl ObjectImpl for ExportJobItem {}
}

glib::wrapper! {
    /// A running export as the operations popover lists it.
    pub struct ExportJobItem(ObjectSubclass<imp::ExportJobItem>);
}

impl ExportJobItem {
    pub(crate) fn new(title: &str, expected: Option<ExpectedRows>, cancel: CancellationToken) -> Self {
        let item: Self = glib::Object::builder().property("title", title).build();
        item.imp().expected.set(expected);
        let _ = item.imp().cancel.set(cancel);
        item
    }

    pub(crate) fn expected(&self) -> Option<ExpectedRows> {
        self.imp().expected.get()
    }

    /// The share of the rows written, while the total is known.
    pub(crate) fn fraction(&self) -> Option<f64> {
        let total = self.expected()?.total();
        (total > 0).then(|| (self.rows() as f64 / total as f64).min(1.0))
    }

    pub(crate) fn stop(&self) {
        if let Some(cancel) = self.imp().cancel.get() {
            cancel.cancel();
        }
    }
}
