use std::cell::RefCell;
use std::rc::Rc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_storage::AppSettings;

use super::ai_page::AiPage;
use super::editor_page::EditorPage;
use super::general_page::GeneralPage;
use super::mcp_page::McpPage;

#[derive(Default, gtk4::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/preferences-dialog.ui")]
pub struct PreferencesDialog {
    #[template_child]
    pub general_page: TemplateChild<GeneralPage>,
    #[template_child]
    pub editor_page: TemplateChild<EditorPage>,
    #[template_child]
    pub mcp_page: TemplateChild<McpPage>,
    #[template_child]
    pub ai_page: TemplateChild<AiPage>,
    pub settings: RefCell<Option<Rc<AppSettings>>>,
}

#[glib::object_subclass]
impl ObjectSubclass for PreferencesDialog {
    const NAME: &'static str = "TableProPreferencesDialog";
    type Type = super::PreferencesDialog;
    type ParentType = adw::PreferencesDialog;

    fn class_init(klass: &mut Self::Class) {
        GeneralPage::ensure_type();
        EditorPage::ensure_type();
        McpPage::ensure_type();
        AiPage::ensure_type();
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
