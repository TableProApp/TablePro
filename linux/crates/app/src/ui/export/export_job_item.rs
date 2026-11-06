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
        /// The file is made whole before it is written, so it has no rows
        /// to count.
        pub whole: Cell<bool>,
        /// A database export's tables written, and how many it has.
        pub tables: Cell<Option<(usize, usize)>>,
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

    /// A job that writes a file made whole first, such as an image.
    pub(crate) fn whole_file(title: &str, cancel: CancellationToken) -> Self {
        let item = Self::new(title, None, cancel);
        item.imp().whole.set(true);
        item
    }

    pub(crate) fn is_whole_file(&self) -> bool {
        self.imp().whole.get()
    }

    /// A database export, which counts its tables. The rows that follow
    /// tell the popover to show them.
    pub(crate) fn set_tables(&self, done: usize, total: usize) {
        self.imp().tables.set(Some((done, total)));
    }

    pub(crate) fn tables(&self) -> Option<(usize, usize)> {
        self.imp().tables.get()
    }

    pub(crate) fn expected(&self) -> Option<ExpectedRows> {
        self.imp().expected.get()
    }

    /// The share of the rows written, while the total is known.
    pub(crate) fn fraction(&self) -> Option<f64> {
        if let Some((done, total)) = self.tables() {
            return (total > 0).then(|| (done as f64 / total as f64).min(1.0));
        }
        let total = self.expected()?.total();
        (total > 0).then(|| (self.rows() as f64 / total as f64).min(1.0))
    }

    pub(crate) fn stop(&self) {
        if let Some(cancel) = self.imp().cancel.get() {
            cancel.cancel();
        }
    }
}
