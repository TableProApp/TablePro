use std::cell::RefCell;
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_session::runtime::WatchForwarder;

use super::canvas::DiagramCanvas;
use super::tab::DiagramModel;
use crate::ui::a11y::describe_icon_button;

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/diagram-tab.ui")]
pub struct DiagramTab {
    #[template_child]
    pub stale_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub outdated_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub inner_stack: TemplateChild<gtk::Stack>,
    #[template_child]
    pub loading_page: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub loading_progress: TemplateChild<gtk::ProgressBar>,
    #[template_child]
    pub loading_stop_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub scroller: TemplateChild<gtk::ScrolledWindow>,
    #[template_child]
    pub canvas: TemplateChild<DiagramCanvas>,
    #[template_child]
    pub error_page: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub zoom_out_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub zoom_reset_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub zoom_in_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub zoom_fit_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub refresh_box: TemplateChild<gtk::Box>,
    #[template_child]
    pub refresh_label: TemplateChild<gtk::Label>,
    #[template_child]
    pub more_button: TemplateChild<gtk::MenuButton>,
    #[template_child]
    pub refresh_button: TemplateChild<gtk::Button>,

    pub(super) model: RefCell<Option<DiagramModel>>,
    /// The tab's `diagram` actions, turned on and off as what is on
    /// screen changes.
    pub(super) actions: RefCell<Option<gtk::gio::SimpleActionGroup>>,
    /// Delivers each reconnect, for as long as the tab is open.
    pub(super) link_watch: RefCell<Option<WatchForwarder>>,
    /// Delivers the running read's progress.
    pub(super) progress_watch: RefCell<Option<WatchForwarder>>,
}

#[glib::object_subclass]
impl ObjectSubclass for DiagramTab {
    const NAME: &'static str = "TableProDiagramTab";
    type Type = super::DiagramTab;
    type ParentType = adw::Bin;

    fn class_init(klass: &mut Self::Class) {
        DiagramCanvas::ensure_type();
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for DiagramTab {
    fn constructed(&self) {
        self.parent_constructed();
        let gettext = crate::i18n::gettext;
        describe_icon_button(
            &self.zoom_out_button.get(),
            &gettext("Zoom Out"),
            Some("diagram.zoom-out"),
        );
        describe_icon_button(&self.zoom_in_button.get(), &gettext("Zoom In"), Some("diagram.zoom-in"));
        describe_icon_button(
            &self.zoom_fit_button.get(),
            &gettext("Best Fit"),
            Some("diagram.zoom-fit"),
        );
        let reset = self.zoom_reset_button.get();
        reset.set_tooltip_text(Some(&gettext("Reset Zoom")));
        reset.update_property(&[gtk::accessible::Property::Description(&gettext("Reset Zoom"))]);
        crate::ui::a11y::announce_key_shortcuts(&reset, "diagram.zoom-reset");
        self.obj().label_refresh_button(false);
    }

    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| {
            vec![
                Signal::builder("open-table")
                    .param_types([String::static_type(), String::static_type()])
                    .build(),
                Signal::builder("show-structure")
                    .param_types([String::static_type(), String::static_type()])
                    .build(),
                Signal::builder("layout-changed").build(),
                Signal::builder("loading-changed")
                    .param_types([bool::static_type()])
                    .build(),
            ]
        })
    }

    fn dispose(&self) {
        self.link_watch.take();
        self.progress_watch.take();
        if let Ok(mut model) = self.model.try_borrow_mut()
            && let Some(mut model) = model.take()
        {
            model.sequencer.cancel_all();
        }
    }
}

impl WidgetImpl for DiagramTab {}
impl BinImpl for DiagramTab {}
