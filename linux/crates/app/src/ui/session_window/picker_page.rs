use gtk4 as gtk;
use gtk4::glib;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

mod imp {
    use super::*;
    use libadwaita::subclass::prelude::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/picker-page.ui")]
    pub struct PickerPage {
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

    impl ObjectImpl for PickerPage {}
    impl WidgetImpl for PickerPage {}
    impl BinImpl for PickerPage {}
}

glib::wrapper! {
    /// The saved connections, with a header bar of their own and the
    /// banner that says when the list could not be read.
    pub struct PickerPage(ObjectSubclass<imp::PickerPage>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl PickerPage {
    pub fn new(welcome: &impl IsA<gtk::Widget>) -> Self {
        let page: Self = glib::Object::new();
        page.imp().welcome_slot.set_child(Some(welcome));
        page
    }

    pub fn banner(&self) -> adw::Banner {
        self.imp().connection_list_banner.get()
    }
}
