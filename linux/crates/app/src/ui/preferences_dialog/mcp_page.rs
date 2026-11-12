use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::SystemTime;

use gio::prelude::SettingsExtManual;
use glib::subclass::Signal;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use secrecy::ExposeSecret;
use tablepro_core::credentials::SecretError;
use tablepro_linux_platform::AppSettings;
use tablepro_linux_platform::settings::keys;
use tablepro_mcp::SeenClient;
use tablepro_mcp::clients::{
    Applies, ClientConfigStatus, ClientDefinition, ClientPlatform, ConfigEditError, StaleReason, UnsupportedReason,
};
use tokio::sync::watch;

use crate::i18n::{gettext, gettext_f};
use crate::services::mcp_clients::{self, ClientAction, ClientHost, ClientSetupError, ClientState, SetupOutcome};
use crate::services::mcp_service::McpService;
use crate::services::mcp_status::{McpFailure, McpStatus};
use crate::services::secret_save_report::SecretSaveReport;

const CANCEL: &str = "cancel";
const REGENERATE: &str = "regenerate";
const REMOVE: &str = "remove";
// What the page shows in place of the token. Copy puts the real one on
// the clipboard.
const MASKED_AUTHORIZATION: &str = "Bearer tp_••••••••••••••••";

mod imp {
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/preferences-mcp-page.ui")]
    pub struct McpPage {
        #[template_child]
        pub enabled_row: TemplateChild<adw::SwitchRow>,
        #[template_child]
        pub status_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub retry_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub port_row: TemplateChild<adw::SpinRow>,
        #[template_child]
        pub client_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub address_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub copy_address_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub token_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub copy_token_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub regenerate_row: TemplateChild<adw::ButtonRow>,
        #[template_child]
        pub clients_group: TemplateChild<adw::PreferencesGroup>,
        pub service: RefCell<Option<McpService>>,
        pub status: RefCell<Option<McpStatus>>,
        pub following: RefCell<Option<glib::JoinHandle<()>>>,
        pub following_clients: RefCell<Option<glib::JoinHandle<()>>>,
        pub surveying: RefCell<Option<glib::JoinHandle<()>>>,
        pub survey_generation: Cell<u64>,
        pub host: RefCell<Option<ClientHost>>,
        pub states: RefCell<Vec<ClientState>>,
        pub client_rows: RefCell<Vec<super::ClientRow>>,
        pub rows_placed: Cell<bool>,
        pub subpage: RefCell<Option<super::OpenSubpage>>,
        pub sightings: RefCell<HashMap<String, SystemTime>>,
        pub(super) unsaved_token: crate::ui::UnsavedSecretToasts,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for McpPage {
        const NAME: &'static str = "TableProMcpPage";
        type Type = super::McpPage;
        type ParentType = adw::PreferencesPage;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for McpPage {
        fn dispose(&self) {
            for handle in [&self.following, &self.following_clients, &self.surveying] {
                if let Some(running) = handle.take() {
                    running.abort();
                }
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

    impl WidgetImpl for McpPage {}
    impl PreferencesPageImpl for McpPage {}
}

glib::wrapper! {
    pub struct McpPage(ObjectSubclass<imp::McpPage>)
        @extends adw::PreferencesPage, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for McpPage {
    fn default() -> Self {
        glib::Object::new()
    }
}

// The client page pushed over the dialog, rebuilt when a survey changes
// what it shows.
pub struct OpenSubpage {
    id: String,
    view: adw::ToolbarView,
    page: glib::WeakRef<adw::NavigationPage>,
    shown: Shown,
}

// Everything a client's page is built from. A survey that changes none
// of it leaves the page alone, and with it the focus inside.
#[derive(Debug, Clone, PartialEq)]
struct Shown {
    status: ClientConfigStatus,
    config_path: Option<PathBuf>,
    action: ClientAction,
    removable: bool,
    port: u16,
}

impl Shown {
    fn of(state: &ClientState, port: u16) -> Self {
        Self {
            status: state.status,
            config_path: state.config_path.clone(),
            action: state.action,
            removable: state.removable,
            port,
        }
    }
}

// A client's row lives as long as the page: a survey rewrites its text
// and its button in place, so the keyboard focus stays on it.
#[derive(Clone)]
pub struct ClientRow {
    id: String,
    row: adw::ActionRow,
    button: gtk4::Button,
}

impl McpPage {
    // `service` is `None` where no server can run, such as a test that
    // brings none; the page then only edits the preferences.
    pub(super) fn bind(&self, settings: &AppSettings, service: Option<McpService>) {
        self.bind_on(settings, service, ClientHost::current());
    }

    fn bind_on(&self, settings: &AppSettings, service: Option<McpService>, host: ClientHost) {
        let imp = self.imp();
        let gio_settings = settings.gio();
        gio_settings
            .bind(keys::MCP_SERVER_ENABLED, &imp.enabled_row.get(), "active")
            .build();
        gio_settings
            .bind(keys::MCP_SERVER_PORT, &imp.port_row.get(), "value")
            .build();
        imp.token_row.set_subtitle(MASKED_AUTHORIZATION);
        self.connect_controls();

        imp.clients_group.set_visible(service.is_some());
        match &service {
            Some(service) => {
                imp.host.replace(Some(host));
                self.follow(service.status());
                self.follow_clients(service.seen_clients());
            }
            None => self.show_status(McpStatus::Off),
        }
        let surveyed = service.is_some();
        imp.service.replace(service);
        if surveyed {
            self.show_clients(Vec::new());
            self.refresh_clients();
        }
        // Another program may have changed a client's file since.
        self.connect_map(|page| page.refresh_clients());
    }

    fn connect_controls(&self) {
        let imp = self.imp();
        let page = self.downgrade();
        imp.port_row.connect_value_notify(move |_| {
            if let Some(page) = page.upgrade() {
                page.refresh();
                page.refresh_clients();
            }
        });
        let page = self.downgrade();
        imp.copy_address_button.connect_clicked(move |_| {
            if let Some(page) = page.upgrade() {
                page.copy_address();
            }
        });
        let page = self.downgrade();
        imp.copy_token_button.connect_clicked(move |_| {
            if let Some(page) = page.upgrade() {
                page.copy_authorization();
            }
        });
        let page = self.downgrade();
        imp.regenerate_row.connect_activated(move |_| {
            if let Some(page) = page.upgrade() {
                page.confirm_regenerate();
            }
        });
        let page = self.downgrade();
        imp.retry_button.connect_clicked(move |_| {
            if let Some(service) = page.upgrade().and_then(|page| page.service()) {
                service.retry();
            }
        });
    }

    // AdwPreferencesDialog owns the toast overlay, so the page hands its
    // toasts up rather than looking for one.
    pub(super) fn connect_toast<F: Fn(&Self, &adw::Toast) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "toast",
            false,
            glib::closure_local!(move |page: &Self, toast: adw::Toast| f(page, &toast)),
        )
    }

    fn service(&self) -> Option<McpService> {
        self.imp().service.borrow().clone()
    }

    fn follow(&self, mut status: watch::Receiver<McpStatus>) {
        let page = self.downgrade();
        let following = glib::spawn_future_local(async move {
            loop {
                let shown = status.borrow_and_update().clone();
                let Some(page) = page.upgrade() else {
                    return;
                };
                page.show_status(shown);
                page.refresh_clients();
                drop(page);
                if status.changed().await.is_err() {
                    return;
                }
            }
        });
        if let Some(previous) = self.imp().following.replace(Some(following)) {
            previous.abort();
        }
    }

    fn show_status(&self, status: McpStatus) {
        self.imp().status.replace(Some(status));
        self.refresh();
    }

    // The address and the token are known while the server is off, and a
    // token that leaked has to be replaceable without serving it first.
    fn refresh(&self) {
        let imp = self.imp();
        let status = imp.status.borrow().clone().unwrap_or(McpStatus::Off);
        imp.status_row.set_subtitle(&status_text(&status));
        imp.retry_button.set_visible(matches!(status, McpStatus::Failed(_)));
        imp.address_row.set_subtitle(&address(self.port()));
    }

    fn port(&self) -> u16 {
        let imp = self.imp();
        let running = imp.status.borrow().as_ref().and_then(McpStatus::port);
        running.unwrap_or(imp.port_row.value() as u16)
    }

    fn copy_address(&self) {
        crate::ui::clipboard::copy_text(self, address(self.port()), |message| self.toast(message));
    }

    fn copy_authorization(&self) {
        let page = self.clone();
        glib::spawn_future_local(async move {
            if let Some(header) = page.authorization().await {
                crate::ui::clipboard::copy_text(&page, header, |message| page.toast(message));
            }
        });
    }

    // The header value with the token, read from the keyring if the
    // server is off. A failure has been shown when this is None.
    async fn authorization(&self) -> Option<String> {
        let service = self.service()?;
        match service.access_token().await {
            Ok(token) => Some(authorization_header(token.expose_secret())),
            Err(failure) => {
                self.toast(&failure_text(&failure));
                None
            }
        }
    }

    fn confirm_regenerate(&self) {
        let alert = adw::AlertDialog::new(
            Some(&gettext("Regenerate Access Token?")),
            Some(&gettext(
                "Clients that use the current token are refused until you give them the new one.",
            )),
        );
        alert.add_response(CANCEL, &gettext("_Cancel"));
        alert.add_response(REGENERATE, &gettext("_Regenerate"));
        alert.set_response_appearance(REGENERATE, adw::ResponseAppearance::Destructive);
        alert.set_default_response(Some(CANCEL));
        alert.set_close_response(CANCEL);
        let page = self.clone();
        glib::spawn_future_local(async move {
            let parent: gtk4::Widget = page.clone().upcast();
            if crate::workspace::respond(&alert, &parent).await != REGENERATE {
                return;
            }
            let Some(service) = page.service() else {
                return;
            };
            match service.regenerate_token().await {
                Ok(()) => {
                    page.imp().unsaved_token.dismiss();
                    page.toast(&gettext("New access token made. Copy it to your clients."));
                    page.refresh_clients();
                }
                Err(McpFailure::Keyring(error)) => {
                    let toast = page
                        .imp()
                        .unsaved_token
                        .replace(SecretSaveReport::access_token(error), &page);
                    page.emit_by_name::<()>("toast", &[&toast]);
                }
                Err(failure) => page.toast(&failure_text(&failure)),
            }
        });
    }

    fn toast(&self, message: &str) {
        self.emit_by_name::<()>("toast", &[&crate::ui::plain_toast(message)]);
    }

    // Reads every client's file off the GTK thread. The token is compared
    // only while the server runs, so an off server never opens the keyring.
    fn refresh_clients(&self) {
        let imp = self.imp();
        let (Some(service), Some(host)) = (self.service(), imp.host.borrow().clone()) else {
            return;
        };
        let generation = imp.survey_generation.get() + 1;
        imp.survey_generation.set(generation);
        let url = address(self.port());
        let authorization = service.token().map(|token| authorization_header(token.expose_secret()));
        let surveying = service
            .tasks()
            .spawn_blocking_task(move || mcp_clients::survey(&host, &url, authorization.as_deref()));
        let page = self.downgrade();
        let delivering = glib::spawn_future_local(async move {
            let surveyed = surveying.await;
            let Some(page) = page.upgrade() else {
                return;
            };
            if page.imp().survey_generation.get() != generation {
                return;
            }
            match surveyed {
                Ok(states) => page.show_clients(states),
                Err(failure) => tracing::warn!(%failure, "reading the MCP clients' files failed"),
            }
        });
        if let Some(previous) = imp.surveying.replace(Some(delivering)) {
            previous.abort();
        }
    }

    fn show_clients(&self, states: Vec<ClientState>) {
        let imp = self.imp();
        let order = self.client_order(&states);
        imp.states.replace(states);
        let shown: Vec<String> = imp.client_rows.borrow().iter().map(|row| row.id.clone()).collect();
        let mut kept: HashMap<String, ClientRow> = imp
            .client_rows
            .take()
            .into_iter()
            .map(|row| (row.id.clone(), row))
            .collect();
        let rows: Vec<ClientRow> = order
            .into_iter()
            .map(|client| kept.remove(&client.id).unwrap_or_else(|| self.client_row(client)))
            .collect();
        for row in &rows {
            self.update_row(row);
        }
        if rows.iter().map(|row| &row.id).ne(shown.iter()) {
            let focus = self.focus_in_clients();
            let placed = rows.iter().filter(|row| shown.contains(&row.id));
            for row in kept.values().chain(placed) {
                imp.clients_group.remove(&row.row);
            }
            for row in &rows {
                imp.clients_group.add(&row.row);
            }
            // Taking a row out of the group takes the focus with it.
            if let Some(widget) = focus
                && widget.is_visible()
                && widget.is_ancestor(&*imp.clients_group)
            {
                widget.grab_focus();
            }
        }
        imp.client_rows.replace(rows);
        self.refresh_subpage();
    }

    // The first survey sorts the rows, set up first. Later ones keep that
    // order, so no row moves while the user is on it; the next dialog
    // sorts again.
    fn client_order(&self, states: &[ClientState]) -> Vec<&'static ClientDefinition> {
        let imp = self.imp();
        if states.is_empty() {
            return mcp_clients::linux_clients().collect();
        }
        let shown: Vec<String> = imp.client_rows.borrow().iter().map(|row| row.id.clone()).collect();
        let same_clients = shown.len() == states.len() && states.iter().all(|state| shown.contains(&state.client.id));
        let mut surveyed: Vec<&ClientState> = states.iter().collect();
        match imp.rows_placed.get() && same_clients {
            true => surveyed.sort_by_key(|state| shown.iter().position(|id| *id == state.client.id)),
            false => {
                surveyed.sort_by_key(|state| state.rank());
                imp.rows_placed.set(true);
            }
        }
        surveyed.into_iter().map(|state| state.client).collect()
    }

    fn focus_in_clients(&self) -> Option<gtk4::Widget> {
        let focus = gtk4::prelude::RootExt::focus(&self.root()?)?;
        focus.is_ancestor(&*self.imp().clients_group).then_some(focus)
    }

    fn client_row(&self, client: &ClientDefinition) -> ClientRow {
        let row = adw::ActionRow::builder()
            .title(client.name.as_str())
            .use_markup(false)
            .activatable(true)
            .build();
        row.add_prefix(&gtk4::Image::from_icon_name(crate::ui::icons::client_icon(
            &client.icon,
        )));
        let button = gtk4::Button::builder()
            .valign(gtk4::Align::Center)
            .visible(false)
            .build();
        let (page, id) = (self.downgrade(), client.id.clone());
        button.connect_clicked(move |_| {
            if let Some(page) = page.upgrade()
                && let Some(state) = page.state(&id)
            {
                page.run_action(&id, state.action);
            }
        });
        row.add_suffix(&button);
        row.add_suffix(&gtk4::Image::from_icon_name(crate::ui::icons::GO_NEXT));
        let (page, id) = (self.downgrade(), client.id.clone());
        row.connect_activated(move |_| {
            if let Some(page) = page.upgrade() {
                page.open_client(&id);
            }
        });
        ClientRow {
            id: client.id.clone(),
            row,
            button,
        }
    }

    fn update_row(&self, row: &ClientRow) {
        let state = self.state(&row.id);
        let status = state.as_ref().map_or_else(|| gettext("Checking…"), row_status_text);
        row.row.set_subtitle(&status);
        match state.as_ref().and_then(action_labels) {
            Some((label, described)) => {
                row.button.set_label(&label);
                row.button
                    .update_property(&[gtk4::accessible::Property::Label(&described)]);
                row.button.set_visible(true);
            }
            None => {
                // A hidden button that keeps the focus leaves the keyboard
                // nowhere, so the row takes it.
                if row.button.is_focus() {
                    row.row.grab_focus();
                }
                row.button.set_visible(false);
            }
        }
    }

    fn state(&self, id: &str) -> Option<ClientState> {
        self.imp()
            .states
            .borrow()
            .iter()
            .find(|state| state.client.id == id)
            .cloned()
    }

    fn run_action(&self, id: &str, action: ClientAction) {
        match action {
            ClientAction::Install | ClientAction::Update => self.install_client(id),
            ClientAction::Copy => self.copy_setup(id),
            ClientAction::None => {}
        }
    }

    fn copy_setup(&self, id: &str) {
        let (page, id) = (self.clone(), id.to_owned());
        glib::spawn_future_local(async move {
            let Some(header) = page.authorization().await else {
                return;
            };
            match mcp_clients::setup_text(&id, &address(page.port()), &header) {
                Ok(setup) => crate::ui::clipboard::copy_text(&page, setup, |message| page.toast(message)),
                Err(error) => page.toast(&setup_error_text(&error, &page.home())),
            }
        });
    }

    fn sandboxed(&self) -> bool {
        self.imp().host.borrow().as_ref().is_some_and(|host| host.sandboxed)
    }

    fn home(&self) -> std::path::PathBuf {
        self.imp()
            .host
            .borrow()
            .as_ref()
            .map(|host| host.home.clone())
            .unwrap_or_default()
    }

    fn install_client(&self, id: &str) {
        let (page, id) = (self.clone(), id.to_owned());
        glib::spawn_future_local(async move {
            let (Some(service), Some(host)) = (page.service(), page.imp().host.borrow().clone()) else {
                return;
            };
            let Some(header) = page.authorization().await else {
                return;
            };
            let (client, url) = (id.clone(), address(page.port()));
            let installing = service
                .tasks()
                .spawn_blocking_task(move || mcp_clients::install(&host, &client, &url, &header));
            let outcome = installing.await;
            page.report(&id, outcome, Done::Installed);
        });
    }

    fn remove_client(&self, id: &str) {
        let (page, id) = (self.clone(), id.to_owned());
        glib::spawn_future_local(async move {
            let (Some(service), Some(host), Some(state)) =
                (page.service(), page.imp().host.borrow().clone(), page.state(&id))
            else {
                return;
            };
            let alert = removal_alert(&state, &host);
            let parent: gtk4::Widget = page.clone().upcast();
            if crate::workspace::respond(&alert, &parent).await != REMOVE {
                return;
            }
            let client = id.clone();
            let removing = service
                .tasks()
                .spawn_blocking_task(move || mcp_clients::remove(&host, &client));
            let outcome = removing.await;
            page.report(&id, outcome, Done::Removed);
        });
    }

    fn report(
        &self,
        id: &str,
        outcome: Result<Result<SetupOutcome, ClientSetupError>, tablepro_session::runtime::TaskFailure>,
        done: Done,
    ) {
        let name = self
            .state(id)
            .map(|state| state.client.name.clone())
            .unwrap_or_default();
        match outcome {
            Ok(Ok(_)) => {
                let message = match done {
                    Done::Installed => {
                        let applies = self.state(id).and_then(|state| state.applies());
                        let mut message = gettext_f("{client} is set up.", &[("client", &name)]);
                        if let Some(applies) = applies {
                            message = format!("{message} {}", applies_text(applies, &name));
                        }
                        message
                    }
                    Done::Removed => gettext_f("TablePro was removed from {client}.", &[("client", &name)]),
                };
                self.toast(&message);
            }
            Ok(Err(error)) => {
                tracing::warn!(%error, client = id, "setting up an MCP client failed");
                self.toast(&setup_error_text(&error, &self.home()));
            }
            Err(failure) => {
                tracing::warn!(%failure, client = id, "setting up an MCP client was interrupted");
                self.toast(&gettext("The change to the client stopped unexpectedly."));
            }
        }
        self.refresh_clients();
    }

    fn open_client(&self, id: &str) {
        let Some(state) = self.state(id) else {
            return;
        };
        let view = adw::ToolbarView::new();
        view.add_top_bar(&adw::HeaderBar::new());
        view.set_content(Some(&self.client_content(&state)));
        let subpage = adw::NavigationPage::new(&view, &state.client.name);
        let page = self.downgrade();
        subpage.connect_hidden(move |hidden| {
            let Some(page) = page.upgrade() else {
                return;
            };
            let open = page
                .imp()
                .subpage
                .borrow()
                .as_ref()
                .and_then(|open| open.page.upgrade());
            if open.as_ref() == Some(hidden) {
                page.imp().subpage.replace(None);
            }
        });
        self.imp().subpage.replace(Some(OpenSubpage {
            id: id.to_owned(),
            view,
            page: subpage.downgrade(),
            shown: Shown::of(&state, self.port()),
        }));
        if let Some(dialog) = self
            .ancestor(adw::PreferencesDialog::static_type())
            .and_downcast::<adw::PreferencesDialog>()
        {
            dialog.push_subpage(&subpage);
        }
    }

    fn refresh_subpage(&self) {
        let open = self
            .imp()
            .subpage
            .borrow()
            .as_ref()
            .map(|open| (open.id.clone(), open.view.clone(), open.shown.clone()));
        let Some((id, view, shown)) = open else {
            return;
        };
        let Some(state) = self.state(&id) else {
            return;
        };
        let now = Shown::of(&state, self.port());
        if now == shown {
            return;
        }
        view.set_content(Some(&self.client_content(&state)));
        if let Some(open) = self.imp().subpage.borrow_mut().as_mut() {
            open.shown = now;
        }
    }

    fn client_content(&self, state: &ClientState) -> adw::PreferencesPage {
        let content = adw::PreferencesPage::new();
        content.add(&self.connection_group(state));
        if state.unsupported().is_none() {
            content.add(&self.manual_group(state));
            if let Some(actions) = self.actions_group(state) {
                content.add(&actions);
            }
        }
        content
    }

    fn connection_group(&self, state: &ClientState) -> adw::PreferencesGroup {
        let name = state.client.name.as_str();
        let group = adw::PreferencesGroup::builder().title(gettext("Connection")).build();
        let description = match state.status {
            ClientConfigStatus::Disabled => Some(gettext_f(
                "TablePro is turned off in {client}. Turn it on there to use it.",
                &[("client", name)],
            )),
            ClientConfigStatus::Stale(StaleReason::Shadowed) => Some(gettext_f(
                "A project in {client} has its own TablePro setup with an old address or access token, and uses it in place of this one.",
                &[("client", name)],
            )),
            _ => state
                .applies()
                .filter(|_| state.unsupported().is_none())
                .map(|applies| applies_text(applies, name)),
        };
        // A group's description is markup.
        if let Some(description) = description {
            group.set_description(Some(&glib::markup_escape_text(&description)));
        }
        group.add(&property_row(&gettext("Status"), &row_status_text(state)));
        if let Some(reason) = state.unsupported() {
            let row = property_row(&gettext("Reason"), &reason_text(reason, name));
            row.set_subtitle_lines(0);
            group.add(&row);
        }
        if let Some(path) = &state.config_path {
            let row = property_row(&gettext("Configuration File"), &display_path(path, &self.home()));
            row.set_subtitle_selectable(true);
            group.add(&row);
        }
        group
    }

    fn manual_group(&self, state: &ClientState) -> adw::PreferencesGroup {
        let id = state.client.id.as_str();
        let group = adw::PreferencesGroup::builder()
            .title(gettext("Manual Setup"))
            .description(glib::markup_escape_text(&manual_text(
                state,
                self.sandboxed(),
                &self.home(),
            )))
            .build();
        let copy = gtk4::Button::with_label(&gettext("Copy"));
        copy.set_valign(gtk4::Align::Center);
        copy.add_css_class("flat");
        copy.update_property(&[gtk4::accessible::Property::Label(&gettext("Copy the Setup"))]);
        let (page, client) = (self.downgrade(), id.to_owned());
        copy.connect_clicked(move |_| {
            if let Some(page) = page.upgrade() {
                page.copy_setup(&client);
            }
        });
        group.set_header_suffix(Some(&copy));
        let shown = mcp_clients::setup_text(id, &address(self.port()), MASKED_AUTHORIZATION).unwrap_or_default();
        group.add(&code_card(&shown));
        let note = gtk4::Label::builder()
            .label(gettext("The access token is hidden here. Copy includes it."))
            .xalign(0.0)
            .wrap(true)
            .margin_top(6)
            .build();
        note.add_css_class("caption");
        note.add_css_class("dim-label");
        group.add(&note);
        group
    }

    fn actions_group(&self, state: &ClientState) -> Option<adw::PreferencesGroup> {
        let group = adw::PreferencesGroup::new();
        let mut any = false;
        let label = match state.action {
            ClientAction::Install => Some(gettext("Install")),
            ClientAction::Update => Some(gettext("Update")),
            ClientAction::Copy | ClientAction::None => None,
        };
        if let Some(label) = label {
            let row = adw::ButtonRow::builder().title(label).build();
            row.add_css_class("suggested-action");
            let (page, id, action) = (self.downgrade(), state.client.id.clone(), state.action);
            row.connect_activated(move |_| {
                if let Some(page) = page.upgrade() {
                    page.run_action(&id, action);
                }
            });
            group.add(&row);
            any = true;
        }
        if state.removable {
            let row = adw::ButtonRow::builder().title(gettext("Remove…")).build();
            row.add_css_class("destructive-action");
            let (page, id) = (self.downgrade(), state.client.id.clone());
            row.connect_activated(move |_| {
                if let Some(page) = page.upgrade() {
                    page.remove_client(&id);
                }
            });
            group.add(&row);
            any = true;
        }
        any.then_some(group)
    }

    fn follow_clients(&self, mut seen: watch::Receiver<Vec<SeenClient>>) {
        let known = seen
            .borrow_and_update()
            .iter()
            .map(|client| (client.name.clone(), client.seen_at))
            .collect();
        self.imp().sightings.replace(known);
        let page = self.downgrade();
        let following = glib::spawn_future_local(async move {
            while seen.changed().await.is_ok() {
                let clients = seen.borrow_and_update().clone();
                let Some(page) = page.upgrade() else {
                    return;
                };
                page.announce(clients);
            }
        });
        if let Some(previous) = self.imp().following_clients.replace(Some(following)) {
            previous.abort();
        }
    }

    fn announce(&self, clients: Vec<SeenClient>) {
        let fresh: Vec<SeenClient> = {
            let known = self.imp().sightings.borrow();
            clients
                .iter()
                .filter(|client| known.get(&client.name) != Some(&client.seen_at))
                .cloned()
                .collect()
        };
        self.imp().sightings.replace(
            clients
                .into_iter()
                .map(|client| (client.name, client.seen_at))
                .collect(),
        );
        let states = self.imp().states.borrow().clone();
        for client in fresh {
            let name = connected_name(&client, &states);
            self.toast(&gettext_f("{client} just connected", &[("client", &name)]));
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum Done {
    Installed,
    Removed,
}

// The row button's label and the longer name a screen reader says.
fn action_labels(state: &ClientState) -> Option<(String, String)> {
    let client = [("client", state.client.name.as_str())];
    match state.action {
        ClientAction::Install => Some((gettext("Install"), gettext_f("Install in {client}", &client))),
        ClientAction::Update => Some((gettext("Update"), gettext_f("Update {client}", &client))),
        ClientAction::Copy => Some((gettext("Copy"), gettext_f("Copy the Setup for {client}", &client))),
        ClientAction::None => None,
    }
}

fn property_row(title: &str, subtitle: &str) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .title(title)
        .subtitle(subtitle)
        .use_markup(false)
        .build();
    row.add_css_class("property");
    row
}

fn code_card(text: &str) -> gtk4::Box {
    let label = gtk4::Label::builder()
        .label(text)
        .xalign(0.0)
        .wrap(true)
        .wrap_mode(gtk4::pango::WrapMode::WordChar)
        .selectable(true)
        .margin_top(10)
        .margin_bottom(10)
        .margin_start(12)
        .margin_end(12)
        .build();
    label.add_css_class("monospace");
    let card = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    card.add_css_class("card");
    card.append(&label);
    card
}

fn removal_alert(state: &ClientState, host: &ClientHost) -> adw::AlertDialog {
    let name = state.client.name.as_str();
    let body = match (state.removes_with_command, &state.config_path) {
        (true, _) => mcp_clients::remove_command(host, &state.client.id).map(|command| {
            gettext_f(
                "TablePro runs “{command}” to remove its entry.",
                &[("command", &command)],
            )
        }),
        (false, Some(path)) => Some(gettext_f(
            "TablePro removes its entry from {file}. The file as it was is kept as {backup}.",
            &[
                ("file", &display_path(path, &host.home)),
                ("backup", &display_path(&mcp_clients::backup_path(path), &host.home)),
            ],
        )),
        (false, None) => None,
    };
    let alert = adw::AlertDialog::new(
        Some(&gettext_f("Remove TablePro From {client}?", &[("client", name)])),
        body.as_deref(),
    );
    alert.add_response(CANCEL, &gettext("_Cancel"));
    alert.add_response(REMOVE, &gettext("_Remove"));
    alert.set_response_appearance(REMOVE, adw::ResponseAppearance::Destructive);
    alert.set_default_response(Some(CANCEL));
    alert.set_close_response(CANCEL);
    alert
}

pub(crate) fn address(port: u16) -> String {
    format!("http://127.0.0.1:{port}{}", tablepro_mcp::MCP_PATH)
}

// A client that sends the token without the scheme is refused, so the
// header value is what gets copied.
fn authorization_header(token: &str) -> String {
    format!("Bearer {token}")
}

fn display_path(path: &Path, home: &Path) -> String {
    match path.strip_prefix(home) {
        Ok(below) if !home.as_os_str().is_empty() => format!("~/{}", below.display()),
        _ => path.display().to_string(),
    }
}

// Several clients share an engine, as ChatGPT and Codex do, so the one
// found on this computer names a sighting.
fn connected_name(seen: &SeenClient, states: &[ClientState]) -> String {
    let matches = mcp_clients::catalog()
        .map(|catalog| catalog.clients_for_client_info(&seen.name, ClientPlatform::Linux))
        .unwrap_or_default();
    let found = matches.iter().find(|client| {
        states
            .iter()
            .any(|state| state.client.id == client.id && (state.detected || state.status.is_configured()))
    });
    match found.or(matches.first()) {
        Some(client) => client.name.clone(),
        None => seen.title.clone().unwrap_or_else(|| seen.name.clone()),
    }
}

fn row_status_text(state: &ClientState) -> String {
    match state.unsupported() {
        Some(UnsupportedReason::StdioOnly) => gettext("Cannot connect to an address"),
        Some(UnsupportedReason::RemoteOnly) => gettext("Connects only to servers on the internet"),
        None => client_status_text(state.status),
    }
}

fn client_status_text(status: ClientConfigStatus) -> String {
    match status {
        ClientConfigStatus::NotConfigured => gettext("Not set up"),
        ClientConfigStatus::Current => gettext("Set up"),
        ClientConfigStatus::Disabled => gettext("Set up but turned off in the client"),
        ClientConfigStatus::Stale(StaleReason::Shadowed) => gettext("Set up, but a project uses an old setup"),
        ClientConfigStatus::Stale(StaleReason::OtherUrl) => gettext("Set up for another address"),
        ClientConfigStatus::Stale(StaleReason::OtherToken) => gettext("Set up with an old access token"),
        ClientConfigStatus::Stale(StaleReason::OtherCommand | StaleReason::CommandMissing) => {
            gettext("Set up for another server")
        }
        ClientConfigStatus::OtherScope => gettext("Set up for one project only"),
        ClientConfigStatus::Unreadable => gettext("Its configuration file cannot be read"),
        ClientConfigStatus::Unknown => gettext("Set up by hand in the client"),
    }
}

fn reason_text(reason: UnsupportedReason, client: &str) -> String {
    match reason {
        UnsupportedReason::StdioOnly => gettext_f(
            "{client} runs only servers it starts itself, and TablePro on Linux serves MCP at an address.",
            &[("client", client)],
        ),
        UnsupportedReason::RemoteOnly => gettext_f(
            "{client} connects to MCP servers from the internet, so it cannot reach TablePro on this computer.",
            &[("client", client)],
        ),
    }
}

fn applies_text(applies: Applies, client: &str) -> String {
    let client = [("client", client)];
    match applies {
        Applies::Live => gettext_f("{client} picks up the change on its own.", &client),
        Applies::NewSession => gettext_f("Start a new session in {client} to use it.", &client),
        Applies::RestartApp => gettext_f("Quit and reopen {client} to use it.", &client),
        Applies::Reload => gettext_f("Reload the MCP servers in {client} to use it.", &client),
    }
}

fn manual_text(state: &ClientState, sandboxed: bool, home: &Path) -> String {
    let name = [("client", state.client.name.as_str())];
    if mcp_clients::setup_is_command(state.client) {
        return match sandboxed {
            true => gettext_f(
                "Run this command in a terminal. TablePro runs in a sandbox and cannot start {client} itself.",
                &name,
            ),
            false => gettext("Run this command in a terminal."),
        };
    }
    match &state.config_path {
        Some(path) => gettext_f("Add this to {file}.", &[("file", &display_path(path, home))]),
        None => gettext_f("Add this in the MCP settings of {client}.", &name),
    }
}

fn setup_error_text(error: &ClientSetupError, home: &Path) -> String {
    let path = match error {
        ClientSetupError::Edit { path, .. }
        | ClientSetupError::Io { path, .. }
        | ClientSetupError::NotText(path)
        | ClientSetupError::ChangedDuringWrite(path)
        | ClientSetupError::VerificationFailed(path) => display_path(path, home),
        _ => String::new(),
    };
    let file = [("file", path.as_str())];
    match error {
        ClientSetupError::UnknownClient | ClientSetupError::NoInstaller => {
            gettext("TablePro cannot set up this client. Copy the setup instead.")
        }
        ClientSetupError::Template(_) => gettext("The setup for this client could not be made."),
        ClientSetupError::Edit {
            error: ConfigEditError::InvalidSyntax { .. },
            ..
        } => gettext_f("{file} is not valid, so TablePro left it as it is.", &file),
        ClientSetupError::Edit {
            error: ConfigEditError::DuplicateKey { .. },
            ..
        } => gettext_f("{file} names a setting twice, so TablePro left it as it is.", &file),
        ClientSetupError::Edit { .. } => gettext_f(
            "{file} is written in a way TablePro does not edit. Copy the setup instead.",
            &file,
        ),
        ClientSetupError::Io { source, .. } => gettext_f(
            "{file} could not be written: {detail}",
            &[("file", &path), ("detail", &source.to_string())],
        ),
        ClientSetupError::NotText(_) => gettext_f("{file} is not a text file, so TablePro left it as it is.", &file),
        ClientSetupError::ChangedDuringWrite(_) => {
            gettext_f("{file} kept changing while TablePro wrote it. Try again.", &file)
        }
        ClientSetupError::VerificationFailed(_) => gettext_f(
            "{file} did not keep the change. Check whether the client rewrote it.",
            &file,
        ),
        ClientSetupError::CommandFailed(_) => gettext("The client’s command failed."),
        ClientSetupError::CommandTimedOut => gettext("The client’s command did not finish."),
    }
}

pub(crate) fn status_text(status: &McpStatus) -> String {
    match status {
        McpStatus::Off => gettext("Off"),
        McpStatus::Starting => gettext("Starting…"),
        McpStatus::Running { port } => gettext_f("Running on port {port}", &[("port", &port.to_string())]),
        McpStatus::Failed(failure) => failure_text(failure),
    }
}

pub(crate) fn failure_text(failure: &McpFailure) -> String {
    match failure {
        McpFailure::PortInUse(port) => gettext_f(
            "Port {port} is in use by another program. Choose another port.",
            &[("port", &port.to_string())],
        ),
        McpFailure::Listen { port, kind } => match kind {
            std::io::ErrorKind::PermissionDenied => gettext_f(
                "The system does not let TablePro listen on port {port}. Choose another port.",
                &[("port", &port.to_string())],
            ),
            _ => gettext_f(
                "TablePro could not listen on port {port}.",
                &[("port", &port.to_string())],
            ),
        },
        McpFailure::Keyring(error) => keyring_text(error),
        McpFailure::NoRandomness => {
            gettext("The system’s random number source failed, so no access token could be made.")
        }
        McpFailure::Interrupted(_) => gettext("The server stopped unexpectedly."),
    }
}

// The token is not a password, so the keyring sentences say what the
// server cannot do without it.
fn keyring_text(error: &SecretError) -> String {
    match error {
        SecretError::Locked | SecretError::UnlockDismissed => {
            gettext("The keyring is locked, so the access token cannot be read. Unlock it and try again.")
        }
        SecretError::ServiceUnavailable { .. } => {
            gettext("No keyring is running, so the access token cannot be kept. Start a keyring and try again.")
        }
        SecretError::PortalUnavailable { .. } => gettext(
            "The secret portal is unavailable, so the access token cannot be kept. Check that xdg-desktop-portal and a keyring are running.",
        ),
        SecretError::InvalidEncoding => gettext("The stored access token is not readable text."),
        SecretError::Backend { service_message, .. } => match service_message {
            Some(message) => gettext_f("The keyring reported: {detail}", &[("detail", message)]),
            None => gettext("The keyring failed without giving a reason."),
        },
    }
}

#[cfg(test)]
mod tests {
    use std::rc::Rc;
    use std::sync::Arc;
    use std::time::Duration;

    use super::*;
    use crate::services::mcp_service::tests::{MemoryTokens, context, free_port};
    use crate::test_support::{MemorySettings, OwnedWindow, assert_labelled, descendants, test_runtime, wait_until};

    const WAIT: Duration = Duration::from_secs(10);

    fn bound_page(settings: &MemorySettings, service: Option<McpService>) -> McpPage {
        crate::register_test_resources();
        let page = McpPage::default();
        page.bind(settings.get(), service);
        page
    }

    fn page_on(settings: &MemorySettings, service: McpService, home: &Path) -> McpPage {
        crate::register_test_resources();
        let page = McpPage::default();
        page.bind_on(settings.get(), Some(service), ClientHost::under(home));
        page
    }

    fn subtitle(page: &McpPage, name: &str) -> Option<String> {
        page.imp()
            .client_rows
            .borrow()
            .iter()
            .find(|client| client.row.title() == name)
            .and_then(|client| client.row.subtitle())
            .map(|text| text.to_string())
    }

    fn client_row(page: &McpPage, id: &str) -> ClientRow {
        page.imp()
            .client_rows
            .borrow()
            .iter()
            .find(|client| client.id == id)
            .cloned()
            .expect("the client's row")
    }

    fn shown_on_a_window(page: &McpPage) -> OwnedWindow<adw::Window> {
        let window = OwnedWindow::presented(adw::Window::builder().default_width(900).default_height(700).build());
        window.set_content(Some(page));
        window
    }

    fn stopped_service(settings: &MemorySettings, runtime: &crate::runtime::AppRuntime, root: &Path) -> McpService {
        settings.get().set_mcp_server_port(free_port()).expect("the port");
        McpService::start(
            settings.get().clone(),
            runtime.tasks(),
            Arc::new(MemoryTokens::default()),
            context(root),
        )
    }

    #[gtk4::test]
    fn the_switch_and_port_edit_the_preferences() {
        let settings = MemorySettings::new();
        let page = bound_page(&settings, None);
        let imp = page.imp();

        assert_eq!(page.title(), "MCP");
        assert!(!imp.enabled_row.is_active(), "the server starts off");
        assert_eq!(imp.port_row.value(), 23508.0);
        assert_eq!(imp.status_row.subtitle().as_deref(), Some("Off"));
        assert!(
            imp.client_group.is_sensitive(),
            "the address, the header and Regenerate work while the server is off"
        );
        assert_eq!(imp.token_row.subtitle().as_deref(), Some(MASKED_AUTHORIZATION));
        assert!(!imp.clients_group.is_visible(), "no server, so no client to set up");

        imp.enabled_row.set_active(true);
        imp.port_row.set_value(40_000.0);

        assert!(settings.get().mcp_server_enabled());
        assert_eq!(settings.get().mcp_server_port(), 40_000);
        assert_eq!(
            imp.address_row.subtitle().as_deref(),
            Some("http://127.0.0.1:40000/mcp")
        );
    }

    #[gtk4::test]
    fn a_running_server_shows_its_port_and_offers_the_token() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let root = tempfile::tempdir().expect("tempdir");
        let home = tempfile::tempdir().expect("tempdir");
        let service = stopped_service(&settings, &runtime, root.path());
        let port = settings.get().mcp_server_port();
        let page = page_on(&settings, service.clone(), home.path());
        let imp = page.imp();

        imp.enabled_row.set_active(true);

        let running = format!("Running on port {port}");
        wait_until(WAIT, || imp.status_row.subtitle().as_deref() == Some(running.as_str()))
            .expect("the running status");
        assert!(imp.client_group.is_sensitive());
        assert!(!imp.retry_button.is_visible());
        assert_eq!(
            imp.address_row.subtitle().map(|text| text.to_string()),
            Some(format!("http://127.0.0.1:{port}/mcp"))
        );
        assert!(service.token().is_some());
        service.stop();
        runtime.shutdown();
    }

    #[gtk4::test]
    fn the_clients_are_listed_set_up_first_with_their_state() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let (root, home) = (
            tempfile::tempdir().expect("tempdir"),
            tempfile::tempdir().expect("tempdir"),
        );
        let service = stopped_service(&settings, &runtime, root.path());
        let cursor = format!(
            r#"{{"mcpServers": {{"tablepro": {{"url": "{}", "headers": {{"Authorization": "Bearer tp_x"}}}}}}}}"#,
            address(settings.get().mcp_server_port())
        );
        std::fs::create_dir_all(home.path().join(".cursor")).expect("a folder");
        std::fs::write(home.path().join(".cursor/mcp.json"), cursor).expect("a config");

        let page = page_on(&settings, service.clone(), home.path());

        wait_until(WAIT, || subtitle(&page, "Cursor").as_deref() == Some("Set up")).expect("Cursor read as set up");
        let rows: Vec<adw::ActionRow> = page
            .imp()
            .client_rows
            .borrow()
            .iter()
            .map(|client| client.row.clone())
            .collect();
        assert_eq!(rows.len(), mcp_clients::linux_clients().count());
        assert_eq!(rows[0].title(), "Cursor");
        assert_eq!(
            subtitle(&page, "Claude Desktop").as_deref(),
            Some("Cannot connect to an address")
        );
        assert_eq!(subtitle(&page, "Zed").as_deref(), Some("Not set up"));
        for row in &rows {
            assert_labelled(row).unwrap_or_else(|problem| panic!("{}: {problem}", row.title()));
        }
        assert_eq!(
            crate::test_support::unlabelled_icon_buttons(&page),
            Vec::<String>::new()
        );
        service.stop();
        runtime.shutdown();
    }

    #[gtk4::test]
    fn a_refresh_keeps_the_focus_on_the_row_it_changes() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let (root, home) = (
            tempfile::tempdir().expect("tempdir"),
            tempfile::tempdir().expect("tempdir"),
        );
        let service = stopped_service(&settings, &runtime, root.path());
        let page = page_on(&settings, service.clone(), home.path());
        let window = shown_on_a_window(&page);
        wait_until(WAIT, || subtitle(&page, "Cursor").as_deref() == Some("Not set up")).expect("the survey");
        let order = |page: &McpPage| -> Vec<String> {
            page.imp()
                .client_rows
                .borrow()
                .iter()
                .map(|client| client.id.clone())
                .collect()
        };
        let before = order(&page);
        let cursor = client_row(&page, "cursor");
        cursor.row.grab_focus();
        assert!(cursor.row.is_focus(), "the row takes the focus");

        let host = ClientHost::under(home.path());
        mcp_clients::install(&host, "cursor", &address(page.port()), "Bearer tp_x").expect("installed");
        page.refresh_clients();

        wait_until(WAIT, || subtitle(&page, "Cursor").as_deref() == Some("Set up")).expect("Cursor set up");
        assert_eq!(client_row(&page, "cursor").row, cursor.row, "the row was built again");
        assert!(cursor.row.is_focus(), "the refresh took the focus off the row");
        assert_eq!(order(&page), before, "a row moved while the page was open");
        drop(window);
        service.stop();
        runtime.shutdown();
    }

    #[gtk4::test]
    fn sorting_the_rows_keeps_the_focus_on_the_row_that_had_it() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let (root, home) = (
            tempfile::tempdir().expect("tempdir"),
            tempfile::tempdir().expect("tempdir"),
        );
        let service = stopped_service(&settings, &runtime, root.path());
        let page = page_on(&settings, service.clone(), home.path());
        let window = shown_on_a_window(&page);
        wait_until(WAIT, || subtitle(&page, "Zed").as_deref() == Some("Not set up")).expect("the survey");
        let zed = client_row(&page, "zed");
        zed.row.grab_focus();
        // As before the first survey, which sorts the rows.
        page.imp().rows_placed.set(false);

        let host = ClientHost::under(home.path());
        mcp_clients::install(&host, "cursor", &address(page.port()), "Bearer tp_x").expect("installed");
        page.refresh_clients();

        wait_until(WAIT, || {
            page.imp()
                .client_rows
                .borrow()
                .first()
                .is_some_and(|first| first.id == "cursor")
        })
        .expect("Cursor sorted first once set up");
        assert!(zed.row.is_focus(), "sorting took the focus off the row");
        drop(window);
        service.stop();
        runtime.shutdown();
    }

