use std::cell::RefCell;
use std::time::SystemTime;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::HistoryEntryObject;
use super::history_formatting::{outcome_icon, outcome_label, preview_title, subtitle};
use crate::i18n::gettext;
use crate::ui::a11y::describe_icon_button;

mod imp {
    use super::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/history-row.ui")]
    pub struct HistoryRow {
        #[template_child]
        pub check: TemplateChild<gtk::CheckButton>,
        #[template_child]
        pub status_icon: TemplateChild<gtk::Image>,
        #[template_child]
        pub title_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub subtitle_label: TemplateChild<gtk::Label>,
        #[template_child]
        pub pin_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub delete_button: TemplateChild<gtk::Button>,
        pub entry: RefCell<Option<HistoryEntryObject>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for HistoryRow {
        const NAME: &'static str = "TableProHistoryRow";
        type Type = super::HistoryRow;
        type ParentType = gtk::Box;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for HistoryRow {
        fn constructed(&self) {
            self.parent_constructed();
            self.obj().show_pinned(false);
        }
    }
    impl WidgetImpl for HistoryRow {}
    impl BoxImpl for HistoryRow {}
}

glib::wrapper! {
    /// A row of the history list. The list view builds a few and fills
    /// them again as the user scrolls, so nothing here belongs to one
    /// entry for longer than a bind.
    pub struct HistoryRow(ObjectSubclass<imp::HistoryRow>)
        @extends gtk::Box, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget, gtk::Orientable;
}

impl Default for HistoryRow {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl HistoryRow {
    pub(super) fn bind(&self, object: &HistoryEntryObject, now: SystemTime) {
        let imp = self.imp();
        imp.entry.replace(Some(object.clone()));
        let Some(entry) = object.entry() else {
            return;
        };
        imp.title_label.set_label(&preview_title(&entry.query));
        imp.subtitle_label.set_label(&subtitle(entry, now));
        imp.status_icon.set_icon_name(Some(outcome_icon(entry)));
        imp.status_icon
            .update_property(&[gtk::accessible::Property::Label(&outcome_label(entry))]);

        self.show_pinned(entry.pinned);
        let id = entry.id.to_variant();
        // The target goes first: an action that takes an id, named on a
        // button without one, warns that it cannot be activated.
        imp.pin_button.set_action_target_value(Some(&id));
        imp.pin_button.set_action_name(Some("history.pin"));
        imp.delete_button.set_action_target_value(Some(&id));
        imp.delete_button.set_action_name(Some("history.delete"));
    }

    fn show_pinned(&self, pinned: bool) {
        let button = self.imp().pin_button.get();
        let label = if pinned { gettext("Unpin") } else { gettext("Pin") };
        describe_icon_button(&button, &label, None);
        if pinned {
            button.add_css_class("accent");
        } else {
            button.remove_css_class("accent");
        }
    }

    pub(super) fn unbind(&self) {
        self.imp().entry.replace(None);
    }

    /// The entry the row shows now, if it is bound.
    pub(super) fn entry(&self) -> Option<HistoryEntryObject> {
        self.imp().entry.borrow().clone()
    }

    pub(super) fn check(&self) -> gtk::CheckButton {
        self.imp().check.get()
    }

    #[cfg(test)]
    pub(super) fn title(&self) -> String {
        self.imp().title_label.label().to_string()
    }
}
