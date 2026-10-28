//! The window's sidebar: the saved connections in their groups, and
//! under each connection open in the window its schemas and their
//! tables. A search shows what it finds in a second list of the same
//! shape, so the tree's own rows stay open or folded as the user left
//! them, and clearing the search shows them as they were.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::{Rc, Weak};

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, gio, glib, graphene};
use libadwaita as adw;
use tablepro_core::meta::TableRef;
use tablepro_session::SessionKey;

use super::object_key::ObjectKey;
use super::sidebar_menu::{GROUP, object_menu, schema_menu};
use super::sidebar_object::SidebarObject;
use super::sidebar_view::{Holds, RowsObserverId, SidebarView};
use super::store_sync;
use super::tree_menu::{InWindow, SHOW_SESSION, session_section};
use super::tree_node::{NodeKind, TreeNode};
use super::tree_row::TreeRow;
use crate::application::{ShortcutOwner, local_shortcut_controller};
use crate::services::connection_search::ConnectionSearch;
use crate::services::saved_connection_list::{SavedConnectionList, StateObserverId};
use crate::services::saved_connection_object::SavedConnectionObject;
use crate::services::saved_connection_order;

/// The tree's own action: the menu of the row the keyboard is on.
const TREE: &str = "tree";
const CONTEXT_MENU: &str = "context-menu";

const TREE_PAGE: &str = "tree";
const FOUND_PAGE: &str = "found";
const NOTHING_PAGE: &str = "nothing";

/// How an open session is doing, as its connection's row shows it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) enum SessionRowState {
    #[default]
    Ready,
    /// Reconnecting, or otherwise at work for a while.
    Busy,
    /// Lost or failing, and why.
    Trouble(String),
}

#[derive(Clone)]
pub(crate) struct ConnectionTree {
    pub(super) inner: Rc<TreeInner>,
}

/// One list over the tree, or over what the search finds.
pub(super) struct Pane {
    pub(super) list_view: gtk::ListView,
    pub(super) selection: gtk::SingleSelection,
    pub(super) model: gtk::TreeListModel,
}

/// Which of the two lists.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Which {
    Tree,
    Found,
}

pub(super) struct TreeInner {
    pub(super) root: gtk::Stack,
    pub(super) tree: Pane,
    pub(super) found: Pane,
    /// The roots the search finds, over `roots` only while there is a
    /// search.
    found_roots: gtk::FilterListModel,
    /// Which connections the search finds, and the groups holding them.
    matches: gtk::CustomFilter,
    pub(super) popover: gtk::PopoverMenu,
    /// The connections in no group, then the groups, then the
    /// connections the window holds that no saved connection names.
    roots: gio::ListStore,
    /// Each group's node, by its name as the user wrote it: groups that
    /// differ only in case are two, as in the picker.
    groups: RefCell<HashMap<String, TreeNode>>,
    /// Every connection's node, which keeps its row whatever the list
    /// does around it.
    nodes: RefCell<HashMap<SessionKey, TreeNode>>,
    branches: RefCell<HashMap<SessionKey, Branch>>,
    /// The connects the window runs, with the names they show under.
    connects: RefCell<HashMap<SessionKey, String>>,
    /// Why each key's last connect failed, until its next one.
    failures: RefCell<HashMap<SessionKey, String>>,
    saved: Rc<SavedConnectionList>,
    saved_watch: Cell<Option<StateObserverId>>,
    /// The search as typed, trimmed; empty for none.
    query: RefCell<String>,
    search: RefCell<ConnectionSearch>,
    search_watch: RefCell<Option<(glib::WeakRef<gtk::SearchEntry>, glib::SignalHandlerId)>>,
    /// The table of the tab in front, or its session, which the
    /// selection follows.
    followed: RefCell<Option<Followed>>,
    /// The table a middle press went down on. A new list can bind its
    /// row to another table before the release.
    middle: RefCell<Option<(SessionKey, TableRef)>>,
}

/// An open session's part of the tree.
struct Branch {
    view: SidebarView,
    observer: RowsObserverId,
    state: SessionRowState,
    /// The lone schema the tree opened, so a lone schema opens once, as
    /// it comes: its row says nothing the connection's does not.
    lone: Option<TreeNode>,
}

/// What the selection follows, and whether its row is still to be
/// opened and scrolled to: its list was not read yet, or the row's
/// parents were never opened.
#[derive(Clone)]
struct Followed {
    key: SessionKey,
    table: Option<TableRef>,
    unrevealed: bool,
}

impl ConnectionTree {
    pub(crate) fn new(saved: Rc<SavedConnectionList>) -> Self {
        let inner = Rc::new_cyclic(|tree: &Weak<TreeInner>| {
            let finding = tree.clone();
            let matches = gtk::CustomFilter::new(move |item| finding.upgrade().is_some_and(|tree| tree.finds(item)));
            let roots = gio::ListStore::new::<TreeNode>();
            let found_roots = gtk::FilterListModel::new(None::<gio::ListModel>, Some(matches.clone()));
            let tree_pane = Pane::new(tree_model(&roots), &crate::i18n::gettext("Connections"));
            let found_pane = Pane::new(
                found_model(&found_roots, &matches),
                &crate::i18n::gettext("Search Results"),
            );
            let root = pages(&tree_pane, &found_pane);
            let popover = gtk::PopoverMenu::from_model(None::<&gio::MenuModel>);
            popover.set_has_arrow(true);
            popover.set_parent(&root);
            TreeInner {
                root,
                tree: tree_pane,
                found: found_pane,
                found_roots,
                matches,
                popover,
                roots,
                groups: RefCell::new(HashMap::new()),
                nodes: RefCell::new(HashMap::new()),
                branches: RefCell::new(HashMap::new()),
                connects: RefCell::new(HashMap::new()),
                failures: RefCell::new(HashMap::new()),
                saved,
                saved_watch: Cell::new(None),
                query: RefCell::new(String::new()),
                search: RefCell::new(ConnectionSearch::default()),
                search_watch: RefCell::new(None),
                followed: RefCell::new(None),
                middle: RefCell::new(None),
            }
        });
        for which in [Which::Tree, Which::Found] {
            connect_pane(&inner, which);
        }
        install_actions(&inner);
        // One rebuild per list the store publishes: a write patches the
        // list a step at a time, and a step can hold a connection twice.
        let tree = Rc::downgrade(&inner);
        let watch = inner.saved.connect_state_changed(move |_| {
            if let Some(tree) = tree.upgrade() {
                tree.rebuild();
            }
        });
        inner.saved_watch.set(Some(watch));
        inner.rebuild();
        Self { inner }
    }

