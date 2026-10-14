use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, gio, glib};
use libadwaita as adw;
use tablepro_core::meta::{ObjectInfo, SchemaInfo, TableRef};

use super::object_key::ObjectKey;
use super::sidebar_affordances::SidebarAffordances;
use super::sidebar_event::SidebarEvent;
use super::sidebar_header_factory::header_factory;
use super::sidebar_menu::{
    CONTEXT_MENU, DROP_TABLE, EDIT_STRUCTURE, GROUP, IMPORT_CSV, NEW_TABLE, OPEN_IN_NEW_TAB, SHOW_CREATE_TABLE,
    object_menu, offers,
};
use super::sidebar_model::SidebarModel;
use super::sidebar_row_factory::row_factory;
use crate::application::{ShortcutOwner, local_shortcut_controller};

const LIST_PAGE: &str = "list";
const EMPTY_PAGE: &str = "empty";

/// The session's tables in one list view that recycles its rows, in a
/// section per schema, with one shared menu.
#[derive(Clone)]
pub(crate) struct SidebarView {
    inner: Rc<SidebarInner>,
}

pub(crate) struct SidebarInner {
    root: gtk::Stack,
    pub(super) list_view: gtk::ListView,
    model: SidebarModel,
    pub(super) popover: gtk::PopoverMenu,
    actions: gio::SimpleActionGroup,
    empty: adw::StatusPage,
    events: Box<dyn Fn(SidebarEvent)>,
    affordances: Cell<SidebarAffordances>,
    header_factory: RefCell<Option<gtk::SignalListItemFactory>>,
    /// The table of the tab in front. Activation on a single click also
    /// selects rows on hover, so the selection returns here.
    active: RefCell<Option<TableRef>>,
    /// The recycled rows, to point the keyboard's menu at one.
    rows: RefCell<Vec<glib::WeakRef<gtk::ListItem>>>,
    handlers: RefCell<Vec<(glib::WeakRef<glib::Object>, glib::SignalHandlerId)>>,
    hover: RefCell<Option<gtk::EventControllerMotion>>,
}

impl SidebarView {
    pub(crate) fn new(events: impl Fn(SidebarEvent) + 'static, affordances: SidebarAffordances) -> Self {
        let model = SidebarModel::new();
        let list_view = gtk::ListView::new(Some(model.selection().clone()), None::<gtk::ListItemFactory>);
        list_view.add_css_class("navigation-sidebar");
        // A click opens the table, as the list always did; Enter and a
        // double click reach the same activate.
        list_view.set_single_click_activate(true);
        list_view.update_property(&[gtk::accessible::Property::Label(&crate::i18n::gettext("Tables"))]);
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&list_view)
            .build();
        let empty = adw::StatusPage::new();
        empty.add_css_class("compact");
        let root = gtk::Stack::new();
        root.add_named(&scroll, Some(LIST_PAGE));
        root.add_named(&empty, Some(EMPTY_PAGE));
        let actions = gio::SimpleActionGroup::new();
        // Before the popover is parented: a popover menu finds its
        // actions through the parent it had when it was set up.
        list_view.insert_action_group(GROUP, Some(&actions));
        let popover = gtk::PopoverMenu::from_model(None::<&gio::MenuModel>);
        popover.set_has_arrow(true);
        popover.set_parent(&list_view);
        let inner = Rc::new(SidebarInner {
            root,
            list_view,
            model,
            popover,
            actions,
            empty,
            events: Box::new(events),
            affordances: Cell::new(affordances),
            header_factory: RefCell::new(None),
            active: RefCell::new(None),
            rows: RefCell::new(Vec::new()),
            handlers: RefCell::new(Vec::new()),
            hover: RefCell::new(None),
        });
        inner.list_view.set_factory(Some(&row_factory(Rc::downgrade(&inner))));
        let headers = header_factory(Rc::downgrade(&inner));
        inner.list_view.set_header_factory(Some(&headers));
        inner.header_factory.replace(Some(headers));
        inner
            .list_view
            .add_controller(local_shortcut_controller(ShortcutOwner::SidebarList));
        install_actions(&inner);
        connect_view(&inner);
        inner.refresh_placeholder();
        Self { inner }
    }

    pub(crate) fn widget(&self) -> &gtk::Stack {
        &self.inner.root
    }

    /// Show a new object list. The selection goes back to the tab in
    /// front's table, which the new list holds as a new object.
    pub(crate) fn apply_objects(&self, objects: &[ObjectInfo], schemas: &[SchemaInfo]) {
        self.inner.model.replace(objects, schemas);
        self.inner.reselect();
    }

    pub(crate) fn set_query(&self, query: &str) {
        self.inner.model.set_query(query);
        self.inner.reselect();
    }

    /// Select the row of the table the tab in front shows, or none for
    /// any other tab: a selected row would say the editor shows it.
    pub(crate) fn sync_selection(&self, table: Option<&TableRef>) {
        self.inner.active.replace(table.cloned());
        self.inner.model.select(table);
    }

    /// A reconnect can reach a server that edits less, so the headers are
    /// bound again with what it offers.
    pub(crate) fn set_affordances(&self, affordances: SidebarAffordances) {
        if self.inner.affordances.replace(affordances) == affordances {
            return;
        }
        if let Some(headers) = self.inner.header_factory.borrow().as_ref() {
            self.inner.list_view.set_header_factory(None::<&gtk::ListItemFactory>);
            self.inner.list_view.set_header_factory(Some(headers));
        }
    }

    /// Filter as the user types in `entry`.
    pub(crate) fn follow_search(&self, entry: &gtk::SearchEntry) {
        let view = Rc::downgrade(&self.inner);
        let handler = entry.connect_search_changed(move |entry| {
            if let Some(view) = view.upgrade() {
                SidebarView { inner: view }.set_query(&entry.text());
            }
        });
        self.inner.remember(entry, handler);
    }

    /// Let go of the menu and the signals, before the widgets go.
    pub(crate) fn shutdown(&self) {
        let inner = &self.inner;
        inner.popover.popdown();
        if inner.popover.parent().is_some() {
            inner.popover.unparent();
        }
        for (object, handler) in inner.handlers.take() {
            if let Some(object) = object.upgrade() {
                object.disconnect(handler);
            }
        }
        if let Some(hover) = inner.hover.take() {
            inner.list_view.remove_controller(&hover);
        }
        inner.list_view.insert_action_group(GROUP, None::<&gio::ActionGroup>);
        inner.rows.take();
    }

    #[cfg(test)]
    pub(crate) fn inner(&self) -> &Rc<SidebarInner> {
        &self.inner
    }

    #[cfg(test)]
    pub(crate) fn shown(&self) -> u32 {
        self.inner.model.shown()
    }

    #[cfg(test)]
    pub(crate) fn selected_table(&self) -> Option<TableRef> {
        let model = &self.inner.model;
        model
            .object_at(model.selection().selected())
            .map(|object| object.table_ref())
    }
}

