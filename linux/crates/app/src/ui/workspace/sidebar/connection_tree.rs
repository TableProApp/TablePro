//! The window's sidebar: the saved connections in their groups, and
//! under each connection open in the window its schemas and their
//! tables. A search shows what it finds in a flat list beside the tree,
//! a section for the connections it names and one for each schema it
//! finds tables in, so the tree's own rows stay open or folded as the
//! user left them, and clearing the search shows them as they were. The
//! flat list makes objects only for the rows on screen, which a tree
//! cannot: GtkTreeListModel reads every child of a row it opens.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::{Rc, Weak};

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, gio, glib, graphene, pango};
use libadwaita as adw;
use tablepro_core::meta::TableRef;
use tablepro_session::SessionKey;
use uuid::Uuid;

use super::object_key::ObjectKey;
use super::object_target::ObjectTarget;
use super::sidebar_menu::{GROUP, object_menu, schema_menu};
use super::sidebar_object::SidebarObject;
use super::sidebar_view::{Holds, RowsObserverId, SidebarView};
use super::store_sync;
use super::tree_menu::{InWindow, SHOW_CONNECT_FAILURE, SHOW_SESSION, session_section};
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

/// The tree's list, or the list of what the search finds.
pub(super) struct Pane {
    pub(super) list_view: gtk::ListView,
    pub(super) selection: gtk::SingleSelection,
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
    pub(super) rows: gtk::TreeListModel,
    /// What the search finds: a section per model of `sections`.
    pub(super) results: gtk::FlattenListModel,
    /// The connections the search names, then each open session's
    /// schemas' found tables, in the tree's order.
    sections: gio::ListStore,
    /// What each of `sections` is, in its order.
    headings: RefCell<Vec<Heading>>,
    /// Every connection, in the tree's order.
    connections: gio::ListStore,
    /// The connections the search names, over `connections` only while
    /// there is a search.
    named: gtk::FilterListModel,
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

/// A section of what the search finds: the session whose tables it
/// holds, none for the connections, and its heading.
struct Heading {
    model: glib::Object,
    key: Option<SessionKey>,
    title: String,
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
            let rows = tree_model(&roots);
            let connections = gio::ListStore::new::<TreeNode>();
            let named = gtk::FilterListModel::new(None::<gio::ListModel>, Some(matches.clone()));
            let sections = gio::ListStore::new::<gio::ListModel>();
            let results = gtk::FlattenListModel::new(Some(sections.clone()));
            let tree_pane = Pane::new(&rows, &crate::i18n::gettext("Connections"));
            let found_pane = Pane::new(&results, &crate::i18n::gettext("Search Results"));
            let root = pages(&tree_pane, &found_pane);
            let popover = gtk::PopoverMenu::from_model(None::<&gio::MenuModel>);
            popover.set_has_arrow(true);
            popover.set_parent(&root);
            TreeInner {
                root,
                tree: tree_pane,
                found: found_pane,
                rows,
                results,
                headings: RefCell::new(Vec::new()),
                sections,
                connections,
                named,
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
        node.set_children(Some(sidebar.rows()));
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
            node.set_children(None);
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

    /// The name and the reason of the last failed connect of `key`, or
    /// `None` once another starts or the window lets it go. A key no
    /// saved connection names keeps a row of its own while it failed.
    pub(crate) fn set_failure(&self, key: &SessionKey, failure: Option<(&str, &str)>) {
        let inner = &self.inner;
        match failure {
            Some((name, reason)) => {
                inner.node_for(key, name);
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
        inner.named.set_model(None::<&gio::ListModel>);
    }
}

impl Pane {
    fn new(model: &impl IsA<gio::ListModel>, label: &str) -> Self {
        let selection = gtk::SingleSelection::new(Some(model.clone()));
        selection.set_autoselect(false);
        selection.set_can_unselect(true);
        let list_view = gtk::ListView::new(Some(selection.clone()), None::<gtk::ListItemFactory>);
        list_view.add_css_class("navigation-sidebar");
        // A click opens a table or a connection, as the picker's rows
        // do; Enter and a double click reach the same activate.
        list_view.set_single_click_activate(true);
        list_view.update_property(&[gtk::accessible::Property::Label(label)]);
        Self { list_view, selection }
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
            SessionKey::SavedIn { id, database } => {
                self.saved.get(*id).map(|saved| sibling_title(&saved.name, database))
            }
            SessionKey::File(_) => None,
        }
    }

    /// The open databases of the connection `id` beside its own, by name.
    fn siblings_of(&self, id: uuid::Uuid) -> Vec<(SessionKey, String)> {
        let mut siblings: Vec<(SessionKey, String)> = self
            .branches
            .borrow()
            .keys()
            .filter_map(|key| match key {
                SessionKey::SavedIn { id: of, database } if *of == id => Some((key.clone(), database.clone())),
                _ => None,
            })
            .collect();
        siblings.sort_by_cached_key(|(_, database)| (database.to_lowercase(), database.clone()));
        siblings
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
            // The connection's other open databases come right after it,
            // in its group, by name ([0030]).
            let mut rows = vec![node];
            for (sibling, database) in self.siblings_of(saved.id) {
                let title = sibling_title(&saved.name, &database);
                let node = self.node_for(&sibling, &title);
                node.update(
                    &title,
                    crate::ui::icons::DRIVE_HARDDISK,
                    saved.color.map_or("", crate::ui::connection_appearance::color_class),
                );
                kept.insert(sibling);
                rows.push(node);
            }
            match &saved.group {
                None => ungrouped.extend(rows),
                Some(group) => match grouped.last_mut() {
                    Some((name, members)) if *name == group.as_str() => members.extend(rows),
                    _ => grouped.push((group.as_str().to_owned(), rows)),
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
        let in_order: Vec<TreeNode> = ungrouped
            .iter()
            .chain(grouped.iter().flat_map(|(_, members)| members))
            .chain(&others)
            .cloned()
            .collect();
        let desired: Vec<TreeNode> = ungrouped.into_iter().chain(group_nodes).chain(others).collect();
        store_sync::sync(&self.roots, &desired);
        store_sync::sync(&self.connections, &in_order);
        self.reopen(&open);
        if self.searching() {
            // An edit can change what the search names.
            self.matches.changed(gtk::FilterChange::Different);
        }
        self.sync_sections();
        self.refresh_page();
        self.reselect();
    }

    /// The sections of what the search finds: the connections it names,
    /// then each open session's schemas, in the tree's order. A schema's
    /// section is its list of found tables, empty while there is no
    /// search, and a new list once a search changes them.
    fn sync_sections(&self) {
        let mut headings = vec![Heading {
            model: self.named.clone().upcast(),
            key: None,
            title: crate::i18n::gettext("Connections"),
        }];
        let connections: Vec<TreeNode> = (0..self.connections.n_items())
            .filter_map(|at| self.connections.item(at).and_downcast::<TreeNode>())
            .collect();
        for connection in connections {
            let Some(key) = connection.key() else {
                continue;
            };
            let Some(view) = self.view_of(&key) else {
                continue;
            };
            let schemas = view.schemas();
            for schema in (0..schemas.n_items()).filter_map(|at| schemas.item(at).and_downcast::<TreeNode>()) {
                let Some(found) = schema.found() else {
                    continue;
                };
                headings.push(Heading {
                    model: found.upcast(),
                    key: Some(key.clone()),
                    // Translators: a schema the search found tables in, and its connection.
                    title: crate::i18n::gettext_f(
                        "{schema} ({connection})",
                        &[("schema", &schema.title()), ("connection", &connection.title())],
                    ),
                });
            }
        }
        let models: Vec<glib::Object> = headings.iter().map(|heading| heading.model.clone()).collect();
        self.headings.replace(headings);
        store_sync::replace(&self.sections, &models);
    }

    /// The section of what the search finds that holds `position`.
    fn heading_at<T>(&self, position: u32, read: impl FnOnce(&Heading) -> T) -> Option<T> {
        let model = self.results.model_for_item(position)?;
        let headings = self.headings.borrow();
        headings
            .iter()
            .find(|heading| heading.model == *model.upcast_ref::<glib::Object>())
            .map(read)
    }

    /// Where `model`'s rows start in what the search finds.
    fn section_start(&self, model: &glib::Object) -> Option<u32> {
        let mut start = 0;
        for at in 0..self.sections.n_items() {
            let section = self.sections.item(at).and_downcast::<gio::ListModel>()?;
            if section.upcast_ref::<glib::Object>() == model {
                return Some(start);
            }
            start += section.n_items();
        }
        None
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
        if let Some(row) = self.connection_row(node, true) {
            expand(&row);
        }
    }

    /// The nodes whose rows are open in the tree, above the tables.
    fn open_rows(&self) -> HashSet<TreeNode> {
        let mut open = HashSet::new();
        let mut rows = top_rows(&self.rows);
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
        let mut rows = top_rows(&self.rows);
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
        self.sync_sections();
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
        if let Some(connection) = self.connection_row(&node, false)
            && connection.is_expanded()
            && let Some(row) = child_row(&connection, &schema)
        {
            open_when_made(&row, &schema);
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
            (false, true) => self.named.set_model(Some(&self.connections)),
            (true, false) => self.named.set_model(None::<&gio::ListModel>),
            (true, true) => self.matches.changed(gtk::FilterChange::Different),
            (false, false) => {}
        }
        let keys: Vec<SessionKey> = self.branches.borrow().keys().cloned().collect();
        for key in &keys {
            self.tell_search(key);
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
        self.connection_row(&node, false).is_some_and(|row| row.is_expanded())
    }

    /// Whether the search names the connection `item`: its name, where
    /// it connects, its group or tags, as the picker's search reads them.
    fn finds(&self, item: &glib::Object) -> bool {
        let Some(node) = item.downcast_ref::<TreeNode>() else {
            return false;
        };
        let Some(key) = node.key() else {
            return false;
        };
        let search = self.search.borrow();
        match &key {
            SessionKey::Saved(id) => match self.saved.get(*id) {
                Some(saved) => search.matches(&saved, &self.saved.tags()),
                None => search.matches_name(&node.title()),
            },
            SessionKey::SavedIn { .. } | SessionKey::File(_) => search.matches_name(&node.title()),
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
        } else if self.results.n_items() == 0 && self.settled() {
            NOTHING_PAGE
        } else {
            FOUND_PAGE
        };
        if self.root.visible_child_name().as_deref() != Some(page) {
            self.root.set_visible_child_name(page);
        }
    }

    /// The tree's row of the connection `node`, among the roots or in its
    /// group; `open` opens the group to show it.
    fn connection_row(&self, node: &TreeNode, open: bool) -> Option<gtk::TreeListRow> {
        let model = &self.rows;
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
        key: &SessionKey,
        connection: &gtk::TreeListRow,
        table: &TableRef,
        open: bool,
    ) -> Option<gtk::TreeListRow> {
        let (schema, offset) = self.view_of(key)?.locate(table)?;
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
        let found = match which {
            Which::Tree => self.tree_position(key, table, reveal),
            Which::Found => self.found_position(key, table),
        };
        let Some((position, shown)) = found else {
            self.unselect(pane);
            return false;
        };
        if reveal {
            // Without FOCUS: the keyboard stays in the editor or the grid.
            pane.list_view.scroll_to(position, gtk::ListScrollFlags::SELECT, None);
        } else if pane.selection.selected() != position {
            pane.selection.set_selected(position);
        }
        shown
    }

    /// Where the tree shows `table`, or the session's connection when it
    /// does not, and whether that is the row asked for.
    fn tree_position(&self, key: &SessionKey, table: Option<&TableRef>, reveal: bool) -> Option<(u32, bool)> {
        let node = self.nodes.borrow().get(key).cloned()?;
        let connection = self.connection_row(&node, reveal)?;
        let found = table.and_then(|table| self.table_row(key, &connection, table, reveal));
        Some(match &found {
            Some(row) => (row.position(), true),
            None => (connection.position(), table.is_none()),
        })
    }

    /// Where the search's list shows `table`, or the session's connection
    /// when it names it and the table is not found.
    fn found_position(&self, key: &SessionKey, table: Option<&TableRef>) -> Option<(u32, bool)> {
        let view = self.view_of(key);
        let located = table.zip(view).and_then(|(table, view)| view.locate_found(table));
        if let Some((schema, offset)) = located {
            let found = schema.found()?.upcast::<glib::Object>();
            return Some((self.section_start(&found)? + offset, true));
        }
        let node = self.nodes.borrow().get(key).cloned()?;
        let at = index_in(&self.named, &node)?;
        Some((self.section_start(self.named.upcast_ref())? + at, table.is_none()))
    }

    /// What the list `which` shows at `position`, and the session whose
    /// table or schema it is.
    fn item_at(&self, which: Which, position: u32) -> Option<(glib::Object, Option<SessionKey>)> {
        match which {
            Which::Tree => {
                let row = self.rows.row(position)?;
                Some((row.item()?, owning_key(&row)))
            }
            Which::Found => {
                let item = self.results.item(position)?;
                let key = match item.downcast_ref::<TreeNode>() {
                    Some(node) => node.key(),
                    None => self.heading_at(position, |heading| heading.key.clone()).flatten(),
                };
                Some((item, key))
            }
        }
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

    /// A click or Enter: a table opens, a routine shows its SQL, a closed
    /// connection connects and an open one comes to the front, and a
    /// group or schema opens or folds. Bringing a connection forward
    /// leaves its row as it is.
    fn activate(&self, which: Which, position: u32) {
        let Some((item, key)) = self.item_at(which, position) else {
            return;
        };
        if let Some(object) = item.downcast_ref::<SidebarObject>() {
            if let Some(view) = key.and_then(|key| self.view_of(&key)) {
                match object.target() {
                    ObjectTarget::Rows(table) => view.open(table),
                    ObjectTarget::Definition(object) => view.show_definition(object),
                }
            }
            return;
        }
        let Some(node) = item.downcast_ref::<TreeNode>() else {
            return;
        };
        match node.kind() {
            NodeKind::Connection => activate_connection(&self.pane(which).list_view, node, self.stored(node)),
            NodeKind::Group | NodeKind::Schema => {
                if let Some(row) = self.rows.row(position).filter(|_| which == Which::Tree) {
                    row.set_expanded(!row.is_expanded());
                }
            }
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
        let Some((item, key)) = self.item_at(which, position) else {
            return false;
        };
        // A definition has no tab to open beside the others.
        let table = item
            .downcast_ref::<SidebarObject>()
            .and_then(|object| object.target().into_rows());
        match button {
            gdk::BUTTON_SECONDARY => {
                self.pane(which).selection.set_selected(position);
                self.popup_menu(which, position, pointing);
                true
            }
            gdk::BUTTON_PRIMARY if modifiers.contains(gdk::ModifierType::CONTROL_MASK) => {
                let (Some(table), Some(view)) = (table, key.and_then(|key| self.view_of(&key))) else {
                    return false;
                };
                view.open_in_new_tab(table);
                true
            }
            gdk::BUTTON_MIDDLE => {
                self.middle.replace(key.zip(table));
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

    /// Open the menu of the row at `position` in the list `which`.
    pub(super) fn popup_menu(&self, which: Which, position: u32, pointing: Option<gdk::Rectangle>) {
        let Some((item, key)) = self.item_at(which, position) else {
            return;
        };
        let Some(menu) = self.menu_for(&item, key) else {
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
        let which = self.shown();
        let pane = self.pane(which);
        let row = focused_row(&pane.list_view).or_else(|| bound_row(&pane.list_view, pane.selection.selected()));
        let position = row
            .as_ref()
            .and_then(TreeRow::position)
            .unwrap_or_else(|| pane.selection.selected());
        if position == gtk::INVALID_LIST_POSITION {
            return;
        }
        let pointing = row.and_then(|row| bounds_in(&row, &self.root));
        self.popup_menu(which, position, pointing);
    }

    /// The menu of a row. The popover reaches the session's table
    /// actions, and a connection's choices, through groups of its own.
    fn menu_for(&self, item: &glib::Object, key: Option<SessionKey>) -> Option<gio::Menu> {
        let view = key.and_then(|key| self.view_of(&key));
        if let Some(object) = item.downcast_ref::<SidebarObject>() {
            let view = view?;
            self.popover.insert_action_group(GROUP, Some(view.actions()));
            return Some(object_menu(
                &ObjectKey(object.target()),
                object.kind(),
                view.affordances(),
            ));
        }
        let node = item.downcast_ref::<TreeNode>()?;
        match node.kind() {
            NodeKind::Schema => {
                let view = view?;
                self.popover.insert_action_group(GROUP, Some(view.actions()));
                schema_menu(node.schema_name().as_deref(), view.affordances(), view.holds())
            }
            NodeKind::Connection => self.connection_menu(node),
            NodeKind::Group | NodeKind::Placeholder => None,
        }
    }

    /// The id of the saved connection `node` shows, while the list has it.
    fn stored(&self, node: &TreeNode) -> Option<Uuid> {
        match node.key()? {
            SessionKey::Saved(id) => self.saved.get(id).map(|_| id),
            // A database's row is not the connection's: it has no editing.
            SessionKey::SavedIn { .. } | SessionKey::File(_) => None,
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
                stored: self.stored(node).is_some(),
            }
        };
        // A saved connection's own row, on an engine whose catalog holds
        // one database (0030).
        let opens_databases = matches!(key, SessionKey::Saved(_))
            && self
                .branches
                .borrow()
                .get(&key)
                .is_some_and(|branch| branch.view.affordances().opens_databases);
        let lead = session_section(&key, state, opens_databases);
        let saved = match &key {
            SessionKey::Saved(id) => self.saved.get(*id),
            SessionKey::SavedIn { .. } | SessionKey::File(_) => None,
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
/// one comes to the front. One connecting waits. A row only a failed
/// connect keeps, of a file or of a connection not saved, says why.
fn activate_connection(list_view: &gtk::ListView, node: &TreeNode, stored: Option<Uuid>) {
    let Some(key) = node.key() else {
        return;
    };
    let fired = if node.open() {
        list_view.activate_action(SHOW_SESSION, Some(&crate::ui::session_target::to_variant(&key)))
    } else if node.busy() {
        return;
    } else if let Some(id) = stored {
        let (action, target) = crate::ui::picker::connect_action(id);
        list_view.activate_action(&action, Some(&target))
    } else {
        list_view.activate_action(SHOW_CONNECT_FAILURE, Some(&crate::ui::session_target::to_variant(&key)))
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
    let tree = Rc::downgrade(inner);
    match which {
        Which::Tree => pane.list_view.set_factory(Some(&tree_factory(tree))),
        Which::Found => {
            pane.list_view.set_factory(Some(&found_factory(tree.clone())));
            pane.list_view.set_header_factory(Some(&heading_factory(tree)));
        }
    }
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
fn tree_factory(tree: Weak<TreeInner>) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(move |_, object| {
        let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        item.set_focusable(false);
        let expander = gtk::TreeExpander::new();
        expander.set_indent_for_icon(true);
        expander.set_child(Some(&TreeRow::new(item)));
        expander.add_controller(click_gesture(tree.clone(), Which::Tree, item));
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

/// The search's rows, which open nothing beneath them.
fn found_factory(tree: Weak<TreeInner>) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(move |_, object| {
        let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let row = TreeRow::new(item);
        row.add_controller(click_gesture(tree.clone(), Which::Found, item));
        item.set_child(Some(&row));
    });
    factory.connect_bind(|_, object| {
        let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        if let (Some(row), Some(shown)) = (item.child().and_downcast::<TreeRow>(), item.item()) {
            row.bind(&shown);
        }
    });
    factory.connect_unbind(|_, object| {
        if let Some(row) = object
            .downcast_ref::<gtk::ListItem>()
            .and_then(|item| item.child())
            .and_downcast::<TreeRow>()
        {
            row.unbind();
        }
    });
    factory
}

/// Each section of what the search finds is headed by what it is, as
/// GtkPlacesSidebar heads its sections: small, bold and dim.
fn heading_factory(tree: Weak<TreeInner>) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, object| {
        let Some(header) = object.downcast_ref::<gtk::ListHeader>() else {
            return;
        };
        let title = gtk::Label::builder()
            .xalign(0.0)
            .ellipsize(pango::EllipsizeMode::End)
            .margin_top(12)
            .margin_bottom(6)
            .margin_start(12)
            .margin_end(12)
            .build();
        title.add_css_class("caption-heading");
        title.add_css_class("dimmed");
        header.set_child(Some(&title));
    });
    factory.connect_bind(move |_, object| {
        let Some(header) = object.downcast_ref::<gtk::ListHeader>() else {
            return;
        };
        let (Some(tree), Some(title)) = (tree.upgrade(), header.child().and_downcast::<gtk::Label>()) else {
            return;
        };
        let heading = tree.heading_at(header.start(), |heading| heading.title.clone());
        title.set_label(heading.as_deref().unwrap_or_default());
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

/// The row the keyboard focus is in or on: its expander or its eject
/// button in the tree, the row itself in the search's list.
fn focused_row(list_view: &gtk::ListView) -> Option<TreeRow> {
    let mut widget = list_view.root()?.focus();
    while let Some(current) = widget {
        if let Some(row) = row_in(&current) {
            return Some(row);
        }
        if &current == list_view.upcast_ref::<gtk::Widget>() {
            return None;
        }
        widget = current.parent();
    }
    None
}

/// The row `widget` is, or holds: an expander's child, or a list item's
/// in either list.
fn row_in(widget: &gtk::Widget) -> Option<TreeRow> {
    if let Some(row) = widget.downcast_ref::<TreeRow>() {
        return Some(row.clone());
    }
    if let Some(expander) = widget.downcast_ref::<gtk::TreeExpander>() {
        return expander.child().and_downcast();
    }
    let child = widget.first_child()?;
    match child.downcast::<TreeRow>() {
        Ok(row) => Some(row),
        Err(child) => child.downcast::<gtk::TreeExpander>().ok()?.child().and_downcast(),
    }
}

/// The row at `position`, when it is bound.
fn bound_row(list_view: &gtk::ListView, position: u32) -> Option<TreeRow> {
    let mut child = list_view.first_child();
    while let Some(widget) = child {
        if let Some(row) = row_in(&widget).filter(|row| row.position() == Some(position)) {
            return Some(row);
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

/// The rows of a schema made in one turn of the main loop before it opens.
const ROWS_PER_TURN: u32 = 2_000;

/// Open the `schema`'s `row` once its tables' rows are made, a batch per
/// turn of the main loop: GtkTreeListModel asks for every row of a schema
/// it opens, and 50,000 made in one turn stall the window.
fn open_when_made(row: &gtk::TreeListRow, schema: &TreeNode) {
    let Some(rows) = schema.rows().filter(|rows| !rows.make_rows(ROWS_PER_TURN)) else {
        expand(row);
        return;
    };
    let row = row.downgrade();
    glib::idle_add_local(move || {
        let Some(row) = row.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if !rows.make_rows(ROWS_PER_TURN) {
            return glib::ControlFlow::Continue;
        }
        expand(&row);
        glib::ControlFlow::Break
    });
}

/// Where `object` is in `model`: the roots, a group's connections or a
/// connection's schemas, never a schema's tables.
fn index_in(model: &impl IsA<gio::ListModel>, object: &impl IsA<glib::Object>) -> Option<u32> {
    let object = object.upcast_ref::<glib::Object>();
    (0..model.n_items()).find(|&at| model.item(at).as_ref() == Some(object))
}

/// A sibling database's row: its connection and the database, apart.
fn sibling_title(connection: &str, database: &str) -> String {
    // Translators: a connection and another of its server's databases, open beside it.
    crate::i18n::gettext_f(
        "{connection} · {database}",
        &[("connection", connection), ("database", database)],
    )
}
