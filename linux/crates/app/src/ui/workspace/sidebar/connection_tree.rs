//! The window's sidebar: the saved connections in their groups, and
//! under each connection open in the window its schemas and their
//! tables. A schema's rows are a slice of the session's own sidebar list,
//! so its index, its search off the GTK thread and the objects it makes
//! for the rows on screen serve the tree as they served the list.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap};
use std::rc::{Rc, Weak};

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, gio, glib, graphene, pango};
use libadwaita as adw;
use tablepro_session::SessionKey;
use uuid::Uuid;

use super::object_key::ObjectKey;
use super::schema_slice::SchemaSlice;
use super::sidebar_event::SidebarEvent;
use super::sidebar_list::SidebarList;
use super::sidebar_menu::{GROUP, NEW_TABLE, SHOW_SCHEMA_DIAGRAM, object_menu};
use super::sidebar_object::SidebarObject;
use super::sidebar_view::SidebarView;
use super::tree_node::{NodeKind, TreeNode};
use crate::services::saved_connection_list::SavedConnectionList;
use crate::services::saved_connection_object::SavedConnectionObject;

/// The tree's own actions, on the connection or group whose menu is open.
const TREE: &str = "tree";
const CONNECT: &str = "connect";
const DISCONNECT: &str = "disconnect";
const NEW_QUERY: &str = "new-query";
const REFRESH: &str = "refresh";
const EDIT: &str = "edit";

/// What the tree asks of the window or of a session's workspace.
#[derive(Debug, Clone)]
pub(crate) enum TreeRequest {
    /// Open the connection in this window.
    Connect(SessionKey),
    Disconnect(SessionKey),
    /// Bring the session to the front.
    Show(SessionKey),
    /// Open the saved connection in the connect dialog.
    Edit(Uuid),
    NewQuery(SessionKey),
    Refresh(SessionKey),
    /// What the user asked of a table in the session's branch.
    Table(SessionKey, SidebarEvent),
}

#[derive(Clone)]
pub(crate) struct ConnectionTree {
    inner: Rc<TreeInner>,
}

struct TreeInner {
    root: gtk::ScrolledWindow,
    list_view: gtk::ListView,
    roots: gio::ListStore,
    tree: gtk::TreeListModel,
    popover: gtk::PopoverMenu,
    /// The row whose menu is open.
    menu_target: RefCell<Option<TreeNode>>,
    groups: RefCell<HashMap<String, TreeNode>>,
    connections: RefCell<HashMap<SessionKey, TreeNode>>,
    branches: RefCell<HashMap<SessionKey, SessionBranch>>,
    saved: Rc<SavedConnectionList>,
    saved_watch: Cell<Option<glib::SignalHandlerId>>,
    requests: RefCell<Option<TreeRequests>>,
    /// The search, which opens the schemas whose tables it finds.
    query: RefCell<String>,
    /// Each bound row's bindings to its node, let go of when the row is
    /// bound to another.
    bindings: RefCell<HashMap<gtk::ListItem, Vec<glib::Binding>>>,
    /// Each bound connection row's watch on its arrow.
    expand_watches: RefCell<HashMap<gtk::ListItem, ExpandWatch>>,
}

/// Where the tree's requests go.
type TreeRequests = Box<dyn Fn(TreeRequest)>;

/// A bound connection row and its watch on its arrow.
type ExpandWatch = (gtk::TreeListRow, glib::SignalHandlerId);

/// An open session's part of the tree: its connection row's schemas,
/// each a slice of the session's list.
struct SessionBranch {
    view: SidebarView,
    list: SidebarList,
    node: TreeNode,
    schemas: HashMap<String, (TreeNode, SchemaSlice)>,
    handler: Option<glib::SignalHandlerId>,
}

