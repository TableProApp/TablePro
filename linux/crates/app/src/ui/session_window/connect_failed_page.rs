use gtk4 as gtk;
use gtk4::glib;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

mod imp {
    use super::*;
    use libadwaita::subclass::prelude::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/connect-failed-page.ui")]
    pub struct ConnectFailedPage {
        #[template_child]
        pub status_page: TemplateChild<adw::StatusPage>,
        #[template_child]
        pub edit_button: TemplateChild<gtk::Button>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ConnectFailedPage {
        const NAME: &'static str = "TableProConnectFailedPage";
        type Type = super::ConnectFailedPage;
        type ParentType = adw::Bin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for ConnectFailedPage {}
    impl WidgetImpl for ConnectFailedPage {}
    impl BinImpl for ConnectFailedPage {}
}

glib::wrapper! {
    /// A connect that failed: why, and Retry, Edit Connection and
    /// Choose Connection as the ways on.
    pub struct ConnectFailedPage(ObjectSubclass<imp::ConnectFailedPage>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl ConnectFailedPage {
    /// `edit` labels the button that opens the connect dialog, and is
    /// `None` for a connection the dialog cannot edit, such as a file
    /// nobody saved.
    pub fn new(message: &str, edit: Option<&str>) -> Self {
        let page: Self = glib::Object::new();
        let imp = page.imp();
        imp.status_page.set_description(Some(message));
        if let Some(label) = edit {
            imp.edit_button.set_label(label);
            imp.edit_button.set_visible(true);
        }
        page
    }

    #[cfg(test)]
    pub fn message(&self) -> Option<String> {
        self.imp().status_page.description().map(|text| text.to_string())
    }
}