    pub(crate) fn widget(&self) -> gtk::Widget {
        self.inner.root.clone().upcast()
    }

    /// Search as the user types in `entry`, and for what it holds now:
    /// the connections it finds, and the tables each open session finds.
    pub(crate) fn follow_search(&self, entry: &gtk::SearchEntry) {
        let tree = Rc::downgrade(&self.inner);
        let handler = entry.connect_search_changed(move |entry| {
            if let Some(tree) = tree.upgrade() {
                tree.apply_query(&entry.text());
            }
        });
        let previous = self.inner.search_watch.replace(Some((entry.downgrade(), handler)));
        if let Some((entry, handler)) = previous
            && let Some(entry) = entry.upgrade()
        {
            entry.disconnect(handler);
        }
        self.inner.apply_query(&entry.text());
    }

    /// The session under `key` joined the window: its row lists its
    /// schemas, and opens once, on them. `title` names a session no saved
    /// connection describes.
    pub(crate) fn add_session(&self, key: &SessionKey, title: &str, sidebar: &SidebarView) {
        let inner = &self.inner;
        let node = inner.node_for(key, title);
        if inner.saved_name(key).is_none() && node.title() != title {
            node.set_title(title);
        }
        node.set_branches(Some(sidebar.rows()), Some(sidebar.found_rows()));
        let tree = Rc::downgrade(inner);
        let shown = key.clone();
        let observer = sidebar.connect_rows_shown(move || {
            if let Some(tree) = tree.upgrade() {
                tree.on_rows_shown(&shown);
            }
        });
        let replaced = inner.branches.borrow_mut().insert(
            key.clone(),
            Branch {
                view: sidebar.clone(),
                observer,
                state: SessionRowState::Ready,
                lone: None,
            },
        );
        if let Some(replaced) = replaced {
            replaced.view.disconnect_rows_shown(replaced.observer);
        }
        inner.refresh_state(key);
        inner.reinsert(&node);
        inner.rebuild();
        inner.reveal(&node);
        inner.tell_search(key);
        inner.on_rows_shown(key);
    }

    /// The session under `key` left the window: its row lists nothing.
    pub(crate) fn remove_session(&self, key: &SessionKey) {
        let inner = &self.inner;
        let Some(branch) = inner.branches.borrow_mut().remove(key) else {
            return;
        };
        branch.view.disconnect_rows_shown(branch.observer);
        let node = inner.nodes.borrow().get(key).cloned();
        if let Some(node) = &node {
            node.set_branches(None, None);
        }
        inner.refresh_state(key);
        if let Some(node) = &node {
            inner.reinsert(node);
        }
        let followed = inner
            .followed
            .borrow()
            .as_ref()
            .is_some_and(|followed| &followed.key == key);
        if followed {
            inner.followed.replace(None);
        }
        inner.rebuild();
    }

    /// The connects the window runs now, each with the name its row
    /// shows when no saved connection names it.
    pub(crate) fn set_connects(&self, connects: &[(SessionKey, String)]) {
        let inner = &self.inner;
        for (key, name) in connects {
            inner.node_for(key, name);
        }
        let running: HashMap<SessionKey, String> = connects.iter().cloned().collect();
        let before = inner.connects.replace(running);
        for key in before.keys().chain(connects.iter().map(|(key, _)| key)) {
            inner.refresh_state(key);
        }
        inner.rebuild();
    }

    /// Why the last connect of `key` failed, or `None` once another
    /// starts.
    pub(crate) fn set_failure(&self, key: &SessionKey, reason: Option<&str>) {
        let inner = &self.inner;
        match reason {
            Some(reason) => {
                inner.failures.borrow_mut().insert(key.clone(), reason.to_owned());
            }
            None => {
                if inner.failures.borrow_mut().remove(key).is_none() {
                    return;
                }
            }
        }
        inner.refresh_state(key);
        inner.rebuild();
    }

    pub(crate) fn set_session_state(&self, key: &SessionKey, state: SessionRowState) {
        let inner = &self.inner;
        match inner.branches.borrow_mut().get_mut(key) {
            Some(branch) => branch.state = state,
            None => return,
        }
        inner.refresh_state(key);
    }

