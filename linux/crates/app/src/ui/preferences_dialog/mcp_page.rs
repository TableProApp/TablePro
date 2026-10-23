use std::cell::RefCell;
use std::sync::OnceLock;

use gio::prelude::SettingsExtManual;
use glib::subclass::Signal;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use secrecy::ExposeSecret;
use tablepro_core::credentials::SecretError;
use tablepro_storage::AppSettings;
use tablepro_storage::settings::keys;
use tokio::sync::watch;

use crate::services::mcp_service::McpService;
use crate::services::mcp_status::{McpFailure, McpStatus};

const CANCEL: &str = "cancel";
const REGENERATE: &str = "regenerate";

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
        pub service: RefCell<Option<McpService>>,
        pub status: RefCell<Option<McpStatus>>,
        pub following: RefCell<Option<glib::JoinHandle<()>>>,
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
            if let Some(following) = self.following.take() {
                following.abort();
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
    /// The MCP page: the server's switch, status and port, and what a
    /// client needs to reach it.
    pub struct McpPage(ObjectSubclass<imp::McpPage>)
        @extends adw::PreferencesPage, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for McpPage {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl McpPage {
    /// `service` is `None` where no server can run, such as a test that
    /// brings none; the page then only edits the preferences.
    pub(super) fn bind(&self, settings: &AppSettings, service: Option<McpService>) {
        let imp = self.imp();
        let gio_settings = settings.gio();
        gio_settings
            .bind(keys::MCP_SERVER_ENABLED, &imp.enabled_row.get(), "active")
            .build();
        gio_settings
            .bind(keys::MCP_SERVER_PORT, &imp.port_row.get(), "value")
            .build();

        let page = self.downgrade();
        imp.port_row.connect_value_notify(move |_| {
            if let Some(page) = page.upgrade() {
                page.refresh();
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
                page.copy_token();
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

        match &service {
            Some(service) => self.follow(service.status()),
            None => self.show_status(McpStatus::Off),
        }
        imp.service.replace(service);
    }

    /// AdwPreferencesDialog owns the toast overlay, so the page hands its
    /// toasts up rather than looking for one.
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

    fn refresh(&self) {
        let imp = self.imp();
        let status = imp.status.borrow().clone().unwrap_or(McpStatus::Off);
        imp.status_row.set_subtitle(&status_text(&status));
        imp.retry_button.set_visible(matches!(status, McpStatus::Failed(_)));
        imp.client_group.set_sensitive(status.port().is_some());
        let port = status.port().unwrap_or(imp.port_row.value() as u16);
        imp.address_row.set_subtitle(&address(port));
    }

    fn copy_address(&self) {
        let Some(port) = self.imp().status.borrow().as_ref().and_then(McpStatus::port) else {
            return;
        };
        crate::ui::clipboard::copy_text(self, address(port), |message| self.toast(message));
    }

    fn copy_token(&self) {
        let Some(token) = self.service().and_then(|service| service.token()) else {
            return;
        };
        crate::ui::clipboard::copy_text(self, token.expose_secret().to_owned(), |message| self.toast(message));
    }

    fn confirm_regenerate(&self) {
        let alert = adw::AlertDialog::new(
            Some(&crate::i18n::gettext("Regenerate Access Token?")),
            Some(&crate::i18n::gettext(
                "Clients that use the current token are refused until you give them the new one.",
            )),
        );
        alert.add_response(CANCEL, &crate::i18n::gettext("_Cancel"));
        alert.add_response(REGENERATE, &crate::i18n::gettext("_Regenerate"));
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
                Ok(()) => page.toast(&crate::i18n::gettext("New access token made. Copy it to your clients.")),
                Err(failure) => page.toast(&failure_text(&failure)),
            }
        });
    }

    fn toast(&self, message: &str) {
        self.emit_by_name::<()>("toast", &[&adw::Toast::new(message)]);
    }
}

pub(crate) fn address(port: u16) -> String {
    format!("http://127.0.0.1:{port}{}", tablepro_mcp::MCP_PATH)
}

pub(crate) fn status_text(status: &McpStatus) -> String {
    match status {
        McpStatus::Off => crate::i18n::gettext("Off"),
        McpStatus::Starting => crate::i18n::gettext("Starting…"),
        McpStatus::Running { port } => crate::i18n::gettext_f("Running on port {port}", &[("port", &port.to_string())]),
        McpStatus::Failed(failure) => failure_text(failure),
    }
}

pub(crate) fn failure_text(failure: &McpFailure) -> String {
    match failure {
        McpFailure::PortInUse(port) => crate::i18n::gettext_f(
            "Port {port} is in use by another program. Choose another port.",
            &[("port", &port.to_string())],
        ),
        McpFailure::Listen { port, kind } => match kind {
            std::io::ErrorKind::PermissionDenied => crate::i18n::gettext_f(
                "The system does not let TablePro listen on port {port}. Choose another port.",
                &[("port", &port.to_string())],
            ),
            _ => crate::i18n::gettext_f(
                "TablePro could not listen on port {port}.",
                &[("port", &port.to_string())],
            ),
        },
        McpFailure::Keyring(error) => keyring_text(error),
        McpFailure::NoRandomness => {
            crate::i18n::gettext("The system’s random number source failed, so no access token could be made.")
        }
        McpFailure::Interrupted(_) => crate::i18n::gettext("The server stopped unexpectedly."),
    }
}

/// The token is not a password, so the keyring sentences say what the
/// server cannot do without it.
fn keyring_text(error: &SecretError) -> String {
    match error {
        SecretError::Locked | SecretError::UnlockDismissed => {
            crate::i18n::gettext("The keyring is locked, so the access token cannot be read. Unlock it and try again.")
        }
        SecretError::ServiceUnavailable { .. } => crate::i18n::gettext(
            "No keyring is running, so the access token cannot be kept. Start a keyring and try again.",
        ),
        SecretError::PortalUnavailable { .. } => crate::i18n::gettext(
            "The secret portal is unavailable, so the access token cannot be kept. Check that xdg-desktop-portal and a keyring are running.",
        ),
        SecretError::InvalidEncoding => crate::i18n::gettext("The stored access token is not readable text."),
        SecretError::Backend { service_message, .. } => match service_message {
            Some(message) => crate::i18n::gettext_f("The keyring reported: {detail}", &[("detail", message)]),
            None => crate::i18n::gettext("The keyring failed without giving a reason."),
        },
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use super::*;
    use crate::services::mcp_service::tests::{MemoryTokens, context, free_port};
    use crate::test_support::{MemorySettings, test_runtime, wait_until};

    const WAIT: Duration = Duration::from_secs(10);

    fn bound_page(settings: &MemorySettings, service: Option<McpService>) -> McpPage {
        crate::register_test_resources();
        let page = McpPage::default();
        page.bind(settings.get(), service);
        page
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
        assert!(!imp.client_group.is_sensitive());

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
        let port = free_port();
        settings.get().set_mcp_server_port(port).expect("the port");
        let service = McpService::start(
            settings.get().clone(),
            runtime.tasks(),
            Arc::new(MemoryTokens::default()),
            context(root.path()),
        );
        let page = bound_page(&settings, Some(service.clone()));
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
