use std::cell::OnceCell;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::ImportPages;

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/import-from-app-dialog.ui")]
pub struct ImportFromAppDialog {
    #[template_child]
    pub navigation: TemplateChild<adw::NavigationView>,

    pub(super) pages: OnceCell<ImportPages>,
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