    /// Select the row of `table` under the session `key`, opening the
    /// rows above it, or the connection's row when the tab in front
    /// shows no table or the tree does not list it; with no session in
    /// front, no row. The rows open only when the tab in front changes,
    /// so a row the user folded stays folded while the tab stays. The
    /// keyboard stays in the tab.
    pub(crate) fn select(&self, key: Option<&SessionKey>, table: Option<&TableRef>) {
        let inner = &self.inner;
        let Some(key) = key else {
            inner.followed.replace(None);
            inner.unselect(&inner.tree);
            inner.unselect(&inner.found);
            return;
        };
        let same =
            inner.followed.borrow().as_ref().is_some_and(|followed| {
                &followed.key == key && followed.table.as_ref() == table && !followed.unrevealed
            });
        let shown = inner.show_selection(key, table, !same);
        // A row it could not reveal is revealed once its list lands; one
        // the user folded since stays folded.
        inner.followed.replace(Some(Followed {
            key: key.clone(),
            table: table.cloned(),
            unrevealed: !same && !shown,
        }));
    }

    pub(crate) fn shutdown(&self) {
        let inner = &self.inner;
        if let Some(watch) = inner.saved_watch.take() {
            inner.saved.disconnect_state_changed(watch);
        }
        if let Some((entry, handler)) = inner.search_watch.take()
            && let Some(entry) = entry.upgrade()
        {
            entry.disconnect(handler);
        }
        inner.popover.popdown();
        if inner.popover.parent().is_some() {
            inner.popover.unparent();
        }
        let branches: Vec<Branch> = inner.branches.take().into_values().collect();
        for branch in branches {
            branch.view.disconnect_rows_shown(branch.observer);
        }
        inner.followed.replace(None);
        inner.found_roots.set_model(None::<&gio::ListModel>);
    }
}

impl Pane {
    fn new(model: gtk::TreeListModel, label: &str) -> Self {
        let selection = gtk::SingleSelection::new(Some(model.clone()));
        selection.set_autoselect(false);
        selection.set_can_unselect(true);
        let list_view = gtk::ListView::new(Some(selection.clone()), None::<gtk::ListItemFactory>);
        list_view.add_css_class("navigation-sidebar");
        // A click opens a table or a connection, as the picker's rows
        // do; Enter and a double click reach the same activate.
        list_view.set_single_click_activate(true);
        list_view.update_property(&[gtk::accessible::Property::Label(label)]);
        Self {
            list_view,
            selection,
            model,
        }
    }
}

impl TreeInner {
    fn pane(&self, which: Which) -> &Pane {
        match which {
            Which::Tree => &self.tree,
            Which::Found => &self.found,
        }
    }

    fn searching(&self) -> bool {
        !self.query.borrow().is_empty()
    }

    /// The list on screen.
    fn shown(&self) -> Which {
        if self.searching() { Which::Found } else { Which::Tree }
    }

    fn view_of(&self, key: &SessionKey) -> Option<SidebarView> {
        self.branches.borrow().get(key).map(|branch| branch.view.clone())
    }

    fn saved_name(&self, key: &SessionKey) -> Option<String> {
        match key {
            SessionKey::Saved(id) => self.saved.get(*id).map(|saved| saved.name),
            SessionKey::File(_) => None,
        }
    }

    /// The node of the connection under `key`, made under `title` for a
    /// key the tree has not seen.
    fn node_for(&self, key: &SessionKey, title: &str) -> TreeNode {
        self.nodes
            .borrow_mut()
            .entry(key.clone())
            .or_insert_with(|| TreeNode::connection(key.clone(), title))
            .clone()
    }

    /// Whether the window holds `key` though no saved connection may
    /// name it: open, connecting, or failed to connect.
    fn holds(&self, key: &SessionKey) -> bool {
        self.branches.borrow().contains_key(key)
            || self.connects.borrow().contains_key(key)
            || self.failures.borrow().contains_key(key)
    }

    fn refresh_state(&self, key: &SessionKey) {
        let Some(node) = self.nodes.borrow().get(key).cloned() else {
            return;
        };
        let state = self.branches.borrow().get(key).map(|branch| branch.state.clone());
        let connecting = self.connects.borrow().contains_key(key);
        let busy = connecting || state == Some(SessionRowState::Busy);
        let problem = match &state {
            Some(SessionRowState::Trouble(reason)) => reason.clone(),
            Some(_) => String::new(),
            None => self.failures.borrow().get(key).cloned().unwrap_or_default(),
        };
        node.update_state(state.is_some(), busy, &problem);
    }

