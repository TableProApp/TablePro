use gtk4 as gtk;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;

mod imp {
    use super::*;
    use libadwaita::subclass::prelude::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/picker-page.ui")]
    pub struct PickerPage {
        #[template_child]
        pub toast_overlay: TemplateChild<adw::ToastOverlay>,
        #[template_child]
        pub header_bar: TemplateChild<adw::HeaderBar>,
        #[template_child]
        pub new_connection_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub search_toggle: TemplateChild<gtk::ToggleButton>,
        #[template_child]
        pub search_bar: TemplateChild<gtk::SearchBar>,
        #[template_child]
        pub search_entry: TemplateChild<gtk::SearchEntry>,
        #[template_child]
        pub connection_list_banner: TemplateChild<adw::Banner>,
        #[template_child]
        pub welcome_slot: TemplateChild<adw::Bin>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for PickerPage {
        const NAME: &'static str = "TableProPickerPage";
        type Type = super::PickerPage;
        type ParentType = adw::Bin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for PickerPage {
        fn constructed(&self) {
            self.parent_constructed();
            crate::ui::a11y::describe_icon_button(
                &self.new_connection_button.get(),
                &crate::i18n::gettext("New Connection"),
                None,
            );
            crate::ui::a11y::describe_icon_button(
                &self.search_toggle.get(),
                &crate::i18n::gettext("Search Connections"),
                Some(SEARCH_ACTION),
            );
            self.search_bar.connect_entry(&*self.search_entry);
            self.search_toggle
                .bind_property("active", &*self.search_bar, "search-mode-enabled")
                .bidirectional()
                .sync_create()
                .build();
            let entry = self.search_entry.downgrade();
            // A closed search shows every connection again.
            self.search_bar.connect_search_mode_enabled_notify(move |bar| {
                if let (false, Some(entry)) = (bar.is_search_mode(), entry.upgrade()) {
                    entry.set_text("");
                }
            });
            let obj = self.obj();
            self.search_bar.set_key_capture_widget(Some(&*obj));
            let actions = gio::SimpleActionGroup::new();
            let search = gio::SimpleAction::new("search", None);
            let (bar, entry) = (self.search_bar.downgrade(), self.search_entry.downgrade());
            search.connect_activate(move |_, _| {
                if let (Some(bar), Some(entry)) = (bar.upgrade(), entry.upgrade()) {
                    bar.set_search_mode(true);
                    entry.grab_focus();
                }
            });
            actions.add_action(&search);
            obj.insert_action_group("picker-page", Some(&actions));
            obj.add_controller(crate::application::local_shortcut_controller(
                crate::application::ShortcutOwner::PickerPage,
            ));
        }
    }
    impl WidgetImpl for PickerPage {}
    impl BinImpl for PickerPage {}
}

glib::wrapper! {
    /// The saved connections, with a header bar of their own and the
    /// banner that says when the list could not be read. It sits outside
    /// any split view, so no empty sidebar can show while disconnected.
    pub struct PickerPage(ObjectSubclass<imp::PickerPage>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl PickerPage {
    pub fn new(welcome: &impl IsA<gtk::Widget>, app: Option<&gtk::Application>) -> Self {
        let page: Self = glib::Object::new();
        let imp = page.imp();
        imp.welcome_slot.set_child(Some(welcome));
        // The main menu sits at the very end, so the search moves in after it.
        let search = imp.search_toggle.get();
        imp.header_bar.remove(&search);
        imp.header_bar.pack_end(&crate::ui::shell::primary_menu_button(app));
        imp.header_bar.pack_end(&search);
        page
    }

    pub fn toast_overlay(&self) -> adw::ToastOverlay {
        self.imp().toast_overlay.get()
    }

    pub fn banner(&self) -> adw::Banner {
        self.imp().connection_list_banner.get()
    }

    pub fn search_entry(&self) -> gtk::SearchEntry {
        self.imp().search_entry.get()
    }

    #[cfg(test)]
    pub fn search_bar(&self) -> gtk::SearchBar {
        self.imp().search_bar.get()
    }
}

/// Opens the search and puts the focus in it.
const SEARCH_ACTION: &str = "picker-page.search";
