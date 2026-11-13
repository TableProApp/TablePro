mod form;
mod imp;
mod pages;
mod preview;
mod sheet_view;
mod table_read;
#[cfg(test)]
mod tests;

use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_account::{Account, AccountError, CreatedShare, Share, ShareLimits};
use tablepro_session::runtime::{TaskFailure, Tasks};
use tokio_util::sync::CancellationToken;

use self::form::build_form;
use self::sheet_view::SheetPage;
use crate::i18n::gettext;
use crate::runtime::spawn_and_deliver;
use crate::services::account_service::{AccountHandle, AccountStart};
use crate::services::share_subject::ShareSubject;
use crate::services::telemetry::Telemetry;
use crate::ui::error_text::{account_error_message, account_unavailable_message, share_error_message};

// Pages of live links read for the list at the limit; Pro's 1,000 links are ten pages of the core's 100.
const LIST_PAGES: usize = 10;

pub(crate) struct ShareDialogInit {
    pub subject: ShareSubject,
    pub account: AccountHandle,
    pub tasks: Tasks,
    pub telemetry: Telemetry,
}

pub(super) struct Deps {
    account: AccountHandle,
    tasks: Tasks,
    telemetry: Telemetry,
}

pub(super) struct Chrome {
    toolbar: adw::ToolbarView,
    header: adw::HeaderBar,
    banner: adw::Banner,
    cancel: gtk::Button,
    create: gtk::Button,
    footer: gtk::Label,
}

type LimitsRead = Result<(ShareLimits, Vec<Share>), AccountError>;

glib::wrapper! {
    pub struct ShareDialog(ObjectSubclass<imp::ShareDialog>)
        @extends adw::Dialog, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget, gtk::ShortcutManager;
}

impl ShareDialog {
    pub(crate) fn new(init: ShareDialogInit) -> Self {
        let dialog: Self = glib::Object::builder()
            .property("title", sheet_view::title(init.subject.kind()))
            .property("content-width", 560)
            .property("content-height", 640)
            .build();
        let imp = dialog.imp();
        let _ = imp.chrome.set(dialog.build_chrome());
        imp.subject.replace(Some(Arc::new(init.subject)));
        let _ = imp.deps.set(Deps {
            account: init.account,
            tasks: init.tasks,
            telemetry: init.telemetry,
        });
        dialog.follow_account();
        dialog.begin();
        dialog
    }

    #[cfg(test)]
    pub(crate) fn subject(&self) -> Option<Arc<ShareSubject>> {
        self.current_subject()
    }