impl ConnectionTree {
    pub(crate) fn new(saved: Rc<SavedConnectionList>) -> Self {
        let roots = gio::ListStore::new::<TreeNode>();
        let tree = gtk::TreeListModel::new(roots.clone(), false, false, |item| {
            item.downcast_ref::<TreeNode>().and_then(TreeNode::children)
        });
        let selection = gtk::SingleSelection::new(Some(tree.clone()));
        selection.set_autoselect(false);
        selection.set_can_unselect(true);
        let list_view = gtk::ListView::new(Some(selection), None::<gtk::ListItemFactory>);
        list_view.add_css_class("navigation-sidebar");
        list_view.set_single_click_activate(true);
        list_view.update_property(&[gtk::accessible::Property::Label(&crate::i18n::gettext("Connections"))]);
        let root = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&list_view)
            .build();
        let popover = gtk::PopoverMenu::from_model(None::<&gio::MenuModel>);
        popover.set_has_arrow(true);
        popover.set_parent(&list_view);
        let inner = Rc::new(TreeInner {
            root,
            list_view,
            roots,
            tree,
            popover,
            menu_target: RefCell::new(None),
            groups: RefCell::new(HashMap::new()),
            connections: RefCell::new(HashMap::new()),
            branches: RefCell::new(HashMap::new()),
            saved,
            saved_watch: Cell::new(None),
            requests: RefCell::new(None),
            query: RefCell::new(String::new()),
            bindings: RefCell::new(HashMap::new()),
            expand_watches: RefCell::new(HashMap::new()),
        });
        inner.list_view.set_factory(Some(&row_factory(Rc::downgrade(&inner))));
        install_actions(&inner);
        let view = Rc::downgrade(&inner);
        inner.list_view.connect_activate(move |_, position| {
            if let Some(view) = view.upgrade() {
                view.activate(position);
            }
        });
        let view = Rc::downgrade(&inner);
        let watch = inner.saved.model().connect_items_changed(move |_, _, _, _| {
            if let Some(view) = view.upgrade() {
                view.rebuild_roots();
            }
        });
        inner.saved_watch.set(Some(watch));
        inner.rebuild_roots();
        Self { inner }
    }

    pub(crate) fn widget(&self) -> &gtk::ScrolledWindow {
        &self.inner.root
    }

    /// Where the tree's requests go.
    pub(crate) fn set_requests(&self, requests: impl Fn(TreeRequest) + 'static) {
        self.inner.requests.replace(Some(Box::new(requests)));
    }

    /// Open the schemas whose tables `entry` finds as the user types.
    pub(crate) fn follow_search(&self, entry: &gtk::SearchEntry) {
        let view = Rc::downgrade(&self.inner);
        entry.connect_search_changed(move |entry| {
            if let Some(view) = view.upgrade() {
                view.query.replace(entry.text().trim().to_owned());
            }
        });
    }

    /// The session under `key` opened in this window: its row says so and
    /// lists its schemas, and opens on them.
    pub(crate) fn add_session(&self, key: &SessionKey, title: &str, view: &SidebarView) {
        let inner = &self.inner;
        let node = inner.connection_node(key, title);
        node.set_connecting(false);
        node.set_open(true);
        let list = view.list();
        let refresh = Rc::downgrade(inner);
        let refreshed_key = key.clone();
        let scheduled = Rc::new(Cell::new(false));
        // A new list takes every row out, then puts the new ones in; the
        // branch follows once both are done, so its open schemas stay open.
        let handler = list.connect_items_changed(move |_, _, _, _| {
            if scheduled.replace(true) {
                return;
            }
            let (refresh, key, scheduled) = (refresh.clone(), refreshed_key.clone(), scheduled.clone());
            glib::idle_add_local_once(move || {
                scheduled.set(false);
                if let Some(inner) = refresh.upgrade() {
                    inner.refresh_branch(&key);
                }
            });
        });
        inner.branches.borrow_mut().insert(
            key.clone(),
            SessionBranch {
                view: view.clone(),
                list,
                node: node.clone(),
                schemas: HashMap::new(),
                handler: Some(handler),
            },
        );
        inner.rebuild_roots();
        inner.refresh_branch(key);
        inner.set_expanded(&node, true);
    }

    /// The session under `key` closed: its row folds up and lists nothing.
    pub(crate) fn remove_session(&self, key: &SessionKey) {
        let inner = &self.inner;
        let branch = inner.branches.borrow_mut().remove(key);
        if let Some(mut branch) = branch {
            if let Some(handler) = branch.handler.take() {
                branch.list.disconnect(handler);
            }
            inner.set_expanded(&branch.node, false);
            if let Some(store) = branch.node.child_store() {
                store.remove_all();
            }
            branch.node.set_open(false);
        }
        inner.rebuild_roots();
    }

    /// The connection under `key` is connecting in this window, or no
    /// longer is.
    pub(crate) fn set_connecting(&self, key: &SessionKey, connecting: bool) {
        if let Some(node) = self.inner.connections.borrow().get(key) {
            node.set_connecting(connecting);
        }
    }

    pub(crate) fn shutdown(&self) {
        let inner = &self.inner;
        if let Some(watch) = inner.saved_watch.take() {
            inner.saved.model().disconnect(watch);
        }
        inner.popover.popdown();
        if inner.popover.parent().is_some() {
            inner.popover.unparent();
        }
        let keys: Vec<SessionKey> = inner.branches.borrow().keys().cloned().collect();
        for key in keys {
            self.remove_session(&key);
        }
        inner.requests.replace(None);
    }
}

