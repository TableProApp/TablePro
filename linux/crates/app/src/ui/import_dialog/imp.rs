use std::cell::{OnceCell, RefCell};
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_core::import::CsvSheet;

use super::{CsvImport, CsvRequest, DialogParts};
use crate::runtime::RequestSequencer;

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/import-csv-dialog.ui")]
pub struct ImportCsvDialog {
    #[template_child]
    pub window_title: TemplateChild<adw::WindowTitle>,
    #[template_child]
    pub import_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub delimiter_row: TemplateChild<adw::ComboRow>,
    #[template_child]
    pub header_row: TemplateChild<adw::SwitchRow>,
    #[template_child]
    pub null_row: TemplateChild<adw::EntryRow>,
    #[template_child]
    pub mapping_group: TemplateChild<adw::PreferencesGroup>,
    #[template_child]
    pub summary: TemplateChild<gtk::Label>,

    pub(super) parts: OnceCell<DialogParts>,
    pub(super) sheet: RefCell<CsvSheet>,
    pub(super) read_error: RefCell<Option<String>>,
    // One per table column, in column order. Position 0 is Skip, position n + 1 is field n.
    pub(super) mapping_rows: RefCell<Vec<adw::ComboRow>>,
    pub(super) sequencer: RefCell<RequestSequencer<CsvRequest>>,
}

#[glib::object_subclass]
impl ObjectSubclass for ImportCsvDialog {
    const NAME: &'static str = "TableProImportCsvDialog";
    type Type = super::ImportCsvDialog;
    type ParentType = adw::Dialog;

    fn class_init(klass: &mut Self::Class) {
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for ImportCsvDialog {
    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| {
            vec![
                Signal::builder("import")
                    .param_types([CsvImport::static_type()])
                    .build(),
            ]
        })
    }

    fn dispose(&self) {
        self.sequencer.borrow_mut().cancel_all();
    }
}

impl WidgetImpl for ImportCsvDialog {}

impl AdwDialogImpl for ImportCsvDialog {
    // The dialog lives on through its close animation, which a read landing then must not fill.
    fn closed(&self) {
        self.sequencer.borrow_mut().cancel_all();
        self.parent_closed();
    }
}
