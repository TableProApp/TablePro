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
use super::sidebar_index::search_key;
use super::sidebar_list::SidebarList;
use super::sidebar_menu::{GROUP, NEW_TABLE, SHOW_SCHEMA_DIAGRAM, object_menu};
use super::sidebar_object::SidebarObject;
use super::sidebar_view::SidebarView;
use super::tree_node::{NodeKind, TreeNode};
use crate::application::{ShortcutOwner, local_shortcut_controller};
use crate::services::saved_connection_list::SavedConnectionList;
use crate::services::saved_connection_object::SavedConnectionObject;

/// The tree's own actions, on the connection or group whose menu is open.
const TREE: &str = "tree";
const CONTEXT_MENU: &str = "context-menu";
const CONNECT: &str = "connect";
const DISCONNECT: &str = "disconnect";
const NEW_QUERY: &str = "new-query";
const REFRESH: &str = "refresh";
const EDIT: &str = "edit";

const LIST_PAGE: &str = "list";
const EMPTY_PAGE: &str = "empty";

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
    root: gtk::Stack,
    list_view: gtk::ListView,
    selection: gtk::SingleSelection,
    roots: gio::ListStore,
    tree: gtk::TreeListModel,
    /// Hides the connections and groups the search does not find. It
    /// filters the roots and each group's connections, never the
    /// flattened tree, which would leave a hidden row's children behind.
    filter: gtk::CustomFilter,
    popover: gtk::PopoverMenu,
    /// The row whose menu is open.
    menu_target: RefCell<Option<TreeNode>>,
    groups: RefCell<HashMap<String, TreeNode>>,
    connections: RefCell<HashMap<SessionKey, TreeNode>>,
    branches: RefCell<HashMap<SessionKey, SessionBranch>>,
    saved: Rc<SavedConnectionList>,
    saved_watch: Cell<Option<glib::SignalHandlerId>>,
    requests: RefCell<Option<TreeRequests>>,
    /// The search as `search_key` folds it, empty for none. It opens the
    /// schemas whose tables it finds.
    query: Rc<RefCell<String>>,
    /// Which rows were open before the search, to open or fold them
    /// again once it is cleared.
    before_search: RefCell<Option<Expansion>>,
    /// The session whose tab is in front, whose row the selection follows.
    followed: RefCell<Option<Followed>>,
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

/// Whether each group's, connection's and schema's row is open. A filter
/// change can take out and put back rows it does not hide, which folds
/// them.
type Expansion = HashMap<TreeNode, bool>;

/// The session the selection follows, and whether its table's row is
/// still to be opened and scrolled to: its list was not read yet, or the
/// search hid it.
#[derive(Clone)]
struct Followed {
    key: SessionKey,
    unrevealed: bool,
}

/// An open session's part of the tree: its connection row's schemas,
/// each a slice of the session's list.
struct SessionBranch {
    view: SidebarView,
    list: SidebarList,
    node: TreeNode,
    schemas: HashMap<String, (TreeNode, SchemaSlice)>,
    handler: Option<glib::SignalHandlerId>,
    /// Whether the connection's row was opened once, which happens the
    /// first time the row is in the tree. After that the user decides.
    revealed: bool,
}