impl SidebarInner {
    pub(super) fn affordances(&self) -> SidebarAffordances {
        self.affordances.get()
    }

    pub(super) fn track_row(&self, item: &gtk::ListItem) {
        let mut rows = self.rows.borrow_mut();
        rows.retain(|row| row.upgrade().is_some());
        rows.push(item.downgrade());
    }

    /// A press on the row at `position`. True when the sidebar handled
    /// it, so the row's own click does not select or open it too.
    pub(crate) fn pressed(
        &self,
        position: u32,
        button: u32,
        modifiers: gdk::ModifierType,
        pointing: Option<gdk::Rectangle>,
    ) -> bool {
        match button {
            gdk::BUTTON_SECONDARY => {
                self.popup_menu(position, pointing);
                true
            }
            gdk::BUTTON_PRIMARY if modifiers.contains(gdk::ModifierType::CONTROL_MASK) => {
                self.open_in_new_tab(position);
                true
            }
            _ => false,
        }
    }

    /// A middle click opens the table in a new tab, as a link does.
    pub(super) fn released(&self, position: u32, button: u32) -> bool {
        if button != gdk::BUTTON_MIDDLE {
            return false;
        }
        self.open_in_new_tab(position);
        true
    }

    fn open_in_new_tab(&self, position: u32) {
        if let Some(object) = self.model.object_at(position) {
            (self.events)(SidebarEvent::OpenInNewTab(object.table_ref()));
        }
    }

    fn activate(&self, position: u32) {
        if let Some(object) = self.model.object_at(position) {
            (self.events)(SidebarEvent::Open(object.table_ref()));
        }
    }

    /// Select the row at `position` and open its menu, pointing at
    /// `pointing` in the list view, or at the whole list.
    pub(crate) fn popup_menu(&self, position: u32, pointing: Option<gdk::Rectangle>) {
        let Some(object) = self.model.object_at(position) else {
            return;
        };
        self.model.selection().set_selected(position);
        let menu = object_menu(&ObjectKey(object.table_ref()), object.kind(), self.affordances.get());
        self.popover.set_menu_model(Some(&menu));
        self.popover.set_pointing_to(pointing.as_ref());
        self.popover.popup();
    }

    /// The Menu key and Shift+F10: the selected row's menu, over that
    /// row.
    fn popup_selected_menu(&self) {
        let position = self.model.selection().selected();
        if position == gtk::INVALID_LIST_POSITION {
            return;
        }
        let pointing = self.row_bounds(position).or_else(|| {
            self.list_view
                .focus_child()
                .and_then(|row| bounds_in(&row, &self.list_view))
        });
        self.popup_menu(position, pointing);
    }

    fn row_bounds(&self, position: u32) -> Option<gdk::Rectangle> {
        let rows = self.rows.borrow();
        let row = rows
            .iter()
            .filter_map(glib::WeakRef::upgrade)
            .find(|item| item.position() == position && item.item().is_some())?
            .child()?;
        bounds_in(&row, &self.list_view)
    }

