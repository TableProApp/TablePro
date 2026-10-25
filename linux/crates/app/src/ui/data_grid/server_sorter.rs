use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct ServerSorter;

    #[glib::object_subclass]
    impl ObjectSubclass for ServerSorter {
        const NAME: &'static str = "TableProServerSorter";
        type Type = super::ServerSorter;
        type ParentType = gtk::Sorter;
    }

    impl ObjectImpl for ServerSorter {}

    impl SorterImpl for ServerSorter {
        fn compare(&self, _: &glib::Object, _: &glib::Object) -> gtk::Ordering {
            gtk::Ordering::Equal
        }

        fn order(&self) -> gtk::SorterOrder {
            gtk::SorterOrder::None
        }
    }
}

glib::wrapper! {
    /// A header's sorter where the server sorts: it lets the header show
    /// the sort and leaves the rows in the order they arrived.
    pub struct ServerSorter(ObjectSubclass<imp::ServerSorter>)
        @extends gtk::Sorter;
}

impl ServerSorter {
    pub fn new() -> Self {
        glib::Object::new()
    }
}
