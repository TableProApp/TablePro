use std::cell::{Cell, OnceCell, RefCell};
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::columns::ColumnSet;
use super::edit::EditController;
use super::find_bar::FindState;
use super::grid_menu::GridMenus;
use super::references::Armed;
use super::row_detail::RowDetailPane;
use super::selection::Target;
use super::{GridConfig, GridStore};

/// The grid's selection model, made with the grid and given its rows once
/// the grid knows how it sorts.
#[derive(Debug)]
pub struct Selection(pub gtk4::MultiSelection);

impl Default for Selection {
    fn default() -> Self {
        Self(gtk4::MultiSelection::new(None::<gio::ListModel>))
    }
}

#[derive(Default, gtk4::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/data-grid.ui")]
pub struct DataGrid {
    #[template_child]
    pub split_view: TemplateChild<adw::OverlaySplitView>,
    #[template_child]
    pub search_bar: TemplateChild<gtk4::SearchBar>,
    #[template_child]
    pub search_entry: TemplateChild<gtk4::SearchEntry>,
    #[template_child]
    pub match_label: TemplateChild<gtk4::Label>,
    #[template_child]
    pub find_previous: TemplateChild<gtk4::Button>,
    #[template_child]
    pub find_next: TemplateChild<gtk4::Button>,
    #[template_child]
    pub scrolled: TemplateChild<gtk4::ScrolledWindow>,
    #[template_child]
    pub column_view: TemplateChild<gtk4::ColumnView>,
    #[template_child]
    pub empty_page: TemplateChild<adw::StatusPage>,
    #[template_child]
    pub detail_pane: TemplateChild<RowDetailPane>,

    pub config: OnceCell<GridConfig>,
    pub store: GridStore,
    pub selection: Selection,
    /// Set for a grid that sorts the rows it holds.
    pub sort_model: OnceCell<gtk4::SortListModel>,
    pub columns: RefCell<ColumnSet>,
    pub actions: gio::SimpleActionGroup,
    pub menus: OnceCell<GridMenus>,
    pub edit: EditController,
    pub find: FindState,
    /// What a menu was opened on, until it closes.
    pub menu_target: RefCell<Option<Target>>,
    /// The key choices the latest menu or chooser offered, which its items
    /// act on whatever the keys or rows are by then.
    pub armed_references: RefCell<Armed>,
    /// Set while the grid puts a sort on the headers itself, which asks
    /// the server for nothing.
    pub quiet_sort: Cell<bool>,
    /// The number the first row read is shown as, less one.
    pub row_base: Cell<u64>,
    /// An inline or pane editor is open.
    pub editing: Cell<bool>,
    /// The window's focus handler, while the grid is in a window.
    pub focus_watch: RefCell<Option<(glib::WeakRef<gtk4::Window>, glib::SignalHandlerId)>>,
}

#[glib::object_subclass]
impl ObjectSubclass for DataGrid {
    const NAME: &'static str = "TableProDataGrid";
    type Type = super::DataGrid;
    type ParentType = adw::Bin;

    fn class_init(klass: &mut Self::Class) {
        RowDetailPane::ensure_type();
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for DataGrid {
    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| {
            vec![
                Signal::builder("request")
                    .param_types([glib::BoxedAnyObject::static_type()])
                    .build(),
                Signal::builder("selection-changed").build(),
                Signal::builder("editing-changed").build(),
            ]
        })
    }

    fn dispose(&self) {
        self.obj().stop_watching_focus();
        if let Some(menus) = self.menus.get() {
            menus.unparent();
        }
        self.columns.borrow_mut().release();
        self.store.clear();
    }
}

impl WidgetImpl for DataGrid {
    fn root(&self) {
        self.parent_root();
        self.obj().watch_focus();
    }

    fn unroot(&self) {
        self.obj().stop_watching_focus();
        self.parent_unroot();
    }
}

impl BinImpl for DataGrid {}
