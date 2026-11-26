// Import from another app as a dialog: the shared import pages on the one app the user picks.

mod imp;
mod pages;
#[cfg(test)]
pub(crate) mod tests;
mod wording;

use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::DriverRegistry;
use tablepro_foreign_import::ForeignAppDirs;
use tablepro_session::runtime::Tasks;
use tablepro_storage::ConnectionStore;

pub(crate) use pages::{ImportPages, ImportPagesInit, ImportPagesMode, ImportRequested};
pub(crate) use wording::source_subtitle;

glib::wrapper! {
    pub struct ImportFromAppDialog(ObjectSubclass<imp::ImportFromAppDialog>)
        @extends adw::Dialog, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

pub(crate) struct ImportFromAppInit {
    pub dirs: ForeignAppDirs,
    pub drivers: Arc<DriverRegistry>,
    pub connections: ConnectionStore,
    pub tasks: Tasks,
    pub on_import: ImportRequested,
}

impl ImportFromAppDialog {
    pub(crate) fn new(init: ImportFromAppInit) -> Self {
        let dialog: Self = glib::Object::new();
        let importing = dialog.downgrade();
        let on_import = init.on_import;
        let cancelling = dialog.downgrade();
        let pages = ImportPages::new(ImportPagesInit {
            dirs: init.dirs,
            drivers: init.drivers,
            connections: init.connections,
            tasks: init.tasks,
            mode: ImportPagesMode::PickOne,
            on_import: Box::new(move |review, plan| {
                on_import(review, plan);
                if let Some(dialog) = importing.upgrade() {
                    dialog.close();
                }
            }),
            on_cancel: Box::new(move || {
                if let Some(dialog) = cancelling.upgrade() {
                    dialog.close();
                }
            }),
        });
        pages.attach(&dialog.imp().navigation);
        dialog.connect_closed(|dialog| {
            if let Some(pages) = dialog.imp().pages.get() {
                pages.cancel();
            }
        });
        let _ = dialog.imp().pages.set(pages.clone());
        pages.start();
        dialog
    }

    #[cfg(test)]
    fn pages(&self) -> Option<&ImportPages> {
        self.imp().pages.get()
    }
}
