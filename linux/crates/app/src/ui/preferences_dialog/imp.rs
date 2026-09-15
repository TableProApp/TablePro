use std::cell::RefCell;
use std::rc::Rc;

use gtk4::glib;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_storage::AppSettings;

#[derive(Default, gtk4::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/preferences-dialog.ui")]
pub struct PreferencesDialog {
    #[template_child]
    pub page_size_row: TemplateChild<adw::SpinRow>,
    #[template_child]
    pub confirm_row: TemplateChild<adw::SwitchRow>,
    #[template_child]
    pub retention_row: TemplateChild<adw::SpinRow>,
    #[template_child]
    pub clear_row: TemplateChild<adw::ActionRow>,
    #[template_child]
    pub clear_button: TemplateChild<gtk4::Button>,
    #[template_child]
    pub storage_row: TemplateChild<adw::ActionRow>,
    #[template_child]
    pub storage_button: TemplateChild<gtk4::Button>,
    #[template_child]
    pub system_font_row: TemplateChild<adw::SwitchRow>,
    #[template_child]
    pub font_row: TemplateChild<adw::ActionRow>,
    #[template_child]
    pub font_button: TemplateChild<gtk4::FontDialogButton>,
    #[template_child]
    pub style_scheme_box: TemplateChild<gtk4::FlowBox>,
    #[template_child]
    pub timeout_row: TemplateChild<adw::SpinRow>,
    pub settings: RefCell<Option<Rc<AppSettings>>>,
}

#[glib::object_subclass]
impl ObjectSubclass for PreferencesDialog {
    const NAME: &'static str = "TableProPreferencesDialog";
    type Type = super::PreferencesDialog;
    type ParentType = adw::PreferencesDialog;

    fn class_init(klass: &mut Self::Class) {
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for PreferencesDialog {}
impl WidgetImpl for PreferencesDialog {}
impl AdwDialogImpl for PreferencesDialog {}
impl PreferencesDialogImpl for PreferencesDialog {}
