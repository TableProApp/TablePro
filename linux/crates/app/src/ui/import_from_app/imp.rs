use std::cell::{OnceCell, RefCell};

use gtk4 as gtk;
use gtk4::glib;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::{DialogParts, Reviewing, SourceRow};

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/import-from-app-dialog.ui")]
pub struct ImportFromAppDialog {
    #[template_child]
    pub navigation: TemplateChild<adw::NavigationView>,
    #[template_child]
    pub continue_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub sources_stack: TemplateChild<gtk::Stack>,
    #[template_child]
    pub apps_group: TemplateChild<adw::PreferencesGroup>,
    #[template_child]
    pub passwords_row: TemplateChild<adw::SwitchRow>,
    #[template_child]
    pub queries_row: TemplateChild<adw::SwitchRow>,
    #[template_child]
    pub reading_status: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub failed_status: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub review_page: TemplateChild<adw::NavigationPage>,
    #[template_child]
    pub passwords_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub review_preferences: TemplateChild<adw::PreferencesPage>,
    #[template_child]
    pub connections_group: TemplateChild<adw::PreferencesGroup>,
    #[template_child]
    pub queries_group: TemplateChild<adw::PreferencesGroup>,
    #[template_child]
    pub summary_label: TemplateChild<gtk::Label>,
    #[template_child]
    pub import_button: TemplateChild<gtk::Button>,

    pub(super) parts: OnceCell<DialogParts>,
    pub(super) sources: RefCell<Vec<SourceRow>>,
    pub(super) reviewing: RefCell<Option<Reviewing>>,
}

#[glib::object_subclass]
impl ObjectSubclass for ImportFromAppDialog {
    const NAME: &'static str = "TableProImportFromAppDialog";
    type Type = super::ImportFromAppDialog;
    type ParentType = adw::Dialog;

    fn class_init(klass: &mut Self::Class) {
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for ImportFromAppDialog {}
impl WidgetImpl for ImportFromAppDialog {}
impl AdwDialogImpl for ImportFromAppDialog {}