    /// Lay the roots out again from the saved connections as the store
    /// published them, keeping every node, so the rows that stay keep
    /// their place, and a row that moves opens again as it was.
    fn rebuild(&self) {
        let open = self.open_rows();
        let model = self.saved.model();
        let mut listed: Vec<(tablepro_storage::SavedConnection, bool)> = (0..model.n_items())
            .filter_map(|at| model.item(at).and_downcast::<SavedConnectionObject>())
            .filter_map(|object| Some((object.saved()?.clone(), object.file_based())))
            .collect();
        listed.sort_by(|left, right| saved_connection_order::by_name(&left.0, &right.0));
        let mut ungrouped: Vec<TreeNode> = Vec::new();
        let mut grouped: Vec<(String, Vec<TreeNode>)> = Vec::new();
        let mut kept: HashSet<SessionKey> = HashSet::new();
        for (saved, file_based) in &listed {
            let key = SessionKey::Saved(saved.id);
            let node = self.node_for(&key, &saved.name);
            node.update(
                &saved.name,
                connection_icon(saved.icon, *file_based),
                saved.color.map_or("", crate::ui::connection_appearance::color_class),
            );
            kept.insert(key);
            match &saved.group {
                None => ungrouped.push(node),
                Some(group) => match grouped.last_mut() {
                    Some((name, members)) if *name == group.as_str() => members.push(node),
                    _ => grouped.push((group.as_str().to_owned(), vec![node])),
                },
            }
        }
        let held: Vec<(SessionKey, TreeNode)> = self
            .nodes
            .borrow()
            .iter()
            .filter(|(key, _)| !kept.contains(*key))
            .map(|(key, node)| (key.clone(), node.clone()))
            .collect();
        let mut others: Vec<TreeNode> = Vec::new();
        for (key, node) in held {
            if self.holds(&key) {
                if node.icon_name().is_empty() {
                    let file = matches!(key, SessionKey::File(_));
                    node.update(&node.title(), connection_icon(None, file), "");
                }
                others.push(node);
            } else {
                self.nodes.borrow_mut().remove(&key);
            }
        }
        others.sort_by_cached_key(|node| (node.title().to_lowercase(), node.title()));
        let group_nodes: Vec<TreeNode> = {
            let mut groups = self.groups.borrow_mut();
            groups.retain(|name, _| grouped.iter().any(|(held, _)| held == name));
            grouped
                .iter()
                .map(|(name, _)| {
                    groups
                        .entry(name.clone())
                        .or_insert_with(|| TreeNode::group(name))
                        .clone()
                })
                .collect()
        };
        for (group, (_, members)) in group_nodes.iter().zip(&grouped) {
            if let Some(store) = group.child_store() {
                store_sync::sync(&store, members);
            }
        }
        let desired: Vec<TreeNode> = ungrouped.into_iter().chain(group_nodes).chain(others).collect();
        store_sync::sync(&self.roots, &desired);
        self.reopen(&open);
        if self.searching() {
            // A group shows by its connections, which this may have moved.
            self.matches.changed(gtk::FilterChange::Different);
            self.expand_found();
        }
        self.refresh_page();
        self.reselect();
    }

    /// Take `node` out and put it back where it is: whether a
    /// connection's row lists anything is read as the row is made.
    fn reinsert(&self, node: &TreeNode) {
        let store = if index_in(&self.roots, node).is_some() {
            Some(self.roots.clone())
        } else {
            self.group_of(node).and_then(|group| group.child_store())
        };
        if let Some(store) = store
            && let Some(at) = index_in(&store, node)
        {
            store.remove(at);
            store.insert(at, node);
        }
    }

    fn group_of(&self, node: &TreeNode) -> Option<TreeNode> {
        self.groups
            .borrow()
            .values()
            .find(|group| {
                group
                    .child_store()
                    .is_some_and(|store| index_in(&store, node).is_some())
            })
            .cloned()
    }

    /// Open the row of a connection that joined, and its group's.
    fn reveal(&self, node: &TreeNode) {
        if let Some(row) = self.connection_row(Which::Tree, node, true) {
            expand(&row);
        }
    }

    /// The nodes whose rows are open in the tree, above the tables.
    fn open_rows(&self) -> HashSet<TreeNode> {
        let mut open = HashSet::new();
        let mut rows = top_rows(&self.tree.model);
        while let Some(row) = rows.pop() {
            if !row.is_expanded() {
                continue;
            }
            let Some(node) = row.item().and_downcast::<TreeNode>() else {
                continue;
            };
            if node.kind() != NodeKind::Schema {
                rows.extend(child_rows(&row));
            }
            open.insert(node);
        }
        open
    }

    /// Open again each of `open`'s rows that a move took out and put back.
    fn reopen(&self, open: &HashSet<TreeNode>) {
        if open.is_empty() {
            return;
        }
        let mut rows = top_rows(&self.tree.model);
        while let Some(row) = rows.pop() {
            let Some(node) = row.item().and_downcast::<TreeNode>() else {
                continue;
            };
            if !open.contains(&node) {
                continue;
            }
            expand(&row);
            if node.kind() != NodeKind::Schema {
                rows.extend(child_rows(&row));
            }
        }
    }

    /// A list or a search's rows landed for the session `key`.
    fn on_rows_shown(&self, key: &SessionKey) {
        self.open_lone_schema(key);
        if self.searching() {
            self.matches.changed(gtk::FilterChange::Different);
            self.expand_found();
        }
        self.refresh_page();
        self.reselect();
    }

    /// A lone schema, as a file or a key-value engine has, opens as it
    /// comes, while its connection's row is open.
    fn open_lone_schema(&self, key: &SessionKey) {
        let Some(view) = self.view_of(key) else {
            return;
        };
        let schemas = view.schemas();
        let lone = (schemas.n_items() == 1)
            .then(|| schemas.item(0).and_downcast::<TreeNode>())
            .flatten();
        {
            let mut branches = self.branches.borrow_mut();
            let Some(branch) = branches.get_mut(key) else {
                return;
            };
            if branch.lone == lone {
                return;
            }
            branch.lone.clone_from(&lone);
        }
        let (Some(schema), Some(node)) = (lone, self.nodes.borrow().get(key).cloned()) else {
            return;
        };
        if let Some(connection) = self.connection_row(Which::Tree, &node, false)
            && connection.is_expanded()
            && let Some(row) = child_row(&connection, &schema)
        {
            expand(&row);
        }
    }

    /// Search for `text`: the connections it finds, and each session's
    /// tables. A key-value engine's server matches its keys, so it is
    /// asked only while its branch is open in the tree.
    fn apply_query(&self, text: &str) {
        let text = text.trim();
        if *self.query.borrow() == text {
            return;
        }
        let was = self.searching();
        self.query.replace(text.to_owned());
        self.search.replace(ConnectionSearch::new(text));
        match (was, self.searching()) {
            (false, true) => self.found_roots.set_model(Some(&self.roots)),
            (true, false) => self.found_roots.set_model(None::<&gio::ListModel>),
            (true, true) => self.matches.changed(gtk::FilterChange::Different),
            (false, false) => {}
        }
        let keys: Vec<SessionKey> = self.branches.borrow().keys().cloned().collect();
        for key in &keys {
            self.tell_search(key);
        }
        if self.searching() {
            self.expand_found();
        }
        self.refresh_page();
        self.reselect();
    }

