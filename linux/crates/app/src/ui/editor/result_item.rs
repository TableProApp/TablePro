use std::cell::RefCell;

use gtk4::glib;
use gtk4::subclass::prelude::*;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct ResultItem {
        pub title: RefCell<String>,
        pub subtitle: RefCell<String>,
        pub icon_name: RefCell<String>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ResultItem {
        const NAME: &'static str = "TableProResultItem";
        type Type = super::ResultItem;
    }

    impl ObjectImpl for ResultItem {}
}

glib::wrapper! {
    /// One line of the results list.
    pub struct ResultItem(ObjectSubclass<imp::ResultItem>);
}

impl ResultItem {
    pub fn new(title: &str, subtitle: &str, icon_name: &str) -> Self {
        let item: Self = glib::Object::new();
        let imp = item.imp();
        imp.title.replace(title.to_owned());
        imp.subtitle.replace(subtitle.to_owned());
        imp.icon_name.replace(icon_name.to_owned());
        item
    }

    pub fn title(&self) -> String {
        self.imp().title.borrow().clone()
    }

    pub fn subtitle(&self) -> String {
        self.imp().subtitle.borrow().clone()
    }

    pub fn icon_name(&self) -> String {
        self.imp().icon_name.borrow().clone()
    }
}
