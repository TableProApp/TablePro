use std::cell::{Cell, RefCell};

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, gio, glib};
use libadwaita as adw;
use libadwaita::subclass::prelude::*;

use super::Shown;
use super::value_editor::{Loaded, OpenEdit, Placeholders};
use crate::ui::data_grid::{DataGrid, PinnedRow};
use crate::ui::handler_guard::HandlerGuard;

/// The fields the list shows, each a data column's index, made with the
/// pane since a list store has no default item type.
#[derive(Debug)]
pub struct Fields(pub gio::ListStore);

impl Default for Fields {
    fn default() -> Self {
        Self(gio::ListStore::new::<glib::BoxedAnyObject>())
    }
}

#[derive(Default, gtk::CompositeTemplate)]
#[template(resource = "/app/tablepro/TablePro/ui/row-detail-pane.ui")]
pub struct RowDetailPane {
    #[template_child]
    pub stack: TemplateChild<gtk::Stack>,
    #[template_child]
    pub title_label: TemplateChild<gtk::Label>,
    #[template_child]
    pub state_box: TemplateChild<gtk::Box>,
    #[template_child]
    pub state_icon: TemplateChild<gtk::Image>,
    #[template_child]
    pub state_label: TemplateChild<gtk::Label>,
    #[template_child]
    pub close_button: TemplateChild<gtk::Button>,
    #[template_child]
    pub field_list: TemplateChild<gtk::ListView>,
    #[template_child]
    pub field_label: TemplateChild<gtk::Label>,
    #[template_child]
    pub calendar_button: TemplateChild<gtk::MenuButton>,
    #[template_child]
    pub calendar_popover: TemplateChild<gtk::Popover>,
    #[template_child]
    pub calendar: TemplateChild<gtk::Calendar>,
    #[template_child]
    pub value_menu_button: TemplateChild<gtk::MenuButton>,
    #[template_child]
    pub value_view: TemplateChild<sourceview5::View>,
    #[template_child]
    pub value_buffer: TemplateChild<sourceview5::Buffer>,
    #[template_child]
    pub placeholder_label: TemplateChild<gtk::Label>,
    #[template_child]
    pub message_label: TemplateChild<gtk::Label>,

    pub grid: glib::WeakRef<DataGrid>,
    pub fields: Fields,
    pub selection: gtk::SingleSelection,
    /// The row the pane shows, while it has one.
    pub shown: RefCell<Option<Shown>>,
    /// The data column of the selected field.
    pub field: Cell<Option<usize>>,
    /// What the value editor holds, so a focus move that changes nothing
    /// does not write the buffer again.
    pub loaded: RefCell<Option<Loaded>>,
    pub placeholders: RefCell<Placeholders>,
    pub edit: RefCell<Option<OpenEdit>>,
    /// Set while the pane writes the buffer itself, which is no edit.
    pub loading: Cell<bool>,
    /// Set while the pane selects a field itself, which moves no focus.
    pub syncing: Cell<bool>,
    /// An input method holds a preedit in the value editor.
    pub composing: Cell<bool>,
    pub commit_when_composed: Cell<bool>,
    /// Set while the pane puts the calendar on a day, which is no pick.
    pub quiet_calendar: Cell<bool>,
    /// The row and field the open calendar picks a day for.
    pub calendar_target: RefCell<Option<(PinnedRow, usize)>>,
    pub sync_queued: Cell<bool>,
    /// The field rows bound now, which redraw when the row changes.
    pub bound: RefCell<Vec<gtk::ListItem>>,
    pub column_watches: RefCell<Vec<(glib::WeakRef<gtk::ColumnViewColumn>, glib::SignalHandlerId)>>,
    pub(super) guards: RefCell<Vec<HandlerGuard>>,
}

#[glib::object_subclass]
impl ObjectSubclass for RowDetailPane {
    const NAME: &'static str = "TableProRowDetailPane";
    type Type = super::RowDetailPane;
    type ParentType = adw::Bin;

    fn class_init(klass: &mut Self::Class) {
        sourceview5::View::ensure_type();
        sourceview5::Buffer::ensure_type();
        klass.bind_template();
    }

    fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
        object.init_template();
    }
}

impl ObjectImpl for RowDetailPane {
    fn dispose(&self) {
        self.guards.take();
        self.obj().stop_watching_columns();
        self.obj().watch_row(None);
        self.bound.take();
    }
}

impl WidgetImpl for RowDetailPane {}
impl BinImpl for RowDetailPane {}