    fn tell_search(&self, key: &SessionKey) {
        let Some(view) = self.view_of(key) else {
            return;
        };
        let query = self.query.borrow().clone();
        if view.holds() == Holds::Keys && !self.follows(key) {
            view.set_query("");
        } else {
            view.set_query(&query);
        }
    }

    /// Whether the session's branch is open in the tree.
    fn follows(&self, key: &SessionKey) -> bool {
        let Some(node) = self.nodes.borrow().get(key).cloned() else {
            return false;
        };
        self.connection_row(Which::Tree, &node, false)
            .is_some_and(|row| row.is_expanded())
    }

    /// Whether the search finds `item`: a connection it names, or whose
    /// session lists tables it finds, and a group holding such a one.
    fn finds(&self, item: &glib::Object) -> bool {
        let Some(node) = item.downcast_ref::<TreeNode>() else {
            return true;
        };
        match node.kind() {
            NodeKind::Group => node.child_store().is_some_and(|store| {
                (0..store.n_items())
                    .filter_map(|at| store.item(at).and_downcast::<TreeNode>())
                    .any(|connection| self.finds_connection(&connection))
            }),
            NodeKind::Connection => self.finds_connection(node),
            NodeKind::Schema | NodeKind::Placeholder => true,
        }
    }

    fn finds_connection(&self, node: &TreeNode) -> bool {
        let Some(key) = node.key() else {
            return false;
        };
        let named = {
            let search = self.search.borrow();
            match &key {
                SessionKey::Saved(id) => match self.saved.get(*id) {
                    Some(saved) => search.matches(&saved, &self.saved.tags()),
                    None => search.matches_name(&node.title()),
                },
                SessionKey::File(_) => search.matches_name(&node.title()),
            }
        };
        named
            || self
                .view_of(&key)
                .is_some_and(|view| view.found_schemas().n_items() > 0)
    }

    /// Open every row the search shows down to the schemas, so what it
    /// found is in view.
    fn expand_found(&self) {
        let mut rows = top_rows(&self.found.model);
        while let Some(row) = rows.pop() {
            let Some(node) = row.item().and_downcast::<TreeNode>() else {
                continue;
            };
            match node.kind() {
                NodeKind::Group | NodeKind::Connection if row.is_expandable() => {
                    expand(&row);
                    rows.extend(child_rows(&row));
                }
                NodeKind::Schema => expand(&row),
                _ => {}
            }
        }
    }

    /// Whether every session shows the rows last asked for, so an empty
    /// result is the search's answer, not one still on its way.
    fn settled(&self) -> bool {
        self.branches.borrow().values().all(|branch| branch.view.settled())
    }

    fn refresh_page(&self) {
        let page = if !self.searching() {
            TREE_PAGE
        } else if self.found_roots.n_items() == 0 && self.settled() {
            NOTHING_PAGE
        } else {
            FOUND_PAGE
        };
        if self.root.visible_child_name().as_deref() != Some(page) {
            self.root.set_visible_child_name(page);
        }
    }

    /// The row of the connection `node` in `which` list, among the roots
    /// or in its group; `open` opens the group to show it.
    fn connection_row(&self, which: Which, node: &TreeNode, open: bool) -> Option<gtk::TreeListRow> {
        let model = &self.pane(which).model;
        if let Some(at) = index_in(&model.model(), node) {
            return model.child_row(at);
        }
        let group = self.group_of(node)?;
        let row = model.child_row(index_in(&model.model(), &group)?)?;
        if open {
            expand(&row);
        }
        child_row(&row, node)
    }

    /// The row of `table` under the open connection's `connection` row,
    /// opening the rows above it when `open`.
    fn table_row(
        &self,
        which: Which,
        key: &SessionKey,
        connection: &gtk::TreeListRow,
        table: &TableRef,
        open: bool,
    ) -> Option<gtk::TreeListRow> {
        let view = self.view_of(key)?;
        let (schema, offset) = match which {
            Which::Tree => view.locate(table),
            Which::Found => view.locate_found(table),
        }?;
        if open {
            expand(connection);
        }
        let schema = child_row(connection, &schema)?;
        if open {
            expand(&schema);
        }
        schema.child_row(offset)
    }

    /// Select the row of `table`, or of the session's connection, in the
    /// list on screen. `reveal` opens the rows above it and scrolls to
    /// it. True when the row selected is the one asked for.
    fn show_selection(&self, key: &SessionKey, table: Option<&TableRef>, reveal: bool) -> bool {
        let which = self.shown();
        let pane = self.pane(which);
        let node = self.nodes.borrow().get(key).cloned();
        let Some(connection) = node.and_then(|node| self.connection_row(which, &node, reveal)) else {
            self.unselect(pane);
            return false;
        };
        let found = table.and_then(|table| self.table_row(which, key, &connection, table, reveal));
        let (position, shown) = match &found {
            Some(row) => (row.position(), true),
            None => (connection.position(), table.is_none()),
        };
        if reveal {
            // Without FOCUS: the keyboard stays in the editor or the grid.
            pane.list_view.scroll_to(position, gtk::ListScrollFlags::SELECT, None);
        } else if pane.selection.selected() != position {
            pane.selection.set_selected(position);
        }
        shown
    }

