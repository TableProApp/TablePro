use std::cell::RefCell;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::SavedQueryObject;

mod imp {
    use super::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/saved-query-row.ui")]
    pub struct SavedQueryRow {
        #[template_child]
        pub name_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub summary_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub menu_button: TemplateChild<gtk::MenuButton>,
        pub object: RefCell<Option<SavedQueryObject>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for SavedQueryRow {
        const NAME: &'static str = "TableProSavedQueryRow";
        type Type = super::SavedQueryRow;
        type ParentType = gtk::Box;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for SavedQueryRow {
        fn constructed(&self) {
            self.parent_constructed();
            self.menu_button.set_menu_model(Some(&super::super::row_menu()));
        }
    }
    impl WidgetImpl for SavedQueryRow {}
    impl BoxImpl for SavedQueryRow {}
}

glib::wrapper! {
    // The list view fills a few of these again as it scrolls, so a row
    // belongs to one saved query only between a bind and its unbind.
    pub struct SavedQueryRow(ObjectSubclass<imp::SavedQueryRow>)
        @extends gtk::Box, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget, gtk::Orientable;
}

impl Default for SavedQueryRow {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl SavedQueryRow {
    pub(super) fn bind(&self, object: &SavedQueryObject) {
        let imp = self.imp();
        imp.name_label.set_label(object.name().unwrap_or_default());
        let summary = object.summary().unwrap_or_default();
        imp.summary_label.set_label(summary);
        imp.summary_label.set_visible(!summary.is_empty());
        imp.object.replace(Some(object.clone()));
    }

    pub(super) fn unbind(&self) {
        self.imp().object.replace(None);
    }

    pub(super) fn id(&self) -> Option<i64> {
        self.imp().object.borrow().as_ref().and_then(SavedQueryObject::id)
    }

    #[cfg(test)]
    pub(super) fn labels(&self) -> (gtk::Label, gtk::Label) {
        let imp = self.imp();
        (imp.name_label.get(), imp.summary_label.get())
    }
}
