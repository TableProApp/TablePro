use std::cell::{Cell, OnceCell, RefCell};
use std::rc::Rc;
use std::sync::OnceLock;

use chrono::Utc;
use glib::subclass::Signal;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_account::{AccountError, AccountStatus, Device, Profile, read_offline_file_blocking};
use tablepro_session::runtime::Tasks;
use tokio_util::sync::CancellationToken;

use super::account_view::{self, Facts, Fetch, Listing, Mode, Notice, NoticeAction, Plan, PlanRow, Removal};
use super::device_limit_dialog::DeviceLimitDialog;
use crate::i18n::{gettext, gettext_f};
use crate::services::account_service::{AccountHandle, AccountStart};
use crate::services::telemetry::Telemetry;
use crate::ui::error_text::{account_error_message, offline_file_message};
use crate::ui::icons;

const CANCEL: &str = "cancel";
const REMOVE: &str = "remove";
// The source macOS's Settings > Account sends, so upgrade_clicked and the pricing page's referrer read the same
// from both apps; the query goes before the fragment, where the site reads it.
const UPGRADE_SOURCE: &str = "app-settings";
const PRICING: &str = "https://tablepro.app/?ref=app-settings#pricing";
const LICENSING_GUIDE: &str = "https://docs.tablepro.app/features/licensing";

mod imp {
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/preferences-account-page.ui")]
    pub struct AccountPage {
        #[template_child]
        pub account_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub plan_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub features_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub devices_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub manage_devices_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub teams_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub offline_group: TemplateChild<adw::PreferencesGroup>,
        pub(super) deps: OnceCell<Deps>,
        pub(super) rows: RefCell<Vec<(adw::PreferencesGroup, gtk4::Widget)>>,
        pub(super) profile: RefCell<Fetch<Profile>>,
        pub(super) devices: RefCell<Fetch<Vec<Device>>>,
        pub(super) signing_in: RefCell<Option<CancellationToken>>,
        // Moved by each sign-in, so one that a later one replaced ends without touching the page.
        pub(super) sign_in_attempt: Cell<u64>,
        pub(super) failure: RefCell<Option<String>>,
        pub(super) busy: Cell<bool>,
        pub(super) shown_mode: Cell<Option<Mode>>,
        // A sign-in started here sends signed_in once the account's ID is known.
        pub(super) signed_in_pending: Cell<bool>,
        pub(super) limit_dialog: RefCell<Option<Rc<DeviceLimitDialog>>>,
        pub(super) following: RefCell<Vec<glib::JoinHandle<()>>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for AccountPage {
        const NAME: &'static str = "TableProAccountPage";
        type Type = super::AccountPage;
        type ParentType = adw::PreferencesPage;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for AccountPage {
        fn dispose(&self) {
            for following in self.following.take() {
                following.abort();
            }
            if let Some(signing_in) = self.signing_in.take() {
                signing_in.cancel();
            }
        }

        fn signals() -> &'static [Signal] {
            static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
            SIGNALS.get_or_init(|| {
                vec![
                    Signal::builder("toast")
                        .param_types([adw::Toast::static_type()])
                        .build(),
                ]
            })
        }
    }

    impl WidgetImpl for AccountPage {
        fn map(&self) {
            self.parent_map();
            self.obj().details_shown();
        }
    }

