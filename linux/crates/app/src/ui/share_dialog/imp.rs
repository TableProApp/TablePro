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
    pub(super) subject: OnceCell<Arc<ShareSubject>>,
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
