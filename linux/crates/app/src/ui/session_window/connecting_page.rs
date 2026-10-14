use gtk4 as gtk;
use gtk4::glib;
use gtk4::subclass::prelude::*;
use libadwaita as adw;

mod imp {
    use super::*;
    use libadwaita::subclass::prelude::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/connecting-page.ui")]
    pub struct ConnectingPage {
        #[template_child]
        pub status_page: TemplateChild<adw::StatusPage>,
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
    pub fn new(name: &str) -> Self {
        let page: Self = glib::Object::new();
        page.imp()
            .status_page
            .set_title(&crate::i18n::gettext_f("Connecting to {name}", &[("name", name)]));
        page
    }
}
