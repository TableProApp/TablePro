use std::cell::OnceCell;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::Parts;

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/setup-guide.ui")]
pub struct SetupGuide {
    #[template_child]
    pub toasts: TemplateChild<adw::ToastOverlay>,
    #[template_child]
    pub navigation: TemplateChild<adw::NavigationView>,
    #[template_child]
    pub origin_skip: TemplateChild<gtk::Button>,
    #[template_child]
    pub from_app_row: TemplateChild<adw::ActionRow>,
    #[template_child]
    pub from_file_row: TemplateChild<adw::ActionRow>,
    #[template_child]
    pub start_row: TemplateChild<adw::ActionRow>,
    #[template_child]
    pub import_continue: TemplateChild<gtk::Button>,
    #[template_child]
    pub import_skip: TemplateChild<gtk::Button>,
    #[template_child]
    pub import_stack: TemplateChild<gtk::Stack>,
    #[template_child]
    pub import_apps_group: TemplateChild<adw::PreferencesGroup>,
    #[template_child]
    pub first_continue: TemplateChild<gtk::Button>,
    #[template_child]
    pub first_skip: TemplateChild<gtk::Button>,
    #[template_child]
    pub new_connection_check: TemplateChild<gtk::CheckButton>,
    #[template_child]
    pub sample_check: TemplateChild<gtk::CheckButton>,
    #[template_child]
    pub finish_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub options_skip: TemplateChild<gtk::Button>,
    #[template_child]
    pub shortcuts_row: TemplateChild<adw::ComboRow>,
    #[template_child]
    pub vim_row: TemplateChild<adw::SwitchRow>,
    #[template_child]
    pub system_style_row: TemplateChild<adw::SwitchRow>,
    #[template_child]
    pub style_scheme_box: TemplateChild<gtk::FlowBox>,

    pub(super) parts: OnceCell<Parts>,
}

#[glib::object_subclass]
impl ObjectSubclass for SetupGuide {
    const NAME: &'static str = "TableProSetupGuide";
    type Type = super::SetupGuide;
    type ParentType = adw::Bin;

    fn class_init(klass: &mut Self::Class) {
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for SetupGuide {
    fn dispose(&self) {
        self.obj().shutdown();
    }
}

impl WidgetImpl for SetupGuide {}
impl BinImpl for SetupGuide {}
