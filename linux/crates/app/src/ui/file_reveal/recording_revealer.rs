use std::cell::RefCell;
use std::path::PathBuf;

use futures::future::LocalBoxFuture;
use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gio, glib};

use super::FileRevealer;

/// Remembers each file it was asked to show and answers with `outcome`.
pub(crate) struct RecordingRevealer {
    revealed: RefCell<Vec<PathBuf>>,
    outcome: Result<(), glib::Error>,
}

impl RecordingRevealer {
    pub(crate) fn succeeding() -> Self {
        Self {
            revealed: RefCell::default(),
            outcome: Ok(()),
        }
    }

    pub(crate) fn failing() -> Self {
        Self {
            revealed: RefCell::default(),
            outcome: Err(glib::Error::new(gio::IOErrorEnum::NotSupported, "no file manager")),
        }
    }

    pub(crate) fn revealed(&self) -> Vec<PathBuf> {
        self.revealed.borrow().clone()
    }
}

impl FileRevealer for RecordingRevealer {
    fn reveal(
        &self,
        file: gio::File,
        _parent: Option<gtk::Window>,
    ) -> LocalBoxFuture<'static, Result<(), glib::Error>> {
        if let Some(path) = file.path() {
            self.revealed.borrow_mut().push(path);
        }
        let outcome = self.outcome.clone();
        Box::pin(async move { outcome })
    }
}
