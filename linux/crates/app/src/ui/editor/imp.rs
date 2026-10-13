use std::cell::{Cell, OnceCell, RefCell};
use std::sync::{Arc, OnceLock};

use glib::subclass::Signal;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tokio_util::sync::CancellationToken;

use super::EditorDeps;
use super::editor_session_slot::EditorSessionSlot;
use super::results_pane::ResultsPane;
use super::run_log::RunLog;
use crate::ui::grid::GridMsg;
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
    pub source_view: TemplateChild<sourceview5::View>,
    #[template_child]
    pub results: TemplateChild<ResultsPane>,

    pub(super) deps: OnceCell<EditorDeps>,
    /// This tab's own connection, which keeps its transaction and
    /// temporary tables between runs.
    pub slot: Arc<EditorSessionSlot>,
    pub running: RefCell<Option<RunningScript>>,
    pub log: RefCell<Option<RunLog>>,
    pub grid_sender: OnceCell<relm4::Sender<GridMsg>>,
    /// Whether the last run left a transaction open, as last reported.
    pub transaction_dirty: Cell<bool>,
    pub shut_down: Cell<bool>,
    /// Theme and font handlers on the app-wide style manager and
    /// settings, which would otherwise outlive the tab.
    pub(super) app_handlers: RefCell<Vec<HandlerGuard>>,
}

#[glib::object_subclass]
impl ObjectSubclass for SqlEditor {
    const NAME: &'static str = "TableProSqlEditor";
    type Type = super::SqlEditor;
    type ParentType = adw::Bin;

    fn class_init(klass: &mut Self::Class) {
        sourceview5::View::ensure_type();
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
                // No text: the buffer can be megabytes, and a listener
                // reads only what it needs from it.
                Signal::builder("content-changed").build(),
                Signal::builder("copy-to-clipboard")
                    .param_types([String::static_type()])
                    .build(),
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
            ]
        })
    }

    fn dispose(&self) {
        self.obj().shutdown();
        self.app_handlers.take();
    }
}

impl WidgetImpl for SqlEditor {}
impl BinImpl for SqlEditor {}