    /// Run a table action whose target came through GAction: a target of
    /// the wrong shape, or for a table the list no longer has, does
    /// nothing.
    fn act_on(&self, action: &str, target: Option<&glib::Variant>) {
        let Some(ObjectKey(table)) = target.and_then(ObjectKey::from_variant) else {
            tracing::warn!(action, "a sidebar action came without a table");
            return;
        };
        let Some(kind) = self.model.kind_of(&table) else {
            tracing::warn!(action, "a sidebar action named a table the list no longer has");
            return;
        };
        if !offers(action, kind, self.affordances.get()) {
            tracing::warn!(action, "a sidebar action the table or the connection does not offer");
            return;
        }
        let event = match action {
            OPEN_IN_NEW_TAB => SidebarEvent::OpenInNewTab(table),
            EDIT_STRUCTURE => SidebarEvent::EditStructure(table),
            SHOW_CREATE_TABLE => SidebarEvent::ShowCreateTable(table),
            IMPORT_CSV => SidebarEvent::ImportCsv(table),
            DROP_TABLE => SidebarEvent::DropTable(table),
            _ => return,
        };
        (self.events)(event);
    }

    fn new_table(&self, target: Option<&glib::Variant>) {
        let Some(schema) = target.and_then(|target| target.get::<Option<String>>()) else {
            tracing::warn!("a new table was asked for without a schema");
            return;
        };
        if !self.affordances.get().offers_new_table() {
            return;
        }
        (self.events)(SidebarEvent::NewTable(schema.filter(|schema| !schema.is_empty())));
    }

    fn reselect(&self) {
        self.model.select(self.active.borrow().as_ref());
    }

    fn refresh_placeholder(&self) {
        if self.model.shown() > 0 {
            self.root.set_visible_child_name(LIST_PAGE);
            return;
        }
        if self.model.has_query() {
            self.empty.set_icon_name(Some(crate::ui::icons::SYSTEM_SEARCH));
            self.empty.set_title(&crate::i18n::gettext("No Matching Tables"));
            self.empty
                .set_description(Some(&crate::i18n::gettext("Try a different search.")));
        } else {
            self.empty.set_icon_name(Some(crate::ui::icons::VIEW_GRID));
            self.empty.set_title(&crate::i18n::gettext("No Tables"));
            self.empty.set_description(None);
        }
        self.root.set_visible_child_name(EMPTY_PAGE);
    }

    fn remember(&self, object: &impl IsA<glib::Object>, handler: glib::SignalHandlerId) {
        self.handlers
            .borrow_mut()
            .push((object.upcast_ref::<glib::Object>().downgrade(), handler));
    }
}

fn install_actions(inner: &Rc<SidebarInner>) {
    for name in [
        OPEN_IN_NEW_TAB,
        EDIT_STRUCTURE,
        SHOW_CREATE_TABLE,
        IMPORT_CSV,
        DROP_TABLE,
    ] {
        let action = gio::SimpleAction::new(name, Some(&ObjectKey::variant_type()));
        let view = Rc::downgrade(inner);
        action.connect_activate(move |_, target| {
            if let Some(view) = view.upgrade() {
                view.act_on(name, target);
            }
        });
        inner.actions.add_action(&action);
    }
    let new_table = gio::SimpleAction::new(NEW_TABLE, Some(&Option::<String>::static_variant_type()));
    let view = Rc::downgrade(inner);
    new_table.connect_activate(move |_, target| {
        if let Some(view) = view.upgrade() {
            view.new_table(target);
        }
    });
    inner.actions.add_action(&new_table);
    let menu = gio::SimpleAction::new(CONTEXT_MENU, None);
    let view = Rc::downgrade(inner);
    menu.connect_activate(move |_, _| {
        if let Some(view) = view.upgrade() {
            view.popup_selected_menu();
        }
    });
    inner.actions.add_action(&menu);
}

fn connect_view(inner: &Rc<SidebarInner>) {
    let view: Weak<SidebarInner> = Rc::downgrade(inner);
    let handler = inner.list_view.connect_activate(move |_, position| {
        if let Some(view) = view.upgrade() {
            view.activate(position);
        }
    });
    inner.remember(&inner.list_view, handler);
    let view = Rc::downgrade(inner);
    let handler = inner.model.selection().connect_items_changed(move |_, _, _, _| {
        if let Some(view) = view.upgrade() {
            view.refresh_placeholder();
        }
    });
    inner.remember(inner.model.selection(), handler);
    let hover = gtk::EventControllerMotion::new();
    let view = Rc::downgrade(inner);
    hover.connect_leave(move |_| {
        if let Some(view) = view.upgrade() {
            view.reselect();
        }
    });
    inner.list_view.add_controller(hover.clone());
    inner.hover.replace(Some(hover));
}

fn bounds_in(widget: &impl IsA<gtk::Widget>, target: &gtk::ListView) -> Option<gdk::Rectangle> {
    widget.compute_bounds(target).map(|bounds| {
        gdk::Rectangle::new(
            bounds.x() as i32,
            bounds.y() as i32,
            bounds.width() as i32,
            bounds.height() as i32,
        )
    })
}