    #[gtk4::test]
    fn a_button_a_refresh_hides_hands_the_focus_to_its_row() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let (root, home) = (
            tempfile::tempdir().expect("tempdir"),
            tempfile::tempdir().expect("tempdir"),
        );
        let service = stopped_service(&settings, &runtime, root.path());
        let page = page_on(&settings, service.clone(), home.path());
        let window = shown_on_a_window(&page);
        wait_until(WAIT, || subtitle(&page, "Zed").as_deref() == Some("Not set up")).expect("Zed listed");
        let zed = client_row(&page, "zed");
        assert_eq!(zed.button.label().as_deref(), Some("Install"));
        zed.button.grab_focus();
        assert!(zed.button.is_focus(), "Install takes the focus");

        page.install_client("zed");

        wait_until(WAIT, || subtitle(&page, "Zed").as_deref() == Some("Set up")).expect("Zed set up");
        assert!(!zed.button.is_visible(), "a set up client has nothing to install");
        assert!(zed.row.is_focus(), "the focus went with the hidden button");
        drop(window);
        service.stop();
        runtime.shutdown();
    }

    #[gtk4::test]
    fn a_client_page_is_built_again_only_when_what_it_shows_changes() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let (root, home) = (
            tempfile::tempdir().expect("tempdir"),
            tempfile::tempdir().expect("tempdir"),
        );
        let service = stopped_service(&settings, &runtime, root.path());
        let page = page_on(&settings, service.clone(), home.path());
        wait_until(WAIT, || subtitle(&page, "Zed").as_deref() == Some("Not set up")).expect("Zed listed");
        page.open_client("zed");
        let view = page
            .imp()
            .subpage
            .borrow()
            .as_ref()
            .map(|open| open.view.clone())
            .expect("Zed's page");
        let content = view.content();

