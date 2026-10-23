//! What one window's assistant may send: the provider the settings
//! name, the connection's AI policy read again before every request,
//! and the user's answer under Ask Each Time, kept until the window's
//! session ends.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_ai::{Endpoint, SchemaContext};
use tablepro_core::{AiPolicy, AiProvider};

use crate::services::active_session::ActiveSession;
use crate::services::ai_service::AiService;

const CANCEL: &str = "cancel";
const ALLOW: &str = "allow";

/// Where requests go: the provider and the address they are sent to.
/// An answer under Ask Each Time holds for this one place only.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Destination {
    provider: AiProvider,
    base: String,
}

impl Destination {
    fn new(provider: AiProvider, base: &str) -> Self {
        Self {
            provider,
            base: base.trim().trim_end_matches('/').to_owned(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Availability {
    /// No provider: nothing is sent anywhere.
    Off,
    /// The connection's policy is Never.
    Blocked,
    Ready,
}

pub(crate) struct AssistantAccess {
    ai: AiService,
    session: ActiveSession,
    /// The engine as the user knows it, for the prompts.
    engine: String,
    policy: Box<dyn Fn() -> AiPolicy>,
    /// Where the user allowed requests to go from this window, under Ask
    /// Each Time.
    granted: RefCell<Option<Destination>>,
    asking: Cell<bool>,
}

impl AssistantAccess {
    /// `policy` reads the connection's policy as it is now, so a change
    /// in the connect dialog applies from the next request.
    pub(crate) fn new(
        ai: AiService,
        session: ActiveSession,
        engine: String,
        policy: impl Fn() -> AiPolicy + 'static,
    ) -> Rc<Self> {
        Rc::new(Self {
            ai,
            session,
            engine,
            policy: Box::new(policy),
            granted: RefCell::new(None),
            asking: Cell::new(false),
        })
    }

    pub(crate) fn ai(&self) -> &AiService {
        &self.ai
    }

    pub(crate) fn availability(&self) -> Availability {
        if self.ai.provider().is_none() {
            Availability::Off
        } else if (self.policy)() == AiPolicy::Never {
            Availability::Blocked
        } else {
            Availability::Ready
        }
    }

    /// Whether a request may go without asking: the policy allows it,
    /// or the user already did in this window, for where requests go now.
    pub(crate) fn is_granted(&self) -> bool {
        let Some(current) = self.current_destination() else {
            return false;
        };
        self.availability() == Availability::Ready
            && ((self.policy)() == AiPolicy::Allow || self.granted.borrow().as_ref() == Some(&current))
    }

    /// The last check before `endpoint` is sent anything: it must still
    /// be where requests go, and they must be allowed to go there. The
    /// preferences or the policy can change while a request is made.
    pub(crate) fn may_send_to(&self, endpoint: &Endpoint) -> bool {
        self.is_granted() && self.current_destination() == Some(Destination::new(endpoint.kind(), endpoint.base_url()))
    }

    fn current_destination(&self) -> Option<Destination> {
        let provider = self.ai.provider()?;
        Some(Destination::new(provider, &self.ai.settings().ai_base_url(provider)))
    }

    /// Suggestions never ask: they start once a request is allowed.
    pub(crate) fn suggests_while_typing(&self) -> bool {
        self.ai.settings().ai_inline_suggestions() && self.is_granted()
    }

    /// Whether a request may go now. Under Ask Each Time the first one
    /// asks over `parent`, naming where the data goes.
    pub(crate) async fn permit(&self, parent: &gtk::Widget) -> bool {
        if self.availability() != Availability::Ready {
            return false;
        }
        if self.is_granted() {
            return true;
        }
        let Some(asked_for) = self.current_destination() else {
            return false;
        };
        if self.asking.replace(true) {
            return false;
        }
        let asking = Asking {
            flag: &self.asking,
            dialog: self.consent_dialog(),
        };
        let allowed = crate::workspace::respond(&asking.dialog, parent).await == ALLOW;
        drop(asking);
        // The answer is for the place the question named; the policy or
        // the provider may have changed while it was open.
        if allowed
            && self.availability() == Availability::Ready
            && self.current_destination().as_ref() == Some(&asked_for)
        {
            self.granted.replace(Some(asked_for));
        }
        self.is_granted()
    }

    fn consent_dialog(&self) -> adw::AlertDialog {
        let connection = self
            .session
            .metadata()
            .map(|metadata| metadata.name)
            .unwrap_or_default();
        let destination = self.destination();
        let dialog = adw::AlertDialog::new(
            Some(&crate::i18n::gettext("Use the AI Assistant Here?")),
            Some(&crate::i18n::gettext_f(
                "The assistant sends your questions, your SQL and the structure of the tables involved from “{connection}” to {destination}. It reads no rows. Your answer lasts until this window disconnects.",
                &[("connection", &connection), ("destination", &destination)],
            )),
        );
        dialog.add_response(CANCEL, &crate::i18n::gettext("_Cancel"));
        dialog.add_response(ALLOW, &crate::i18n::gettext("_Allow"));
        dialog.set_response_appearance(ALLOW, adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some(CANCEL));
        dialog.set_close_response(CANCEL);
        dialog
    }

    /// The provider and the host its requests go to.
    pub(crate) fn destination(&self) -> String {
        let Some(provider) = self.ai.provider() else {
            return String::new();
        };
        let name = super::provider_name(provider);
        let host = Endpoint::host_of(&self.ai.settings().ai_base_url(provider));
        match (provider, host) {
            (AiProvider::OpenAiCompatible, Some(host)) => {
                crate::i18n::gettext_f("the server at {host}", &[("host", &host)])
            }
            (_, Some(host)) => crate::i18n::gettext_f("{provider} ({host})", &[("provider", &name), ("host", &host)]),
            (_, None) => name,
        }
    }

    /// What the prompt says about the connection, with the structure of
    /// the tables `text` names.
    pub(crate) async fn context(&self, text: String) -> SchemaContext {
        let Some(session) = self.session.get() else {
            return SchemaContext {
                engine: self.engine.clone(),
                ..SchemaContext::default()
            };
        };
        let engine = self.engine.clone();
        let read = self
            .ai
            .tasks()
            .spawn_task(async move { super::schema_reader::read(session, engine, text).await })
            .await;
        read.unwrap_or_else(|failure| {
            tracing::warn!(%failure, "the schema for the assistant could not be read");
            SchemaContext {
                engine: self.engine.clone(),
                ..SchemaContext::default()
            }
        })
    }
}

/// The question while it is open. Dropped when the answer comes, or
/// when the request that asked is stopped, which takes the question
/// down with it.
struct Asking<'a> {
    flag: &'a Cell<bool>,
    dialog: adw::AlertDialog,
}

impl Drop for Asking<'_> {
    fn drop(&mut self) {
        self.flag.set(false);
        // Answered, it has closed and left its window already.
        if self.dialog.parent().is_some() {
            self.dialog.close();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::time::Duration;

    use super::*;
    use crate::test_support::{MemorySettings, OwnedWindow, test_runtime, wait_until};

    fn permitted(access: &Rc<AssistantAccess>, parent: gtk::Widget) -> bool {
        let access = access.clone();
        crate::test_support::finish_on_main(Duration::from_secs(10), async move { access.permit(&parent).await })
            .expect("an answer")
    }

    fn access(
        settings: &MemorySettings,
        policy: Rc<Cell<AiPolicy>>,
    ) -> (Rc<AssistantAccess>, crate::runtime::AppRuntime) {
        let runtime = test_runtime();
        let service = AiService::new(settings.get().clone(), runtime.tasks(), None);
        let access = AssistantAccess::new(service, ActiveSession::new(), "SQLite".to_owned(), move || policy.get());
        (access, runtime)
    }

    #[gtk4::test]
    fn with_no_provider_nothing_is_allowed() {
        let settings = MemorySettings::new();
        let (access, _runtime) = access(&settings, Rc::new(Cell::new(AiPolicy::Allow)));

        assert_eq!(access.availability(), Availability::Off);
        assert!(!access.is_granted());
        assert!(!permitted(&access, gtk::Label::new(None).upcast()));
    }

    #[gtk4::test]
    fn never_keeps_everything_back_whatever_was_answered_before() {
        let settings = MemorySettings::new();
        settings.get().set_ai_provider(Some(AiProvider::Anthropic)).unwrap();
        settings.get().set_ai_inline_suggestions(true).unwrap();
        let policy = Rc::new(Cell::new(AiPolicy::Allow));
        let (access, _runtime) = access(&settings, policy.clone());
        assert!(access.suggests_while_typing());

        policy.set(AiPolicy::Never);

        assert_eq!(access.availability(), Availability::Blocked);
        assert!(!access.is_granted());
        assert!(!access.suggests_while_typing());
        assert!(!permitted(&access, gtk::Label::new(None).upcast()));
    }

    #[gtk4::test]
    fn ask_each_time_asks_once_and_the_answer_holds() {
        let settings = MemorySettings::new();
        settings.get().set_ai_provider(Some(AiProvider::Anthropic)).unwrap();
        settings.get().set_ai_inline_suggestions(true).unwrap();
        let (access, _runtime) = access(&settings, Rc::new(Cell::new(AiPolicy::Ask)));
        let window = OwnedWindow::presented(adw::Window::builder().default_width(800).default_height(600).build());
        assert!(!access.suggests_while_typing(), "suggestions start only once allowed");

        let answer = Rc::new(Cell::new(None));
        let seen = answer.clone();
        let asking = access.clone();
        let parent: gtk::Widget = (*window).clone().upcast();
        glib::spawn_future_local(async move { seen.set(Some(asking.permit(&parent).await)) });
        wait_until(Duration::from_secs(10), || {
            crate::test_support::first_descendant_of_type::<adw::AlertDialog>(&*window).is_some()
        })
        .expect("the question");
        let alert = crate::test_support::first_descendant_of_type::<adw::AlertDialog>(&*window).expect("the question");
        let body = alert.body();
        assert!(body.contains("Anthropic (api.anthropic.com)"), "{body}");
        assert!(body.contains("It reads no rows"), "{body}");
        assert_eq!(alert.default_response().as_deref(), Some(CANCEL));
        crate::test_support::respond(&alert, ALLOW);
        wait_until(Duration::from_secs(10), || answer.get().is_some()).expect("the answer");

        assert_eq!(answer.get(), Some(true));
        assert!(access.is_granted());
        assert!(access.suggests_while_typing());
        assert!(permitted(&access, (*window).clone().upcast()));
    }

    #[gtk4::test]
    fn a_compatible_server_is_named_by_its_host() {
        let settings = MemorySettings::new();
        settings
            .get()
            .set_ai_provider(Some(AiProvider::OpenAiCompatible))
            .unwrap();
        settings.get().set_ai_compatible_url("http://gpu-box:11434/v1").unwrap();
        let (access, _runtime) = access(&settings, Rc::new(Cell::new(AiPolicy::Ask)));

        assert_eq!(access.destination(), "the server at gpu-box");
    }

    /// Ask over a window, run `meanwhile` while the question is open,
    /// then answer it with `response`. What `permit` said comes back.
    fn answer(access: &Rc<AssistantAccess>, response: &str, meanwhile: impl FnOnce()) -> bool {
        let window = OwnedWindow::presented(adw::Window::builder().default_width(800).default_height(600).build());
        let answer = Rc::new(Cell::new(None));
        let seen = answer.clone();
        let asking = access.clone();
        let parent: gtk::Widget = (*window).clone().upcast();
        glib::spawn_future_local(async move { seen.set(Some(asking.permit(&parent).await)) });
        wait_until(Duration::from_secs(10), || {
            crate::test_support::first_descendant_of_type::<adw::AlertDialog>(&*window).is_some()
        })
        .expect("the question");
        meanwhile();
        let alert = crate::test_support::first_descendant_of_type::<adw::AlertDialog>(&*window).expect("the question");
        crate::test_support::respond(&alert, response);
        wait_until(Duration::from_secs(10), || answer.get().is_some()).expect("the answer");
        answer.get().unwrap_or_default()
    }

    fn compatible(settings: &MemorySettings, address: &str) -> Endpoint {
        settings.get().set_ai_compatible_url(address).unwrap();
        Endpoint::new(AiProvider::OpenAiCompatible, address, "m", None).unwrap()
    }

    #[gtk4::test]
    fn an_answer_holds_only_for_the_server_it_named() {
        let settings = MemorySettings::new();
        settings
            .get()
            .set_ai_provider(Some(AiProvider::OpenAiCompatible))
            .unwrap();
        let first = compatible(&settings, "http://localhost:11434/v1");
        let (access, _runtime) = access(&settings, Rc::new(Cell::new(AiPolicy::Ask)));
        assert!(!access.may_send_to(&first), "sent before the user allowed it");

        assert!(answer(&access, ALLOW, || {}));
        assert!(access.may_send_to(&first));

        let second = compatible(&settings, "http://gpu-box:11434/v1/");
        assert!(!access.is_granted(), "the answer moved to another server");
        assert!(!access.may_send_to(&second));
        assert!(!access.may_send_to(&first), "sent to a server no longer chosen");

        settings
            .get()
            .set_ai_compatible_url("http://localhost:11434/v1/")
            .unwrap();
        assert!(access.may_send_to(&first));
    }

    #[gtk4::test]
    fn an_allow_given_after_the_server_changed_allows_nothing() {
        let settings = MemorySettings::new();
        settings
            .get()
            .set_ai_provider(Some(AiProvider::OpenAiCompatible))
            .unwrap();
        compatible(&settings, "http://localhost:11434/v1");
        let (access, _runtime) = access(&settings, Rc::new(Cell::new(AiPolicy::Ask)));

        let allowed = answer(&access, ALLOW, || {
            settings.get().set_ai_compatible_url("http://gpu-box:11434/v1").unwrap();
        });

        assert!(!allowed);
        assert!(!access.is_granted());
    }

    #[gtk4::test]
    fn under_allow_a_request_made_before_a_change_is_not_sent() {
        let settings = MemorySettings::new();
        settings
            .get()
            .set_ai_provider(Some(AiProvider::OpenAiCompatible))
            .unwrap();
        let first = compatible(&settings, "http://localhost:11434/v1");
        let policy = Rc::new(Cell::new(AiPolicy::Allow));
        let (access, _runtime) = access(&settings, policy.clone());
        assert!(access.may_send_to(&first));

        let second = compatible(&settings, "http://gpu-box:11434/v1");
        assert!(!access.may_send_to(&first));
        assert!(access.may_send_to(&second));

        policy.set(AiPolicy::Ask);
        assert!(!access.may_send_to(&second), "Allow carried over to Ask Each Time");
    }

    #[gtk4::test]
    fn a_question_stopped_while_open_is_taken_down_and_asked_again_later() {
        let settings = MemorySettings::new();
        settings.get().set_ai_provider(Some(AiProvider::Anthropic)).unwrap();
        let (access, _runtime) = access(&settings, Rc::new(Cell::new(AiPolicy::Ask)));
        let window = OwnedWindow::presented(adw::Window::builder().default_width(800).default_height(600).build());
        let asking = access.clone();
        let parent: gtk::Widget = (*window).clone().upcast();
        let work = glib::spawn_future_local(async move { asking.permit(&parent).await });
        wait_until(Duration::from_secs(10), || {
            crate::test_support::first_descendant_of_type::<adw::AlertDialog>(&*window).is_some()
        })
        .expect("the question");

        // The handle holds the task's future until it goes too.
        work.abort();
        drop(work);
        wait_until(Duration::from_secs(10), || {
            crate::workspace::visible_alert(&*window).is_none()
        })
        .expect("the question taken down");

        assert!(answer(&access, ALLOW, || {}), "a later request was never asked");
    }
}