impl ConnectionTree {
    pub(crate) fn new(saved: Rc<SavedConnectionList>) -> Self {
        let roots = gio::ListStore::new::<TreeNode>();
        let query = Rc::new(RefCell::new(String::new()));
        let (tree, filter) = tree_model(&roots, &query);
        let selection = gtk::SingleSelection::new(Some(tree.clone()));
        selection.set_autoselect(false);
        selection.set_can_unselect(true);
        let list_view = gtk::ListView::new(Some(selection.clone()), None::<gtk::ListItemFactory>);
        list_view.add_css_class("navigation-sidebar");
        list_view.set_single_click_activate(true);
        list_view.update_property(&[gtk::accessible::Property::Label(&crate::i18n::gettext("Connections"))]);
        let root = tree_root(&list_view);
        let popover = gtk::PopoverMenu::from_model(None::<&gio::MenuModel>);
        popover.set_has_arrow(true);
        popover.set_parent(&list_view);
        let inner = Rc::new(TreeInner {
            root,
            list_view,
            selection,
            roots,
            tree,
            filter,
            popover,
            menu_target: RefCell::new(None),
            groups: RefCell::new(HashMap::new()),
            connections: RefCell::new(HashMap::new()),
            branches: RefCell::new(HashMap::new()),
            saved,
            saved_watch: Cell::new(None),
            requests: RefCell::new(None),
            query,
            before_search: RefCell::new(None),
            followed: RefCell::new(None),
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
        connect_hover(&inner);
        inner.rebuild_roots();
        Self { inner }
    }

    pub(crate) fn widget(&self) -> &gtk::Stack {
        &self.inner.root
    }

    /// Where the tree's requests go.
    pub(crate) fn set_requests(&self, requests: impl Fn(TreeRequest) + 'static) {
        self.inner.requests.replace(Some(Box::new(requests)));
    }

    /// Show only the connections whose names `entry` finds, or whose
    /// tables it finds, and open the schemas of those tables, as the user
    /// types and for what it holds now.
    pub(crate) fn follow_search(&self, entry: &gtk::SearchEntry) {
        let view = Rc::downgrade(&self.inner);
        entry.connect_search_changed(move |entry| {
            if let Some(view) = view.upgrade() {
                view.apply_query(&entry.text());
            }
        });
        self.inner.apply_query(&entry.text());
    }

    /// Select the row of `object` under the session `key`, opening the
    /// rows above it, or the connection's row when the tab in front shows
    /// no object or the tree does not show it. The keyboard stays in the
    /// tab.
    pub(crate) fn select(&self, key: &SessionKey, object: Option<&SidebarObject>) {
        let inner = &self.inner;
        let wanted = object.is_some() || inner.view_of(key).is_some_and(|view| view.follows_table());
        let shown = inner.show_selection(key, object, true);
        inner.followed.replace(Some(Followed {
            key: key.clone(),
            unrevealed: wanted && !shown,
        }));
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
        // The schemas it has already follow the list at once, so none of
        // them reads rows of a range the list no longer has.
        let resync = Rc::downgrade(inner);
        let resync_key = key.clone();
        let handler = list.connect_items_changed(move |_, _, _, _| {
            if let Some(inner) = resync.upgrade() {
                inner.resync_slices(&resync_key);
            }
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
                revealed: false,
            },
        );
        inner.rebuild_roots();
        inner.refresh_branch(key);
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
        let followed = inner
            .followed
            .borrow()
            .as_ref()
            .is_some_and(|followed| &followed.key == key);
        if followed {
            inner.followed.replace(None);
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

    /// Each bound table row's name and what a screen reader says it is.
    #[cfg(test)]
    pub(crate) fn row_descriptions(&self) -> Vec<(String, String)> {
        let mut found: Vec<(String, String)> = self
            .inner
            .bindings
            .borrow()
            .keys()
            .filter_map(|item| {
                let row = item.item().and_downcast::<gtk::TreeListRow>()?;
                let object = row.item().and_downcast::<SidebarObject>()?;
                let description = item.property::<Option<String>>("accessible-description")?;
                Some((object.name(), description))
            })
            .collect();
        found.sort();
        found
    }

    /// Each row's name, in the tree's order.
    #[cfg(test)]
    pub(crate) fn shown_rows(&self) -> Vec<String> {
        let tree = &self.inner.tree;
        (0..tree.n_items())
            .filter_map(|position| tree.row(position))
            .filter_map(|row| row_title(&row))
            .collect()
    }

    #[cfg(test)]
    pub(crate) fn selected_row(&self) -> Option<String> {
        let row = self
            .inner
            .selection
            .selected_item()
            .and_downcast::<gtk::TreeListRow>()?;
        row_title(&row)
    }

    /// Whether the tree says the search found nothing.
    #[cfg(test)]
    pub(crate) fn says_nothing_found(&self) -> bool {
        self.inner.root.visible_child_name().as_deref() == Some(EMPTY_PAGE)
    }

    /// The names of the connections the tree says are open.
    #[cfg(test)]
    pub(crate) fn open_connections(&self) -> Vec<String> {
        let mut open: Vec<String> = self
            .inner
            .connections
            .borrow()
            .values()
            .filter(|node| node.open())
            .map(TreeNode::title)
            .collect();
        open.sort();
        open
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
        // A file opened with no saved connection, or a connection open
        // before the list was read or deleted since, still has its row.
        let mut files: Vec<(String, TreeNode)> = branches
            .iter()
            .filter(|(key, _)| !kept.contains(key))
            .map(|(_, branch)| (branch.node.title().to_lowercase(), branch.node.clone()))
            .collect();
        files.sort_by(|left, right| left.0.cmp(&right.0));
        desired.extend(files.into_iter().map(|(_, node)| node));
        drop(branches);
        // A connection deleted while open keeps its row until it closes.
        kept.extend(self.branches.borrow().keys().cloned());
        self.connections.borrow_mut().retain(|key, _| kept.contains(key));
        set_store(&self.roots, &desired);
        self.reveal_branches();
        // A group shows by its connections, which this may have moved.
        self.refilter();
    }

    /// Open the row of each session whose row was never opened, once the
    /// row is in the tree.
    fn reveal_branches(&self) {
        let waiting: Vec<(SessionKey, TreeNode)> = self
            .branches
            .borrow()
            .iter()
            .filter(|(_, branch)| !branch.revealed)
            .map(|(key, branch)| (key.clone(), branch.node.clone()))
            .collect();
        for (key, node) in waiting {
            if let Some(row) = self.row_of(&node) {
                row.set_expanded(true);
                if let Some(branch) = self.branches.borrow_mut().get_mut(&key) {
                    branch.revealed = true;
                }
                // Clearing the search does not fold a session that
                // opened under it.
                if let Some(before) = self.before_search.borrow_mut().as_mut() {
                    before.remove(&node);
                }
            }
        }
    }

    /// List the session's schemas again from its list, keeping the rows
    /// of the schemas that stay.
    /// Point each schema the branch has at its run of the list as it is
    /// now, and a schema the list no longer has at nothing.
    fn resync_slices(&self, key: &SessionKey) {
        let branches = self.branches.borrow();
        let Some(branch) = branches.get(key) else {
            return;
        };
        let list = &branch.list;
        let mut ranges: HashMap<String, (u32, u32)> = HashMap::new();
        let mut position = 0;
        let count = list.n_items();
        while position < count {
            let (start, end) = list.section(position);
            let end = end.min(count).max(start + 1);
            let Some(first) = list.item(start).and_downcast::<SidebarObject>() else {
                break;
            };
            ranges.insert(first.section_title(), (start, end));
            position = end;
        }
        for (title, (_, slice)) in &branch.schemas {
            let (start, end) = ranges.get(title).copied().unwrap_or((0, 0));
            slice.set_range(start, end);
        }
    }

    fn refresh_branch(&self, key: &SessionKey) {
        let mut branches = self.branches.borrow_mut();
        let Some(branch) = branches.get_mut(key) else {
            return;
        };
        let list = branch.list.clone();
        let mut desired = Vec::new();
        let mut born = Vec::new();
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
                    born.push(node.clone());
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
        self.reveal_branches();
        // A lone schema, as a file or a key-value engine has, opens as it
        // comes: its row says nothing the connection's does not.
        let lone = desired.len() == 1 && born.len() == 1;
        if !self.query.borrow().is_empty() || lone {
            for node in desired {
                self.set_expanded(&node, true);
            }
        }
        // Whether the search shows the connection depends on its rows.
        self.refilter();
    }

    /// The tree's row showing `node`, when its parents are open. It walks
    /// down from the roots, so it never looks through a schema's tables.
    fn row_of(&self, node: &TreeNode) -> Option<gtk::TreeListRow> {
        match node.kind() {
            NodeKind::Group => self.top_row(node),
            NodeKind::Connection => self.connection_row(node, false),
            NodeKind::Schema => {
                let connection = self
                    .branches
                    .borrow()
                    .values()
                    .find(|branch| branch.schemas.values().any(|(schema, _)| schema == node))
                    .map(|branch| branch.node.clone())?;
                child_row(&self.connection_row(&connection, false)?, node)
            }
        }
    }

    fn top_row(&self, node: &TreeNode) -> Option<gtk::TreeListRow> {
        let position = index_in(&self.tree.model(), node)?;
        self.tree.child_row(position)
    }

    /// The row of the connection `node`, among the roots or in its
    /// group; `open` opens the group to show it.
    fn connection_row(&self, node: &TreeNode, open: bool) -> Option<gtk::TreeListRow> {
        if let Some(row) = self.top_row(node) {
            return Some(row);
        }
        let group = self
            .groups
            .borrow()
            .values()
            .find(|group| {
                group
                    .child_store()
                    .is_some_and(|store| position_in(&store, node, 0).is_some())
            })
            .cloned()?;
        let row = self.top_row(&group)?;
        if open {
            expand(&row);
        }
        child_row(&row, node)
    }

    fn view_of(&self, key: &SessionKey) -> Option<SidebarView> {
        self.branches.borrow().get(key).map(|branch| branch.view.clone())
    }

    /// The schema whose slice holds `object` in the session's list, and
    /// where in the slice. The list finds the row through its index, so
    /// no row is looked through.
    fn schema_offset(&self, key: &SessionKey, object: &SidebarObject) -> Option<(TreeNode, u32)> {
        let branches = self.branches.borrow();
        let branch = branches.get(key)?;
        let entry = branch.list.index().find(&object.table_ref())?;
        let position = branch.list.position_of_entry(entry)?;
        branch
            .schemas
            .values()
            .find_map(|(schema, slice)| Some((schema.clone(), slice.offset_of(position)?)))
    }

    /// The position of `object`'s row under the connection `key`, or of
    /// the connection's row when the tree does not show the object's, and
    /// whether it is the object's. `open` opens the rows above the
    /// object's.
    fn locate(&self, key: &SessionKey, object: Option<&SidebarObject>, open: bool) -> Option<(u32, bool)> {
        let node = self.connections.borrow().get(key).cloned()?;
        let connection = self.connection_row(&node, open)?;
        let found = object
            .and_then(|object| self.schema_offset(key, object))
            .and_then(|(schema, offset)| object_row(&connection, &schema, offset, open));
        Some(found.map_or((connection.position(), false), |row| (row.position(), true)))
    }

    /// Select the row `locate` finds, or none. `reveal` opens the rows
    /// above it and scrolls to it. True when the row is the object's.
    fn show_selection(&self, key: &SessionKey, object: Option<&SidebarObject>, reveal: bool) -> bool {
        let Some((position, is_object)) = self.locate(key, object, reveal) else {
            if self.selection.selected() != gtk::INVALID_LIST_POSITION {
                self.selection.set_selected(gtk::INVALID_LIST_POSITION);
            }
            return false;
        };
        if reveal {
            // Without FOCUS: the keyboard stays in the editor or the grid.
            self.list_view.scroll_to(position, gtk::ListScrollFlags::SELECT, None);
        } else if self.selection.selected() != position {
            self.selection.set_selected(position);
        }
        is_object
    }

    /// Select again the row of the session the selection follows, once
    /// its rows moved or the pointer left: activation on a single click
    /// selects rows on hover.
    fn reselect(&self) {
        let Some(followed) = self.followed.borrow().clone() else {
            return;
        };
        let object = self.view_of(&followed.key).and_then(|view| view.active_object());
        let reveal = followed.unrevealed && object.is_some();
        let shown = self.show_selection(&followed.key, object.as_ref(), reveal);
        if reveal
            && shown
            && let Some(followed) = self.followed.borrow_mut().as_mut()
        {
            followed.unrevealed = false;
        }
    }

    /// Filter by `text` as `search_key` folds it. Each row the filter
    /// keeps stays open or folded, and clearing the search opens and
    /// folds the rows as they were before it.
    fn apply_query(&self, text: &str) {
        let text = text.trim();
        let query = if text.is_empty() {
            String::new()
        } else {
            search_key(text)
        };
        if *self.query.borrow() == query {
            return;
        }
        let states = self.expansion();
        let started = self.query.borrow().is_empty();
        let ended = query.is_empty();
        self.query.replace(query);
        let states = if started {
            self.before_search.replace(Some(states.clone()));
            states
        } else if ended {
            self.before_search.take().unwrap_or(states)
        } else {
            states
        };
        self.refilter_keeping(&states);
    }

    /// What a branch or the saved connections hold changed, which can
    /// change what the search shows.
    fn refilter(&self) {
        if self.query.borrow().is_empty() {
            self.reselect();
            return;
        }
        let states = self.expansion();
        self.refilter_keeping(&states);
    }

    fn refilter_keeping(&self, states: &Expansion) {
        self.filter.changed(gtk::FilterChange::Different);
        self.restore(states);
        if !self.query.borrow().is_empty() {
            self.open_matches();
        }
        let nothing = !self.query.borrow().is_empty() && self.tree.model().n_items() == 0;
        self.root
            .set_visible_child_name(if nothing { EMPTY_PAGE } else { LIST_PAGE });
        self.reselect();
    }

    fn expansion(&self) -> Expansion {
        let mut states = Expansion::new();
        let mut rows = top_rows(&self.tree);
        while let Some(row) = rows.pop() {
            let Some(node) = row.item().and_downcast::<TreeNode>() else {
                continue;
            };
            if row.is_expanded() && node.kind() != NodeKind::Schema {
                rows.extend(child_rows(&row));
            }
            states.insert(node, row.is_expanded());
        }
        states
    }

    /// Open or fold each row as `states` has it. A closed connection's
    /// row is never opened: that connects it.
    fn restore(&self, states: &Expansion) {
        let mut rows = top_rows(&self.tree);
        while let Some(row) = rows.pop() {
            let Some(node) = row.item().and_downcast::<TreeNode>() else {
                continue;
            };
            if let Some(&expanded) = states.get(&node)
                && expanded != row.is_expanded()
                && (!expanded || node.kind() != NodeKind::Connection || node.open())
            {
                row.set_expanded(expanded);
            }
            if row.is_expanded() && node.kind() != NodeKind::Schema {
                rows.extend(child_rows(&row));
            }
        }
    }

    /// Open each group the search shows, each open connection with tables
    /// it found and their schemas, so what it found is in view.
    fn open_matches(&self) {
        let mut rows = top_rows(&self.tree);
        while let Some(row) = rows.pop() {
            let Some(node) = row.item().and_downcast::<TreeNode>() else {
                continue;
            };
            match node.kind() {
                NodeKind::Group => {
                    expand(&row);
                    rows.extend(child_rows(&row));
                }
                NodeKind::Connection if node.open() && has_schemas(&node) => {
                    expand(&row);
                    rows.extend(child_rows(&row));
                }
                NodeKind::Schema => expand(&row),
                NodeKind::Connection => {}
            }
        }
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

    /// The menu of the row with the keyboard focus, from the Menu key,
    /// under that row.
    fn popup_keyboard_menu(&self) {
        let focused = self.list_view.focus_child();
        let item = focused.and_then(|focused| {
            self.bindings
                .borrow()
                .keys()
                .find(|item| {
                    item.child()
                        .is_some_and(|row| row == focused || row.is_ancestor(&focused))
                })
                .cloned()
        });
        let position = item
            .as_ref()
            .map_or_else(|| self.selection.selected(), gtk::ListItem::position);
        let Some(row) = self.row_at(position) else {
            return;
        };
        let Some(menu) = self.menu_for(&row) else {
            return;
        };
        let pointing = item
            .and_then(|item| item.child())
            .and_then(|row| row.compute_bounds(&self.list_view))
            .map(|bounds| {
                gdk::Rectangle::new(
                    bounds.x() as i32,
                    bounds.y() as i32,
                    bounds.width() as i32,
                    bounds.height() as i32,
                )
            });
        self.popover.set_menu_model(Some(&menu));
        self.popover.set_pointing_to(pointing.as_ref());
        self.popover.popup();
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

/// Make `store` hold `desired`, in order. Only what differs is taken out
/// or put in, so the rows of the nodes that stay keep their place and
/// stay open.
fn set_store(store: &gio::ListStore, desired: &[TreeNode]) {
    let mut position: u32 = 0;
    for node in desired {
        // A node held here that is wanted nowhere goes first.
        while let Some(held) = store.item(position).and_downcast::<TreeNode>() {
            if &held == node || desired.contains(&held) {
                break;
            }
            store.remove(position);
        }
        let held = store.item(position).and_downcast::<TreeNode>();
        if held.as_ref() != Some(node) {
            if let Some(at) = position_in(store, node, position + 1) {
                store.remove(at);
            }
            store.insert(position, node);
        }
        position += 1;
    }
    while store.n_items() > position {
        store.remove(position);
    }
}

/// The tree over `roots`: each group's connections and the roots go
/// through the search's filter, and the filter it returns.
fn tree_model(roots: &gio::ListStore, query: &Rc<RefCell<String>>) -> (gtk::TreeListModel, gtk::CustomFilter) {
    let shown = query.clone();
    let filter = gtk::CustomFilter::new(move |item| shows(item, &shown.borrow()));
    let groups = filter.clone();
    let shown_roots = gtk::FilterListModel::new(Some(roots.clone()), Some(filter.clone()));
    let tree = gtk::TreeListModel::new(shown_roots, false, false, move |item| {
        let node = item.downcast_ref::<TreeNode>()?;
        let children = node.children()?;
        if node.kind() == NodeKind::Group {
            return Some(gtk::FilterListModel::new(Some(children), Some(groups.clone())).upcast::<gio::ListModel>());
        }
        Some(children)
    });
    (tree, filter)
}

/// The tree's rows, or a page that says the search found nothing.
fn tree_root(list_view: &gtk::ListView) -> gtk::Stack {
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(list_view)
        .build();
    let empty = adw::StatusPage::builder()
        .icon_name(crate::ui::icons::SYSTEM_SEARCH)
        .title(crate::i18n::gettext("No Results Found"))
        .description(crate::i18n::gettext("Try a different search."))
        .build();
    empty.add_css_class("compact");
    let root = gtk::Stack::new();
    root.add_named(&scroll, Some(LIST_PAGE));
    root.add_named(&empty, Some(EMPTY_PAGE));
    root
}

/// Activation on a single click selects the row under the pointer, so
/// the selection goes back to the tab in front's row when it leaves.
fn connect_hover(inner: &Rc<TreeInner>) {
    let hover = gtk::EventControllerMotion::new();
    let view = Rc::downgrade(inner);
    hover.connect_leave(move |_| {
        if let Some(view) = view.upgrade() {
            view.reselect();
        }
    });
    inner.list_view.add_controller(hover);
}

/// Whether the search `query` shows `item`: a connection whose name it
/// finds or whose session lists tables it finds, and a group with such a
/// connection. A session's list is already filtered by the search.
fn shows(item: &glib::Object, query: &str) -> bool {
    if query.is_empty() {
        return true;
    }
    let Some(node) = item.downcast_ref::<TreeNode>() else {
        return true;
    };
    match node.kind() {
        NodeKind::Connection => connection_shows(node, query),
        NodeKind::Group => node.child_store().is_some_and(|store| {
            (0..store.n_items())
                .filter_map(|position| store.item(position).and_downcast::<TreeNode>())
                .any(|connection| connection_shows(&connection, query))
        }),
        NodeKind::Schema => true,
    }
}

fn connection_shows(node: &TreeNode, query: &str) -> bool {
    search_key(&node.title()).contains(query) || has_schemas(node)
}

/// A closed connection lists no schema, and an open one lists only the
/// schemas whose tables the search finds.
fn has_schemas(node: &TreeNode) -> bool {
    node.child_store().is_some_and(|store| store.n_items() > 0)
}

fn top_rows(tree: &gtk::TreeListModel) -> Vec<gtk::TreeListRow> {
    let count = tree.model().n_items();
    (0..count).filter_map(|position| tree.child_row(position)).collect()
}

fn child_rows(row: &gtk::TreeListRow) -> Vec<gtk::TreeListRow> {
    let count = row.children().map_or(0, |children| children.n_items());
    (0..count).filter_map(|position| row.child_row(position)).collect()
}

/// The row of `node` among the children of the open row `parent`.
fn child_row(parent: &gtk::TreeListRow, node: &TreeNode) -> Option<gtk::TreeListRow> {
    let position = index_in(&parent.children()?, node)?;
    parent.child_row(position)
}

/// The row at `offset` in `schema` under the open connection's row,
/// opening the schema and the connection when `open`.
fn object_row(connection: &gtk::TreeListRow, schema: &TreeNode, offset: u32, open: bool) -> Option<gtk::TreeListRow> {
    if open {
        expand(connection);
    }
    let schema = child_row(connection, schema)?;
    if open {
        expand(&schema);
    }
    schema.child_row(offset)
}

fn expand(row: &gtk::TreeListRow) {
    if !row.is_expanded() {
        row.set_expanded(true);
    }
}

/// Where `node` is in `model`: the roots, a group's connections or a
/// connection's schemas, never a schema's tables.
fn index_in(model: &gio::ListModel, node: &TreeNode) -> Option<u32> {
    (0..model.n_items()).find(|&at| model.item(at).as_ref() == Some(node.upcast_ref::<glib::Object>()))
}

#[cfg(test)]
fn row_title(row: &gtk::TreeListRow) -> Option<String> {
    let item = row.item()?;
    if let Some(object) = item.downcast_ref::<SidebarObject>() {
        return Some(object.name());
    }
    item.downcast_ref::<TreeNode>().map(TreeNode::title)
}

/// Where `node` is in `store` at or after `from`.
fn position_in(store: &gio::ListStore, node: &TreeNode, from: u32) -> Option<u32> {
    (from..store.n_items()).find(|&at| store.item(at).as_ref() == Some(node.upcast_ref::<glib::Object>()))
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
    } else if node.connecting() {
        // A connect beside the open sessions can wait for a host that
        // never answers, so it stops here.
        session.append(
            Some(&crate::i18n::gettext("Stop Connecting")),
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
    let menu = gio::SimpleAction::new(CONTEXT_MENU, None);
    let view = Rc::downgrade(inner);
    menu.connect_activate(move |_, _| {
        if let Some(view) = view.upgrade() {
            view.popup_keyboard_menu();
        }
    });
    actions.add_action(&menu);
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
    inner
        .list_view
        .add_controller(local_shortcut_controller(ShortcutOwner::ConnectionTree));
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
    if let Some(view) = view.upgrade() {
        view.bindings.borrow_mut().insert(item.clone(), Vec::new());
    }
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

fn connection_icon_name(node: &TreeNode) -> String {
    let fallback = if node.file_based() {
        crate::ui::icons::DRIVE_HARDDISK
    } else {
        crate::ui::icons::NETWORK_SERVER
    };
    node.connection_icon()
        .map_or(fallback, crate::ui::icons::connection_icon)
        .to_owned()
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
    let bindings = vec![
        node.bind_property("appearance", &parts.label, "label")
            .transform_to(|binding, _: u32| binding.source().and_downcast::<TreeNode>().map(|node| node.title()))
            .sync_create()
            .build(),
        node.bind_property("appearance", &parts.icon, "icon-name")
            .transform_to(|binding, _: u32| {
                binding
                    .source()
                    .and_downcast::<TreeNode>()
                    .map(|node| connection_icon_name(&node))
            })
            .sync_create()
            .build(),
        node.bind_property("appearance", &parts.icon, "css-classes")
            .transform_to(|binding, _: u32| {
                let color = binding
                    .source()
                    .and_downcast::<TreeNode>()
                    .and_then(|node| node.color());
                Some(
                    color
                        .map(|color| vec![crate::ui::connection_appearance::color_class(color).to_owned()])
                        .unwrap_or_default(),
                )
            })
            .sync_create()
            .build(),
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

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use tablepro_core::DriverRegistry;
    use tablepro_core::meta::{ObjectInfo, ObjectKind, SchemaInfo, TableRef};
    use tablepro_storage::{ConnectionGroupName, ConnectionStore, SavedConnection, StoragePaths};

    use super::super::SidebarAffordances;
    use super::*;
    use crate::test_support::wait_until;

    const WAIT: Duration = Duration::from_secs(10);

    fn connection(name: &str, group: Option<&str>) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: name.to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db".to_owned(),
            port: 5432,
            database: "app".to_owned(),
            username: "postgres".to_owned(),
            tls: tablepro_core::TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: group.map(|group| ConnectionGroupName::new(group).expect("a group name")),
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    /// A tree over a store holding `connections`, and the directory the
    /// store writes to.
    fn tree_of(connections: &[SavedConnection]) -> (tempfile::TempDir, ConnectionTree) {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let store = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
        let list = SavedConnectionList::follow(&store, Arc::new(DriverRegistry::new()));
        for saved in connections {
            store.upsert_blocking(saved.clone()).expect("save the connection");
        }
        wait_until(WAIT, || list.model().n_items() as usize == connections.len()).expect("the list to have them");
        (dir, ConnectionTree::new(list))
    }

    /// A session's sidebar listing `tables`, each a schema and a name.
    fn session_view(tables: &[(&str, &str)]) -> SidebarView {
        let objects: Vec<ObjectInfo> = tables
            .iter()
            .map(|(schema, name)| ObjectInfo {
                schema: Some((*schema).to_owned()),
                name: (*name).to_owned(),
                kind: ObjectKind::Table,
            })
            .collect();
        let mut schemas: Vec<SchemaInfo> = tables
            .iter()
            .map(|(schema, _)| SchemaInfo {
                name: (*schema).to_owned(),
                is_default: *schema == "public",
                is_system: false,
            })
            .collect();
        schemas.dedup_by(|left, right| left.name == right.name);
        let view = SidebarView::new(|_| {}, SidebarAffordances::default(), None);
        view.apply_objects(&objects, &schemas);
        view
    }

    #[gtk4::test]
    fn a_search_hides_the_connections_and_groups_it_does_not_find() {
        let (_dir, tree) = tree_of(&[
            connection("Alpha", Some("Work")),
            connection("Beta", None),
            connection("Gamma", Some("Home")),
        ]);
        let entry = gtk::SearchEntry::new();
        tree.follow_search(&entry);
        assert_eq!(tree.shown_rows(), ["Home", "Work", "Beta"]);

        entry.set_text("ALP");
        wait_until(WAIT, || tree.shown_rows() == ["Work", "Alpha"]).expect("only Alpha, in its group opened");
        assert!(!tree.says_nothing_found());

        entry.set_text("nothing like it");
        wait_until(WAIT, || tree.says_nothing_found()).expect("the tree to say nothing was found");
        assert!(tree.shown_rows().is_empty());

        entry.set_text("");
        wait_until(WAIT, || tree.shown_rows() == ["Home", "Work", "Beta"])
            .expect("every row back, the groups folded as before the search");
        assert!(!tree.says_nothing_found());
    }

    #[gtk4::test]
    fn a_search_keeps_a_connection_whose_tables_it_finds() {
        let alpha = connection("Alpha", None);
        let (_dir, tree) = tree_of(&[alpha.clone(), connection("Beta", None)]);
        let view = session_view(&[("public", "orders"), ("public", "users")]);
        tree.add_session(&SessionKey::Saved(alpha.id), "Alpha", &view);
        let entry = gtk::SearchEntry::new();
        tree.follow_search(&entry);
        view.follow_search(&entry);
        assert_eq!(tree.shown_rows(), ["Alpha", "public", "orders", "users", "Beta"]);

        entry.set_text("ord");

        wait_until(WAIT, || tree.shown_rows() == ["Alpha", "public", "orders"])
            .expect("Alpha by its table, and Beta hidden");
    }

    #[gtk4::test]
    fn a_session_joining_under_a_search_lists_only_what_it_finds() {
        let alpha = connection("Alpha", None);
        let (_dir, tree) = tree_of(&[alpha.clone(), connection("Beta", None)]);
        let entry = gtk::SearchEntry::new();
        tree.follow_search(&entry);
        entry.set_text("ord");
        wait_until(WAIT, || tree.says_nothing_found()).expect("no connection named so");

        let view = session_view(&[("public", "orders"), ("public", "users")]);
        view.follow_search(&entry);
        tree.add_session(&SessionKey::Saved(alpha.id), "Alpha", &view);

        wait_until(WAIT, || tree.shown_rows() == ["Alpha", "public", "orders"])
            .expect("the new session's tables filtered by the search at once");
        assert!(!tree.says_nothing_found());
    }

    #[gtk4::test]
    fn the_tree_selects_the_table_in_front_or_its_connection() {
        let alpha = connection("Alpha", Some("Work"));
        let (_dir, tree) = tree_of(&[alpha.clone(), connection("Beta", None)]);
        let view = session_view(&[("public", "orders"), ("public", "users"), ("sales", "leads")]);
        let key = SessionKey::Saved(alpha.id);
        tree.add_session(&key, "Alpha", &view);

        tree.select(&key, None);
        assert_eq!(
            tree.selected_row().as_deref(),
            Some("Alpha"),
            "the group was not opened to the connection"
        );

        let users = view
            .object_of(&TableRef::new(Some("public".to_owned()), "users"))
            .expect("the users row");
        tree.select(&key, Some(&users));
        assert_eq!(tree.selected_row().as_deref(), Some("users"));
        assert!(tree.shown_rows().contains(&"users".to_owned()));

        tree.select(&SessionKey::Saved(Uuid::new_v4()), None);
        assert_eq!(
            tree.selected_row(),
            None,
            "a connection the tree lacks kept a row selected"
        );
    }
}