impl TreeInner {
    fn request(&self, request: TreeRequest) {
        if let Some(requests) = self.requests.borrow().as_ref() {
            requests(request);
        }
    }

    /// The row of the connection under `key`, made when the window opens
    /// a file no saved connection names.
    fn connection_node(&self, key: &SessionKey, title: &str) -> TreeNode {
        let mut connections = self.connections.borrow_mut();
        let node = connections
            .entry(key.clone())
            .or_insert_with(|| TreeNode::connection(key.clone()));
        if let SessionKey::File(_) = key {
            node.describe(title, None, None, true);
        }
        node.clone()
    }

    /// Lay the roots out again from the saved connections: the groups by
    /// name, then the connections in no group, then the files open with no
    /// saved connection. Rows that stay keep their objects, so they stay
    /// open.
    fn rebuild_roots(&self) {
        let model = self.saved.model();
        let mut grouped: BTreeMap<String, (String, Vec<(String, TreeNode)>)> = BTreeMap::new();
        let mut loose: Vec<(String, TreeNode)> = Vec::new();
        let mut kept: Vec<SessionKey> = Vec::new();
        for position in 0..model.n_items() {
            let Some(object) = model.item(position).and_downcast::<SavedConnectionObject>() else {
                continue;
            };
            let Some(saved) = object.saved() else {
                continue;
            };
            let key = SessionKey::Saved(saved.id);
            let node = {
                let mut connections = self.connections.borrow_mut();
                connections
                    .entry(key.clone())
                    .or_insert_with(|| TreeNode::connection(key.clone()))
                    .clone()
            };
            node.describe(&saved.name, saved.color, saved.icon, object.file_based());
            kept.push(key);
            let sort = saved.name.to_lowercase();
            match &saved.group {
                Some(group) => grouped
                    .entry(group.as_str().to_lowercase())
                    .or_insert_with(|| (group.as_str().to_owned(), Vec::new()))
                    .1
                    .push((sort, node)),
                None => loose.push((sort, node)),
            }
        }
        let mut desired: Vec<TreeNode> = Vec::new();
        let mut groups = self.groups.borrow_mut();
        let mut kept_groups = Vec::new();
        for (sort, (title, mut members)) in grouped {
            let group = groups
                .entry(sort.clone())
                .or_insert_with(|| TreeNode::group(&title))
                .clone();
            members.sort_by(|left, right| left.0.cmp(&right.0));
            if let Some(store) = group.child_store() {
                set_store(&store, &members.into_iter().map(|(_, node)| node).collect::<Vec<_>>());
            }
            kept_groups.push(sort);
            desired.push(group);
        }
        groups.retain(|sort, _| kept_groups.contains(sort));
        drop(groups);
        loose.sort_by(|left, right| left.0.cmp(&right.0));
        desired.extend(loose.into_iter().map(|(_, node)| node));
        let branches = self.branches.borrow();
        let mut files: Vec<(String, TreeNode)> = branches
            .iter()
            .filter(|(key, _)| matches!(key, SessionKey::File(_)))
            .map(|(key, branch)| {
                kept.push(key.clone());
                (branch.node.title().to_lowercase(), branch.node.clone())
            })
            .collect();
        files.sort_by(|left, right| left.0.cmp(&right.0));
        desired.extend(files.into_iter().map(|(_, node)| node));
        drop(branches);
        // A connection deleted while open keeps its row until it closes.
        kept.extend(self.branches.borrow().keys().cloned());
        self.connections.borrow_mut().retain(|key, _| kept.contains(key));
        set_store(&self.roots, &desired);
    }