    /// Select again the row the selection follows, once rows moved or
    /// the pointer left: activation on a single click selects rows on
    /// hover.
    fn reselect(&self) {
        let Some(followed) = self.followed.borrow().clone() else {
            self.unselect(self.pane(self.shown()));
            return;
        };
        let shown = self.show_selection(&followed.key, followed.table.as_ref(), followed.unrevealed);
        if followed.unrevealed
            && shown
            && let Some(followed) = self.followed.borrow_mut().as_mut()
        {
            followed.unrevealed = false;
        }
    }

    fn unselect(&self, pane: &Pane) {
        if pane.selection.selected() != gtk::INVALID_LIST_POSITION {
            pane.selection.set_selected(gtk::INVALID_LIST_POSITION);
        }
    }

    /// A click or Enter: a table opens, a closed connection connects and
    /// an open one comes to the front, and a group or schema opens or
    /// folds. Bringing a connection forward leaves its row as it is.
    fn activate(&self, which: Which, position: u32) {
        let pane = self.pane(which);
        let Some(row) = pane.model.row(position) else {
            return;
        };
        let Some(item) = row.item() else {
            return;
        };
        if let Some(object) = item.downcast_ref::<SidebarObject>() {
            if let Some(view) = owning_key(&row).and_then(|key| self.view_of(&key)) {
                view.open(object.table_ref());
            }
            return;
        }
        let Some(node) = item.downcast_ref::<TreeNode>() else {
            return;
        };
        match node.kind() {
            NodeKind::Connection => activate_connection(&pane.list_view, node),
            NodeKind::Group | NodeKind::Schema => row.set_expanded(!row.is_expanded()),
            NodeKind::Placeholder => {}
        }
    }

    /// A press on a row: the secondary button selects it and opens its
    /// menu, and Ctrl or the middle button opens a table in a new tab.
    /// True when handled, which cancels the row's own click.
    pub(super) fn pressed(
        &self,
        which: Which,
        position: u32,
        button: u32,
        modifiers: gdk::ModifierType,
        pointing: Option<gdk::Rectangle>,
    ) -> bool {
        let pane = self.pane(which);
        let Some(row) = pane.model.row(position) else {
            return false;
        };
        let table = row
            .item()
            .and_downcast::<SidebarObject>()
            .map(|object| object.table_ref());
        match button {
            gdk::BUTTON_SECONDARY => {
                pane.selection.set_selected(position);
                self.popup_menu(&row, pointing);
                true
            }
            gdk::BUTTON_PRIMARY if modifiers.contains(gdk::ModifierType::CONTROL_MASK) => {
                let (Some(table), Some(view)) = (table, owning_key(&row).and_then(|key| self.view_of(&key))) else {
                    return false;
                };
                view.open_in_new_tab(table);
                true
            }
            gdk::BUTTON_MIDDLE => {
                self.middle.replace(owning_key(&row).zip(table));
                false
            }
            _ => false,
        }
    }

    /// A middle click opens the table it was pressed on in a new tab, as
    /// a link does, while its session still lists it.
    pub(super) fn released(&self, button: u32) -> bool {
        if button != gdk::BUTTON_MIDDLE {
            return false;
        }
        let Some((key, table)) = self.middle.take() else {
            return false;
        };
        if let Some(view) = self.view_of(&key)
            && view.lists(&table)
        {
            view.open_in_new_tab(table);
        }
        true
    }

    pub(super) fn popup_menu(&self, row: &gtk::TreeListRow, pointing: Option<gdk::Rectangle>) {
        let Some(menu) = self.menu_for(row) else {
            return;
        };
        self.popover.set_menu_model(Some(&menu));
        self.popover.set_pointing_to(pointing.as_ref());
        self.popover.popup();
    }

    /// The Menu key and Shift+F10: the menu of the row the keyboard is
    /// on, over that row. The selection follows the tab in front, not
    /// the keyboard, so it stands in only when no row has focus.
    fn popup_keyboard_menu(&self) {
        let pane = self.pane(self.shown());
        let (row, expander) = match focused_row(&pane.list_view) {
            Some((row, expander)) => (Some(row), Some(expander)),
            None => {
                let position = pane.selection.selected();
                (pane.model.row(position), bound_expander(&pane.list_view, position))
            }
        };
        let Some(row) = row else {
            return;
        };
        let pointing = expander.and_then(|expander| bounds_in(&expander, &self.root));
        self.popup_menu(&row, pointing);
    }

    /// The menu of a row. The popover reaches the session's table
    /// actions, and a connection's choices, through groups of its own.
    fn menu_for(&self, row: &gtk::TreeListRow) -> Option<gio::Menu> {
        let item = row.item()?;
        if let Some(object) = item.downcast_ref::<SidebarObject>() {
            let view = owning_key(row).and_then(|key| self.view_of(&key))?;
            self.popover.insert_action_group(GROUP, Some(view.actions()));
            return Some(object_menu(
                &ObjectKey(object.table_ref()),
                object.kind(),
                view.affordances(),
            ));
        }
        let node = item.downcast::<TreeNode>().ok()?;
        match node.kind() {
            NodeKind::Schema => {
                let view = owning_key(row).and_then(|key| self.view_of(&key))?;
                self.popover.insert_action_group(GROUP, Some(view.actions()));
                schema_menu(node.schema_name().as_deref(), view.affordances(), view.holds())
            }
            NodeKind::Connection => self.connection_menu(&node),
            NodeKind::Group | NodeKind::Placeholder => None,
        }
    }