    impl PreferencesPageImpl for AccountPage {}
}

pub(super) struct Deps {
    handle: AccountHandle,
    tasks: Tasks,
    telemetry: Telemetry,
}

glib::wrapper! {
    pub struct AccountPage(ObjectSubclass<imp::AccountPage>)
        @extends adw::PreferencesPage, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for AccountPage {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl AccountPage {
    pub(super) fn bind(&self, handle: AccountHandle, tasks: Tasks, telemetry: Telemetry) {
        let imp = self.imp();
        let page = self.downgrade();
        imp.manage_devices_button.connect_clicked(move |_| {
            if let Some(page) = page.upgrade() {
                page.open_portal("/devices");
            }
        });
        let mut status = handle.status.clone();
        let mut start = handle.start.clone();
        if imp
            .deps
            .set(Deps {
                handle,
                tasks,
                telemetry,
            })
            .is_err()
        {
            return;
        }
        let page = self.downgrade();
        let follow_status = glib::spawn_future_local(async move {
            while status.changed().await.is_ok() {
                let Some(page) = page.upgrade() else {
                    return;
                };
                page.status_changed();
            }
        });
        let page = self.downgrade();
        let follow_start = glib::spawn_future_local(async move {
            while start.changed().await.is_ok() {
                let Some(page) = page.upgrade() else {
                    return;
                };
                page.status_changed();
            }
        });
        imp.following.replace(vec![follow_status, follow_start]);
        self.status_changed();
    }

    pub(super) fn connect_toast<F: Fn(&Self, &adw::Toast) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "toast",
            false,
            glib::closure_local!(move |page: &Self, toast: adw::Toast| f(page, &toast)),
        )
    }

    // What /v2/me and /v2/devices answered; the page fetches them itself while it is shown.
    pub(crate) fn show_details(&self, profile: Fetch<Profile>, devices: Fetch<Vec<Device>>) {
        let imp = self.imp();
        if let (Fetch::Loaded(loaded), Some(deps)) = (&profile, imp.deps.get()) {
            deps.telemetry.account_changed(Some(&loaded.id));
            if imp.signed_in_pending.replace(false) {
                deps.telemetry.signed_in(&loaded.id);
            }
        }
        imp.profile.replace(profile);
        imp.devices.replace(devices);
        self.render();
    }

    pub(crate) fn sign_in(&self) {
        let imp = self.imp();
        let Some((deps, account)) = self.ready() else {
            return;
        };
        let cancel = CancellationToken::new();
        if let Some(earlier) = imp.signing_in.replace(Some(cancel.clone())) {
            earlier.cancel();
        }
        let attempt = imp.sign_in_attempt.get() + 1;
        imp.sign_in_attempt.set(attempt);
        imp.failure.replace(None);
        self.render();
        // Cancel ends the wait for the browser only, so tokens already on their way are still stored.
        let signing_in = deps
            .tasks
            .spawn_task(async move { account.sign_in(cancel.cancelled_owned()).await });
        let page = self.downgrade();
        glib::spawn_future_local(async move {
            let result = signing_in.await;
            let Some(page) = page.upgrade() else {
                return;
            };
            if page.imp().sign_in_attempt.get() != attempt {
                return;
            }
            page.imp().signing_in.replace(None);
            match result {
                Ok(Err(AccountError::SignInCanceled)) => page.render(),
                Ok(result) => page.signed_in(result),
                Err(error) => {
                    tracing::warn!(%error, "the sign-in did not finish");
                    page.render();
                }
            }
        });
    }

    pub(crate) fn cancel_sign_in(&self) {
        if let Some(signing_in) = self.imp().signing_in.take() {
            signing_in.cancel();
        }
        self.render();
    }

    pub(crate) fn sign_out(&self) {
        let Some((deps, account)) = self.ready() else {
            return;
        };
        self.imp().signed_in_pending.set(false);
        deps.telemetry.signed_out();
        self.run(async move { account.sign_out().await }, |page, result| {
            if let Err(error) = result {
                page.toast(&account_error_message(&error));
            }
        });
    }

    pub(crate) fn refresh(&self) {
        let Some((_, account)) = self.ready() else {
            return;
        };
        self.run(async move { account.refresh_entitlement().await }, |page, result| {
            if let Err(error) = result
                && !matches!(error, AccountError::DeviceLimitReached { .. })
            {
                page.toast(&account_error_message(&error));
            }
            page.reload_details();
        });
    }

    pub(crate) fn import_offline_file(&self, token: String) {
        let Some((_, account)) = self.ready() else {
            return;
        };
        self.run(
            async move { account.import_offline_file(&token).await },
            |page, result| match result {
                Ok(()) => {
                    let until = page
                        .status()
                        .entitlement()
                        .map(|entitlement| account_view::day(entitlement.expires_at()))
                        .unwrap_or_default();
                    page.toast(&gettext_f(
                        "Offline file imported. It is valid until {date}.",
                        &[("date", &until)],
                    ));
                }
                Err(error) => page.toast(&gettext_f(
                    "The offline file was not imported. {reason}",
                    &[("reason", &account_error_message(&error))],
                )),
            },
        );
    }

    pub(crate) fn present_device_limit(&self) {
        let imp = self.imp();
        let Some(deps) = imp.deps.get() else {
            return;
        };
        if imp.limit_dialog.borrow().is_some() {
            return;
        }
        let Some(holding) = deps.handle.status.borrow().device_limit().map(<[Device]>::to_vec) else {
            return;
        };
        let page = self.downgrade();
        let dialog = DeviceLimitDialog::new(holding, deps.handle.clone(), deps.tasks.clone(), move |name| {
            if let Some(page) = page.upgrade() {
                page.toast(&gettext_f(
                    "Removed {name}. The paid features work on this computer now.",
                    &[("name", name)],
                ));
                page.reload_details();
            }
        });
        let page = self.downgrade();
        dialog.dialog.connect_closed(move |_| {
            if let Some(page) = page.upgrade() {
                page.imp().limit_dialog.replace(None);
            }
        });
        dialog.dialog.present(Some(self));
        imp.limit_dialog.replace(Some(dialog));
    }

    #[cfg(test)]
    pub(crate) fn device_limit_dialog(&self) -> Option<Rc<DeviceLimitDialog>> {
        self.imp().limit_dialog.borrow().clone()
    }

    fn ready(&self) -> Option<(&Deps, tablepro_account::Account)> {
        let deps = self.imp().deps.get()?;
        Some((deps, deps.handle.account()?))
    }

    fn status(&self) -> AccountStatus {
        self.imp()
            .deps
            .get()
            .map(|deps| deps.handle.status.borrow().clone())
            .unwrap_or_default()
    }

    fn signed_in(&self, result: Result<(), AccountError>) {
        let imp = self.imp();
        match &result {
            Ok(()) => {}
            Err(AccountError::DeviceLimitReached { .. }) => self.present_device_limit(),
            // Signed in after all: the notices say what went wrong.
            Err(_) if matches!(self.status(), AccountStatus::SignedIn(_)) => {}
            Err(error) => {
                imp.failure.replace(Some(account_error_message(error)));
                self.render();
                return;
            }
        }
        match self.status().entitlement().map(|it| it.claims().sub.clone()) {
            Some(account_id) => {
                if let Some(deps) = imp.deps.get() {
                    deps.telemetry.signed_in(&account_id);
                }
            }
            None => imp.signed_in_pending.set(true),
        }
        self.reload_details();
    }

    fn run<F, T>(&self, work: F, done: impl FnOnce(&Self, T) + 'static)
    where
        F: Future<Output = T> + Send + 'static,
        T: Send + 'static,
    {
        let imp = self.imp();
        let Some(deps) = imp.deps.get() else {
            return;
        };
        imp.busy.set(true);
        self.render();
        let running = deps.tasks.spawn_task(work);
        let page = self.downgrade();
        glib::spawn_future_local(async move {
            let result = running.await;
            let Some(page) = page.upgrade() else {
                return;
            };
            page.imp().busy.set(false);
            match result {
                Ok(result) => done(&page, result),
                Err(error) => tracing::warn!(%error, "an account task did not finish"),
            }
            page.render();
        });
    }

    fn status_changed(&self) {
        let imp = self.imp();
        let mode = account_view::mode(&self.status());
        if imp.shown_mode.replace(Some(mode)) != Some(mode) {
            imp.profile.replace(Fetch::Idle);
            imp.devices.replace(Fetch::Idle);
            if mode == Mode::SignedIn {
                self.load_details();
            }
        }
        self.render();
    }

    fn reload_details(&self) {
        let imp = self.imp();
        imp.profile.replace(Fetch::Idle);
        imp.devices.replace(Fetch::Idle);
        self.load_details();
    }

    // Each time the page is shown, so what changed in the portal or on another device shows then.
    fn details_shown(&self) {
        if matches!(*self.imp().profile.borrow(), Fetch::Loading) {
            return;
        }
        self.reload_details();
    }

    fn load_details(&self) {
        let imp = self.imp();
        if !self.is_mapped() || !matches!(*imp.profile.borrow(), Fetch::Idle) {
            return;
        }
        let Some((deps, account)) = self.ready() else {
            return;
        };
        if account_view::mode(&self.status()) != Mode::SignedIn {
            return;
        }
        imp.profile.replace(Fetch::Loading);
        imp.devices.replace(Fetch::Loading);
        self.render();
        let fetching = deps
            .tasks
            .spawn_task(async move { (account.profile().await, account.devices().await) });
        let page = self.downgrade();
        glib::spawn_future_local(async move {
            let fetched = fetching.await;
            let Some(page) = page.upgrade() else {
                return;
            };
            // A sign-out while the answers were on their way leaves nothing to show them in.
            if account_view::mode(&page.status()) != Mode::SignedIn {
                return;
            }
            let (profile, devices) = match fetched {
                Ok((profile, devices)) => (fetch(profile), fetch(devices)),
                Err(error) => {
                    tracing::warn!(%error, "the account details were not fetched");
                    (Fetch::Idle, Fetch::Idle)
                }
            };
            page.show_details(profile, devices);
        });
    }

    fn render(&self) {
        let imp = self.imp();
        for (group, row) in imp.rows.take() {
            group.remove(&row);
        }
        let status = self.status();
        let machine_id = self
            .ready()
            .map(|(_, account)| account.machine_id().as_str().to_owned());
        let profile = imp.profile.borrow();
        let devices = imp.devices.borrow();
        let facts = Facts {
            status: &status,
            profile: &profile,
            devices: &devices,
            machine_id: machine_id.as_deref(),
            now: Utc::now(),
        };
        let mode = account_view::mode(&status);
        self.render_account(&facts, mode);
        imp.plan_group.set_visible(mode != Mode::SignedOut);
        if mode != Mode::SignedOut {
            self.render_plan(&facts);
        }
        for feature in account_view::features(&facts) {
            let row = adw::ActionRow::builder().title(&feature.title).build();
            if let Some(subtitle) = &feature.subtitle {
                row.set_subtitle(subtitle);
            }
            row.add_suffix(&included(feature.included));
            self.add(&imp.features_group, &row);
        }
        if mode == Mode::SignedOut {
            let buy = self.web_row(&gettext("Buy a License"), PRICING);
            let page = self.downgrade();
            buy.connect_activated(move |_| {
                if let Some(page) = page.upgrade() {
                    page.upgrade_clicked();
                }
            });
            self.add(&imp.features_group, &buy);
        }
        let guide = self.web_row(&gettext("Learn More About Licensing"), LICENSING_GUIDE);
        self.add(&imp.features_group, &guide);
        imp.devices_group.set_visible(mode == Mode::SignedIn);
        imp.teams_group.set_visible(mode == Mode::SignedIn);
        if mode == Mode::SignedIn {
            self.render_devices(&facts);
            self.render_teams(&profile);
        }
        self.render_offline(&facts, machine_id.as_deref());
    }

    fn render_account(&self, facts: &Facts<'_>, mode: Mode) {
        let imp = self.imp();
        let group = imp.account_group.get();
        let start = imp.deps.get().map(|deps| deps.handle.start.borrow().clone());
        let unavailable = match &start {
            None | Some(AccountStart::Starting | AccountStart::Ready(_)) => None,
            Some(AccountStart::NoMachineId(detail)) => Some(gettext_f(
                "TablePro accounts need this computer’s machine ID, which could not be read: {detail}",
                &[("detail", detail)],
            )),
            Some(AccountStart::Misconfigured(detail)) => Some(gettext_f(
                "This development build’s account settings are not valid: {detail}",
                &[("detail", detail)],
            )),
            Some(AccountStart::Failed(error)) => Some(account_error_message(error)),
        };
        if let Some(reason) = unavailable {
            self.add(&group, &warning_row(&gettext("Accounts Unavailable"), &reason));
            return;
        }
        let ready = matches!(start, Some(AccountStart::Ready(_)));
        let identity = account_view::identity(facts);
        match (mode, identity) {
            (Mode::SignedIn, Some(identity)) => {
                let row = identity_row(&identity.name, identity.email.as_deref());
                row.add_suffix(&self.sign_out_button());
                self.add(&group, &row);
                self.add(&group, &self.link_row(&gettext("Manage Account"), None, "/"));
            }
            // Without an entitlement only /v2/me names the account, and it can fail.
            (Mode::SignedIn, None) => {
                let row = match facts.profile {
                    Fetch::Failed(error) => {
                        let row = warning_row(&gettext("Signed In"), &account_error_message(error));
                        row.add_suffix(&self.try_again_button());
                        row
                    }
                    Fetch::Idle | Fetch::Loading | Fetch::Loaded(_) => {
                        let row = adw::ActionRow::builder()
                            .title(gettext("Signed In"))
                            .subtitle(gettext("Loading the account…"))
                            .build();
                        row.add_suffix(&adw::Spinner::new());
                        row
                    }
                };
                row.add_suffix(&self.sign_out_button());
                self.add(&group, &row);
            }
            (Mode::Offline, identity) => {
                let name = identity.map_or_else(|| gettext("Offline File"), |identity| identity.name);
                let row = identity_row(&name, Some(&gettext("Using an offline file")));
                row.add_suffix(&self.sign_in_button(ready, false));
                self.add(&group, &row);
            }
            (Mode::SignedOut, _) => self.render_sign_in(&group, ready),
        }
        if let Some(failure) = imp.failure.borrow().as_ref() {
            self.add(&group, &warning_row(&gettext("Sign-In Failed"), failure));
        }
    }

    fn render_sign_in(&self, group: &adw::PreferencesGroup, ready: bool) {
        let signing_in = self.imp().signing_in.borrow().is_some();
        let row = adw::ActionRow::builder()
            .title(gettext("Sign In to TablePro"))
            .subtitle(match signing_in {
                true => gettext("Finish signing in in the web browser that opened."),
                false => {
                    gettext("Use your plan’s paid features on this computer. Everything else works without an account.")
                }
            })
            .build();
        if signing_in {
            row.add_suffix(&adw::Spinner::new());
            let cancel = gtk4::Button::builder()
                .label(gettext("Cancel"))
                .valign(gtk4::Align::Center)
                .build();
            let page = self.downgrade();
            cancel.connect_clicked(move |_| {
                if let Some(page) = page.upgrade() {
                    page.cancel_sign_in();
                }
            });
            row.add_suffix(&cancel);
        } else {
            row.add_suffix(&self.sign_in_button(ready, true));
        }
        self.add(group, &row);
    }

    fn sign_out_button(&self) -> gtk4::Button {
        let button = gtk4::Button::builder()
            .label(gettext("Sign Out"))
            .valign(gtk4::Align::Center)
            .sensitive(!self.imp().busy.get())
            .build();
        let page = self.downgrade();
        button.connect_clicked(move |_| {
            if let Some(page) = page.upgrade() {
                page.sign_out();
            }
        });
        button
    }

    // Refreshes the entitlement too, as every Try Again does (clients.md, Shared rules).
    fn try_again_button(&self) -> gtk4::Button {
        let button = gtk4::Button::builder()
            .label(gettext("Try Again"))
            .valign(gtk4::Align::Center)
            .sensitive(!self.imp().busy.get())
            .build();
        let page = self.downgrade();
        button.connect_clicked(move |_| {
            if let Some(page) = page.upgrade() {
                page.refresh();
            }
        });
        button
    }

    fn sign_in_button(&self, ready: bool, suggested: bool) -> gtk4::Button {
        let button = gtk4::Button::builder()
            .label(gettext("Sign In…"))
            .valign(gtk4::Align::Center)
            .sensitive(ready && !self.imp().busy.get())
            .build();
        if suggested {
            button.add_css_class("suggested-action");
        }
        let page = self.downgrade();
        button.connect_clicked(move |_| {
            if let Some(page) = page.upgrade() {
                page.sign_in();
            }
        });
        button
    }

    fn render_plan(&self, facts: &Facts<'_>) {
        let group = self.imp().plan_group.get();
        for notice in account_view::notices(facts) {
            let row = self.notice_row(&notice);
            self.add(&group, &row);
        }
        match account_view::plan(facts) {
            Ok(Plan::Free) => {
                let row = adw::ActionRow::builder()
                    .title(gettext("Free"))
                    .subtitle(gettext(
                        "Starter or a seat in a team adds the paid features on 3 of your devices.",
                    ))
                    .build();
                let upgrade = gtk4::Button::builder()
                    .label(gettext("Upgrade…"))
                    .valign(gtk4::Align::Center)
                    .build();
                let page = self.downgrade();
                upgrade.connect_clicked(move |_| {
                    if let Some(page) = page.upgrade() {
                        page.upgrade_clicked();
                        page.open_portal("/billing");
                    }
                });
                row.add_suffix(&upgrade);
                self.add(&group, &row);
            }
            Ok(Plan::Licenses(rows)) => {
                for license in rows {
                    let row = self.plan_row(&license);
                    self.add(&group, &row);
                }
            }
            Err(listing) => self.add_listing_state(&group, listing),
        }
    }

    fn plan_row(&self, license: &PlanRow) -> adw::ActionRow {
        let row = adw::ActionRow::builder()
            .use_markup(false)
            .title(&license.title)
            .subtitle(&license.subtitle)
            .build();
        let Some(path) = license.billing.clone() else {
            return row;
        };
        let billing = gtk4::Button::builder()
            .label(gettext("Billing…"))
            .valign(gtk4::Align::Center)
            .tooltip_text(gettext("Opens in your web browser"))
            .build();
        let page = self.downgrade();
        billing.connect_clicked(move |_| {
            if let Some(page) = page.upgrade() {
                page.open_portal(&path);
            }
        });
        row.add_suffix(&billing);
        row
    }

    fn render_devices(&self, facts: &Facts<'_>) {
        let group = self.imp().devices_group.get();
        let rows = match account_view::devices(facts) {
            Listing::Rows(rows) => rows,
            other => return self.add_listing_state(&group, other),
        };
        let busy = self.imp().busy.get();
        for device in rows {
            let row = adw::ActionRow::builder()
                .use_markup(false)
                .title(&device.name)
                .subtitle(&device.subtitle)
                .build();
            match &device.removal {
                Removal::ThisDevice => {}
                Removal::KeptUntil(until) => row.add_suffix(&dim_label(until)),
                Removal::Allowed => {
                    let remove = gtk4::Button::builder()
                        .label(gettext("Remove"))
                        .valign(gtk4::Align::Center)
                        .sensitive(!busy)
                        .build();
                    remove.update_property(&[gtk4::accessible::Property::Label(&gettext_f(
                        "Remove {name}",
                        &[("name", &device.name)],
                    ))]);
                    let page = self.downgrade();
                    let (id, name) = (device.id.clone(), device.name.clone());
                    remove.connect_clicked(move |_| {
                        if let Some(page) = page.upgrade() {
                            page.confirm_removal(id.clone(), name.clone());
                        }
                    });
                    row.add_suffix(&remove);
                }
            }
            self.add(&group, &row);
        }
    }

    fn render_teams(&self, profile: &Fetch<Profile>) {
        let group = self.imp().teams_group.get();
        match account_view::teams(profile) {
            Listing::Rows(rows) if rows.is_empty() => {
                let row = adw::ActionRow::builder()
                    .title(gettext("Not in a Team"))
                    .subtitle(gettext("A team’s owner or admin can invite you."))
                    .build();
                self.add(&group, &row);
            }
            Listing::Rows(rows) => {
                for team in rows {
                    let row = self.link_row(&team.title, Some(&team.subtitle), &team.path);
                    self.add(&group, &row);
                }
            }
            other => self.add_listing_state(&group, other),
        }
    }

    fn render_offline(&self, facts: &Facts<'_>, machine_id: Option<&str>) {
        let imp = self.imp();
        let group = imp.offline_group.get();
        let busy = imp.busy.get();
        if let Some(verification) = account_view::verification(facts) {
            let row = adw::ActionRow::builder()
                .title(&verification.title)
                .subtitle(&verification.subtitle)
                .build();
            if account_view::mode(facts.status) == Mode::SignedIn {
                let refresh = gtk4::Button::builder()
                    .label(gettext("Refresh"))
                    .valign(gtk4::Align::Center)
                    .sensitive(!busy)
                    .build();
                let page = self.downgrade();
                refresh.connect_clicked(move |_| {
                    if let Some(page) = page.upgrade() {
                        page.refresh();
                    }
                });
                row.add_suffix(&refresh);
            }
            self.add(&group, &row);
        }
        let import = adw::ButtonRow::builder()
            .title(gettext("Import Offline File…"))
            .sensitive(self.ready().is_some() && !busy)
            .build();
        let page = self.downgrade();
        import.connect_activated(move |_| {
            if let Some(page) = page.upgrade() {
                page.choose_offline_file();
            }
        });
        if let Some(machine_id) = machine_id {
            // Copy gives the exact value; selecting would take the line break too.
            let row = adw::ActionRow::builder()
                .use_markup(true)
                .title(gettext("Machine ID"))
                .subtitle(machine_id_markup(machine_id))
                .build();
            row.add_css_class("property");
            let copy = gtk4::Button::builder()
                .icon_name(icons::EDIT_COPY)
                .tooltip_text(gettext("Copy Machine ID"))
                .valign(gtk4::Align::Center)
                .build();
            copy.add_css_class("flat");
            copy.update_property(&[gtk4::accessible::Property::Label(&gettext("Copy Machine ID"))]);
            let page = self.downgrade();
            let text = machine_id.to_owned();
            copy.connect_clicked(move |_| {
                if let Some(page) = page.upgrade() {
                    crate::ui::clipboard::copy_text(&page, text.clone(), |message| page.toast(message));
                }
            });
            row.add_suffix(&copy);
            self.add(&group, &row);
        }
        self.add(&group, &import);
    }

    fn notice_row(&self, notice: &Notice) -> adw::ActionRow {
        let row = warning_row(&notice.title, &notice.body);
        let Some(action) = &notice.action else {
            return row;
        };
        let label = match action {
            NoticeAction::ChooseDevice => gettext("Remove a Device…"),
            NoticeAction::Refresh => gettext("Try Again"),
            NoticeAction::Open { label, .. } => label.clone(),
        };
        let button = gtk4::Button::builder()
            .label(label)
            .valign(gtk4::Align::Center)
            .sensitive(!self.imp().busy.get())
            .build();
        let page = self.downgrade();
        let action = action.clone();
        button.connect_clicked(move |_| {
            let Some(page) = page.upgrade() else {
                return;
            };
            match &action {
                NoticeAction::ChooseDevice => page.present_device_limit(),
                NoticeAction::Refresh => page.refresh(),
                NoticeAction::Open { path, .. } => page.open_portal(path),
            }
        });
        row.add_suffix(&button);
        row
    }

    fn web_row(&self, title: &str, address: &'static str) -> adw::ActionRow {
        let row = adw::ActionRow::builder()
            .use_markup(false)
            .title(title)
            .activatable(true)
            .build();
        row.add_suffix(&decoration(icons::WEB_BROWSER));
        row.set_tooltip_text(Some(&gettext("Opens in your web browser")));
        let page = self.downgrade();
        row.connect_activated(move |_| {
            if let Some(page) = page.upgrade() {
                page.open_uri(address.to_owned());
            }
        });
        row
    }

    fn link_row(&self, title: &str, subtitle: Option<&str>, path: &str) -> adw::ActionRow {
        let row = adw::ActionRow::builder()
            .use_markup(false)
            .title(title)
            .activatable(true)
            .build();
        if let Some(subtitle) = subtitle {
            row.set_subtitle(subtitle);
        }
        row.add_suffix(&decoration(icons::WEB_BROWSER));
        row.set_tooltip_text(Some(&gettext("Opens in your web browser")));
        let page = self.downgrade();
        let path = path.to_owned();
        row.connect_activated(move |_| {
            if let Some(page) = page.upgrade() {
                page.open_portal(&path);
            }
        });
        row
    }

    fn add_listing_state<T>(&self, group: &adw::PreferencesGroup, listing: Listing<T>) {
        match listing {
            Listing::Loading => {
                let row = adw::ActionRow::builder().title(gettext("Loading…")).build();
                row.add_suffix(&adw::Spinner::new());
                self.add(group, &row);
            }
            Listing::Failed(reason) => {
                let row = warning_row(&gettext("Could Not Load"), &reason);
                row.add_suffix(&self.try_again_button());
                self.add(group, &row);
            }
            Listing::Rows(_) => {}
        }
    }

    fn add(&self, group: &adw::PreferencesGroup, row: &impl IsA<gtk4::Widget>) {
        group.add(row);
        self.imp().rows.borrow_mut().push((group.clone(), row.clone().upcast()));
    }

    fn confirm_removal(&self, id: String, name: String) {
        let alert = adw::AlertDialog::new(
            Some(&gettext_f("Remove {name}?", &[("name", &name)])),
            Some(&gettext(
                "TablePro on it signs out the next time it checks in. You can sign in on it again later.",
            )),
        );
        alert.add_response(CANCEL, &gettext("_Cancel"));
        alert.add_response(REMOVE, &gettext("_Remove"));
        alert.set_response_appearance(REMOVE, adw::ResponseAppearance::Destructive);
        alert.set_default_response(Some(CANCEL));
        alert.set_close_response(CANCEL);
        let page = self.clone();
        glib::spawn_future_local(async move {
            let parent: gtk4::Widget = page.clone().upcast();
            if crate::workspace::respond(&alert, &parent).await != REMOVE {
                return;
            }
            let Some((_, account)) = page.ready() else {
                return;
            };
            page.run(async move { account.remove_device(&id).await }, move |page, result| {
                match result {
                    Ok(()) => page.toast(&gettext_f("Removed {name}.", &[("name", &name)])),
                    Err(error) => page.toast(&account_error_message(&error)),
                }
                page.reload_details();
            });
        });
    }

    fn choose_offline_file(&self) {
        let filter = gtk4::FileFilter::new();
        filter.set_name(Some(&gettext("Offline Files")));
        filter.add_pattern("*.jwt");
        let filters = gio::ListStore::new::<gtk4::FileFilter>();
        filters.append(&filter);
        let dialog = gtk4::FileDialog::builder()
            .title(gettext("Import Offline File"))
            .modal(true)
            .filters(&filters)
            .default_filter(&filter)
            .build();
        let window = self.root().and_downcast::<gtk4::Window>();
        let page = self.downgrade();
        glib::spawn_future_local(async move {
            let Ok(file) = dialog.open_future(window.as_ref()).await else {
                return;
            };
            let (Some(page), Some(path)) = (page.upgrade(), file.path()) else {
                return;
            };
            let Some(deps) = page.imp().deps.get() else {
                return;
            };
            let reading = deps
                .tasks
                .spawn_blocking_task(move || read_offline_file_blocking(&path));
            match reading.await {
                Ok(Ok(token)) => page.import_offline_file(token),
                Ok(Err(error)) => page.toast(&offline_file_message(&error)),
                Err(error) => tracing::warn!(%error, "the offline file was not read"),
            }
        });
    }

    fn open_portal(&self, path: &str) {
        let Some(deps) = self.imp().deps.get() else {
            return;
        };
        self.open_uri(format!("{}{path}", deps.handle.portal));
    }

    fn open_uri(&self, address: String) {
        let window = self.root().and_downcast::<gtk4::Window>();
        let page = self.downgrade();
        gtk4::UriLauncher::new(&address).launch(window.as_ref(), gio::Cancellable::NONE, move |launched| {
            if let (Err(error), Some(page)) = (launched, page.upgrade()) {
                tracing::warn!(%error, "the account page was not opened");
                page.toast(&gettext_f("Could not open {address}", &[("address", &address)]));
            }
        });
    }

    fn upgrade_clicked(&self) {
        if let Some(deps) = self.imp().deps.get() {
            deps.telemetry.upgrade_clicked(UPGRADE_SOURCE);
        }
    }

    fn toast(&self, message: &str) {
        self.emit_by_name::<()>("toast", &[&crate::ui::plain_toast(message)]);
    }
}

fn fetch<T>(result: Result<T, AccountError>) -> Fetch<T> {
    match result {
        Ok(value) => Fetch::Loaded(value),
        Err(error) => Fetch::Failed(error),
    }
}

// Two even lines in a fixed-width font, for someone who types it on another computer.
fn machine_id_markup(machine_id: &str) -> String {
    let (first, second) = machine_id
        .split_at_checked(machine_id.len() / 2)
        .unwrap_or((machine_id, ""));
    format!(
        "<tt>{}\n{}</tt>",
        glib::markup_escape_text(first),
        glib::markup_escape_text(second)
    )
}

fn identity_row(name: &str, email: Option<&str>) -> adw::ActionRow {
    let row = adw::ActionRow::builder().use_markup(false).title(name).build();
    if let Some(email) = email {
        row.set_subtitle(email);
    }
    let avatar = adw::Avatar::builder()
        .size(40)
        .text(name)
        .show_initials(true)
        .accessible_role(gtk4::AccessibleRole::Presentation)
        .build();
    row.add_prefix(&avatar);
    row
}

fn warning_row(title: &str, body: &str) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .use_markup(false)
        .title(title)
        .subtitle(body)
        .build();
    let icon = decoration(icons::DIALOG_WARNING);
    icon.add_css_class("warning");
    row.add_prefix(&icon);
    row
}

fn decoration(icon: &str) -> gtk4::Image {
    gtk4::Image::builder()
        .icon_name(icon)
        .valign(gtk4::Align::Center)
        .accessible_role(gtk4::AccessibleRole::Presentation)
        .build()
}

fn included(included: bool) -> gtk4::Widget {
    match included {
        true => dim_label(&gettext("Included")).upcast(),
        false => {
            let icon = gtk4::Image::from_icon_name(icons::CHANGES_PREVENT);
            icon.add_css_class("dim-label");
            icon.set_tooltip_text(Some(&gettext("Not included")));
            icon.update_property(&[gtk4::accessible::Property::Label(&gettext("Not included"))]);
            icon.upcast()
        }
    }
}

fn dim_label(text: &str) -> gtk4::Label {
    let label = gtk4::Label::builder().label(text).valign(gtk4::Align::Center).build();
    label.add_css_class("dim-label");
    label
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use async_trait::async_trait;
    use chrono::TimeDelta;
    use tablepro_account::{
        Account, AccountSettings, AppClient, BrowserLauncher, CallbackPage, DeviceDescription, Endpoints,
        EntitlementClaims, EntitlementProblem, LicenseClaim, MachineId, Membership, SignedIn, TeamClaim, Url, fakes,
    };
    use tokio::sync::watch;

    use super::*;
    use crate::runtime::AppRuntime;
    use crate::test_support::{
        Approving, CloudStub, MemoryKeyring, OwnedWindow, assert_labelled, deliver, descendants, test_runtime,
        unlabelled_icon_buttons, wait_until,
    };

    const WAIT: Duration = Duration::from_secs(20);
    const PORTAL: &str = "http://account.localhost:5284";

    // Keeps the URL the page asked to open, and answers with `refusal` when given one.
    struct Browser {
        opened: Mutex<Vec<Url>>,
        refusal: Option<String>,
    }

    #[async_trait]
    impl BrowserLauncher for Browser {
        async fn open(&self, url: &Url) -> Result<(), String> {
            self.opened.lock().expect("the URLs").push(url.clone());
            self.refusal.clone().map_or(Ok(()), Err)
        }
    }

    struct Harness {
        page: AccountPage,
        status: watch::Sender<AccountStatus>,
        start: watch::Sender<AccountStart>,
        browser: Arc<Browser>,
        dir: tempfile::TempDir,
        // Without a key until a test begins it.
        telemetry: Telemetry,
        runtime: AppRuntime,
    }

    impl Harness {
        fn new(refusal: Option<&str>) -> Self {
            crate::register_test_resources();
            let runtime = test_runtime();
            let dir = tempfile::tempdir().expect("a temporary directory");
            let (status, status_receiver) = watch::channel(AccountStatus::SignedOut);
            let (start, start_receiver) = watch::channel(AccountStart::Starting);
            let browser = Arc::new(Browser {
                opened: Mutex::new(Vec::new()),
                refusal: refusal.map(str::to_owned),
            });
            let page = AccountPage::default();
            let telemetry = Telemetry::default();
            page.bind(
                AccountHandle {
                    status: status_receiver,
                    start: start_receiver,
                    portal: PORTAL.to_owned(),
                },
                runtime.tasks(),
                telemetry.clone(),
            );
            Self {
                page,
                status,
                start,
                browser,
                dir,
                telemetry,
                runtime,
            }
        }

        // An account whose service nothing answers, so only what a test sends shows.
        fn ready(&self) {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
            let base = format!("http://{}", listener.local_addr().expect("its address"));
            drop(listener);
            let endpoints = Endpoints::new(&base, &format!("{base}/v2")).expect("the endpoints");
            let machine = MachineId::derive("4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n").expect("a machine ID");
            self.ready_with(
                endpoints,
                fakes::keys().expect("the test key"),
                machine,
                self.browser.clone(),
            );
        }

        fn ready_with(
            &self,
            endpoints: Endpoints,
            keys: tablepro_account::EntitlementKeys,
            machine_id: MachineId,
            browser: Arc<dyn BrowserLauncher>,
        ) {
            let settings = AccountSettings {
                client: AppClient::LINUX,
                endpoints,
                device: DeviceDescription {
                    name: "Ada's laptop".to_owned(),
                    app_version: "0.1.0".to_owned(),
                    os_version: "Ubuntu 26.04".to_owned(),
                },
                machine_id,
                keys,
                account_file: self.dir.path().join("account.json"),
                callback_page: CallbackPage {
                    finished: String::new(),
                    unknown: String::new(),
                },
            };
            let account = Account::new(
                settings,
                Arc::new(MemoryKeyring::default()),
                browser,
                self.status.clone(),
            )
            .expect("an account");
            self.start.send_replace(AccountStart::Ready(account));
            self.settle();
        }

        fn send(&self, status: AccountStatus) {
            self.status.send_replace(status);
            self.settle();
        }

        fn share_usage_data(&self, collector: &crate::test_support::PostHogCollector) {
            let settings = crate::services::telemetry::TelemetrySettings {
                key: "phc_test".to_owned(),
                host: collector.url.clone(),
                state_file: self.dir.path().join("telemetry.json"),
                person: crate::services::telemetry::PersonProperties {
                    app_version: "0.1.0".to_owned(),
                    os_version: "Ubuntu 26.04".to_owned(),
                    architecture: "arm64".to_owned(),
                    locale: "en_US".to_owned(),
                },
            };
            self.telemetry.begin(settings, true, &self.runtime.tasks());
        }

        fn settle(&self) {
            crate::test_support::drain_main_context();
        }

        fn rows(&self, group: &adw::PreferencesGroup) -> Vec<adw::PreferencesRow> {
            descendants(group)
                .into_iter()
                .filter_map(|widget| widget.downcast::<adw::PreferencesRow>().ok())
                .collect()
        }

        fn titles(&self, group: &adw::PreferencesGroup) -> Vec<String> {
            self.rows(group).iter().map(|row| row.title().to_string()).collect()
        }

        fn row(&self, title: &str) -> adw::ActionRow {
            descendants(&self.page)
                .into_iter()
                .filter_map(|widget| widget.downcast::<adw::ActionRow>().ok())
                .find(|row| row.title() == title)
                .unwrap_or_else(|| panic!("no row {title}"))
        }

        fn button(&self, root: &impl IsA<gtk4::Widget>, label: &str) -> gtk4::Button {
            descendants(root)
                .into_iter()
                .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
                .find(|button| button.label().is_some_and(|text| text == label))
                .unwrap_or_else(|| panic!("no button {label}"))
        }

        fn audit(&self) {
            for row in descendants(&self.page)
                .into_iter()
                .filter_map(|widget| widget.downcast::<adw::PreferencesRow>().ok())
            {
                assert_labelled(&row).unwrap_or_else(|problem| panic!("{}: {problem}", row.title()));
            }
            assert_eq!(unlabelled_icon_buttons(&self.page), Vec::<String>::new());
        }
    }

    fn license(plan: &str, cycle: &str, status: &str, team: Option<(&str, &str)>) -> LicenseClaim {
        LicenseClaim {
            id: "lic_01".to_owned(),
            plan: plan.to_owned(),
            cycle: cycle.to_owned(),
            source: "subscription".to_owned(),
            status: status.to_owned(),
            renews_at: None,
            ends_at: None,
            team: team.map(|(id, name)| TeamClaim {
                id: id.to_owned(),
                name: name.to_owned(),
            }),
        }
    }

    fn signed_in(licenses: Vec<LicenseClaim>, features: &[&str]) -> AccountStatus {
        let mut claims: EntitlementClaims =
            fakes::claims(Utc::now() - TimeDelta::hours(2), TimeDelta::days(14), features);
        claims.licenses = licenses;
        claims.account.email = "ada@m17.example".to_owned();
        claims.account.name = "Ada Lovelace".to_owned();
        AccountStatus::SignedIn(Box::new(SignedIn {
            entitlement: Some(fakes::entitlement(&claims).expect("an entitlement")),
            problem: None,
            remembered: true,
        }))
    }

    fn profile(licenses: Vec<LicenseClaim>, teams: Vec<Membership>) -> Profile {
        Profile {
            id: "acct_01k8d6wk00f8xsr79e7x052rkk".to_owned(),
            email: "ada@m17.example".to_owned(),
            name: Some("Ada Lovelace".to_owned()),
            licenses,
            teams,
        }
    }

    fn device(id: &str, name: &str, machine_id: &str) -> Device {
        Device {
            id: id.to_owned(),
            machine_id: machine_id.to_owned(),
            platform: "linux".to_owned(),
            name: name.to_owned(),
            app_version: "0.1.0".to_owned(),
            os_version: "Fedora Linux 43".to_owned(),
            last_seen_at: Utc::now() - TimeDelta::hours(5),
            licensed_at: Some(Utc::now()),
            offline_until: None,
        }
    }

    #[gtk4::test]
    fn signed_out_the_page_offers_sign_in_the_locked_features_and_the_offline_file() {
        let harness = Harness::new(None);
        let imp = harness.page.imp();
        assert!(
            !harness.button(&harness.page, "Sign In…").is_sensitive(),
            "Sign In before the account started"
        );

        harness.ready();

        assert!(harness.button(&harness.page, "Sign In…").is_sensitive());
        assert_eq!(harness.titles(&imp.account_group), ["Sign In to TablePro"]);
        assert!(!imp.plan_group.is_visible());
        assert!(!imp.devices_group.is_visible());
        assert!(!imp.teams_group.is_visible());
        let features = harness.titles(&imp.features_group);
        assert_eq!(features.len(), 12);
        assert_eq!(features[10..], ["Buy a License", "Learn More About Licensing"]);
        assert!(
            descendants(&imp.features_group.get())
                .iter()
                .filter_map(|widget| widget.downcast_ref::<gtk4::Label>())
                .all(|label| label.label() != "Included")
        );
        assert_eq!(
            harness.titles(&imp.offline_group),
            ["Machine ID", "Import Offline File…"]
        );
        let machine_id = harness
            .page
            .ready()
            .map(|(_, account)| account.machine_id().as_str().to_owned())
            .expect("an account");
        let shown: Vec<String> = descendants(&harness.row("Machine ID"))
            .iter()
            .filter_map(|widget| widget.downcast_ref::<gtk4::Label>())
            .map(|label| label.text().to_string())
            .collect();
        assert!(
            shown.contains(&format!("{}\n{}", &machine_id[..32], &machine_id[32..])),
            "{shown:?}"
        );
        harness.audit();
    }

    #[gtk4::test]
    fn without_a_machine_id_the_page_says_why_accounts_are_unavailable() {
        let harness = Harness::new(None);

        harness
            .start
            .send_replace(AccountStart::NoMachineId("cannot read /etc/machine-id".to_owned()));
        harness.settle();

        let row = harness.row("Accounts Unavailable");
        assert!(row.subtitle().is_some_and(|text| text.contains("/etc/machine-id")));
        assert_eq!(
            harness.titles(&harness.page.imp().account_group),
            ["Accounts Unavailable"]
        );
    }

    #[gtk4::test]
    fn a_starter_account_shows_its_plan_features_devices_and_no_team() {
        let harness = Harness::new(None);
        harness.ready();
        let imp = harness.page.imp();
        let this_machine = harness
            .page
            .ready()
            .map(|(_, account)| account.machine_id().as_str().to_owned())
            .expect("an account");
        let mut starter = license("starter", "lifetime", "active", None);
        starter.source = "order".to_owned();

        harness.send(signed_in(vec![starter.clone()], &["env_var_references"]));
        harness.page.show_details(
            Fetch::Loaded(profile(vec![starter], Vec::new())),
            Fetch::Loaded(vec![
                device("dev_mac", "Ada's Mac", &"a".repeat(64)),
                device("dev_here", "Ada's laptop", &this_machine),
            ]),
        );

        assert_eq!(harness.titles(&imp.account_group), ["Ada Lovelace", "Manage Account"]);
        assert_eq!(
            harness.row("Ada Lovelace").subtitle().as_deref(),
            Some("ada@m17.example")
        );
        assert!(harness.button(&imp.account_group.get(), "Sign Out").is_sensitive());
        assert_eq!(harness.titles(&imp.plan_group), ["Starter"]);
        assert_eq!(
            harness.row("Starter").subtitle().as_deref(),
            Some("Lifetime · Personal")
        );
        harness.button(&harness.row("Starter"), "Billing…");
        assert!(!harness.row("Starter").is_activatable());
        assert_eq!(harness.titles(&imp.devices_group), ["Ada's laptop", "Ada's Mac"]);
        assert!(
            harness
                .row("Ada's laptop")
                .subtitle()
                .is_some_and(|text| text.starts_with("This computer"))
        );
        assert!(
            descendants(&harness.row("Ada's laptop"))
                .iter()
                .all(|widget| !widget.is::<gtk4::Button>())
        );
        harness.button(&harness.row("Ada's Mac"), "Remove");
        assert_eq!(harness.titles(&imp.teams_group), ["Not in a Team"]);
        assert!(
            harness
                .titles(&imp.offline_group)
                .contains(&"Verified 2 hours ago".to_owned())
        );
        let included: Vec<String> = harness
            .rows(&imp.features_group)
            .iter()
            .filter(|row| {
                descendants(*row).iter().any(|widget| {
                    widget
                        .downcast_ref::<gtk4::Label>()
                        .is_some_and(|label| label.label() == "Included")
                })
            })
            .map(|row| row.title().to_string())
            .collect();
        assert_eq!(included, ["Environment Variable References"]);
        assert!(
            !harness
                .titles(&imp.features_group)
                .contains(&"Buy a License".to_owned())
        );
        harness.audit();
    }

    #[gtk4::test]
    fn a_team_member_with_a_long_team_name_and_address_sees_the_team_and_its_seat() {
        let harness = Harness::new(None);
        harness.ready();
        let imp = harness.page.imp();
        let team = "The Analytical Engine Society of Greater London & the <Surrounding> Counties";
        let mut seat = license("team", "yearly", "active", Some(("team_01", team)));
        let renews = Utc::now() + TimeDelta::days(200);
        seat.renews_at = Some(renews);
        let membership = Membership {
            team: TeamClaim {
                id: "team_01".to_owned(),
                name: team.to_owned(),
            },
            role: "member".to_owned(),
            has_seat: true,
        };
        let mut long = profile(vec![seat.clone()], vec![membership]);
        long.email = "augusta.ada.king.countess.of.lovelace@m17.example".to_owned();

        harness.send(signed_in(vec![seat], &["team_library"]));
        harness
            .page
            .show_details(Fetch::Loaded(long), Fetch::Loaded(Vec::new()));

        assert_eq!(
            harness.row("Team").subtitle().as_deref(),
            Some(format!("Yearly · {team} · Renews on {}", account_view::day(renews)).as_str())
        );
        assert!(
            descendants(&harness.row("Team"))
                .iter()
                .all(|widget| !widget.is::<gtk4::Button>()),
            "a member gets no Billing…"
        );
        assert_eq!(harness.titles(&imp.teams_group), [team]);
        let shown: Vec<String> = descendants(&imp.teams_group.get())
            .iter()
            .filter_map(|widget| widget.downcast_ref::<gtk4::Label>())
            .map(|label| label.text().to_string())
            .collect();
        assert!(shown.contains(&team.to_owned()), "{shown:?}");
        assert_eq!(harness.row(team).subtitle().as_deref(), Some("Member · Holds a seat"));
        assert!(harness.row(team).is_activatable());
        assert_eq!(
            harness.row("Ada Lovelace").subtitle().as_deref(),
            Some("augusta.ada.king.countess.of.lovelace@m17.example")
        );
        harness.audit();
    }

    #[gtk4::test]
    fn a_past_due_plan_shows_the_payment_notice_first() {
        let harness = Harness::new(None);
        harness.ready();
        let due = license("starter", "monthly", "past_due", None);

        harness.send(signed_in(vec![due.clone()], &["env_var_references"]));
        harness
            .page
            .show_details(Fetch::Loaded(profile(vec![due], Vec::new())), Fetch::Loaded(Vec::new()));

        assert_eq!(
            harness.titles(&harness.page.imp().plan_group),
            ["Payment Problem", "Starter"]
        );
        harness.button(&harness.row("Payment Problem"), "Update Payment Method…");
        assert_eq!(
            harness.row("Starter").subtitle().as_deref(),
            Some("Monthly · Personal · Payment problem")
        );
        harness.audit();
    }

    #[gtk4::test]
    fn over_the_device_limit_the_dialog_lists_the_holders_and_keeps_an_offline_one() {
        let harness = Harness::new(None);
        harness.ready();
        let mut holders = vec![
            device("dev_mac", "Ada's Mac", &"a".repeat(64)),
            device("dev_lab", "Lab machine", &"b".repeat(64)),
            device("dev_old", "Old laptop", &"c".repeat(64)),
        ];
        holders[1].offline_until = Some(Utc::now() + TimeDelta::days(90));
        harness.send(AccountStatus::SignedIn(Box::new(SignedIn {
            entitlement: None,
            problem: Some(EntitlementProblem::DeviceLimitReached(holders.clone())),
            remembered: true,
        })));
        let window = OwnedWindow::presented(adw::Window::builder().default_width(900).default_height(700).build());
        window.set_content(Some(&harness.page));

        harness
            .button(&harness.row("Device Limit Reached"), "Remove a Device…")
            .emit_clicked();
        let dialog = harness.page.device_limit_dialog().expect("the device limit dialog");

        let rows = dialog.rows();
        let titles: Vec<String> = rows.iter().map(|row| row.title().to_string()).collect();
        assert_eq!(titles, ["Ada's Mac", "Lab machine", "Old laptop"]);
        assert!(
            rows[0]
                .subtitle()
                .is_some_and(|text| text.contains("Last active 5 hours ago"))
        );
        harness.button(&rows[0], "Remove");
        assert!(descendants(&rows[1]).iter().all(|widget| !widget.is::<gtk4::Button>()));
        assert!(
            descendants(&rows[1])
                .iter()
                .filter_map(|widget| widget.downcast_ref::<gtk4::Label>())
                .any(|label| label.label().starts_with("Offline file until "))
        );
        assert_eq!(dialog.error(), None);
        for row in &rows {
            assert_labelled(row).expect("a labelled row");
        }

        harness.send(signed_in(Vec::new(), &[]));
        wait_until(WAIT, || harness.page.device_limit_dialog().is_none())
            .expect("the dialog closed once the limit was gone");
        drop(window);
    }

    #[gtk4::test]
    fn signed_in_without_an_entitlement_an_account_that_did_not_load_keeps_sign_out_and_try_again() {
        let harness = Harness::new(None);
        harness.ready();
        let imp = harness.page.imp();
        let unreachable = || AccountError::Unreachable("connection refused".to_owned());
        let problems = [
            EntitlementProblem::DeviceLimitReached(vec![device("dev_mac", "Ada's Mac", &"a".repeat(64))]),
            EntitlementProblem::RefreshFailed(unreachable()),
        ];

        for problem in problems {
            harness.send(AccountStatus::SignedIn(Box::new(SignedIn {
                entitlement: None,
                problem: Some(problem),
                remembered: true,
            })));
            harness
                .page
                .show_details(Fetch::Failed(unreachable()), Fetch::Failed(unreachable()));

            assert_eq!(harness.titles(&imp.account_group), ["Signed In"]);
            let row = harness.row("Signed In");
            assert_eq!(
                row.subtitle().as_deref(),
                Some("TablePro could not reach its account service. Check the internet connection and try again.")
            );
            harness.button(&row, "Try Again");
            assert!(harness.button(&row, "Sign Out").is_sensitive());
            assert!(
                descendants(&imp.account_group.get())
                    .iter()
                    .all(|widget| !widget.is::<adw::Spinner>())
            );
            harness.audit();
        }

        harness.button(&harness.row("Signed In"), "Sign Out").emit_clicked();
        wait_until(WAIT, || harness.titles(&imp.account_group) == ["Sign In to TablePro"]).expect("signed out");
    }

    #[gtk4::test]
    fn over_the_device_limit_the_dialog_says_why_a_held_device_stays_and_closes_once_one_is_removed() {
        let harness = Harness::new(None);
        let machine = MachineId::derive("4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n").expect("a machine ID");
        let stub = limit_stub(&machine);
        let endpoints = Endpoints::new(&stub.url, &format!("{}/v2", stub.url)).expect("the endpoints");
        harness.ready_with(
            endpoints,
            fakes::keys().expect("the test key"),
            machine,
            Arc::new(Approving),
        );
        let window = OwnedWindow::presented(adw::Window::builder().default_width(900).default_height(700).build());
        window.set_content(Some(&harness.page));
        let toasts = Rc::new(RefCell::new(Vec::new()));
        let kept = toasts.clone();
        harness
            .page
            .connect_toast(move |_, toast| kept.borrow_mut().push(toast.title().unwrap_or_default().to_string()));
        let remove = |name: &str| {
            let dialog = harness.page.device_limit_dialog().expect("the device limit dialog");
            let row = dialog
                .rows()
                .into_iter()
                .find(|row| row.title() == name)
                .unwrap_or_else(|| panic!("no row {name}"));
            harness.button(&row, "Remove").emit_clicked();
            wait_until(WAIT, || crate::workspace::answer(&window, "remove")).expect("the confirmation");
        };

        harness.button(&harness.page, "Sign In…").emit_clicked();
        wait_until(WAIT, || harness.page.device_limit_dialog().is_some()).expect("the device limit dialog");
        let dialog = harness.page.device_limit_dialog().expect("the device limit dialog");
        let lab = dialog
            .rows()
            .into_iter()
            .find(|row| row.title() == "Lab machine")
            .expect("Lab machine");
        assert!(descendants(&lab).iter().all(|widget| !widget.is::<gtk4::Button>()));
        assert!(
            descendants(&lab)
                .iter()
                .filter_map(|widget| widget.downcast_ref::<gtk4::Label>())
                .any(|label| label.label().starts_with("Offline file until "))
        );
        remove("Old laptop");
        wait_until(WAIT, || dialog.error().is_some()).expect("the refusal shown");

        assert_eq!(
            dialog.error().as_deref(),
            Some(
                "That device has an offline file that is still valid, so it keeps its license slot until the file expires."
            )
        );
        assert_eq!(dialog.rows().len(), 3);
        // The removal and the status it changes both close the dialog; a second close is a critical.
        let previous = glib::log_set_always_fatal(glib::LogLevels::LEVEL_CRITICAL);
        remove("Ada's Mac");
        wait_until(WAIT, || harness.page.device_limit_dialog().is_none()).expect("the dialog closed");
        crate::test_support::drain_main_context();
        glib::log_set_always_fatal(previous);
        assert!(
            toasts
                .borrow()
                .contains(&"Removed Ada's Mac. The paid features work on this computer now.".to_owned()),
            "{:?}",
            toasts.borrow()
        );
        assert!(stub.requests().contains(&"DELETE /v2/devices/dev_mac".to_owned()));
        let status = harness.status.borrow().clone();
        assert!(
            matches!(&status, AccountStatus::SignedIn(held) if held.problem.is_none() && held.entitlement.is_some()),
            "{status:?}"
        );
        drop(window);
    }

    #[gtk4::test]
    fn try_again_refreshes_the_entitlement_and_loads_the_account_again() {
        let harness = Harness::new(None);
        let machine = MachineId::derive("4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n").expect("a machine ID");
        let stub = limit_stub(&machine);
        let endpoints = Endpoints::new(&stub.url, &format!("{}/v2", stub.url)).expect("the endpoints");
        harness.ready_with(
            endpoints,
            fakes::keys().expect("the test key"),
            machine,
            Arc::new(Approving),
        );
        let window = OwnedWindow::presented(adw::Window::builder().default_width(900).default_height(700).build());
        window.set_content(Some(&harness.page));
        let refresh = "POST /v2/devices/dev_here/entitlement";
        let asked = |request: &str| stub.requests().iter().filter(|it| it.as_str() == request).count();
        let try_again = || {
            harness.settle();
            descendants(&harness.page.imp().account_group.get())
                .into_iter()
                .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
                .find(|button| button.label().is_some_and(|label| label == "Try Again") && button.is_sensitive())
        };

        harness.button(&harness.page, "Sign In…").emit_clicked();
        // The sign-in loads the account more than once; each load asks /v2/me, then /v2/devices.
        wait_until(WAIT, || {
            try_again().is_some() && asked("GET /v2/me") == asked("GET /v2/devices")
        })
        .expect("the account did not load");
        assert_eq!(asked(refresh), 1);
        try_again().expect("Try Again").emit_clicked();

        wait_until(WAIT, || {
            harness.settle();
            let requests = stub.requests();
            let refreshed = requests.iter().rposition(|it| it == refresh);
            let loaded = requests.iter().rposition(|it| it == "GET /v2/me");
            asked(refresh) == 2 && matches!((refreshed, loaded), (Some(refreshed), Some(loaded)) if loaded > refreshed)
        })
        .expect("refreshed, then loaded again");
        drop(window);
    }

    #[gtk4::test]
    fn sign_in_opens_the_authorization_page_and_cancel_takes_it_back() {
        let harness = Harness::new(None);
        harness.ready();

        harness.button(&harness.page, "Sign In…").emit_clicked();
        wait_until(WAIT, || !harness.browser.opened.lock().expect("the URLs").is_empty()).expect("the browser opened");
        harness.settle();

        let opened = harness.browser.opened.lock().expect("the URLs")[0].clone();
        assert_eq!(opened.path(), "/oauth/authorize");
        assert!(
            opened
                .query()
                .is_some_and(|query| query.contains("client_id=tablepro-linux"))
        );
        assert!(
            harness
                .row("Sign In to TablePro")
                .subtitle()
                .is_some_and(|text| text.contains("web browser"))
        );
        harness.button(&harness.page, "Cancel").emit_clicked();
        harness.settle();
        wait_until(WAIT, || {
            harness.settle();
            descendants(&harness.page)
                .into_iter()
                .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
                .any(|button| button.label().is_some_and(|label| label == "Sign In…"))
        })
        .expect("Sign In again after Cancel");
    }

    #[gtk4::test]
    fn a_sign_in_started_after_a_cancel_keeps_its_cancel_when_the_first_one_ends() {
        let harness = Harness::new(None);
        harness.ready();
        let opened = || harness.browser.opened.lock().expect("the URLs").len();

        harness.button(&harness.page, "Sign In…").emit_clicked();
        wait_until(WAIT, || opened() == 1).expect("the browser opened");
        harness.button(&harness.page, "Cancel").emit_clicked();
        harness.button(&harness.page, "Sign In…").emit_clicked();
        wait_until(WAIT, || opened() == 2).expect("the browser opened again");
        let _ = wait_until(Duration::from_millis(500), || {
            harness.settle();
            false
        });

        assert!(
            harness
                .row("Sign In to TablePro")
                .subtitle()
                .is_some_and(|text| text.contains("web browser"))
        );
        harness.button(&harness.page, "Cancel").emit_clicked();
    }

    #[gtk4::test]
    fn a_sign_in_the_browser_could_not_open_says_so() {
        let harness = Harness::new(Some("no handler for http"));
        harness.ready();

        harness.button(&harness.page, "Sign In…").emit_clicked();
        wait_until(WAIT, || {
            harness.settle();
            descendants(&harness.page)
                .into_iter()
                .filter_map(|widget| widget.downcast::<adw::ActionRow>().ok())
                .any(|row| row.title() == "Sign-In Failed")
        })
        .expect("the failure shown");

        assert_eq!(
            harness.row("Sign-In Failed").subtitle().as_deref(),
            Some("TablePro could not open the sign-in page in a web browser.")
        );
    }

    #[gtk4::test]
    fn an_offline_file_unlocks_its_features_and_names_its_end() {
        let harness = Harness::new(None);
        harness.ready();
        let mut claims = fakes::claims(Utc::now(), TimeDelta::days(30), &["data_rewind"]);
        claims.offline = true;
        claims.licenses = vec![license("starter", "yearly", "active", None)];

        harness.send(AccountStatus::Offline(Box::new(
            fakes::entitlement(&claims).expect("an entitlement"),
        )));

        let imp = harness.page.imp();
        assert!(imp.plan_group.is_visible());
        assert!(!imp.devices_group.is_visible());
        assert!(
            harness
                .row("Dat")
                .subtitle()
                .is_some_and(|text| text == "Using an offline file")
        );
        assert!(
            harness
                .row("Offline File")
                .subtitle()
                .is_some_and(|text| text.starts_with("Valid until "))
        );
        assert!(harness.button(&harness.row("Dat"), "Sign In…").is_sensitive());
        harness.audit();
    }

    // The approval runs in Chrome through tests/browser/portal.cjs, which hands back the redirect to
    // the loopback listener instead of following it, so the browser need not reach this machine.
    struct StackBrowser {
        email: String,
        profile: tempfile::TempDir,
    }

    #[async_trait]
    impl BrowserLauncher for StackBrowser {
        async fn open(&self, url: &Url) -> Result<(), String> {
            let callback = self.profile.path().join("callback");
            let portal = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../account/tests/browser/portal.cjs");
            let mut command = std::process::Command::new("node");
            command
                .arg(portal)
                .arg("approve")
                .arg(url.as_str())
                .env("TABLEPRO_CLOUD_EMAIL", &self.email)
                .env("TABLEPRO_CLOUD_PROFILE", self.profile.path().join("chrome"))
                .env("TABLEPRO_CLOUD_MACHINE_NAME", "Ada's laptop")
                .env("TABLEPRO_CLOUD_GRANT", "starter")
                .env("TABLEPRO_CLOUD_CALLBACK_FILE", &callback);
            std::thread::spawn(move || {
                let status = command.status().expect("the browser step ran");
                assert!(status.success(), "the browser step failed: {status}");
                let answer = std::fs::read_to_string(&callback).expect("the redirect");
                deliver(&Url::parse(&answer).expect("a redirect URL"));
            });
            Ok(())
        }
    }

    // Three devices hold the license: Lab machine with an offline file device_limit_reached names, Old laptop
    // with one made since, which the server still refuses to remove, and Ada's Mac, whose removal frees a slot.
    fn limit_stub(machine: &MachineId) -> CloudStub {
        let now = Utc::now();
        let at = |delta: TimeDelta| (now + delta).to_rfc3339();
        let device = |id: &str, name: &str, platform: &str, machine_id: &str, more: &str| {
            format!(
                r#"{{"id":"{id}","machine_id":"{machine_id}","platform":"{platform}","name":"{name}","app_version":"0.1.0","os_version":"26.1","created_at":"{created}","last_seen_at":"{seen}","licensed_at":"{created}"{more}}}"#,
                created = at(-TimeDelta::days(30)),
                seen = at(-TimeDelta::hours(5)),
            )
        };
        let offline = format!(r#","offline_until":"{}""#, at(TimeDelta::days(90)));
        let holders = [
            device("dev_mac", "Ada's Mac", "macos", &"a".repeat(64), ""),
            device("dev_lab", "Lab machine", "linux", &"b".repeat(64), &offline),
            device("dev_old", "Old laptop", "linux", &"c".repeat(64), ""),
        ]
        .join(",");
        let here = device("dev_here", "Ada's laptop", "linux", machine.as_str(), "");
        let mut claims = fakes::claims(now, TimeDelta::days(14), &["env_var_references"]);
        claims.mid = machine.as_str().to_owned();
        claims.dev = "dev_here".to_owned();
        let entitlement = format!(
            r#"{{"token":"{}","expires_at":"{}","refresh_after":"{}"}}"#,
            fakes::sign(&claims).expect("a token"),
            at(TimeDelta::days(14)),
            at(TimeDelta::days(1)),
        );
        let problem = |status: u16, code: &str, more: &str| {
            format!(r#"{{"type":"about:blank","title":"{code}","status":{status},"code":"{code}"{more}}}"#)
        };
        let limit = problem(409, "device_limit_reached", &format!(r#","devices":[{holders}]"#));
        let tokens =
            r#"{"access_token":"stub-access","token_type":"Bearer","expires_in":900,"refresh_token":"stub-refresh"}"#;
        let freed = AtomicBool::new(false);
        CloudStub::start(move |method, path| match (method, path) {
            ("POST", "/oauth/token") => (200, tokens.to_owned()),
            ("POST", "/v2/devices") => (201, here.clone()),
            ("POST", "/v2/devices/dev_here/entitlement") if freed.load(Ordering::SeqCst) => (200, entitlement.clone()),
            ("POST", "/v2/devices/dev_here/entitlement") => (409, limit.clone()),
            ("DELETE", "/v2/devices/dev_old") => (409, problem(409, "offline_file_active", "")),
            ("DELETE", "/v2/devices/dev_mac") => {
                freed.store(true, Ordering::SeqCst);
                (204, String::new())
            }
            _ => (404, problem(404, "not_found", "")),
        })
    }

    // Signs in with an entitlement at once; the revoke is answered only once `revoking` is false.
    fn sign_out_stub(machine: &MachineId, revoking: Arc<AtomicBool>) -> CloudStub {
        let now = Utc::now();
        let mut claims = fakes::claims(now, TimeDelta::days(14), &[]);
        claims.mid = machine.as_str().to_owned();
        claims.dev = "dev_here".to_owned();
        let entitlement = format!(
            r#"{{"token":"{}","expires_at":"{}","refresh_after":"{}"}}"#,
            fakes::sign(&claims).expect("a token"),
            (now + TimeDelta::days(14)).to_rfc3339(),
            (now + TimeDelta::days(1)).to_rfc3339(),
        );
        let here = format!(
            r#"{{"id":"dev_here","machine_id":"{}","platform":"linux","name":"Ada's laptop","app_version":"0.1.0","os_version":"Ubuntu 26.04","created_at":"{now}","last_seen_at":"{now}"}}"#,
            machine.as_str(),
            now = now.to_rfc3339(),
        );
        let tokens =
            r#"{"access_token":"stub-access","token_type":"Bearer","expires_in":900,"refresh_token":"stub-refresh"}"#;
        CloudStub::start(move |method, path| match (method, path) {
            ("POST", "/oauth/token") => (200, tokens.to_owned()),
            ("POST", "/v2/devices") => (201, here.clone()),
            ("POST", "/v2/devices/dev_here/entitlement") => (200, entitlement.clone()),
            ("POST", "/oauth/revoke") => {
                while revoking.load(Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_millis(10));
                }
                (200, String::new())
            }
            _ => (
                404,
                r#"{"type":"about:blank","title":"Not found","status":404,"code":"not_found"}"#.to_owned(),
            ),
        })
    }

    #[gtk4::test]
    fn sign_out_waits_for_the_revocation_and_leaves_the_page_signed_out() {
        let harness = Harness::new(None);
        let machine = MachineId::derive("4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n").expect("a machine ID");
        let revoking = Arc::new(AtomicBool::new(true));
        let stub = sign_out_stub(&machine, revoking.clone());
        let endpoints = Endpoints::new(&stub.url, &format!("{}/v2", stub.url)).expect("the endpoints");
        harness.ready_with(
            endpoints,
            fakes::keys().expect("the test key"),
            machine,
            Arc::new(Approving),
        );
        let window = OwnedWindow::presented(adw::Window::builder().default_width(900).default_height(700).build());
        window.set_content(Some(&harness.page));
        let shows = |title: &str| {
            harness.settle();
            descendants(&harness.page)
                .into_iter()
                .filter_map(|widget| widget.downcast::<adw::ActionRow>().ok())
                .any(|row| row.title() == title)
        };
        harness.button(&harness.page, "Sign In…").emit_clicked();
        let sign_out = || {
            descendants(&harness.page.imp().account_group.get())
                .into_iter()
                .filter_map(|widget| widget.downcast::<gtk4::Button>().ok())
                .find(|button| button.label().is_some_and(|text| text == "Sign Out"))
        };
        wait_until(WAIT, || {
            harness.settle();
            sign_out().is_some()
        })
        .expect("signed in");

        sign_out().expect("Sign Out").emit_clicked();
        wait_until(WAIT, || stub.requests().iter().any(|it| it == "POST /oauth/revoke")).expect("the revoke sent");
        let still_signed_in = !shows("Sign In to TablePro");
        revoking.store(false, Ordering::SeqCst);

        wait_until(WAIT, || shows("Sign In to TablePro")).expect("signed out");
        assert!(still_signed_in);
        assert!(!harness.dir.path().join("account.json").exists());
        drop(window);
    }

    #[gtk4::test]
    fn sign_out_sends_signed_out_once_and_an_answer_landing_during_it_identifies_nobody() {
        let harness = Harness::new(None);
        let collector = crate::test_support::PostHogCollector::start();
        harness.share_usage_data(&collector);
        let machine = MachineId::derive("4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n").expect("a machine ID");
        let revoking = Arc::new(AtomicBool::new(true));
        let stub = sign_out_stub(&machine, revoking.clone());
        let endpoints = Endpoints::new(&stub.url, &format!("{}/v2", stub.url)).expect("the endpoints");
        harness.ready_with(
            endpoints,
            fakes::keys().expect("the test key"),
            machine,
            Arc::new(Approving),
        );
        let window = OwnedWindow::presented(adw::Window::builder().default_width(900).default_height(700).build());
        window.set_content(Some(&harness.page));
        let shows = |title: &str| {
            harness.settle();
            descendants(&harness.page)
                .into_iter()
                .filter_map(|widget| widget.downcast::<adw::ActionRow>().ok())
                .any(|row| row.title() == title)
        };
        harness.button(&harness.page, "Sign In…").emit_clicked();
        wait_until(WAIT, || !collector.named("signed_in").is_empty()).expect("signed in");
        harness.settle();

        harness
            .button(&harness.page.imp().account_group.get(), "Sign Out")
            .emit_clicked();
        wait_until(WAIT, || stub.requests().iter().any(|it| it == "POST /oauth/revoke")).expect("the revoke sent");
        // /v2/me answering while the revoke is still on its way.
        harness
            .page
            .show_details(Fetch::Loaded(profile(Vec::new(), Vec::new())), Fetch::Idle);
        revoking.store(false, Ordering::SeqCst);
        wait_until(WAIT, || shows("Sign In to TablePro")).expect("signed out");
        harness.telemetry.flush();

        let account = fakes::claims(Utc::now(), TimeDelta::days(1), &[]).sub;
        assert_eq!(collector.named("$identify").len(), 1);
        let signed_out = collector.named("signed_out");
        assert_eq!(signed_out.len(), 1);
        assert_eq!(signed_out[0]["distinct_id"], account.as_str());
        drop(window);
    }

    #[gtk4::test]
    fn showing_the_page_again_loads_the_account_again() {
        let harness = Harness::new(None);
        let machine = MachineId::derive("4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n").expect("a machine ID");
        let stub = sign_out_stub(&machine, Arc::new(AtomicBool::new(false)));
        let endpoints = Endpoints::new(&stub.url, &format!("{}/v2", stub.url)).expect("the endpoints");
        harness.ready_with(
            endpoints,
            fakes::keys().expect("the test key"),
            machine,
            Arc::new(Approving),
        );
        let window = OwnedWindow::presented(adw::Window::builder().default_width(900).default_height(700).build());
        window.set_content(Some(&harness.page));
        let asked_me = || stub.requests().iter().filter(|it| *it == "GET /v2/me").count();
        let settled = || {
            harness.settle();
            !matches!(*harness.page.imp().profile.borrow(), Fetch::Idle | Fetch::Loading)
        };
        harness.button(&harness.page, "Sign In…").emit_clicked();
        wait_until(WAIT, || settled() && asked_me() >= 1).expect("the account loaded");
        let first = asked_me();

        window.set_content(None::<&gtk4::Widget>);
        harness.settle();
        window.set_content(Some(&harness.page));

        wait_until(WAIT, || settled() && asked_me() > first).expect("the account loaded again");
        drop(window);
    }

    #[gtk4::test]
    #[ignore = "requires a tablepro-cloud stack"]
    fn the_page_signs_in_through_the_browser_shows_the_account_and_signs_out() {
        let read =
            |name: &str| std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set; see linux/docs/testing.md"));
        let email = format!(
            "linux-page-{}@{}",
            &uuid::Uuid::new_v4().simple().to_string()[..8],
            read("TABLEPRO_CLOUD_EMAIL_DOMAIN")
        );
        let harness = Harness::new(None);
        let endpoints = Endpoints::new(&read("TABLEPRO_CLOUD_ACCOUNT_URL"), &read("TABLEPRO_CLOUD_API_URL"))
            .expect("the endpoints");
        let keys =
            tablepro_account::EntitlementKeys::from_public_keys([read("TABLEPRO_CLOUD_ENTITLEMENT_KEY").as_str()])
                .expect("the stack's key");
        let machine = MachineId::derive(&format!("{}\n", uuid::Uuid::new_v4().simple())).expect("a machine ID");
        let browser = Arc::new(StackBrowser {
            email: email.clone(),
            profile: tempfile::tempdir().expect("a browser profile"),
        });
        harness.ready_with(endpoints, keys, machine, browser);
        let collector = crate::test_support::PostHogCollector::start();
        harness.share_usage_data(&collector);
        let window = OwnedWindow::presented(adw::Window::builder().default_width(900).default_height(900).build());
        window.set_content(Some(&harness.page));
        let shows = |title: &str| {
            harness.settle();
            descendants(&harness.page)
                .into_iter()
                .filter_map(|widget| widget.downcast::<adw::ActionRow>().ok())
                .any(|row| row.title() == title)
        };

        harness.button(&harness.page, "Sign In…").emit_clicked();
        wait_until(Duration::from_secs(120), || shows("Starter") && shows("Ada's laptop"))
            .expect("signed in, with the plan and this computer");

        let imp = harness.page.imp();
        assert_eq!(harness.titles(&imp.account_group), [email.as_str(), "Manage Account"]);
        assert!(
            harness
                .row("Ada's laptop")
                .subtitle()
                .is_some_and(|text| text.starts_with("This computer"))
        );
        // An admin's grant, as the browser step writes it: no cycle and no Billing….
        assert_eq!(harness.row("Starter").subtitle().as_deref(), Some("Personal · Active"));
        assert!(
            descendants(&harness.row("Starter"))
                .iter()
                .all(|widget| !widget.is::<gtk4::Button>())
        );
        assert!(
            harness
                .titles(&imp.offline_group)
                .iter()
                .any(|title| title.starts_with("Verified"))
        );

        harness.button(&imp.account_group.get(), "Sign Out").emit_clicked();
        wait_until(WAIT, || shows("Sign In to TablePro")).expect("signed out");
        wait_until(WAIT, || !collector.named("signed_out").is_empty()).expect("the sign-out sent");
        let identify = collector.named("$identify");
        assert_eq!(identify.len(), 1);
        let account = identify[0]["distinct_id"].as_str().unwrap_or_default().to_owned();
        assert!(account.starts_with("acct_"), "{account}");
        assert_eq!(collector.named("signed_in")[0]["distinct_id"], account.as_str());
        assert_eq!(collector.named("signed_in")[0]["properties"]["method"], "interactive");
        assert_eq!(collector.named("signed_out")[0]["distinct_id"], account.as_str());
        drop(window);
    }
}
