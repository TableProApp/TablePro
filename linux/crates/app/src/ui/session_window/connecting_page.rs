use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;

mod imp {
    use super::*;
    use libadwaita::subclass::prelude::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/connecting-page.ui")]
    pub struct ConnectingPage {
        #[template_child]
        pub toast_overlay: TemplateChild<adw::ToastOverlay>,
        #[template_child]
        pub header_bar: TemplateChild<adw::HeaderBar>,
        #[template_child]
        pub status_page: TemplateChild<adw::StatusPage>,
        #[template_child]
        pub cancel_button: TemplateChild<gtk::Button>,
        #[cfg(test)]
        pub announced: std::cell::RefCell<Vec<(String, gtk::AccessibleAnnouncementPriority)>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ConnectingPage {
        const NAME: &'static str = "TableProConnectingPage";
        type Type = super::ConnectingPage;
        type ParentType = adw::Bin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for ConnectingPage {}
    impl WidgetImpl for ConnectingPage {}
    impl BinImpl for ConnectingPage {}
}

glib::wrapper! {
    /// A connect on its way, which `win.cancel-connect` stops. A remote
    /// or tunnelled connect can take the whole connect timeout.
    pub struct ConnectingPage(ObjectSubclass<imp::ConnectingPage>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl ConnectingPage {
    pub fn new(app: Option<&gtk::Application>) -> Self {
        let page: Self = glib::Object::new();
        page.imp()
            .header_bar
            .pack_end(&crate::ui::shell::primary_menu_button(app));
        page
    }

    /// Say that `name` is connecting, once the page is in its window.
    /// The announcement is what a screen reader hears: the page replaces
    /// the window's content without moving the focus into it. Enter
    /// cancels, as the one thing to do here.
    pub fn show(&self, name: &str) {
        let imp = self.imp();
        let title = crate::i18n::gettext_f("Connecting to {name}", &[("name", name)]);
        imp.status_page.set_title(&title);
        if let Some(window) = self.root().and_downcast::<gtk::Window>() {
            window.set_title(Some(&crate::i18n::gettext("Connecting")));
            window.set_default_widget(Some(&imp.cancel_button.get()));
        }
        let priority = gtk::AccessibleAnnouncementPriority::Medium;
        #[cfg(test)]
        imp.announced.borrow_mut().push((title.clone(), priority));
        // libadwaita's own Accessible impls sit behind a feature left off,
        // and every widget is one.
        imp.status_page.upcast_ref::<gtk::Widget>().announce(&title, priority);
    }

    pub fn toast_overlay(&self) -> adw::ToastOverlay {
        self.imp().toast_overlay.get()
    }

    #[cfg(test)]
    pub fn status_page(&self) -> adw::StatusPage {
        self.imp().status_page.get()
    }

    #[cfg(test)]
    pub fn cancel_button(&self) -> gtk::Button {
        self.imp().cancel_button.get()
    }

    #[cfg(test)]
    pub fn announced(&self) -> Vec<(String, gtk::AccessibleAnnouncementPriority)> {
        self.imp().announced.borrow().clone()
    }
}