    /// The picker's menu for a saved connection, led by what the
    /// connection does in the window.
    fn connection_menu(&self, node: &TreeNode) -> Option<gio::Menu> {
        let key = node.key()?;
        let state = if node.open() {
            InWindow::Open
        } else if self.connects.borrow().contains_key(&key) {
            InWindow::Connecting
        } else {
            InWindow::Closed {
                failed: self.failures.borrow().contains_key(&key),
            }
        };
        let lead = session_section(&key, state);
        let saved = match &key {
            SessionKey::Saved(id) => self.saved.get(*id),
            SessionKey::File(_) => None,
        };
        let Some(saved) = saved else {
            if lead.n_items() == 0 {
                return None;
            }
            let menu = gio::Menu::new();
            menu.append_section(None, &lead);
            return Some(menu);
        };
        let tags = self.saved.tags();
        crate::ui::picker::insert_choice_actions(&self.popover, self.root.upcast_ref(), &saved, &tags);
        Some(crate::ui::picker::connection_menu_with(
            &lead,
            saved.id,
            &self.saved.groups(),
            &tags,
        ))
    }
}

impl Drop for TreeInner {
    fn drop(&mut self) {
        if self.popover.parent().is_some() {
            self.popover.unparent();
        }
    }
}

/// A closed saved connection connects, as its picker row does; an open
/// one comes to the front. One connecting waits.
fn activate_connection(list_view: &gtk::ListView, node: &TreeNode) {
    let Some(key) = node.key() else {
        return;
    };
    let fired = if node.open() {
        list_view.activate_action(SHOW_SESSION, Some(&crate::ui::session_target::to_variant(&key)))
    } else if let SessionKey::Saved(id) = key
        && !node.busy()
    {
        let (action, target) = crate::ui::picker::connect_action(id);
        list_view.activate_action(&action, Some(&target))
    } else {
        return;
    };
    if let Err(error) = fired {
        tracing::warn!(%error, "a connection's row reached no window");
    }
}

/// The tree over `roots`. A closed connection lists nothing, so its row
/// has no expander: activating it connects.
fn tree_model(roots: &gio::ListStore) -> gtk::TreeListModel {
    gtk::TreeListModel::new(roots.clone(), false, false, |item| {
        let node = item.downcast_ref::<TreeNode>()?;
        match node.kind() {
            NodeKind::Connection if !node.open() => None,
            NodeKind::Placeholder => None,
            _ => node.children(),
        }
    })
}

/// What the search finds, in the tree's shape: each group's connections
/// through the same filter as the roots, and each open session's schemas
/// and tables as its search found them.
fn found_model(roots: &gtk::FilterListModel, matches: &gtk::CustomFilter) -> gtk::TreeListModel {
    let matches = matches.clone();
    gtk::TreeListModel::new(roots.clone(), false, false, move |item| {
        let node = item.downcast_ref::<TreeNode>()?;
        match node.kind() {
            NodeKind::Group => {
                Some(gtk::FilterListModel::new(node.children(), Some(matches.clone())).upcast::<gio::ListModel>())
            }
            NodeKind::Connection if node.open() => node.found(),
            NodeKind::Schema => node.found(),
            _ => None,
        }
    })
}

/// The tree, what the search finds, and a page that says it found
/// nothing.
fn pages(tree: &Pane, found: &Pane) -> gtk::Stack {
    let scrolled = |list_view: &gtk::ListView| {
        gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(list_view)
            .build()
    };
    let nothing = adw::StatusPage::builder()
        .icon_name(crate::ui::icons::SYSTEM_SEARCH)
        .title(crate::i18n::gettext("No Results Found"))
        .description(crate::i18n::gettext("Try a different search."))
        .build();
    nothing.add_css_class("compact");
    let root = gtk::Stack::new();
    root.add_named(&scrolled(&tree.list_view), Some(TREE_PAGE));
    root.add_named(&scrolled(&found.list_view), Some(FOUND_PAGE));
    root.add_named(&nothing, Some(NOTHING_PAGE));
    root.set_visible_child_name(TREE_PAGE);
    root
}

fn connect_pane(inner: &Rc<TreeInner>, which: Which) {
    let pane = inner.pane(which);
    pane.list_view
        .set_factory(Some(&row_factory(Rc::downgrade(inner), which)));
    let tree = Rc::downgrade(inner);
    pane.list_view.connect_activate(move |_, position| {
        if let Some(tree) = tree.upgrade() {
            tree.activate(which, position);
        }
    });
    // Activation on a single click selects the row under the pointer, so
    // the selection goes back to the tab in front's row when it leaves.
    let hover = gtk::EventControllerMotion::new();
    let tree = Rc::downgrade(inner);
    hover.connect_leave(move |_| {
        if let Some(tree) = tree.upgrade() {
            tree.reselect();
        }
    });
    pane.list_view.add_controller(hover);
}

fn install_actions(inner: &Rc<TreeInner>) {
    let actions = gio::SimpleActionGroup::new();
    let menu = gio::SimpleAction::new(CONTEXT_MENU, None);
    let tree = Rc::downgrade(inner);
    menu.connect_activate(move |_, _| {
        if let Some(tree) = tree.upgrade() {
            tree.popup_keyboard_menu();
        }
    });
    actions.add_action(&menu);
    inner.root.insert_action_group(TREE, Some(&actions));
    inner
        .root
        .add_controller(local_shortcut_controller(ShortcutOwner::ConnectionTree));
}

