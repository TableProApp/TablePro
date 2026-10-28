use std::cell::{Cell, OnceCell, RefCell};
use std::rc::Rc;
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_core::DataModel;
use tablepro_session::SessionKey;

use super::WorkspaceModel;
use super::tab_index::TabIndex;
use crate::ui::assistant::AssistantPane;

#[derive(Default, gtk::CompositeTemplate, glib::Properties)]
#[properties(wrapper_type = super::Workspace)]
#[template(resource = "/app/tablepro/TablePro/ui/workspace.ui")]
pub struct Workspace {
    #[template_child]
    pub reconnect_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub transaction_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub layout_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub list_banners: TemplateChild<gtk::Box>,
    #[template_child]
    pub catalog_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub key_limit_banner: TemplateChild<adw::Banner>,

    /// The content header's title while the session is in front: the
    /// tab it was left on, or the connection. The shell reads these
    /// properties, never the model.
    #[property(get)]
    pub(super) title: RefCell<String>,
    #[property(get)]
    pub(super) subtitle: RefCell<String>,
    /// The window's title in the window list and Alt+Tab.
    #[property(get)]
    pub(super) window_title: RefCell<String>,
    /// The saved connection's icon, beside the title.
    #[property(get)]
    pub(super) icon_name: RefCell<Option<String>>,
    #[property(get)]
    pub(super) connection_name: RefCell<String>,
    /// The session is parked on a host key the user can review.
    #[property(get)]
    pub(super) can_review_host_key: Cell<bool>,
    /// A provider is chosen, so the assistant's column and toggle show.
    #[property(get)]
    pub(super) assistant_available: Cell<bool>,

    pub(super) key: OnceCell<SessionKey>,
    pub(super) data_model: OnceCell<DataModel>,
    /// Which tab each of the session's pages shows, shared with the
    /// model, so the shell can tell whose a page is while the model is
    /// busy with its input.
    pub(super) index: OnceCell<Rc<TabIndex>>,
    /// The session's own conversation with the assistant.
    pub(super) assistant_pane: OnceCell<AssistantPane>,
    /// What the window was last told closing would lose.
    pub(super) dirty: Cell<bool>,
    pub(super) saving: Cell<bool>,
    /// The window's shell, which holds this workspace and its tabs.
    pub(super) shell: glib::WeakRef<super::WorkspaceShell>,
    pub(super) sender: OnceCell<super::WorkspaceSender>,
    pub(super) model: RefCell<Option<WorkspaceModel>>,
    /// Handles the queued input, and with it every reply the workspace
    /// is still waiting on. Aborted at shutdown, which drops them.
    pub(super) pump: RefCell<Option<glib::JoinHandle<()>>>,
}

#[glib::object_subclass]
impl ObjectSubclass for Workspace {
    const NAME: &'static str = "TableProWorkspace";
    type Type = super::Workspace;
    type ParentType = adw::Bin;

    fn class_init(klass: &mut Self::Class) {
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

#[glib::derived_properties]
impl ObjectImpl for Workspace {
    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| {
            vec![
                Signal::builder("dirty-changed")
                    .param_types([bool::static_type()])
                    .build(),
                Signal::builder("saves-in-flight-changed")
                    .param_types([u32::static_type()])
                    .build(),
                Signal::builder("work-completed")
                    .param_types([glib::BoxedAnyObject::static_type()])
                    .build(),
                Signal::builder("tabs-changed").build(),
            ]
        })
    }

    /// A workspace dropped without a teardown still stops its reads and
    /// lets go of its tabs.
    fn dispose(&self) {
        self.obj().shutdown(false);
    }
}

impl WidgetImpl for Workspace {}
impl BinImpl for Workspace {}