    /// List the session's schemas again from its list, keeping the rows
    /// of the schemas that stay.
    fn refresh_branch(&self, key: &SessionKey) {
        let mut branches = self.branches.borrow_mut();
        let Some(branch) = branches.get_mut(key) else {
            return;
        };
        let list = branch.list.clone();
        let mut desired = Vec::new();
        let mut position = 0;
        let count = list.n_items();
        while position < count {
            let (start, end) = list.section(position);
            let end = end.min(count).max(start + 1);
            let Some(first) = list.item(start).and_downcast::<SidebarObject>() else {
                break;
            };
            let title = first.section_title();
            let (node, slice) = branch
                .schemas
                .entry(title.clone())
                .or_insert_with(|| {
                    let slice = SchemaSlice::new(&list);
                    let node = TreeNode::schema(&title, first.schema(), slice.clone().upcast());
                    (node, slice)
                })
                .clone();
            slice.set_range(start, end);
            desired.push(node);
            position = end;
        }
        let kept: Vec<String> = desired.iter().map(TreeNode::title).collect();
        branch.schemas.retain(|title, _| kept.contains(title));
        if let Some(store) = branch.node.child_store() {
            set_store(&store, &desired);
        }
        drop(branches);
        if !self.query.borrow().is_empty() {
            for node in desired {
                self.set_expanded(&node, true);
            }
        }
    }

    /// The tree's row showing `node`, when its parents are open.
    fn row_of(&self, node: &TreeNode) -> Option<gtk::TreeListRow> {
        (0..self.tree.n_items())
            .filter_map(|position| self.tree.row(position))
            .find(|row| row.item().as_ref() == Some(node.upcast_ref::<glib::Object>()))
    }

    fn set_expanded(&self, node: &TreeNode, expanded: bool) {
        if let Some(row) = self.row_of(node)
            && row.is_expanded() != expanded
        {
            row.set_expanded(expanded);
        }
    }

    fn row_at(&self, position: u32) -> Option<gtk::TreeListRow> {
        self.tree.row(position)
    }

    /// The connection a row belongs to: its own, or its schema's.
    fn owning_key(row: &gtk::TreeListRow) -> Option<SessionKey> {
        let mut current = Some(row.clone());
        while let Some(row) = current {
            if let Some(node) = row.item().and_downcast::<TreeNode>()
                && node.kind() == NodeKind::Connection
            {
                return node.key();
            }
            current = row.parent();
        }
        None
    }

    /// A click or Enter: a table opens, a connection connects or comes to
    /// the front, and a group or schema opens or folds.
    fn activate(&self, position: u32) {
        let Some(row) = self.row_at(position) else {
            return;
        };
        let Some(item) = row.item() else {
            return;
        };
        if let Some(object) = item.downcast_ref::<SidebarObject>() {
            if let Some(key) = Self::owning_key(&row) {
                self.request(TreeRequest::Table(key, SidebarEvent::Open(object.table_ref())));
            }
            return;
        }
        let Some(node) = item.downcast_ref::<TreeNode>() else {
            return;
        };
        match node.kind() {
            NodeKind::Connection => {
                let Some(key) = node.key() else {
                    return;
                };
                if node.open() {
                    row.set_expanded(!row.is_expanded());
                    self.request(TreeRequest::Show(key));
                } else if !node.connecting() {
                    self.connect(node, key);
                }
            }
            NodeKind::Group | NodeKind::Schema => row.set_expanded(!row.is_expanded()),
        }
    }

    fn connect(&self, node: &TreeNode, key: SessionKey) {
        node.set_connecting(true);
        self.request(TreeRequest::Connect(key));
    }

    /// A press on a row: the secondary button opens its menu, the middle
    /// button or Ctrl opens a table in a new tab. True when handled.
    fn pressed(
        &self,
        position: u32,
        button: u32,
        modifiers: gdk::ModifierType,
        pointing: Option<gdk::Rectangle>,
    ) -> bool {
        let Some(row) = self.row_at(position) else {
            return false;
        };
        let new_tab = button == gdk::BUTTON_MIDDLE
            || (button == gdk::BUTTON_PRIMARY && modifiers.contains(gdk::ModifierType::CONTROL_MASK));
        if new_tab {
            let object = row.item().and_downcast::<SidebarObject>();
            if let (Some(object), Some(key)) = (object, Self::owning_key(&row)) {
                self.request(TreeRequest::Table(key, SidebarEvent::OpenInNewTab(object.table_ref())));
                return true;
            }
            return false;
        }
        if button != gdk::BUTTON_SECONDARY {
            return false;
        }
        let Some(menu) = self.menu_for(&row) else {
            return true;
        };
        self.popover.set_menu_model(Some(&menu));
        self.popover.set_pointing_to(pointing.as_ref());
        self.popover.popup();
        true
    }

