use std::cell::RefCell;
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::WorkspaceModel;

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/workspace.ui")]
pub struct Workspace {
    #[template_child]
    pub catalog_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub key_limit_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub reconnect_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub transaction_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub layout_banner: TemplateChild<adw::Banner>,

    /// The window's shell, which holds this workspace and its tabs.
    pub(super) shell: glib::WeakRef<super::WorkspaceShell>,
    pub(super) sender: std::cell::OnceCell<super::WorkspaceSender>,
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
                Signal::builder("title-changed")
                    .param_types([String::static_type()])
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