    fn build_chrome(&self) -> Chrome {
        let cancel = gtk::Button::with_label(&gettext("Cancel"));
        let create = gtk::Button::builder()
            .label(gettext("Create Link"))
            .css_classes(["suggested-action"])
            .build();
        let header = adw::HeaderBar::new();
        header.pack_start(&cancel);
        header.pack_end(&create);
        let banner = adw::Banner::builder().use_markup(false).revealed(false).build();
        let footer = gtk::Label::builder()
            .css_classes(["dim-label", "caption"])
            .margin_top(6)
            .margin_bottom(6)
            .margin_start(12)
            .margin_end(12)
            .wrap(true)
            .build();
        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&header);
        toolbar.add_top_bar(&banner);
        toolbar.add_bottom_bar(&footer);
        self.set_child(Some(&toolbar));
        let dialog = self.downgrade();
        cancel.connect_clicked(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.close();
            }
        });
        let dialog = self.downgrade();
        create.connect_clicked(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.create();
            }
        });
        // A create in flight would make a link nobody sees; the sheet stays until it answers.
        self.connect_close_attempt(|dialog| {
            dialog.alert(&gettext("The link is on its way. Wait for it before closing."));
        });
        Chrome {
            toolbar,
            header,
            banner,
            cancel,
            create,
            footer,
        }
    }

    fn follow_account(&self) {
        let Some(deps) = self.imp().deps.get() else {
            return;
        };
        let mut status = deps.account.status.clone();
        let mut start = deps.account.start.clone();
        let dialog = self.downgrade();
        let following_status = glib::spawn_future_local(async move {
            while status.changed().await.is_ok() {
                let Some(dialog) = dialog.upgrade() else {
                    return;
                };
                dialog.account_changed();
            }
        });
        let dialog = self.downgrade();
        let following_start = glib::spawn_future_local(async move {
            while start.changed().await.is_ok() {
                let Some(dialog) = dialog.upgrade() else {
                    return;
                };
                dialog.account_changed();
            }
        });
        self.imp().following.replace(vec![following_status, following_start]);
    }

    // A read in flight, or a page the limits decided, stays while the account stays signed in.
    fn account_changed(&self) {
        let reading = self.signed_in() && self.account().is_some();
        let keep = match self.page() {
            Some(SheetPage::Created { .. }) => true,
            Some(
                SheetPage::Form
                | SheetPage::AtLimit
                | SheetPage::Unverified
                | SheetPage::Disabled
                | SheetPage::Failed(_)
                | SheetPage::Loading,
            ) => reading,
            _ => false,
        };
        if !keep {
            self.begin();
        }
    }

    fn begin(&self) {
        let Some(deps) = self.imp().deps.get() else {
            return;
        };
        let start = deps.account.start.borrow().clone();
        if let Some(reason) = account_unavailable_message(&start) {
            return self.show(SheetPage::Unavailable(reason));
        }
        if matches!(start, AccountStart::Starting) {
            return self.show(SheetPage::Loading);
        }
        match (self.signed_in(), self.imp().signing_in.borrow().is_some()) {
            (true, _) => self.load_limits(),
            (false, true) => self.show(SheetPage::SigningIn),
            (false, false) => self.show(SheetPage::SignedOut),
        }
    }

    fn signed_in(&self) -> bool {
        self.imp()
            .deps
            .get()
            .is_some_and(|deps| sheet_view::signed_in(&deps.account.status.borrow()))
    }

    fn account(&self) -> Option<Account> {
        self.imp().deps.get()?.account.account()
    }

    fn page(&self) -> Option<SheetPage> {
        self.imp().page.borrow().clone()
    }

    pub(super) fn load_limits(&self) {
        let imp = self.imp();
        let (Some(deps), Some(account)) = (imp.deps.get(), self.account()) else {
            return;
        };
        let read = imp.read.get() + 1;
        imp.read.set(read);
        self.show(SheetPage::Loading);
        let team = imp.target.borrow().clone();
        let dialog = self.downgrade();
        spawn_and_deliver(&deps.tasks, read_limits(account, team), move |result| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.limits_read(read, result);
            }
        });
    }

    fn limits_read(&self, read: u64, result: Result<LimitsRead, TaskFailure>) {
        let imp = self.imp();
        if imp.read.get() != read {
            return;
        }
        match result {
            Ok(Ok((limits, live))) => {
                let target = imp.target.borrow().clone();
                let team = sheet_view::chosen_team(&limits, target.as_deref());
                let page = sheet_view::page_for(&limits, team);
                if let Some(chrome) = imp.chrome.get() {
                    chrome.footer.set_label(&sheet_view::footer(&limits, team));
                }
                let max_rows = limits.max_rows;
                imp.limits.replace(Some(limits));
                imp.live.replace(live);
                match page == SheetPage::Form && self.rows_to_read() {
                    true => self.read_table(max_rows),
                    false => self.show(page),
                }
            }
            Ok(Err(AccountError::SignedOut)) => self.show(SheetPage::SignedOut),
            Ok(Err(error)) => self.show(SheetPage::Failed(load_error_message(&error))),
            Err(failure) => {
                tracing::warn!(%failure, "the share limits were not read");
                self.show(SheetPage::Failed(load_error_message(&AccountError::Protocol(
                    failure.to_string(),
                ))));
            }
        }
    }

    fn show(&self, page: SheetPage) {
        let imp = self.imp();
        let Some(chrome) = imp.chrome.get() else {
            return;
        };
        // A read still in flight answers a page the user has left.
        if page != SheetPage::Loading {
            imp.read.set(imp.read.get() + 1);
        }
        if let Some(left) = imp.form.borrow().as_ref() {
            imp.draft.replace(Some(left.values()));
        }
        let form = matches!(page, SheetPage::Form);
        chrome.banner.set_revealed(false);
        chrome.cancel.set_visible(form);
        chrome.create.set_visible(form);
        chrome.header.set_show_end_title_buttons(!form);
        chrome
            .toolbar
            .set_reveal_bottom_bars(matches!(page, SheetPage::Form | SheetPage::AtLimit));
        let subject = self.current_subject();
        let (content, focus) = match (&page, imp.limits.borrow().as_ref(), subject) {
            (SheetPage::Form, Some(limits), Some(subject)) => {
                let target = imp.target.borrow().clone();
                let fields = build_form(
                    self,
                    &subject,
                    limits,
                    form::Kept {
                        draft: imp.draft.borrow().as_ref(),
                        team: target.as_deref(),
                    },
                );
                let page = fields.page.clone().upcast::<gtk::Widget>();
                imp.form.replace(Some(fields));
                (page, None)
            }
            _ => {
                imp.form.replace(None);
                pages::page_widget(self, &page)
            }
        };
        chrome.toolbar.set_content(Some(&content));
        if let Some(focus) = focus {
            self.set_focus(Some(&focus));
        }
        imp.page.replace(Some(page));
        self.set_busy(false);
    }

    fn set_busy(&self, busy: bool) {
        let imp = self.imp();
        imp.busy.set(busy);
        self.set_can_close(!busy);
        if let Some(chrome) = imp.chrome.get() {
            chrome.create.set_sensitive(!busy);
            chrome.cancel.set_sensitive(!busy);
            match busy {
                true => chrome.create.set_child(Some(&adw::Spinner::new())),
                false => chrome.create.set_label(&gettext("Create Link")),
            }
        }
        if let Some(form) = imp.form.borrow().as_ref() {
            form.page.set_sensitive(!busy);
        }
    }

    fn alert(&self, message: &str) {
        if let Some(chrome) = self.imp().chrome.get() {
            chrome.banner.set_title(message);
            chrome.banner.set_revealed(true);
        }
    }

    fn create(&self) {
        let imp = self.imp();
        if imp.busy.get() {
            return;
        }
        let (Some(deps), Some(account), Some(subject)) = (imp.deps.get(), self.account(), self.current_subject())
        else {
            return;
        };
        let (Some(limits), Some(form)) = (
            imp.limits.borrow().clone(),
            imp.form.borrow().as_ref().map(form::FormFields::values),
        ) else {
            return;
        };
        self.set_busy(true);
        let dialog = self.downgrade();
        spawn_and_deliver(
            &deps.tasks,
            async move {
                let snapshot = subject.rows.as_ref().map(|rows| rows.snapshot(limits.max_rows));
                account.create_share(subject.request(&form, &limits, snapshot)).await
            },
            move |result| {
                if let Some(dialog) = dialog.upgrade() {
                    dialog.created(result);
                }
            },
        );
    }

    fn created(&self, result: Result<Result<CreatedShare, AccountError>, TaskFailure>) {
        self.set_busy(false);
        let error = match result {
            // A link GTK cannot show is no link to hand over.
            Ok(Ok(created)) if created.url.chars().any(char::is_control) => {
                AccountError::Protocol("the link holds a control character".to_owned())
            }
            Ok(Ok(created)) => {
                let copied = crate::ui::clipboard::put_text(self, created.url.clone())
                    .inspect_err(|error| tracing::warn!(?error, "the new link did not reach the clipboard"))
                    .is_ok();
                self.imp().draft.replace(None);
                self.imp().form.replace(None);
                return self.show(SheetPage::Created {
                    url: created.url,
                    copied,
                    columns_truncated: created.columns_truncated,
                });
            }
            Ok(Err(error)) => error,
            Err(failure) => AccountError::Protocol(failure.to_string()),
        };
        match error.code() {
            "account.signed_out" => self.show(SheetPage::SignedOut),
            // The limits say what changed, and their page says it.
            "account.share_limit_reached" | "account.email_unverified" | "account.sharing_disabled" => {
                self.load_limits();
            }
            _ => self.alert(&share_error_message(&error)),
        }
    }

    pub(super) fn revoke(&self, id: String) {
        let imp = self.imp();
        let (Some(deps), Some(account)) = (imp.deps.get(), self.account()) else {
            return;
        };
        if imp.busy.replace(true) {
            return;
        }
        self.show_busy_list();
        let dialog = self.downgrade();
        spawn_and_deliver(
            &deps.tasks,
            async move { account.revoke_share(&id).await },
            move |result| {
                let Some(dialog) = dialog.upgrade() else {
                    return;
                };
                dialog.imp().busy.set(false);
                match result {
                    Ok(Ok(())) => dialog.load_limits(),
                    Ok(Err(error)) => {
                        dialog.show(SheetPage::AtLimit);
                        dialog.alert(&account_error_message(&error));
                    }
                    Err(failure) => {
                        tracing::warn!(%failure, "the revoke did not finish");
                        dialog.show(SheetPage::AtLimit);
                    }
                }
            },
        );
    }

    // The Revoke buttons go insensitive while one runs.
    fn show_busy_list(&self) {
        if let Some(chrome) = self.imp().chrome.get() {
            let (list, _) = pages::page_widget(self, &SheetPage::AtLimit);
            chrome.toolbar.set_content(Some(&list));
        }
    }

    pub(super) fn sign_in(&self) {
        let imp = self.imp();
        let (Some(deps), Some(account)) = (imp.deps.get(), self.account()) else {
            return;
        };
        let cancel = CancellationToken::new();
        if let Some(earlier) = imp.signing_in.replace(Some(cancel.clone())) {
            earlier.cancel();
        }
        let attempt = imp.sign_in_attempt.get() + 1;
        imp.sign_in_attempt.set(attempt);
        self.show(SheetPage::SigningIn);
        let telemetry = deps.telemetry.clone();
        let dialog = self.downgrade();
        spawn_and_deliver(
            &deps.tasks,
            async move { account.sign_in(cancel.cancelled_owned()).await },
            move |result| {
                let Some(dialog) = dialog.upgrade() else {
                    return;
                };
                if dialog.imp().sign_in_attempt.get() != attempt {
                    return;
                }
                dialog.imp().signing_in.replace(None);
                dialog.signed_in_with(result, &telemetry);
            },
        );
    }

    fn signed_in_with(&self, result: Result<Result<(), AccountError>, TaskFailure>, telemetry: &Telemetry) {
        let account_id = self.imp().deps.get().and_then(|deps| {
            let status = deps.account.status.borrow();
            status.entitlement().map(|entitlement| entitlement.claims().sub.clone())
        });
        if let (true, Some(account_id)) = (self.signed_in(), account_id) {
            telemetry.signed_in(&account_id);
        }
        // The account's own watch may have moved the sheet on already.
        if matches!(self.page(), Some(SheetPage::SigningIn | SheetPage::SignedOut)) {
            self.begin();
        }
        match result {
            // Over the device limit the account is still signed in, and sharing needs no license.
            Ok(Err(error)) if !self.signed_in() && !matches!(error, AccountError::SignInCanceled) => {
                self.alert(&account_error_message(&error));
            }
            Err(failure) => tracing::warn!(%failure, "the sign-in did not finish"),
            Ok(_) => {}
        }
    }

    pub(super) fn cancel_sign_in(&self) {
        if let Some(signing_in) = self.imp().signing_in.take() {
            signing_in.cancel();
        }
        self.begin();
    }

    pub(super) fn open_account(&self) {
        if let Some(deps) = self.imp().deps.get() {
            self.open_uri(&format!("{}/", deps.account.portal));
        }
    }

    pub(super) fn copy_link(&self) {
        if let Some(SheetPage::Created { url, .. }) = self.page() {
            match crate::ui::clipboard::put_text(self, url) {
                Ok(()) => self.alert(&gettext("Copied to clipboard")),
                Err(error) => self.alert(&error.message()),
            }
        }
    }

    pub(super) fn open_link(&self) {
        if let Some(SheetPage::Created { url, .. }) = self.page() {
            self.open_uri(&url);
        }
    }

    pub(super) fn open_uri(&self, uri: &str) {
        let window = self.root().and_downcast::<gtk::Window>();
        let dialog = self.downgrade();
        gtk::UriLauncher::new(uri).launch(window.as_ref(), gio::Cancellable::NONE, move |launched| {
            if let (Err(error), Some(dialog)) = (launched, dialog.upgrade()) {
                tracing::warn!(%error, "the browser did not open");
                dialog.alert(&gettext("TablePro could not open the page in a web browser."));
            }
        });
    }
}

// At the limit, the live links the sheet offers to revoke: the team's for a team link.
async fn read_limits(account: Account, team: Option<String>) -> LimitsRead {
    let limits = account.share_limits().await?;
    let team = sheet_view::chosen_team(&limits, team.as_deref()).map(|team| team.id.clone());
    if sheet_view::page_for(&limits, sheet_view::chosen_team(&limits, team.as_deref())) != SheetPage::AtLimit {
        return Ok((limits, Vec::new()));
    }
    let mut live = Vec::new();
    let mut cursor: Option<String> = None;
    for _ in 0..LIST_PAGES {
        let page = account.list_shares(true, team.as_deref(), cursor.as_deref()).await?;
        live.extend(page.shares);
        match page.next_cursor {
            Some(next) => cursor = Some(next),
            None => break,
        }
    }
    Ok((limits, live))
}

fn load_error_message(error: &AccountError) -> String {
    match error {
        AccountError::Unreachable(_) => share_error_message(error),
        _ => account_error_message(error),
    }
}