    /// The menu of a row, with the session's actions on the list for a
    /// table's or a schema's.
    fn menu_for(&self, row: &gtk::TreeListRow) -> Option<gio::Menu> {
        let item = row.item()?;
        if let Some(object) = item.downcast_ref::<SidebarObject>() {
            let key = Self::owning_key(row)?;
            let view = self.branches.borrow().get(&key)?.view.clone();
            self.list_view.insert_action_group(GROUP, Some(view.actions()));
            return Some(object_menu(
                &ObjectKey(object.table_ref()),
                object.kind(),
                view.affordances(),
            ));
        }
        let node = item.downcast::<TreeNode>().ok()?;
        match node.kind() {
            NodeKind::Group => None,
            NodeKind::Schema => {
                let key = Self::owning_key(row)?;
                let view = self.branches.borrow().get(&key)?.view.clone();
                self.list_view.insert_action_group(GROUP, Some(view.actions()));
                schema_menu(&node, view.affordances())
            }
            NodeKind::Connection => {
                self.menu_target.replace(Some(node.clone()));
                Some(connection_menu(&node))
            }
        }
    }

    fn act_on_target(&self, action: &str) {
        let Some(node) = self.menu_target.borrow().clone() else {
            return;
        };
        let Some(key) = node.key() else {
            return;
        };
        match action {
            CONNECT => self.connect(&node, key),
            DISCONNECT => self.request(TreeRequest::Disconnect(key)),
            NEW_QUERY => self.request(TreeRequest::NewQuery(key)),
            REFRESH => self.request(TreeRequest::Refresh(key)),
            EDIT => {
                if let SessionKey::Saved(id) = key {
                    self.request(TreeRequest::Edit(id));
                }
            }
            _ => {}
        }
    }
}

impl Drop for TreeInner {
    fn drop(&mut self) {
        for (_, mut branch) in self.branches.take() {
            if let Some(handler) = branch.handler.take() {
                branch.list.disconnect(handler);
            }
        }
    }
}

/// Make `store` hold `desired`, in order, changing it only when it holds
/// something else, so open rows stay open.
fn set_store(store: &gio::ListStore, desired: &[TreeNode]) {
    let same = store.n_items() as usize == desired.len()
        && desired
            .iter()
            .enumerate()
            .all(|(position, node)| store.item(position as u32).as_ref() == Some(node.upcast_ref::<glib::Object>()));
    if !same {
        store.splice(0, store.n_items(), desired);
    }
}

fn connection_menu(node: &TreeNode) -> gio::Menu {
    let menu = gio::Menu::new();
    let session = gio::Menu::new();
    if node.open() {
        session.append(
            Some(&crate::i18n::gettext("New Query")),
            Some(&format!("{TREE}.{NEW_QUERY}")),
        );
        session.append(
            Some(&crate::i18n::gettext("Refresh")),
            Some(&format!("{TREE}.{REFRESH}")),
        );
        session.append(
            Some(&crate::i18n::gettext("Disconnect")),
            Some(&format!("{TREE}.{DISCONNECT}")),
        );
    } else {
        session.append(
            Some(&crate::i18n::gettext("Connect")),
            Some(&format!("{TREE}.{CONNECT}")),
        );
    }
    menu.append_section(None, &session);
    if matches!(node.key(), Some(SessionKey::Saved(_))) {
        let edit = gio::Menu::new();
        edit.append(
            Some(&crate::i18n::gettext("Edit Connection…")),
            Some(&format!("{TREE}.{EDIT}")),
        );
        menu.append_section(None, &edit);
    }
    menu
}

/// New Table and the schema's diagram, as the list's section header
/// offered them.
fn schema_menu(node: &TreeNode, affordances: super::SidebarAffordances) -> Option<gio::Menu> {
    let menu = gio::Menu::new();
    let target = node.schema_name().unwrap_or_default().to_variant();
    let target = Some(target).to_variant();
    if affordances.offers_new_table() {
        let item = gio::MenuItem::new(Some(&crate::i18n::gettext("New Table…")), None);
        item.set_action_and_target_value(Some(&format!("{GROUP}.{NEW_TABLE}")), Some(&target));
        menu.append_item(&item);
    }
    if affordances.speaks_sql {
        let item = gio::MenuItem::new(Some(&crate::i18n::gettext("Show ER Diagram")), None);
        item.set_action_and_target_value(Some(&format!("{GROUP}.{SHOW_SCHEMA_DIAGRAM}")), Some(&target));
        menu.append_item(&item);
    }
    (menu.n_items() > 0).then_some(menu)
}