        let host = ClientHost::under(home.path());
        mcp_clients::install(&host, "cursor", &address(page.port()), "Bearer tp_x").expect("installed");
        page.refresh_clients();
        wait_until(WAIT, || subtitle(&page, "Cursor").as_deref() == Some("Set up")).expect("Cursor set up");

        assert_eq!(view.content(), content, "a change to another client rebuilt Zed's page");
        page.imp().port_row.set_value(40_000.0);
        wait_until(WAIT, || view.content() != content).expect("a new port shows a new address");
        service.stop();
        runtime.shutdown();
    }

    #[gtk4::test]
    fn install_writes_the_client_file_while_the_server_is_off() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let (root, home) = (
            tempfile::tempdir().expect("tempdir"),
            tempfile::tempdir().expect("tempdir"),
        );
        let tokens = Arc::new(MemoryTokens::default());
        settings.get().set_mcp_server_port(free_port()).expect("the port");
        let service = McpService::start(
            settings.get().clone(),
            runtime.tasks(),
            tokens.clone(),
            context(root.path()),
        );
        let page = page_on(&settings, service.clone(), home.path());
        wait_until(WAIT, || subtitle(&page, "Zed").as_deref() == Some("Not set up")).expect("Zed listed");

        page.install_client("zed");

        wait_until(WAIT, || subtitle(&page, "Zed").as_deref() == Some("Set up")).expect("Zed set up");
        let written = std::fs::read_to_string(home.path().join(".config/zed/settings.json")).expect("the file");
        let token = tokens
            .0
            .lock()
            .expect("tokens")
            .clone()
            .expect("a token kept for the client");
        assert!(
            written.contains(&format!("\"Authorization\": \"Bearer {token}\"")),
            "{written}"
        );
        service.stop();
        runtime.shutdown();
    }

    #[gtk4::test]
    fn a_client_page_shows_its_file_a_masked_setup_and_remove() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let (root, home) = (
            tempfile::tempdir().expect("tempdir"),
            tempfile::tempdir().expect("tempdir"),
        );
        let service = stopped_service(&settings, &runtime, root.path());
        let page = page_on(&settings, service.clone(), home.path());
        wait_until(WAIT, || {
            subtitle(&page, "Cursor").is_some_and(|text| text != "Checking…")
        })
        .expect("the survey");
        let host = ClientHost::under(home.path());
        mcp_clients::install(&host, "cursor", &address(page.port()), "Bearer tp_secret").expect("installed");
        page.refresh_clients();
        wait_until(WAIT, || subtitle(&page, "Cursor").as_deref() == Some("Set up")).expect("Cursor set up");

        let content = page.client_content(&page.state("cursor").expect("Cursor"));

        let labels: Vec<String> = descendants(&content)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk4::Label>().ok())
            .map(|label| label.label().to_string())
            .collect();
        assert!(
            labels.iter().any(|text| text.contains(MASKED_AUTHORIZATION)),
            "{labels:?}"
        );
        assert!(
            !labels.iter().any(|text| text.contains("tp_secret")),
            "the token is on screen"
        );
        assert!(labels.iter().any(|text| text == "~/.cursor/mcp.json"), "{labels:?}");
        let titles: Vec<String> = descendants(&content)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::PreferencesRow>().ok())
            .map(|row| row.title().to_string())
            .collect();
        assert!(titles.contains(&"Remove…".to_owned()), "{titles:?}");
        assert!(!titles.contains(&"Install".to_owned()), "{titles:?}");
        service.stop();
        runtime.shutdown();
    }

    #[gtk4::test]
    fn a_client_that_connects_is_announced_once_by_its_catalog_name() {
        let settings = MemorySettings::new();
        let page = bound_page(&settings, None);
        let toasts = Rc::new(RefCell::new(Vec::<String>::new()));
        let sink = toasts.clone();
        page.connect_toast(move |_, toast| {
            sink.borrow_mut()
                .push(toast.title().map(|title| title.to_string()).unwrap_or_default());
        });
        let seen = |name: &str, second: u64| SeenClient {
            name: name.to_owned(),
            title: None,
            version: "1".to_owned(),
            seen_at: SystemTime::UNIX_EPOCH + Duration::from_secs(second),
        };

        page.announce(vec![seen("claude-code", 1)]);
        page.announce(vec![seen("claude-code", 1), seen("my-agent", 2)]);
        page.announce(vec![seen("my-agent", 2), seen("claude-code", 3)]);

        assert_eq!(
            *toasts.borrow(),
            [
                "Claude Code just connected",
                "my-agent just connected",
                "Claude Code just connected"
            ]
        );
    }

    #[gtk4::test]
    fn a_client_turned_off_says_so_and_offers_no_button() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let (root, home) = (
            tempfile::tempdir().expect("tempdir"),
            tempfile::tempdir().expect("tempdir"),
        );
        let service = stopped_service(&settings, &runtime, root.path());
        let kiro = format!(
            r#"{{"mcpServers": {{"tablepro": {{"url": "{}", "headers": {{"Authorization": "Bearer tp_x"}}, "disabled": true}}}}}}"#,
            address(settings.get().mcp_server_port())
        );
        std::fs::create_dir_all(home.path().join(".kiro/settings")).expect("a folder");
        std::fs::write(home.path().join(".kiro/settings/mcp.json"), kiro).expect("a config");

        let page = page_on(&settings, service.clone(), home.path());

        wait_until(WAIT, || {
            subtitle(&page, "Kiro").as_deref() == Some("Set up but turned off in the client")
        })
        .expect("Kiro read as turned off");
        assert!(!client_row(&page, "kiro").button.is_visible());
        let content = page.client_content(&page.state("kiro").expect("Kiro"));
        let descriptions: Vec<String> = descendants(&content)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::PreferencesGroup>().ok())
            .filter_map(|group| group.description().map(|text| text.to_string()))
            .collect();
        assert!(
            descriptions.iter().any(|text| text.contains("turned off in Kiro")),
            "{descriptions:?}"
        );
        service.stop();
        runtime.shutdown();
    }

    fn cursor_state(config_path: PathBuf) -> ClientState {
        ClientState {
            client: mcp_clients::linux_clients()
                .find(|client| client.id == "cursor")
                .expect("Cursor"),
            detected: false,
            status: ClientConfigStatus::Current,
            config_path: Some(config_path),
            action: ClientAction::None,
            removable: true,
            removes_with_command: false,
        }
    }

    #[gtk4::test]
    fn a_file_path_with_markup_characters_is_shown_as_written() {
        let settings = MemorySettings::new();
        let page = bound_page(&settings, None);

        let group = page.manual_group(&cursor_state(PathBuf::from("/srv/Tom & <Jerry>/mcp.json")));

        let description = group.description().expect("a description");
        let (_, text, _) = gtk4::pango::parse_markup(&description, '\0').expect("valid markup");
        assert_eq!(text.as_str(), "Add this to /srv/Tom & <Jerry>/mcp.json.");
    }

    #[gtk4::test]
    fn the_remove_dialog_names_the_backup_beside_the_file_a_link_points_to() {
        let home = tempfile::tempdir().expect("tempdir");
        let real = home.path().join("dotfiles/mcp.json");
        std::fs::create_dir_all(real.parent().expect("a folder")).expect("a folder");
        std::fs::write(&real, "{}").expect("a config");
        std::fs::create_dir_all(home.path().join(".cursor")).expect("a folder");
        let link = home.path().join(".cursor/mcp.json");
        std::os::unix::fs::symlink(&real, &link).expect("a link");

        let alert = removal_alert(&cursor_state(link), &ClientHost::under(home.path()));

        let body = alert.body().to_string();
        assert!(body.contains("dotfiles/mcp.json.tablepro-backup"), "{body}");
        assert!(!body.contains(".cursor/mcp.json.tablepro-backup"), "{body}");
    }

    #[test]
    fn a_shared_engine_is_named_after_the_client_found_here() {
        let codex = mcp_clients::linux_clients()
            .find(|client| client.id == "codex")
            .expect("Codex CLI");
        let found = ClientState {
            client: codex,
            detected: true,
            status: ClientConfigStatus::NotConfigured,
            config_path: None,
            action: ClientAction::Install,
            removable: false,
            removes_with_command: false,
        };
        let seen = |name: &str, title: Option<&str>| SeenClient {
            name: name.to_owned(),
            title: title.map(str::to_owned),
            version: "1".to_owned(),
            seen_at: SystemTime::UNIX_EPOCH,
        };

        assert_eq!(connected_name(&seen("codex-mcp-client", None), &[found]), "Codex CLI");
        assert_eq!(connected_name(&seen("codex-mcp-client", None), &[]), "ChatGPT");
        assert_eq!(connected_name(&seen("x-agent", Some("X Agent")), &[]), "X Agent");
    }

    #[test]
    fn the_copied_header_carries_the_scheme_and_paths_read_from_home() {
        assert_eq!(authorization_header("tp_abc"), "Bearer tp_abc");
        assert_eq!(
            display_path(Path::new("/home/ana/.cursor/mcp.json"), Path::new("/home/ana")),
            "~/.cursor/mcp.json"
        );
        assert_eq!(
            display_path(Path::new("/etc/x.json"), Path::new("/home/ana")),
            "/etc/x.json"
        );
    }

    #[test]
    fn each_client_status_has_its_own_words() {
        let statuses = [
            ClientConfigStatus::NotConfigured,
            ClientConfigStatus::Current,
            ClientConfigStatus::Disabled,
            ClientConfigStatus::Stale(StaleReason::Shadowed),
            ClientConfigStatus::Stale(StaleReason::OtherUrl),
            ClientConfigStatus::Stale(StaleReason::OtherToken),
            ClientConfigStatus::Stale(StaleReason::OtherCommand),
            ClientConfigStatus::OtherScope,
            ClientConfigStatus::Unreadable,
            ClientConfigStatus::Unknown,
        ];
        let texts: std::collections::HashSet<String> = statuses.into_iter().map(client_status_text).collect();

        assert_eq!(texts.len(), statuses.len());
    }

    #[test]
    fn each_failure_has_its_own_sentence() {
        let failures = [
            McpFailure::PortInUse(23508),
            McpFailure::Listen {
                port: 23508,
                kind: std::io::ErrorKind::PermissionDenied,
            },
            McpFailure::Listen {
                port: 23508,
                kind: std::io::ErrorKind::Other,
            },
            McpFailure::Keyring(SecretError::Locked),
            McpFailure::Keyring(SecretError::ServiceUnavailable { detail: String::new() }),
            McpFailure::NoRandomness,
            McpFailure::Interrupted(String::new()),
        ];
        let texts: std::collections::HashSet<String> = failures.iter().map(failure_text).collect();

        assert_eq!(texts.len(), failures.len());
        assert!(failure_text(&McpFailure::PortInUse(4000)).contains("4000"));
    }
}