/// The ListItem is not focusable, so the keyboard focus is on the
/// expander, whose keys open and fold the row and which says to a screen
/// reader whether it is open.
fn row_factory(tree: Weak<TreeInner>, which: Which) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(move |_, object| {
        let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        item.set_focusable(false);
        let expander = gtk::TreeExpander::new();
        expander.set_indent_for_icon(true);
        expander.set_child(Some(&TreeRow::new(item)));
        expander.add_controller(click_gesture(tree.clone(), which, item));
        item.set_child(Some(&expander));
    });
    factory.connect_bind(|_, object| {
        let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let (Some(expander), Some(row)) = (
            item.child().and_downcast::<gtk::TreeExpander>(),
            item.item().and_downcast::<gtk::TreeListRow>(),
        ) else {
            return;
        };
        expander.set_list_row(Some(&row));
        if let (Some(shown), Some(object)) = (expander.child().and_downcast::<TreeRow>(), row.item()) {
            shown.bind(&object);
        }
    });
    factory.connect_unbind(|_, object| {
        let Some(expander) = object
            .downcast_ref::<gtk::ListItem>()
            .and_then(|item| item.child())
            .and_downcast::<gtk::TreeExpander>()
        else {
            return;
        };
        if let Some(shown) = expander.child().and_downcast::<TreeRow>() {
            shown.unbind();
        }
        expander.set_list_row(None);
    });
    factory
}

/// Button 0, so one gesture sees every button. It claims only what it
/// handles, which cancels the row's own click for that press.
fn click_gesture(tree: Weak<TreeInner>, which: Which, item: &gtk::ListItem) -> gtk::GestureClick {
    let gesture = gtk::GestureClick::new();
    gesture.set_button(0);
    let (pressing, item) = (tree.clone(), item.downgrade());
    gesture.connect_pressed(move |gesture, _, x, y| {
        let (Some(tree), Some(item), Some(widget)) = (pressing.upgrade(), item.upgrade(), gesture.widget()) else {
            return;
        };
        let at = widget.compute_point(&tree.root, &graphene::Point::new(x as f32, y as f32));
        let pointing = at.map(|point| gdk::Rectangle::new(point.x() as i32, point.y() as i32, 1, 1));
        if tree.pressed(
            which,
            item.position(),
            gesture.current_button(),
            gesture.current_event_state(),
            pointing,
        ) {
            gesture.set_state(gtk::EventSequenceState::Claimed);
        }
    });
    gesture.connect_released(move |gesture, _, _, _| {
        if let Some(tree) = tree.upgrade()
            && tree.released(gesture.current_button())
        {
            gesture.set_state(gtk::EventSequenceState::Claimed);
        }
    });
    gesture
}

/// The theme's icon for a connection: the one the user picked, else a
/// file's or a server's.
fn connection_icon(icon: Option<tablepro_storage::ConnectionIcon>, file_based: bool) -> &'static str {
    match icon {
        Some(icon) => crate::ui::icons::connection_icon(icon),
        None if file_based => crate::ui::icons::TEXT_X_GENERIC,
        None => crate::ui::icons::NETWORK_SERVER,
    }
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

/// The row whose expander has the keyboard focus, and the expander.
fn focused_row(list_view: &gtk::ListView) -> Option<(gtk::TreeListRow, gtk::TreeExpander)> {
    let mut widget = list_view.root()?.focus();
    while let Some(current) = widget {
        if let Some(expander) = current.downcast_ref::<gtk::TreeExpander>() {
            return Some((expander.list_row()?, expander.clone()));
        }
        if &current == list_view.upcast_ref::<gtk::Widget>() {
            return None;
        }
        widget = current.parent();
    }
    None
}

/// The expander of the row at `position`, when it is bound.
fn bound_expander(list_view: &gtk::ListView, position: u32) -> Option<gtk::TreeExpander> {
    let mut child = list_view.first_child();
    while let Some(widget) = child {
        if let Some(expander) = widget.first_child().and_downcast::<gtk::TreeExpander>()
            && expander.list_row().is_some_and(|row| row.position() == position)
        {
            return Some(expander);
        }
        child = widget.next_sibling();
    }
    None
}

fn bounds_in(widget: &impl IsA<gtk::Widget>, target: &impl IsA<gtk::Widget>) -> Option<gdk::Rectangle> {
    widget.compute_bounds(target).map(|bounds| {
        gdk::Rectangle::new(
            bounds.x() as i32,
            bounds.y() as i32,
            bounds.width() as i32,
            bounds.height() as i32,
        )
    })
}

fn top_rows(tree: &gtk::TreeListModel) -> Vec<gtk::TreeListRow> {
    let count = tree.model().n_items();
    (0..count).filter_map(|position| tree.child_row(position)).collect()
}

/// The rows under an open row, which never holds a schema's tables when
/// walked from the roots.
fn child_rows(row: &gtk::TreeListRow) -> Vec<gtk::TreeListRow> {
    let count = row.children().map_or(0, |children| children.n_items());
    (0..count).filter_map(|position| row.child_row(position)).collect()
}

/// The row of `node` among the children of the open row `parent`.
fn child_row(parent: &gtk::TreeListRow, node: &TreeNode) -> Option<gtk::TreeListRow> {
    let position = index_in(&parent.children()?, node)?;
    parent.child_row(position)
}

fn expand(row: &gtk::TreeListRow) {
    if !row.is_expanded() {
        row.set_expanded(true);
    }
}

/// Where `object` is in `model`: the roots, a group's connections or a
/// connection's schemas, never a schema's tables.
fn index_in(model: &impl IsA<gio::ListModel>, object: &impl IsA<glib::Object>) -> Option<u32> {
    let object = object.upcast_ref::<glib::Object>();
    (0..model.n_items()).find(|&at| model.item(at).as_ref() == Some(object))
}