fn install_actions(inner: &Rc<TreeInner>) {
    let actions = gio::SimpleActionGroup::new();
    for name in [CONNECT, DISCONNECT, NEW_QUERY, REFRESH, EDIT] {
        let action = gio::SimpleAction::new(name, None);
        let view = Rc::downgrade(inner);
        action.connect_activate(move |_, _| {
            if let Some(view) = view.upgrade() {
                view.act_on_target(name);
            }
        });
        actions.add_action(&action);
    }
    inner.list_view.insert_action_group(TREE, Some(&actions));
}

/// The parts of a row, found again when it is bound.
struct RowParts {
    icon: gtk::Image,
    label: gtk::Label,
    spinner: adw::Spinner,
    status: gtk::Label,
}

fn row_parts(expander: &gtk::TreeExpander) -> Option<RowParts> {
    let row = expander.child()?;
    let icon = row.first_child().and_downcast::<gtk::Image>()?;
    let label = icon.next_sibling().and_downcast::<gtk::Label>()?;
    let spinner = label.next_sibling().and_downcast::<adw::Spinner>()?;
    let status = spinner.next_sibling().and_downcast::<gtk::Label>()?;
    Some(RowParts {
        icon,
        label,
        spinner,
        status,
    })
}

fn row_factory(view: Weak<TreeInner>) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    let setup_view = view.clone();
    factory.connect_setup(move |_, object| {
        if let Some(item) = object.downcast_ref::<gtk::ListItem>() {
            setup_row(&setup_view, item);
        }
    });
    let bind_view = view.clone();
    factory.connect_bind(move |_, object| {
        if let Some(item) = object.downcast_ref::<gtk::ListItem>() {
            bind_row(&bind_view, item);
        }
    });
    factory.connect_unbind(move |_, object| {
        if let Some(item) = object.downcast_ref::<gtk::ListItem>() {
            unbind_row(&view, item);
        }
    });
    factory
}

fn setup_row(view: &Weak<TreeInner>, item: &gtk::ListItem) {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .build();
    let icon = gtk::Image::builder()
        .pixel_size(16)
        .accessible_role(gtk::AccessibleRole::Presentation)
        .build();
    let label = gtk::Label::builder()
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    let spinner = adw::Spinner::builder().visible(false).build();
    // Says the connection is open in the window; the row's description
    // says it to a screen reader.
    let status = gtk::Label::builder()
        .label("●")
        .visible(false)
        .accessible_role(gtk::AccessibleRole::Presentation)
        .build();
    status.add_css_class("success");
    status.add_css_class("caption");
    row.append(&icon);
    row.append(&label);
    row.append(&spinner);
    row.append(&status);
    let expander = gtk::TreeExpander::new();
    expander.set_indent_for_icon(true);
    expander.set_child(Some(&row));
    expander.add_controller(click_gesture(view.clone(), item));
    item.set_child(Some(&expander));
}

fn bind_row(view: &Weak<TreeInner>, item: &gtk::ListItem) {
    let (Some(expander), Some(row)) = (
        item.child().and_downcast::<gtk::TreeExpander>(),
        item.item().and_downcast::<gtk::TreeListRow>(),
    ) else {
        return;
    };
    expander.set_list_row(Some(&row));
    let Some(parts) = row_parts(&expander) else {
        return;
    };
    parts.spinner.set_visible(false);
    parts.status.set_visible(false);
    parts.icon.set_css_classes(&[]);
    parts.label.set_css_classes(&[]);
    parts.icon.set_visible(true);
    let Some(object) = row.item() else {
        return;
    };
    if let Some(object) = object.downcast_ref::<SidebarObject>() {
        parts.icon.set_icon_name(Some(&object.icon_name()));
        parts.label.set_label(&object.name());
        expander.set_tooltip_text(Some(&object.qualified_name()));
        item.set_accessible_description(&object.kind_name());
        return;
    }
    let Ok(node) = object.downcast::<TreeNode>() else {
        return;
    };
    parts.label.set_label(&node.title());
    expander.set_tooltip_text(None);
    match node.kind() {
        NodeKind::Group => {
            parts.icon.set_icon_name(Some(crate::ui::icons::FOLDER));
            item.set_accessible_description(&crate::i18n::gettext("Group"));
        }
        NodeKind::Schema => {
            parts.icon.set_icon_name(Some(crate::ui::icons::DRIVE_HARDDISK));
            item.set_accessible_description(&crate::i18n::gettext("Schema"));
        }
        NodeKind::Connection => bind_connection(view, item, &row, &node, &parts),
    }
}

