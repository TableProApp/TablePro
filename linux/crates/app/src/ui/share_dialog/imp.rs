use std::cell::{Cell, OnceCell, RefCell};
use std::sync::Arc;

use gtk4::glib;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_account::{Share, ShareLimits};
use tokio_util::sync::CancellationToken;

use super::form::FormFields;
use super::sheet_view::SheetPage;
use super::{Chrome, Deps};
use crate::services::share_subject::{ShareForm, ShareSubject};

#[derive(Default)]
pub struct ShareDialog {
    pub(super) chrome: OnceCell<Chrome>,
    pub(super) deps: OnceCell<Deps>,
    // Replaced once a table tab's rows are read.
    pub(super) subject: RefCell<Option<Arc<ShareSubject>>>,
    // The team a link goes to; None is a personal link.
    pub(super) target: RefCell<Option<String>>,
    pub(super) page: RefCell<Option<SheetPage>>,
    pub(super) limits: RefCell<Option<ShareLimits>>,
    pub(super) live: RefCell<Vec<Share>>,
    pub(super) form: RefCell<Option<FormFields>>,
    // One create, revoke or sign-in at a time, however fast the buttons are pressed.
    pub(super) busy: Cell<bool>,
    // Moved by each read of the limits, so a read a later one replaced lands nowhere.
    pub(super) read: Cell<u64>,
    pub(super) signing_in: RefCell<Option<CancellationToken>>,
    // Moved by each sign-in, so one that a later one replaced ends without touching the sheet.
    pub(super) sign_in_attempt: Cell<u64>,
    // What the form held when the sheet left it, so a revoke or a refusal brings it back as typed.
    pub(super) draft: RefCell<Option<ShareForm>>,
    pub(super) following: RefCell<Vec<glib::JoinHandle<()>>>,
    // Moved by each change of the Columns list, so only the newest summary lands.
    pub(super) summaries: Cell<u64>,
    pub(super) summarized: Cell<u64>,
    // The share as the sheet holds it is summarized and can go; false while a summary runs or it is too large.
    pub(super) sendable: Cell<bool>,
}

#[glib::object_subclass]
impl ObjectSubclass for ShareDialog {
    const NAME: &'static str = "TableProShareDialog";
    type Type = super::ShareDialog;
    type ParentType = adw::Dialog;
}

impl ObjectImpl for ShareDialog {
    fn dispose(&self) {
        for following in self.following.take() {
            following.abort();
        }
        if let Some(signing_in) = self.signing_in.take() {
            signing_in.cancel();
        }
    }
}

impl WidgetImpl for ShareDialog {}

impl AdwDialogImpl for ShareDialog {}
