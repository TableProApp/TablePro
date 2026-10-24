use std::cell::{Cell, OnceCell, RefCell};
use std::sync::{Arc, OnceLock};

use glib::subclass::Signal;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tokio_util::sync::CancellationToken;

use super::EditorDeps;
use super::editor_session_slot::EditorSessionSlot;
use super::editor_view::EditorView;
use super::find_bar::FindBar;
use super::results_pane::ResultsPane;
use super::run_log::RunLog;
use super::transaction_dirty::OpenTransaction;
use super::vim_mode::VimMode;
use crate::ui::grid::GridSink;
use crate::ui::handler_guard::HandlerGuard;

/// A run in flight: its cancel switch, and the loop that brings its
/// results to the GTK thread.
pub struct RunningScript {
    pub cancel: CancellationToken,
    pub drain: glib::JoinHandle<()>,
}

#[derive(Default, gtk4::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/sql-editor.ui")]
pub struct SqlEditor {
    #[template_child]
    pub cursor_info: TemplateChild<gtk4::Label>,
    #[template_child]
    pub menu_button: TemplateChild<gtk4::MenuButton>,
    #[template_child]
    pub stop_button: TemplateChild<gtk4::Button>,
    #[template_child]
    pub run_button: TemplateChild<gtk4::Button>,
    #[template_child]
    pub find_bar: TemplateChild<FindBar>,
    #[template_child]
    pub source_view: TemplateChild<EditorView>,
    #[template_child]
    pub text_pane: TemplateChild<adw::ToolbarView>,
    #[template_child]
    pub vim_command_bar: TemplateChild<gtk4::Label>,
    #[template_child]
    pub vim_command: TemplateChild<gtk4::Label>,
    #[template_child]
    pub results: TemplateChild<ResultsPane>,
    #[template_child]
    pub assistant_menu: TemplateChild<gio::MenuModel>,

    pub(super) deps: OnceCell<EditorDeps>,
    /// This tab's own connection, which keeps its transaction and
    /// temporary tables between runs.
    pub slot: Arc<EditorSessionSlot>,
    pub running: RefCell<Option<RunningScript>>,
    pub log: RefCell<Option<RunLog>>,
    pub grid_sink: OnceCell<GridSink>,
    /// Whether the last run left a transaction open, as last reported.
    pub transaction_dirty: Cell<bool>,
    pub open_transaction: Cell<Option<OpenTransaction>>,
    /// Whether the run in flight, or the last one, can change what the
    /// catalog lists.
    pub changes_catalog: Cell<bool>,
    pub shut_down: Cell<bool>,
    /// Safe Mode is asking about the run, which has not started.
    pub confirming: Cell<bool>,
    /// The file the text was opened from or last saved to.
    pub file: RefCell<Option<gio::File>>,
    pub saving: Cell<bool>,
    /// Counts every change to the buffer, so a save knows whether the
    /// text it wrote is still what the tab holds.
    pub edits: Cell<u64>,
    /// Theme and font handlers on the app-wide style manager and
    /// settings, which would otherwise outlive the tab.
    pub(super) app_handlers: RefCell<Vec<HandlerGuard>>,
    pub(super) completion_providers: RefCell<Vec<sourceview5::CompletionProvider>>,
    /// The tab's `editor` group, kept to read what it offers.
    pub(super) actions: OnceCell<gtk4::gio::SimpleActionGroup>,
    pub(super) vim: RefCell<Option<VimMode>>,
    /// The window's assistant, once the workspace attached it.
    pub(super) assistant: RefCell<Option<std::rc::Rc<crate::ui::assistant::AssistantAccess>>>,
    pub(super) suggestion: RefCell<super::inline_suggestion::SuggestionState>,
    /// The Escape being handled found a popup of the view's open. The
    /// completion list closes itself on Escape before the editor's keys
    /// run, and lets the key go on.
    pub(super) escape_found_popup: Cell<bool>,
}

#[glib::object_subclass]
impl ObjectSubclass for SqlEditor {
    const NAME: &'static str = "TableProSqlEditor";
    type Type = super::SqlEditor;
    type ParentType = adw::Bin;

    fn class_init(klass: &mut Self::Class) {
        EditorView::ensure_type();
        FindBar::ensure_type();
        ResultsPane::ensure_type();
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for SqlEditor {
    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| {
            vec![
                Signal::builder("run-state-changed")
                    .param_types([bool::static_type()])
                    .build(),
                Signal::builder("run-finished")
                    .param_types([crate::workspace::WorkOutcome::static_type()])
                    .build(),
                // No text: the buffer can be megabytes, and a listener
                // reads only what it needs from it.
                Signal::builder("content-changed").build(),
                Signal::builder("toast").param_types([String::static_type()]).build(),
                Signal::builder("undoable-toast")
                    .param_types([String::static_type()])
                    .build(),
                Signal::builder("export-results")
                    .param_types([glib::BoxedAnyObject::static_type()])
                    .build(),
                Signal::builder("transaction-changed")
                    .param_types([bool::static_type()])
                    .build(),
                Signal::builder("file-changed").build(),
                // Vim's :q, which closes the tab through its close prompts.
                Signal::builder("close-requested").build(),
                Signal::builder("assistant-requested")
                    .param_types([glib::BoxedAnyObject::static_type()])
                    .build(),
            ]
        })
    }

    fn dispose(&self) {
        self.obj().dismiss_suggestion();
        self.obj().shutdown();
        self.app_handlers.take();
        self.obj().detach_vim();
        self.obj().release_view();
    }
}

impl WidgetImpl for SqlEditor {}
impl BinImpl for SqlEditor {}