/// A connection's icon in its colour, and its open and connecting state,
/// which follow the node while the row shows it.
fn bind_connection(
    view: &Weak<TreeInner>,
    item: &gtk::ListItem,
    row: &gtk::TreeListRow,
    node: &TreeNode,
    parts: &RowParts,
) {
    let fallback = if node.file_based() {
        crate::ui::icons::DRIVE_HARDDISK
    } else {
        crate::ui::icons::NETWORK_SERVER
    };
    let icon = node
        .connection_icon()
        .map_or(fallback, crate::ui::icons::connection_icon);
    parts.icon.set_icon_name(Some(icon));
    if let Some(color) = node.color() {
        parts
            .icon
            .add_css_class(crate::ui::connection_appearance::color_class(color));
    }
    let bindings = vec![
        node.bind_property("open", &parts.status, "visible")
            .sync_create()
            .build(),
        node.bind_property("connecting", &parts.spinner, "visible")
            .sync_create()
            .build(),
        node.bind_property("open", &parts.label, "css-classes")
            .transform_to(|_, open: bool| Some(if open { vec!["heading".to_owned()] } else { Vec::new() }))
            .sync_create()
            .build(),
        node.bind_property("open", item, "accessible-description")
            .transform_to(|_, open: bool| {
                Some(if open {
                    crate::i18n::gettext("Connection, open")
                } else {
                    crate::i18n::gettext("Connection")
                })
            })
            .sync_create()
            .build(),
    ];
    let watch = connect_on_expand(view.clone(), row, node);
    if let Some(view) = view.upgrade() {
        view.bindings.borrow_mut().insert(item.clone(), bindings);
        view.expand_watches
            .borrow_mut()
            .insert(item.clone(), (row.clone(), watch));
    }
}

fn unbind_row(view: &Weak<TreeInner>, item: &gtk::ListItem) {
    if let Some(view) = view.upgrade() {
        if let Some(bindings) = view.bindings.borrow_mut().remove(item) {
            for binding in bindings {
                binding.unbind();
            }
        }
        if let Some((row, watch)) = view.expand_watches.borrow_mut().remove(item) {
            row.disconnect(watch);
        }
    }
    if let Some(expander) = item.child().and_downcast::<gtk::TreeExpander>() {
        expander.set_list_row(None);
    }
}

/// Opening a connection's row by its arrow connects it, as a click does.
fn connect_on_expand(view: Weak<TreeInner>, row: &gtk::TreeListRow, node: &TreeNode) -> glib::SignalHandlerId {
    let node = node.downgrade();
    row.connect_expanded_notify(move |row| {
        if !row.is_expanded() {
            return;
        }
        let (Some(view), Some(node)) = (view.upgrade(), node.upgrade()) else {
            return;
        };
        if node.open() || node.connecting() {
            return;
        }
        let Some(key) = node.key() else {
            return;
        };
        let view = Rc::downgrade(&view);
        // Not from inside the row's own notify.
        glib::idle_add_local_once(move || {
            if let Some(view) = view.upgrade() {
                view.connect(&node, key);
            }
        });
    })
}

/// Button 0, so one gesture sees every button. It claims only what it
/// handles, which cancels the row's own click for that press.
fn click_gesture(view: Weak<TreeInner>, item: &gtk::ListItem) -> gtk::GestureClick {
    let gesture = gtk::GestureClick::new();
    gesture.set_button(0);
    let item = item.downgrade();
    gesture.connect_pressed(move |gesture, _, x, y| {
        let (Some(view), Some(item), Some(row)) = (view.upgrade(), item.upgrade(), gesture.widget()) else {
            return;
        };
        let at = row.compute_point(&view.list_view, &graphene::Point::new(x as f32, y as f32));
        let pointing = at.map(|point| gdk::Rectangle::new(point.x() as i32, point.y() as i32, 1, 1));
        if view.pressed(
            item.position(),
            gesture.current_button(),
            gesture.current_event_state(),
            pointing,
        ) {
            gesture.set_state(gtk::EventSequenceState::Claimed);
        }
    });
    gesture
}
