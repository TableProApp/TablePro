use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::gdk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::subclass::prelude::*;
use tablepro_session::runtime::WatchForwarder;

use super::{BrowseModel, BrowseTabInput};

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/browse-tab.ui")]
pub struct BrowseTab {
    #[template_child]
    pub toolbar: TemplateChild<adw::ToolbarView>,
    #[template_child]
    pub read_only_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub no_pk_banner: TemplateChild<adw::Banner>,
    #[template_child]
    pub inner_stack: TemplateChild<gtk::Stack>,
    #[template_child]
    pub loading_page: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub grid_holder: TemplateChild<gtk::Box>,
    #[template_child]
    pub error_page: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub insert_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub delete_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub first_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub prev_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub next_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub last_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub paginator_label: TemplateChild<gtk::Label>,
    #[template_child]
    pub selection_label: TemplateChild<gtk::Label>,
    #[template_child]
    pub export_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub filter_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub filter_badge: TemplateChild<gtk::Label>,
    #[template_child]
    pub page_size_dropdown: TemplateChild<gtk::DropDown>,
    #[template_child]
    pub pending_revealer: TemplateChild<gtk::Revealer>,
    #[template_child]
    pub pending_label: TemplateChild<gtk::Label>,
    #[template_child]
    pub discard_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub save_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub saving_spinner: TemplateChild<adw::Spinner>,
    #[template_child]
    pub stop_button: TemplateChild<gtk::Button>,

    pub(super) model: RefCell<Option<BrowseModel>>,
    pub(super) queue: RefCell<VecDeque<BrowseTabInput>>,
    pub(super) dispatching: Cell<bool>,
    /// Delivers each reconnect, for as long as the tab is open.
    pub(super) link_watch: RefCell<Option<WatchForwarder>>,
}

#[glib::object_subclass]
impl ObjectSubclass for BrowseTab {
    const NAME: &'static str = "TableProBrowseTab";
    type Type = super::BrowseTab;
    type ParentType = adw::Bin;

    fn class_init(klass: &mut Self::Class) {
        klass.bind_template();
        install_bindings(klass);
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

/// The grid's keyboard model. The bindings act only while the focus is
/// inside this tab, so the editor and the other tabs keep their own.
fn install_bindings(klass: &mut <BrowseTab as ObjectSubclass>::Class) {
    let none = gdk::ModifierType::empty();
    let ctrl = gdk::ModifierType::CONTROL_MASK;
    let send = |input: fn() -> BrowseTabInput, propagation: glib::Propagation| {
        move |tab: &super::BrowseTab| {
            tab.send(input());
            propagation
        }
    };
    // Esc clears a multi-row selection and lets the key go on, so a
    // search bar or dialog above still closes on it.
    klass.add_binding(
        gdk::Key::Escape,
        none,
        send(|| BrowseTabInput::ClearSelection, glib::Propagation::Proceed),
    );
    klass.add_binding(
        gdk::Key::n,
        ctrl,
        send(|| BrowseTabInput::InsertRow, glib::Propagation::Stop),
    );
    // Ctrl+Shift+N is the application's New Window. An open cell editor
    // takes Ctrl+Backspace as delete-word first, so this sees it only on
    // a focused cell.
    klass.add_binding(gdk::Key::BackSpace, ctrl, |tab| tab.set_focused_cell_null());
    // A cell editor's text field consumes Ctrl+C and Ctrl+V first, so
    // these only see the grid's own copy and paste.
    klass.add_binding(
        gdk::Key::c,
        ctrl,
        send(|| BrowseTabInput::CopySelectedRowsAsTsv, glib::Propagation::Stop),
    );
    klass.add_binding(
        gdk::Key::v,
        ctrl,
        send(|| BrowseTabInput::PasteNotSupported, glib::Propagation::Stop),
    );
    klass.add_binding(
        gdk::Key::a,
        ctrl,
        send(|| BrowseTabInput::SelectAllRows, glib::Propagation::Stop),
    );
    // Paging is by offset, so scrolling stops at the page edge; Page Up
    // and Page Down move between pages instead.
    klass.add_binding(
        gdk::Key::Page_Up,
        none,
        send(|| BrowseTabInput::PrevPage, glib::Propagation::Stop),
    );
    klass.add_binding(
        gdk::Key::Page_Down,
        none,
        send(|| BrowseTabInput::NextPage, glib::Propagation::Stop),
    );
    klass.add_binding(
        gdk::Key::Home,
        ctrl,
        send(|| BrowseTabInput::GoToFirstRow, glib::Propagation::Stop),
    );
    klass.add_binding(
        gdk::Key::End,
        ctrl,
        send(|| BrowseTabInput::GoToLastRow, glib::Propagation::Stop),
    );
}

impl ObjectImpl for BrowseTab {
    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| {
            vec![
                Signal::builder("state-changed").build(),
                // Boxed: a GValue string ends at a NUL, and a copied cell
                // can hold one.
                Signal::builder("copy-to-clipboard")
                    .param_types([glib::BoxedAnyObject::static_type()])
                    .build(),
                Signal::builder("export-results")
                    .param_types([glib::BoxedAnyObject::static_type()])
                    .build(),
                Signal::builder("alert")
                    .param_types([String::static_type(), String::static_type()])
                    .build(),
                Signal::builder("toast").param_types([String::static_type()]).build(),
                Signal::builder("dirty-changed")
                    .param_types([bool::static_type()])
                    .build(),
                Signal::builder("save-requested").build(),
                Signal::builder("stop-save-requested").build(),
            ]
        })
    }

    /// A cancelled read lets the server drop its statement rather than
    /// finish it for nobody.
    fn dispose(&self) {
        self.link_watch.take();
        if let Ok(mut model) = self.model.try_borrow_mut()
            && let Some(mut model) = model.take()
        {
            model.sequencer.cancel_all();
        }
    }
}

impl WidgetImpl for BrowseTab {}
impl BinImpl for BrowseTab {}
