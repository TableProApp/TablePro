use std::cell::{Cell, RefCell};
use std::sync::OnceLock;

use gio::prelude::SettingsExtManual;
use glib::subclass::Signal;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use secrecy::SecretString;
use tablepro_core::AiProvider;
use tablepro_storage::settings::keys;

use crate::services::ai_service::AiService;

/// The provider row's entries, `None` first: the assistant starts off.
const PROVIDERS: [Option<AiProvider>; 4] = [
    None,
    Some(AiProvider::Anthropic),
    Some(AiProvider::OpenAi),
    Some(AiProvider::OpenAiCompatible),
];

mod imp {
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/preferences-ai-page.ui")]
    pub struct AiPage {
        #[template_child]
        pub provider_row: TemplateChild<adw::ComboRow>,
        #[template_child]
        pub provider_names: TemplateChild<gtk4::StringList>,
        #[template_child]
        pub connection_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub address_row: TemplateChild<adw::EntryRow>,
        #[template_child]
        pub key_row: TemplateChild<adw::PasswordEntryRow>,
        #[template_child]
        pub key_state: TemplateChild<gtk4::Label>,
        #[template_child]
        pub remove_key_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub model_row: TemplateChild<adw::EntryRow>,
        #[template_child]
        pub models_button: TemplateChild<gtk4::MenuButton>,
        #[template_child]
        pub models_popover: TemplateChild<gtk4::Popover>,
        #[template_child]
        pub models_stack: TemplateChild<gtk4::Stack>,
        #[template_child]
        pub models_problem: TemplateChild<gtk4::Label>,
        #[template_child]
        pub models_list: TemplateChild<gtk4::ListBox>,
        #[template_child]
        pub editor_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub suggestions_row: TemplateChild<adw::SwitchRow>,
        pub(super) service: RefCell<Option<AiService>>,
        /// Set while the page writes its own rows, so their change
        /// handlers do not write the value back.
        pub updating: Cell<bool>,
        /// Counts key reads and writes, so one that lands after the
        /// provider changed, or after a later one, is not shown.
        pub key_read: Cell<u64>,
        /// The keyring read or write in flight, and the model listing.
        pub key_work: RefCell<Option<glib::JoinHandle<()>>>,
        pub models_work: RefCell<Option<glib::JoinHandle<()>>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for AiPage {
        const NAME: &'static str = "TableProAiPage";
        type Type = super::AiPage;
        type ParentType = adw::PreferencesPage;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for AiPage {
        fn dispose(&self) {
            for work in [self.key_work.take(), self.models_work.take()].into_iter().flatten() {
                work.abort();
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

    impl WidgetImpl for AiPage {}
    impl PreferencesPageImpl for AiPage {}
}

glib::wrapper! {
    /// The AI page: the provider, its address, key and model, and the
    /// editor's suggestions.
    pub struct AiPage(ObjectSubclass<imp::AiPage>)
        @extends adw::PreferencesPage, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for AiPage {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl AiPage {
    pub(super) fn bind(&self, service: AiService) {
        let imp = self.imp();
        let names: Vec<String> = PROVIDERS.into_iter().map(provider_label).collect();
        let names: Vec<&str> = names.iter().map(String::as_str).collect();
        imp.provider_names.splice(0, imp.provider_names.n_items(), &names);
        crate::ui::combo_value::show_whole_value(&imp.provider_row);
        service
            .settings()
            .gio()
            .bind(keys::AI_INLINE_SUGGESTIONS, &imp.suggestions_row.get(), "active")
            .build();
        imp.service.replace(Some(service));
        self.show_settings();
        self.connect_rows();
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

    fn service(&self) -> Option<AiService> {
        self.imp().service.borrow().clone()
    }

    fn provider(&self) -> Option<AiProvider> {
        PROVIDERS
            .get(self.imp().provider_row.selected() as usize)
            .copied()
            .flatten()
    }

    fn connect_rows(&self) {
        let imp = self.imp();
        let page = self.downgrade();
        imp.provider_row.connect_selected_notify(move |_| {
            if let Some(page) = page.upgrade()
                && !page.imp().updating.get()
            {
                page.provider_chosen();
            }
        });
        let page = self.downgrade();
        imp.address_row.connect_changed(move |row| {
            if let Some(page) = page.upgrade()
                && !page.imp().updating.get()
            {
                page.address_changed(&row.text());
            }
        });
        let page = self.downgrade();
        imp.model_row.connect_changed(move |row| {
            if let Some(page) = page.upgrade()
                && !page.imp().updating.get()
                && let (Some(service), Some(provider)) = (page.service(), page.provider())
                && let Err(error) = service.settings().set_ai_model(provider, row.text().trim())
            {
                tracing::warn!(%error, "the model could not be saved");
            }
        });
        let page = self.downgrade();
        imp.key_row.connect_apply(move |row| {
            if let Some(page) = page.upgrade() {
                page.save_key(SecretString::from(row.text().to_string()));
            }
        });
        let page = self.downgrade();
        imp.remove_key_button.connect_clicked(move |_| {
            if let Some(page) = page.upgrade() {
                page.save_key(SecretString::from(String::new()));
            }
        });
        let page = self.downgrade();
        imp.models_popover.connect_show(move |_| {
            if let Some(page) = page.upgrade() {
                page.list_models();
            }
        });
        let page = self.downgrade();
        self.connect_map(move |_| {
            if let Some(page) = page.upgrade() {
                page.read_key_state();
            }
        });
    }

    /// Put the settings in the rows, without writing them back.
    fn show_settings(&self) {
        let imp = self.imp();
        let Some(service) = self.service() else {
            return;
        };
        let settings = service.settings();
        let provider = settings.ai_provider();
        imp.updating.set(true);
        let position = PROVIDERS.iter().position(|entry| *entry == provider).unwrap_or(0);
        imp.provider_row.set_selected(position as u32);
        if let Some(provider) = provider {
            imp.model_row.set_text(&settings.ai_model(provider));
            imp.address_row
                .set_text(&settings.ai_base_url(AiProvider::OpenAiCompatible));
        }
        imp.updating.set(false);
        self.show_provider(provider);
    }

    fn provider_chosen(&self) {
        let provider = self.provider();
        if let Some(service) = self.service()
            && let Err(error) = service.settings().set_ai_provider(provider)
        {
            tracing::warn!(%error, "the AI provider could not be saved");
        }
        self.show_settings();
        self.read_key_state();
    }

    fn show_provider(&self, provider: Option<AiProvider>) {
        let imp = self.imp();
        imp.provider_row.set_subtitle(&provider_subtitle(provider));
        imp.connection_group.set_visible(provider.is_some());
        imp.editor_group.set_sensitive(provider.is_some());
        let compatible = provider == Some(AiProvider::OpenAiCompatible);
        imp.address_row.set_visible(compatible);
        imp.key_row.set_title(&if compatible {
            crate::i18n::gettext("API Key (optional)")
        } else {
            crate::i18n::gettext("API Key")
        });
        imp.key_row.set_text("");
        imp.key_state.set_visible(false);
        imp.remove_key_button.set_visible(false);
        if compatible {
            self.check_address(&imp.address_row.text());
        }
    }

    fn address_changed(&self, address: &str) {
        if let Some(service) = self.service()
            && let Err(error) = service.settings().set_ai_compatible_url(address.trim())
        {
            tracing::warn!(%error, "the server address could not be saved");
        }
        self.check_address(address);
    }

    fn check_address(&self, address: &str) {
        let row = self.imp().address_row.get();
        let valid = tablepro_ai::Endpoint::new(AiProvider::OpenAiCompatible, address, "", None).is_ok();
        if valid {
            row.remove_css_class("error");
            crate::ui::a11y::show_invalid(&row, None);
        } else {
            row.add_css_class("error");
            crate::ui::a11y::show_invalid(
                &row,
                Some(&crate::i18n::gettext(
                    "Enter an http or https address with its version path, such as http://localhost:11434/v1.",
                )),
            );
        }
    }

    /// Whether a key is kept for the provider, read when the page shows
    /// or the provider changes, so the keyring is asked only once the
    /// user looks here.
    fn read_key_state(&self) {
        let (Some(service), Some(provider)) = (self.service(), self.provider()) else {
            return;
        };
        if !self.is_mapped() {
            return;
        }
        let imp = self.imp();
        let read = imp.key_read.get() + 1;
        imp.key_read.set(read);
        let page = self.downgrade();
        let work = glib::spawn_future_local(async move {
            let stored = service.load_key(provider).await;
            let Some(page) = page.upgrade() else {
                return;
            };
            if page.imp().key_read.get() != read || page.provider() != Some(provider) {
                return;
            }
            match stored {
                Ok(key) => page.show_key_state(key.is_some()),
                // A local server needs no key, so no keyring is no problem
                // until the user saves one.
                Err(_) if !provider.requires_key() => page.show_key_state(false),
                Err(error) => page.toast(&super::super::assistant::setup_error_text(&error)),
            }
        });
        imp.key_work.replace(Some(work));
    }

    fn show_key_state(&self, stored: bool) {
        let imp = self.imp();
        imp.key_state.set_visible(stored);
        imp.remove_key_button.set_visible(stored);
    }

    fn save_key(&self, key: SecretString) {
        let (Some(service), Some(provider)) = (self.service(), self.provider()) else {
            return;
        };
        let removing = secrecy::ExposeSecret::expose_secret(&key).trim().is_empty();
        let imp = self.imp();
        let write = imp.key_read.get() + 1;
        imp.key_read.set(write);
        let page = self.downgrade();
        let work = glib::spawn_future_local(async move {
            let saved = service.store_key(provider, key).await;
            let Some(page) = page.upgrade() else {
                return;
            };
            if page.imp().key_read.get() != write || page.provider() != Some(provider) {
                if let Err(error) = saved {
                    page.toast(&super::super::assistant::setup_error_text(&error));
                }
                return;
            }
            match saved {
                Ok(()) => {
                    page.imp().key_row.set_text("");
                    page.show_key_state(!removing);
                    page.toast(&if removing {
                        crate::i18n::gettext("API key removed from the keyring.")
                    } else {
                        crate::i18n::gettext("API key saved in the keyring.")
                    });
                }
                Err(error) => page.toast(&super::super::assistant::setup_error_text(&error)),
            }
        });
        self.imp().key_work.replace(Some(work));
    }

    fn list_models(&self) {
        let imp = self.imp();
        let (Some(service), Some(provider)) = (self.service(), self.provider()) else {
            return;
        };
        imp.models_stack.set_visible_child_name("loading");
        let page = self.downgrade();
        let work = glib::spawn_future_local(async move {
            let listed = service.models(provider).await;
            let Some(page) = page.upgrade() else {
                return;
            };
            if page.provider() != Some(provider) {
                return;
            }
            page.show_models(listed);
        });
        if let Some(previous) = imp.models_work.replace(Some(work)) {
            previous.abort();
        }
    }

    fn show_models(&self, listed: Result<Vec<String>, crate::services::ai_service::AiSetupError>) {
        let imp = self.imp();
        let models = match listed {
            Ok(models) if !models.is_empty() => models,
            Ok(_) => {
                imp.models_problem
                    .set_label(&crate::i18n::gettext("The provider lists no models."));
                imp.models_stack.set_visible_child_name("failed");
                return;
            }
            Err(error) => {
                imp.models_problem
                    .set_label(&super::super::assistant::setup_error_text(&error));
                imp.models_stack.set_visible_child_name("failed");
                return;
            }
        };
        imp.models_list.remove_all();
        let current = imp.model_row.text().to_string();
        for model in models {
            let row = adw::ActionRow::builder().title(&model).activatable(true).build();
            row.set_title_lines(1);
            if model == current {
                row.add_suffix(&gtk4::Image::from_icon_name("object-select-symbolic"));
            }
            let page = self.downgrade();
            row.connect_activated(move |_| {
                if let Some(page) = page.upgrade() {
                    page.imp().model_row.set_text(&model);
                    page.imp().models_popover.popdown();
                }
            });
            imp.models_list.append(&row);
        }
        imp.models_stack.set_visible_child_name("models");
    }

    fn toast(&self, message: &str) {
        self.emit_by_name::<()>("toast", &[&crate::ui::plain_toast(message)]);
    }
}

fn provider_label(provider: Option<AiProvider>) -> String {
    match provider {
        None => crate::i18n::gettext("None"),
        Some(provider) => crate::ui::assistant::provider_name(provider),
    }
}

fn provider_subtitle(provider: Option<AiProvider>) -> String {
    match provider {
        None => crate::i18n::gettext("The assistant is off, and nothing is sent anywhere."),
        Some(AiProvider::Anthropic) => {
            crate::i18n::gettext("Requests go to api.anthropic.com, on your Anthropic account.")
        }
        Some(AiProvider::OpenAi) => crate::i18n::gettext("Requests go to api.openai.com, on your OpenAI account."),
        Some(AiProvider::OpenAiCompatible) => {
            crate::i18n::gettext("Requests go to the server address below, such as Ollama on this computer.")
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::services::ai_service::tests::MemoryKeys;
    use crate::test_support::{MemorySettings, test_runtime};

    fn bound_page(settings: &MemorySettings, runtime: &crate::runtime::AppRuntime) -> AiPage {
        crate::register_test_resources();
        let page = AiPage::default();
        page.bind(AiService::new(
            settings.get().clone(),
            runtime.tasks(),
            Some(Arc::new(MemoryKeys::default())),
        ));
        page
    }

    #[gtk4::test]
    fn the_assistant_starts_off_with_nothing_to_set_up() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let page = bound_page(&settings, &runtime);
        let imp = page.imp();

        assert_eq!(page.title(), "AI");
        assert_eq!(imp.provider_row.selected(), 0);
        assert!(!imp.connection_group.is_visible());
        assert!(!imp.editor_group.is_sensitive());
        assert!(!imp.suggestions_row.is_active());
        assert_eq!(settings.get().ai_provider(), None);
    }

    #[gtk4::test]
    fn choosing_a_provider_saves_it_and_shows_its_model() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let page = bound_page(&settings, &runtime);
        let imp = page.imp();

        imp.provider_row.set_selected(1);

        assert_eq!(settings.get().ai_provider(), Some(AiProvider::Anthropic));
        assert!(imp.connection_group.is_visible());
        assert!(!imp.address_row.is_visible(), "Anthropic's address is fixed");
        assert_eq!(imp.model_row.text(), "claude-opus-5-5");
        assert_eq!(imp.key_row.title(), "API Key");

        imp.model_row.set_text("claude-haiku-5-5");
        assert_eq!(settings.get().ai_model(AiProvider::Anthropic), "claude-haiku-5-5");
    }

    #[gtk4::test]
    fn a_compatible_server_takes_an_address_and_an_optional_key() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let page = bound_page(&settings, &runtime);
        let imp = page.imp();

        imp.provider_row.set_selected(3);
        imp.address_row.set_text("http://gpu-box:11434/v1");

        assert!(imp.address_row.is_visible());
        assert_eq!(imp.key_row.title(), "API Key (optional)");
        assert_eq!(
            settings.get().ai_base_url(AiProvider::OpenAiCompatible),
            "http://gpu-box:11434/v1"
        );
        assert!(!imp.address_row.has_css_class("error"));

        imp.address_row.set_text("gpu-box:11434");
        assert!(imp.address_row.has_css_class("error"));
    }

    #[gtk4::test]
    fn a_key_applied_goes_to_the_keyring_and_never_stays_in_the_row() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let keys = Arc::new(MemoryKeys::default());
        crate::register_test_resources();
        let page = AiPage::default();
        page.bind(AiService::new(
            settings.get().clone(),
            runtime.tasks(),
            Some(keys.clone()),
        ));
        let imp = page.imp();
        imp.provider_row.set_selected(2);

        imp.key_row.set_text("sk-openai");
        imp.key_row.emit_by_name::<()>("apply", &[]);
        crate::test_support::wait_until(std::time::Duration::from_secs(10), || imp.key_state.is_visible())
            .expect("the key saved");

        assert_eq!(imp.key_row.text(), "");
        assert!(imp.remove_key_button.is_visible());
        assert!(keys.0.lock().unwrap().contains_key(&AiProvider::OpenAi));

        imp.remove_key_button.emit_clicked();
        crate::test_support::wait_until(std::time::Duration::from_secs(10), || !imp.key_state.is_visible())
            .expect("the key removed");
        assert!(keys.0.lock().unwrap().is_empty());
    }
}
