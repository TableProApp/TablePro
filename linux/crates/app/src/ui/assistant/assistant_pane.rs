//! The assistant's pane beside a connection's tabs: one conversation at
//! a time, its replies streaming in, and what was sent with it.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_ai::{ChatRequest, ReplyEnd, ReplyEvent, StopReason};
use tablepro_storage::settings::keys;
use tokio_util::sync::CancellationToken;

use super::AssistantRequest;
use super::assistant_access::{AssistantAccess, Availability};
use super::code_block::{BlockHooks, CodeBlock};
use super::conversation::{Asked, Conversation};
use super::message_view::MessageView;
use crate::ui::handler_guard::HandlerGuard;

/// What the pane reaches in its window.
#[derive(Clone)]
pub(crate) struct PaneHooks {
    pub access: Rc<AssistantAccess>,
    /// The editor tab in front's text, which a conversation that starts
    /// from a question carries.
    pub editor_text: Rc<dyn Fn() -> Option<String>>,
    /// Put a code block's text in the editor.
    pub insert: Rc<dyn Fn(String)>,
    pub toast: Rc<dyn Fn(String)>,
}

mod imp {
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/assistant-pane.ui")]
    pub struct AssistantPane {
        #[template_child]
        pub toolbar: TemplateChild<adw::ToolbarView>,
        #[template_child]
        pub title: TemplateChild<adw::WindowTitle>,
        #[template_child]
        pub stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub conversation_stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub empty_page: TemplateChild<adw::StatusPage>,
        #[template_child]
        pub scroller: TemplateChild<gtk::ScrolledWindow>,
        #[template_child]
        pub messages: TemplateChild<gtk::Box>,
        #[template_child]
        pub composer_bar: TemplateChild<gtk::Box>,
        #[template_child]
        pub composer: TemplateChild<gtk::TextView>,
        #[template_child]
        pub placeholder: TemplateChild<gtk::Label>,
        #[template_child]
        pub send_stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub send_button: TemplateChild<gtk::Button>,
        #[template_child]
        pub stop_button: TemplateChild<gtk::Button>,
        pub(super) hooks: RefCell<Option<PaneHooks>>,
        pub(super) conversation: RefCell<Option<Conversation>>,
        /// The conversation's turns on screen, kept so their code blocks
        /// follow the style.
        pub(super) rows: RefCell<Vec<TurnRow>>,
        /// The work of the request in flight, from the consent question
        /// to the reply's last event.
        pub(super) work: RefCell<Option<glib::JoinHandle<()>>>,
        pub(super) cancel: RefCell<Option<CancellationToken>>,
        /// The Retry of the last turn, while it failed. A new question
        /// takes it away, since a retry asks for the last turn.
        pub(super) retry: RefCell<Option<gtk::Button>>,
        pub(super) busy: Cell<bool>,
        /// Bumped by each new conversation, so work for an older one
        /// that lands late is dropped.
        pub(super) generation: Cell<u64>,
        /// Whether the view follows the reply as it grows: the user
        /// scrolled to the end, or has not scrolled away.
        pub(super) follow: Cell<bool>,
        pub(super) settings_watch: RefCell<Vec<HandlerGuard>>,
        pub(super) actions: gtk::gio::SimpleActionGroup,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for AssistantPane {
        const NAME: &'static str = "TableProAssistantPane";
        type Type = super::AssistantPane;
        type ParentType = adw::Bin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for AssistantPane {
        fn constructed(&self) {
            self.parent_constructed();
            self.obj().connect_widgets();
        }

        fn dispose(&self) {
            self.obj().stop_work();
            self.settings_watch.take();
            self.hooks.take();
        }
    }

    impl WidgetImpl for AssistantPane {}
    impl BinImpl for AssistantPane {}
}

glib::wrapper! {
    pub struct AssistantPane(ObjectSubclass<imp::AssistantPane>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

/// One question and its reply on screen.
#[derive(Clone)]
pub(super) struct TurnRow {
    reply: Rc<MessageView>,
    footer: gtk::Box,
    /// An action's statement, shown as code.
    statement: Option<Rc<CodeBlock>>,
}

/// A turn as its Retry holds it: the button sits in the turn's footer,
/// so a strong hold would keep the turn alive after it left the pane.
struct WeakTurnRow {
    reply: std::rc::Weak<MessageView>,
    footer: glib::WeakRef<gtk::Box>,
    statement: Option<std::rc::Weak<CodeBlock>>,
}

impl TurnRow {
    fn downgrade(&self) -> WeakTurnRow {
        WeakTurnRow {
            reply: Rc::downgrade(&self.reply),
            footer: self.footer.downgrade(),
            statement: self.statement.as_ref().map(Rc::downgrade),
        }
    }
}

impl WeakTurnRow {
    fn upgrade(&self) -> Option<TurnRow> {
        Some(TurnRow {
            reply: self.reply.upgrade()?,
            footer: self.footer.upgrade()?,
            statement: match &self.statement {
                Some(statement) => Some(statement.upgrade()?),
                None => None,
            },
        })
    }
}

impl AssistantPane {
    pub(crate) fn bind(&self, hooks: PaneHooks) {
        let settings = hooks.access.ai().settings().clone();
        let mut watches = Vec::new();
        for key in [
            keys::AI_PROVIDER,
            keys::AI_ANTHROPIC_MODEL,
            keys::AI_OPENAI_MODEL,
            keys::AI_COMPATIBLE_MODEL,
            keys::AI_COMPATIBLE_URL,
        ] {
            let pane = self.downgrade();
            let handler = settings.gio().connect_changed(Some(key), move |_, _| {
                if let Some(pane) = pane.upgrade() {
                    pane.refresh();
                }
            });
            watches.push(HandlerGuard::new(settings.gio(), handler));
        }
        self.imp().settings_watch.replace(watches);
        self.imp().hooks.replace(Some(hooks));
        self.refresh();
    }

    /// Show what the assistant can do here now: off, kept from this
    /// connection, or the conversation.
    pub(crate) fn refresh(&self) {
        let imp = self.imp();
        let Some(access) = self.access() else {
            return;
        };
        let availability = access.availability();
        let page = match availability {
            Availability::Off => "off",
            Availability::Blocked => "blocked",
            Availability::Ready => "chat",
        };
        // A reply on its way stops as Stop stops it, so its turn keeps what
        // came and the pane can take the conversation up again later.
        if availability != Availability::Ready {
            self.stop();
        }
        imp.stack.set_visible_child_name(page);
        imp.toolbar.set_reveal_bottom_bars(availability == Availability::Ready);
        let settings = access.ai().settings();
        let model = access
            .ai()
            .provider()
            .map(|provider| settings.ai_model(provider))
            .unwrap_or_default();
        imp.title.set_subtitle(&model);
        imp.empty_page.set_description(Some(&glib::markup_escape_text(&crate::i18n::gettext_f(
            "Questions go to {destination} with this connection’s table structure and the SQL in the editor. It reads no rows.",
            &[("destination", &access.destination())],
        ))));
        self.sync_controls();
    }

    /// Start a new conversation on an editor's statement.
    pub(crate) fn run_action(&self, request: AssistantRequest) {
        self.new_conversation();
        self.ask(Asked::Action {
            action: request.action,
            statement: request.statement,
            error: request.error,
        });
    }

    /// Put the focus in the composer, for the key that shows the pane.
    pub(crate) fn focus_composer(&self) {
        let imp = self.imp();
        if imp.stack.visible_child_name().as_deref() == Some("chat") {
            imp.composer.grab_focus();
        }
    }

    /// Stop the reply in flight and let go of the window's services, as
    /// the window's session ends.
    pub(crate) fn shutdown(&self) {
        self.stop_work();
        self.imp().settings_watch.take();
        self.imp().hooks.take();
    }

    pub(crate) fn new_conversation(&self) {
        let imp = self.imp();
        self.stop_work();
        imp.generation.set(imp.generation.get() + 1);
        imp.conversation.take();
        imp.rows.take();
        imp.retry.take();
        while let Some(child) = imp.messages.first_child() {
            imp.messages.remove(&child);
        }
        imp.conversation_stack.set_visible_child_name("empty");
        self.sync_controls();
    }

    fn access(&self) -> Option<Rc<AssistantAccess>> {
        self.imp().hooks.borrow().as_ref().map(|hooks| hooks.access.clone())
    }

    fn hooks(&self) -> Option<PaneHooks> {
        self.imp().hooks.borrow().clone()
    }

    fn connect_widgets(&self) {
        let imp = self.imp();
        let pane = self.downgrade();
        imp.send_button.connect_clicked(move |_| {
            if let Some(pane) = pane.upgrade() {
                pane.send_typed();
            }
        });
        let pane = self.downgrade();
        imp.stop_button.connect_clicked(move |_| {
            if let Some(pane) = pane.upgrade() {
                pane.stop();
            }
        });
        let pane = self.downgrade();
        imp.composer.buffer().connect_changed(move |_| {
            if let Some(pane) = pane.upgrade() {
                pane.sync_controls();
            }
        });
        imp.composer.add_controller(self.send_key());
        let pane = self.downgrade();
        let entry = gtk::gio::ActionEntry::<gtk::gio::SimpleActionGroup>::builder("new-conversation")
            .activate(move |_, _, _| {
                if let Some(pane) = pane.upgrade() {
                    pane.new_conversation();
                }
            })
            .build();
        imp.actions.add_action_entries([entry]);
        self.insert_action_group("assistant", Some(&imp.actions));
        self.follow_the_reply();
    }

    /// Return sends, as in a chat; Shift+Return starts a new line.
    fn send_key(&self) -> gtk::EventControllerKey {
        let controller = gtk::EventControllerKey::new();
        controller.set_propagation_phase(gtk::PropagationPhase::Capture);
        let pane = self.downgrade();
        controller.connect_key_pressed(move |controller, keyval, _, state| {
            if !crate::application::component_matches("assistant.send", keyval, state) {
                return glib::Propagation::Proceed;
            }
            let Some(pane) = pane.upgrade() else {
                return glib::Propagation::Proceed;
            };
            // Return also confirms an input method's composition, which
            // the method takes before anything is sent.
            let composer = pane.imp().composer.get();
            if controller
                .current_event()
                .is_some_and(|event| composer.im_context_filter_keypress(&event))
            {
                return glib::Propagation::Stop;
            }
            pane.send_typed();
            glib::Propagation::Stop
        });
        controller
    }

    fn follow_the_reply(&self) {
        let imp = self.imp();
        imp.follow.set(true);
        let adjustment = imp.scroller.vadjustment();
        let pane = self.downgrade();
        adjustment.connect_value_changed(move |adjustment| {
            if let Some(pane) = pane.upgrade() {
                let end = adjustment.upper() - adjustment.page_size();
                pane.imp().follow.set(adjustment.value() >= end - 24.0);
            }
        });
        let pane = self.downgrade();
        adjustment.connect_upper_notify(move |adjustment| {
            if pane.upgrade().is_some_and(|pane| pane.imp().follow.get()) {
                adjustment.set_value(adjustment.upper() - adjustment.page_size());
            }
        });
    }

    fn composer_text(&self) -> String {
        let buffer = self.imp().composer.buffer();
        let (start, end) = buffer.bounds();
        buffer.text(&start, &end, false).to_string()
    }

    fn sync_controls(&self) {
        let imp = self.imp();
        let text = self.composer_text();
        imp.placeholder.set_visible(text.is_empty());
        let replying = imp.cancel.borrow().is_some();
        imp.send_stack
            .set_visible_child_name(if replying { "stop" } else { "send" });
        imp.send_button
            .set_sensitive(!imp.busy.get() && !text.trim().is_empty());
        let started = imp.conversation.borrow().is_some() || imp.busy.get();
        if let Some(action) = imp
            .actions
            .lookup_action("new-conversation")
            .and_downcast::<gtk::gio::SimpleAction>()
        {
            action.set_enabled(started);
        }
    }

    fn send_typed(&self) {
        let text = self.composer_text();
        if text.trim().is_empty() || self.imp().busy.get() {
            return;
        }
        self.ask(Asked::Typed(text.trim().to_owned()));
    }

    fn stop(&self) {
        if let Some(cancel) = self.imp().cancel.borrow().as_ref() {
            cancel.cancel();
        }
    }

    /// Drop the request in flight, whatever stage it is at.
    fn stop_work(&self) {
        let imp = self.imp();
        if let Some(cancel) = imp.cancel.take() {
            cancel.cancel();
        }
        if let Some(work) = imp.work.take() {
            work.abort();
        }
        imp.busy.set(false);
    }

    fn ask(&self, asked: Asked) {
        let Some(hooks) = self.hooks() else {
            return;
        };
        let imp = self.imp();
        if imp.busy.replace(true) {
            return;
        }
        self.sync_controls();
        let generation = imp.generation.get();
        let pane = self.downgrade();
        let work = glib::spawn_future_local(async move {
            let Some(parent) = pane.upgrade().map(|pane| pane.upcast::<gtk::Widget>()) else {
                return;
            };
            let allowed = hooks.access.permit(&parent).await;
            drop(parent);
            let Some(pane) = pane.upgrade() else {
                return;
            };
            if !allowed || pane.imp().generation.get() != generation {
                // This is that work, so it is let go rather than stopped.
                drop(pane.imp().work.take());
                pane.imp().busy.set(false);
                pane.refresh();
                return;
            }
            if matches!(asked, Asked::Typed(_)) {
                pane.imp().composer.buffer().set_text("");
            }
            pane.begin_turn(&hooks, asked, generation).await;
        });
        imp.work.replace(Some(work));
    }

    /// Start the conversation if there is none, show the question, and
    /// ask for the reply.
    async fn begin_turn(&self, hooks: &PaneHooks, asked: Asked, generation: u64) {
        let imp = self.imp();
        let mut described = Vec::new();
        if imp.conversation.borrow().is_none() {
            let editor = match &asked {
                Asked::Typed(_) => (hooks.editor_text)(),
                Asked::Action { .. } => None,
            };
            let named_in = match &asked {
                Asked::Typed(question) => format!("{}\n{question}", editor.as_deref().unwrap_or_default()),
                Asked::Action { statement, .. } => statement.clone(),
            };
            let context = hooks.access.context(named_in).await;
            if imp.generation.get() != generation {
                return;
            }
            described = context.described_names().into_iter().map(str::to_owned).collect();
            let system = tablepro_ai::chat_system_prompt(&context, editor.as_deref());
            imp.conversation.replace(Some(Conversation::new(system)));
        }
        let Some(request) = imp.conversation.borrow_mut().as_mut().map(|conversation| {
            conversation.ask(asked.clone());
            conversation.request(ChatRequest::CHAT_MAX_TOKENS)
        }) else {
            return;
        };
        drop_retry(&imp.retry);
        let row = self.show_turn(hooks, &asked, &described);
        imp.rows.borrow_mut().push(row.clone());
        self.reply(hooks, request, row, generation).await;
    }

    fn show_turn(&self, hooks: &PaneHooks, asked: &Asked, described: &[String]) -> TurnRow {
        let imp = self.imp();
        let block_hooks = BlockHooks {
            settings: hooks.access.ai().settings().clone(),
            insert: hooks.insert.clone(),
            toast: hooks.toast.clone(),
        };
        let turn = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let (card, statement) = question_card(asked, &block_hooks);
        turn.append(&card);
        if !described.is_empty() {
            let sent = gtk::Label::builder()
                .label(crate::i18n::gettext_f(
                    "Sent with the structure of {tables}",
                    &[("tables", &described.join(", "))],
                ))
                .wrap(true)
                .xalign(0.0)
                .build();
            sent.add_css_class("caption");
            sent.add_css_class("dim-label");
            turn.append(&sent);
        }
        let reply = Rc::new(MessageView::new(block_hooks));
        turn.append(reply.widget());
        let footer = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        turn.append(&footer);
        imp.messages.append(&turn);
        imp.conversation_stack.set_visible_child_name("messages");
        imp.follow.set(true);
        TurnRow {
            reply,
            footer,
            statement,
        }
    }

    async fn reply(&self, hooks: &PaneHooks, request: ChatRequest, row: TurnRow, generation: u64) {
        let imp = self.imp();
        show_waiting(&row.footer);
        let service = hooks.access.ai().clone();
        let endpoint = match service.endpoint().await {
            Ok(endpoint) => endpoint,
            Err(error) => {
                self.failed(&row, generation, &super::setup_error_text(&error));
                return;
            }
        };
        if imp.generation.get() != generation {
            return;
        }
        if let Err(error) = service.prepare().await {
            self.failed(&row, generation, &super::reply_error_text(&error));
            return;
        }
        if imp.generation.get() != generation {
            return;
        }
        // The preferences or the policy may have changed while the request
        // was being made, so the question is asked again where it must be.
        if !hooks.access.may_send_to(&endpoint) {
            let parent = self.clone().upcast::<gtk::Widget>();
            let allowed = hooks.access.permit(&parent).await && hooks.access.may_send_to(&endpoint);
            if imp.generation.get() != generation {
                return;
            }
            if !allowed {
                self.failed(
                    &row,
                    generation,
                    &crate::i18n::gettext("The assistant may not send from this connection now."),
                );
                self.refresh();
                return;
            }
        }
        let mut handle = match service.stream(endpoint, request).await {
            Ok(handle) => handle,
            Err(error) => {
                self.failed(&row, generation, &super::reply_error_text(&error));
                return;
            }
        };
        imp.cancel.replace(Some(handle.cancel.clone()));
        self.sync_controls();
        let mut painter = Painter::new(&row);
        loop {
            // Text that arrived since the last paint is painted once the
            // interval is up, even if nothing else arrives meanwhile.
            let next = match painter.due() {
                Some(wait) => {
                    let received = std::pin::pin!(handle.events.recv());
                    match futures::future::select(received, glib::timeout_future(wait)).await {
                        futures::future::Either::Left((next, _)) => next,
                        futures::future::Either::Right(_) => {
                            painter.paint();
                            continue;
                        }
                    }
                }
                None => handle.events.recv().await,
            };
            let Some(event) = next else {
                break;
            };
            match event {
                ReplyEvent::Text(part) => painter.push(&part),
                ReplyEvent::Finished(end) => {
                    painter.paint();
                    return self.finished(&row, generation, painter.text, &end);
                }
                ReplyEvent::Failed(error) => {
                    painter.paint();
                    return self.failed(&row, generation, &super::reply_error_text(&error));
                }
            }
        }
        painter.paint();
        self.stopped(&row, generation, painter.text);
    }

    fn finished(&self, row: &TurnRow, generation: u64, text: String, end: &ReplyEnd) {
        if !self.end_reply(generation) {
            return;
        }
        if let Some(conversation) = self.imp().conversation.borrow_mut().as_mut() {
            conversation.answer(text);
        }
        clear(&row.footer);
        let note = match end.stop {
            StopReason::Complete => None,
            StopReason::LengthLimit => Some(crate::i18n::gettext("The reply reached its length limit.")),
            StopReason::Refused => Some(crate::i18n::gettext("The model declined to answer.")),
        };
        let usage = end.usage.total().map(|tokens| {
            crate::i18n::ngettext_f(
                "{n} token",
                "{n} tokens",
                crate::ui::format::plural_count(tokens),
                &[("n", &crate::ui::format::format_thousands(tokens))],
            )
        });
        let line = [note, usage].into_iter().flatten().collect::<Vec<_>>().join(" ");
        if !line.is_empty() {
            row.footer.append(&dim_caption(&line));
        }
        crate::ui::a11y::announce(
            self,
            &crate::i18n::gettext("The assistant answered."),
            gtk::AccessibleAnnouncementPriority::Medium,
        );
    }

    fn stopped(&self, row: &TurnRow, generation: u64, text: String) {
        if !self.end_reply(generation) {
            return;
        }
        if let Some(conversation) = self.imp().conversation.borrow_mut().as_mut()
            && !text.is_empty()
        {
            conversation.answer(text);
        }
        clear(&row.footer);
        row.footer.append(&dim_caption(&crate::i18n::gettext("Stopped.")));
    }

    fn failed(&self, row: &TurnRow, generation: u64, message: &str) {
        if !self.end_reply(generation) {
            return;
        }
        clear(&row.footer);
        let label = gtk::Label::builder()
            .label(message)
            .wrap(true)
            .xalign(0.0)
            .hexpand(true)
            .selectable(true)
            .build();
        label.add_css_class("error");
        let retry = gtk::Button::with_label(&crate::i18n::gettext("Retry"));
        retry.set_valign(gtk::Align::Start);
        let pane = self.downgrade();
        let failed = row.downgrade();
        retry.connect_clicked(move |_| {
            if let (Some(pane), Some(row)) = (pane.upgrade(), failed.upgrade()) {
                pane.retry(row);
            }
        });
        row.footer.append(&label);
        row.footer.append(&retry);
        self.imp().retry.replace(Some(retry));
        crate::ui::a11y::announce(self, message, gtk::AccessibleAnnouncementPriority::High);
    }

    /// Ask again for the last turn's reply, which failed, after the
    /// same check a new question goes through.
    fn retry(&self, row: TurnRow) {
        let Some(hooks) = self.hooks() else {
            return;
        };
        let imp = self.imp();
        let last = imp
            .rows
            .borrow()
            .last()
            .is_some_and(|last| Rc::ptr_eq(&last.reply, &row.reply));
        if !last || imp.busy.replace(true) {
            return;
        }
        drop_retry(&imp.retry);
        clear(&row.footer);
        row.reply.set_markdown("");
        self.sync_controls();
        let generation = imp.generation.get();
        let pane = self.downgrade();
        let work = glib::spawn_future_local(async move {
            let Some(parent) = pane.upgrade().map(|pane| pane.upcast::<gtk::Widget>()) else {
                return;
            };
            let allowed = hooks.access.permit(&parent).await;
            drop(parent);
            let Some(pane) = pane.upgrade() else {
                return;
            };
            if pane.imp().generation.get() != generation {
                return;
            }
            if !allowed {
                pane.failed(
                    &row,
                    generation,
                    &crate::i18n::gettext("The assistant may not send from this connection now."),
                );
                pane.refresh();
                return;
            }
            let Some(request) = pane
                .imp()
                .conversation
                .borrow()
                .as_ref()
                .map(|conversation| conversation.request(ChatRequest::CHAT_MAX_TOKENS))
            else {
                return;
            };
            pane.reply(&hooks, request, row, generation).await;
        });
        imp.work.replace(Some(work));
    }

    /// Whether the reply that ended belongs to the conversation on
    /// screen; the pane is free for the next question either way.
    fn end_reply(&self, generation: u64) -> bool {
        let imp = self.imp();
        if imp.generation.get() != generation {
            return false;
        }
        imp.cancel.take();
        imp.work.take();
        imp.busy.set(false);
        self.sync_controls();
        true
    }
}

/// Lays out a streaming reply at most every `PAINT_EVERY`: each layout
/// reads the whole reply again, so painting every small piece would
/// grow with the square of its length.
struct Painter {
    view: Rc<MessageView>,
    footer: gtk::Box,
    text: String,
    painted: usize,
    last: Option<std::time::Instant>,
}

const PAINT_EVERY: std::time::Duration = std::time::Duration::from_millis(80);

impl Painter {
    fn new(row: &TurnRow) -> Self {
        Self {
            view: row.reply.clone(),
            footer: row.footer.clone(),
            text: String::new(),
            painted: 0,
            last: None,
        }
    }

    fn push(&mut self, part: &str) {
        if self.text.is_empty() {
            clear(&self.footer);
        }
        self.text.push_str(part);
        if self.last.is_none_or(|last| last.elapsed() >= PAINT_EVERY) {
            self.paint();
        }
    }

    /// How long until text not painted yet is, or `None` with none.
    fn due(&self) -> Option<std::time::Duration> {
        (self.text.len() > self.painted).then(|| {
            self.last.map_or(std::time::Duration::ZERO, |last| {
                PAINT_EVERY.saturating_sub(last.elapsed())
            })
        })
    }

    fn paint(&mut self) {
        if self.text.len() == self.painted {
            return;
        }
        self.view.set_markdown(&self.text);
        self.painted = self.text.len();
        self.last = Some(std::time::Instant::now());
    }
}

fn question_card(asked: &Asked, hooks: &BlockHooks) -> (gtk::Box, Option<Rc<CodeBlock>>) {
    let card = gtk::Box::new(gtk::Orientation::Vertical, 6);
    card.add_css_class("card");
    let statement = match asked {
        Asked::Typed(question) => {
            let label = gtk::Label::builder()
                .label(question)
                .wrap(true)
                .wrap_mode(gtk::pango::WrapMode::WordChar)
                .xalign(0.0)
                .selectable(true)
                .margin_top(10)
                .margin_bottom(10)
                .margin_start(12)
                .margin_end(12)
                .build();
            card.append(&label);
            None
        }
        Asked::Action { action, statement, .. } => {
            let title = gtk::Label::builder()
                .label(super::action_title(*action))
                .xalign(0.0)
                .margin_top(10)
                .margin_start(12)
                .margin_end(12)
                .build();
            title.add_css_class("heading");
            card.append(&title);
            // Shown as written: through Markdown, a fence inside the
            // statement would cut it into pieces.
            let code = Rc::new(CodeBlock::new(statement, Some("sql"), hooks));
            code.widget().set_margin_start(6);
            code.widget().set_margin_end(6);
            code.widget().set_margin_bottom(6);
            card.append(code.widget());
            Some(code)
        }
    };
    (card, statement)
}

fn drop_retry(retry: &RefCell<Option<gtk::Button>>) {
    if let Some(button) = retry.take()
        && let Some(footer) = button.parent().and_downcast::<gtk::Box>()
    {
        footer.remove(&button);
    }
}

fn show_waiting(footer: &gtk::Box) {
    clear(footer);
    let spinner = adw::Spinner::new();
    footer.append(&spinner);
    footer.append(&dim_caption(&crate::i18n::gettext("Thinking…")));
}

fn dim_caption(text: &str) -> gtk::Label {
    let label = gtk::Label::builder().label(text).wrap(true).xalign(0.0).build();
    label.add_css_class("caption");
    label.add_css_class("dim-label");
    label
}

fn clear(footer: &gtk::Box) {
    while let Some(child) = footer.first_child() {
        footer.remove(&child);
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::time::Duration;

    use tablepro_core::{AiPolicy, AiProvider};

    use super::super::fake_provider::{Provider, serve};
    use super::*;
    use crate::services::active_session::ActiveSession;
    use crate::services::ai_service::AiService;
    use crate::test_support::{MemorySettings, OwnedWindow, descendants, test_runtime, wait_until};

    const WAIT: Duration = Duration::from_secs(10);

    const REPLY: &str = concat!(
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"There are \"}}]}\n\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"**42** orders.\"},\"finish_reason\":\"stop\"}]}\n\n",
        "data: [DONE]\n\n",
    );

    struct Harness {
        pane: AssistantPane,
        window: OwnedWindow<adw::Window>,
        inserted: Rc<RefCell<Option<String>>>,
        _settings: MemorySettings,
        _runtime: crate::runtime::AppRuntime,
    }

    fn pane(provider: &Provider, runtime: crate::runtime::AppRuntime, policy: Rc<Cell<AiPolicy>>) -> Harness {
        crate::register_test_resources();
        let settings = MemorySettings::new();
        settings
            .get()
            .set_ai_provider(Some(AiProvider::OpenAiCompatible))
            .expect("the provider");
        settings
            .get()
            .set_ai_compatible_url(&format!("http://127.0.0.1:{}/v1", provider.port))
            .expect("the address");
        settings
            .get()
            .set_ai_model(AiProvider::OpenAiCompatible, "llama3.2")
            .expect("the model");
        let service = AiService::new(settings.get().clone(), runtime.tasks(), None);
        let access = AssistantAccess::new(service, ActiveSession::new(), "SQLite".to_owned(), move || policy.get());
        let inserted = Rc::new(RefCell::new(None));
        let kept = inserted.clone();
        let pane: AssistantPane = glib::Object::new();
        pane.bind(PaneHooks {
            access,
            editor_text: Rc::new(|| Some("SELECT count(*) FROM orders;".to_owned())),
            insert: Rc::new(move |code| {
                kept.replace(Some(code));
            }),
            toast: Rc::new(|_| {}),
        });
        let window = OwnedWindow::presented(
            adw::Window::builder()
                .default_width(420)
                .default_height(700)
                .content(&pane)
                .build(),
        );
        Harness {
            pane,
            window,
            inserted,
            _settings: settings,
            _runtime: runtime,
        }
    }

    fn texts(pane: &AssistantPane) -> Vec<String> {
        descendants(pane)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
            .map(|label| label.text().to_string())
            .collect()
    }

    #[gtk4::test]
    fn a_question_streams_its_reply_with_the_editors_sql_in_the_prompt() {
        let runtime = test_runtime();
        let provider = serve(&runtime, REPLY);
        let harness = pane(&provider, runtime, Rc::new(Cell::new(AiPolicy::Allow)));
        let imp = harness.pane.imp();
        assert_eq!(imp.stack.visible_child_name().as_deref(), Some("chat"));

        imp.composer.buffer().set_text("How many orders are there?");
        imp.send_button.emit_clicked();

        wait_until(WAIT, || {
            texts(&harness.pane).iter().any(|text| text == "There are 42 orders.")
        })
        .expect("the reply");
        let bodies = provider.bodies.lock().expect("the bodies").clone();
        assert_eq!(bodies.len(), 1);
        let body: serde_json::Value = serde_json::from_str(&bodies[0]).expect("a JSON body");
        assert_eq!(body["model"], "llama3.2");
        let system = body["messages"][0]["content"].as_str().unwrap_or_default();
        assert!(system.contains("SELECT count(*) FROM orders;"), "{system}");
        assert_eq!(body["messages"][1]["content"], "How many orders are there?");
        assert_eq!(harness.pane.composer_text(), "", "the question left the composer");
        wait_until(WAIT, || imp.send_stack.visible_child_name().as_deref() == Some("send")).expect("ready again");
    }

    #[gtk4::test]
    fn never_shows_why_and_sends_nothing() {
        let runtime = test_runtime();
        let provider = serve(&runtime, REPLY);
        let harness = pane(&provider, runtime, Rc::new(Cell::new(AiPolicy::Never)));
        let imp = harness.pane.imp();

        imp.composer.buffer().set_text("anything");
        harness.pane.send_typed();
        crate::test_support::drain_main_context();

        assert_eq!(imp.stack.visible_child_name().as_deref(), Some("blocked"));
        assert!(!imp.toolbar.reveals_bottom_bars(), "the composer stays hidden");
        assert!(provider.bodies.lock().expect("the bodies").is_empty());
    }

    #[gtk4::test]
    fn a_fix_starts_a_new_conversation_with_the_error_and_its_code_inserts() {
        let runtime = test_runtime();
        let provider = serve(
            &runtime,
            concat!(
                "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Use:\\n\\n```sql\\nSELECT 1;\\n```\"},\"finish_reason\":\"stop\"}]}\n\n",
                "data: [DONE]\n\n",
            ),
        );
        let harness = pane(&provider, runtime, Rc::new(Cell::new(AiPolicy::Allow)));

        harness.pane.run_action(AssistantRequest {
            action: tablepro_ai::Action::Fix,
            statement: "SELEC 1".to_owned(),
            error: Some("syntax error at or near \"SELEC\"".to_owned()),
        });
        wait_until(WAIT, || !provider.bodies.lock().expect("the bodies").is_empty()).expect("the request");
        // The question's statement has an Insert of its own; the reply's
        // comes after it.
        let inserts = || {
            descendants(&harness.pane)
                .into_iter()
                .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
                .filter(|button| button.label().as_deref() == Some("Insert"))
                .collect::<Vec<_>>()
        };
        wait_until(WAIT, || inserts().len() == 2).expect("the reply's code block");
        inserts()[1].emit_clicked();

        let body: serde_json::Value =
            serde_json::from_str(&provider.bodies.lock().expect("the bodies")[0]).expect("a JSON body");
        let question = body["messages"][1]["content"].as_str().unwrap_or_default();
        assert!(
            question.contains("SELEC 1") && question.contains("syntax error"),
            "{question}"
        );
        assert!(texts(&harness.pane).iter().any(|text| text == "Fix the Statement"));
        assert_eq!(harness.inserted.borrow().as_deref(), Some("SELECT 1;"));
        drop(harness.window);
    }
}
