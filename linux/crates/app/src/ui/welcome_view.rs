use std::cell::{Cell, OnceCell, RefCell};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, gio, glib, graphene, pango};
use libadwaita as adw;
use tablepro_session::runtime::Tasks;
use tablepro_storage::{ConnectionListState, ConnectionTag, SavedConnection};
use uuid::Uuid;

use crate::services::connection_search::ConnectionSearch;
use crate::services::file_location;
use crate::services::library_outline::{DropSpot, LibraryItem, LibraryOutline, LibrarySection};
use crate::services::saved_connection_list::{SavedConnectionList, StateObserverId};
use crate::services::saved_connection_object::SavedConnectionObject;
use crate::ui::picker::{
    LibraryNode, LibraryRow, NodeLook, Seen, bind_row, connect_action, connection_look, group_look, library_item,
    library_menu, unbind_row,
};
use crate::ui::store_sync;

const LIST: &str = "list";
const FOUND: &str = "found";
const NO_RESULTS: &str = "no-results";
const EMPTY: &str = "empty";

type Key = (LibrarySection, LibraryItem);

mod imp {
    use super::*;
    use libadwaita::subclass::prelude::*;

    #[derive(Default, gtk::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/welcome-view.ui")]
    pub struct WelcomeView {
        #[template_child]
        pub stack: TemplateChild<gtk::Stack>,
        #[template_child]
        pub list_scroller: TemplateChild<gtk::ScrolledWindow>,
        #[template_child]
        pub list_view: TemplateChild<gtk::ListView>,
        // The list waits for its first size to start at its top.
        pub home: Cell<bool>,
        #[template_child]
        pub found_view: TemplateChild<gtk::ListView>,
        pub(super) parts: OnceCell<super::Parts>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for WelcomeView {
        const NAME: &'static str = "TableProWelcomeView";
        type Type = super::WelcomeView;
        type ParentType = adw::Bin;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for WelcomeView {
        fn dispose(&self) {
            self.obj().shutdown();
        }
    }

    impl WidgetImpl for WelcomeView {}
    impl BinImpl for WelcomeView {}
}

glib::wrapper! {
    pub struct WelcomeView(ObjectSubclass<imp::WelcomeView>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Which {
    Tree,
    Found,
}

enum HostPath {
    Looking(String),
    Found(String, Option<PathBuf>),
}

impl HostPath {
    fn database(&self) -> &str {
        match self {
            Self::Looking(database) | Self::Found(database, _) => database,
        }
    }
}

pub(super) struct Parts {
    list: Rc<SavedConnectionList>,
    tasks: Option<Tasks>,
    roots: gio::ListStore,
    favourites: gio::ListStore,
    recent: gio::ListStore,
    found: gio::ListStore,
    tree: gtk::TreeListModel,
    selection: gtk::SingleSelection,
    found_filter: gtk::CustomFilter,
    found_rows: gtk::FilterListModel,
    found_selection: gtk::SingleSelection,
    nodes: RefCell<HashMap<Key, LibraryNode>>,
    found_nodes: RefCell<HashMap<Uuid, LibraryNode>>,
    // Read once per connection and kept, since a row is recycled long before the portal answers.
    host_paths: RefCell<HashMap<Uuid, HostPath>>,
    open: RefCell<HashSet<Uuid>>,
    known: RefCell<HashSet<Uuid>>,
    search: RefCell<ConnectionSearch>,
    focus: Cell<Option<Uuid>>,
    menu: gtk::PopoverMenu,
    state_changed: RefCell<Option<StateObserverId>>,
}

impl Parts {
    fn new(view: &WelcomeView, list: Rc<SavedConnectionList>, tasks: Option<Tasks>) -> Self {
        let (roots, favourites, recent, found) = (
            gio::ListStore::new::<LibraryNode>(),
            gio::ListStore::new::<LibraryNode>(),
            gio::ListStore::new::<LibraryNode>(),
            gio::ListStore::new::<LibraryNode>(),
        );
        let tree = gtk::TreeListModel::new(roots.clone(), false, false, |item| {
            item.downcast_ref::<LibraryNode>()?
                .children()
                .map(|store| store.upcast())
        });
        let sections = gio::ListStore::new::<gio::ListModel>();
        sections.append(&flat(&favourites));
        sections.append(&flat(&recent));
        sections.append(&tree);
        let finding = view.downgrade();
        let found_filter = gtk::CustomFilter::new(move |item| finding.upgrade().is_some_and(|view| view.finds(item)));
        let found_rows = gtk::FilterListModel::new(Some(found.clone()), Some(found_filter.clone()));
        let menu = crate::ui::context_menu::context_menu(Some(&library_menu()));
        Self {
            list,
            tasks,
            roots,
            favourites,
            recent,
            found,
            tree,
            selection: selection_of(&gtk::FlattenListModel::new(Some(sections))),
            found_filter,
            found_selection: selection_of(&flat(&found_rows)),
            found_rows,
            nodes: RefCell::new(HashMap::new()),
            found_nodes: RefCell::new(HashMap::new()),
            host_paths: RefCell::new(HashMap::new()),
            open: RefCell::new(HashSet::new()),
            known: RefCell::new(HashSet::new()),
            search: RefCell::default(),
            focus: Cell::new(None),
            menu,
            state_changed: RefCell::new(None),
        }
    }

    fn node(&self, key: Key) -> LibraryNode {
        self.nodes
            .borrow_mut()
            .entry(key)
            .or_insert_with(|| match key.1 {
                LibraryItem::Group(id) => LibraryNode::group(id),
                LibraryItem::Connection(id) => LibraryNode::connection(key.0, id),
            })
            .clone()
    }

    fn host_path(&self, saved: &SavedConnection) -> Option<PathBuf> {
        match self.host_paths.borrow().get(&saved.id) {
            Some(HostPath::Found(database, found)) if *database == saved.database => found.clone(),
            _ => None,
        }
    }

    fn searching(&self) -> bool {
        !self.search.borrow().is_empty()
    }
}

// One sync of every store against one published list.
struct Pass<'a> {
    parts: &'a Parts,
    outline: &'a LibraryOutline,
    file_based: HashSet<Uuid>,
    tags: Arc<[ConnectionTag]>,
    kept: HashSet<Key>,
}

impl<'a> Pass<'a> {
    fn new(parts: &'a Parts, outline: &'a LibraryOutline) -> Self {
        let model = parts.list.model();
        let file_based = (0..model.n_items())
            .filter_map(|at| model.item(at).and_downcast::<SavedConnectionObject>())
            .filter(SavedConnectionObject::file_based)
            .filter_map(|object| object.saved().map(|saved| saved.id))
            .collect();
        Self {
            parts,
            outline,
            file_based,
            tags: parts.list.tags(),
            kept: HashSet::new(),
        }
    }

    // `parent`'s rows, its stores below synced first, and how many connections they hold.
    fn children(&mut self, parent: Option<Uuid>) -> (Vec<LibraryNode>, u32) {
        let mut nodes = Vec::new();
        let mut count = 0;
        for item in self.outline.children(parent) {
            match item {
                LibraryItem::Group(id) => {
                    let Some(group) = self.outline.group(id) else {
                        continue;
                    };
                    let node = self.parts.node((LibrarySection::Tree, item));
                    let (inside, held) = self.children(Some(id));
                    if let Some(store) = node.children() {
                        store_sync::sync(&store, &inside);
                    }
                    node.show(group_look(group, held));
                    // Open the first time it shows, as macOS does; after that the user's choice stands.
                    if self.parts.known.borrow_mut().insert(id) {
                        self.parts.open.borrow_mut().insert(id);
                    }
                    self.kept.insert((LibrarySection::Tree, item));
                    count += held;
                    nodes.push(node);
                }
                LibraryItem::Connection(id) => {
                    if let Some(node) = self.connection(LibrarySection::Tree, id) {
                        count += 1;
                        nodes.push(node);
                    }
                }
            }
        }
        (nodes, count)
    }

    fn connection(&mut self, section: LibrarySection, id: Uuid) -> Option<LibraryNode> {
        let saved = self.outline.connection(id)?;
        let key = (section, LibraryItem::Connection(id));
        let node = self.parts.node(key);
        node.show(self.look(saved, section, self.path(saved).as_deref()));
        self.kept.insert(key);
        Some(node)
    }

    // A found row is drawn and acted on as a Recent one: no drag, no drop and no Move Up or Down.
    fn found(&self) -> Vec<LibraryNode> {
        let connections = self.parts.list.connections();
        let present: HashSet<Uuid> = connections.iter().map(|saved| saved.id).collect();
        let mut held = self.parts.found_nodes.borrow_mut();
        held.retain(|id, _| present.contains(id));
        connections
            .iter()
            .map(|saved| {
                let node = held
                    .entry(saved.id)
                    .or_insert_with(|| LibraryNode::connection(LibrarySection::Recent, saved.id))
                    .clone();
                let path = self.path(saved);
                node.set_source(saved, path.as_deref());
                node.show(self.look(saved, LibrarySection::Recent, path.as_deref()));
                node
            })
            .collect()
    }

    fn path(&self, saved: &SavedConnection) -> Option<String> {
        saved.group_id.and_then(|group| self.outline.label(group))
    }

    fn look(&self, saved: &SavedConnection, section: LibrarySection, path: Option<&str>) -> NodeLook {
        let host = self.parts.host_path(saved);
        connection_look(
            saved,
            section,
            Seen {
                file_based: self.file_based.contains(&saved.id),
                host_path: host.as_deref(),
                path,
                tags: &self.tags,
                favourite: self.outline.favourites().contains(&saved.id),
            },
        )
    }
}

impl WelcomeView {
    // `tasks` reads the file a portal path stands for; without it a row names the file alone.
    pub(crate) fn new(list: Rc<SavedConnectionList>, tasks: Option<Tasks>) -> Self {
        let view: Self = glib::Object::new();
        let _ = view.imp().parts.set(Parts::new(&view, list.clone(), tasks));
        view.attach();
        view.imp().home.set(true);
        let homing = view.downgrade();
        view.imp()
            .list_scroller
            .vadjustment()
            .connect_changed(move |adjustment| {
                if let Some(view) = homing.upgrade()
                    && adjustment.page_size() > 0.0
                    && view.imp().home.replace(false)
                {
                    adjustment.set_value(0.0);
                }
            });
        // Once per published list: the flat model changes a step at a time, and a step can hold a connection twice.
        let weak = view.downgrade();
        let observer = list.connect_state_changed(move |_| {
            if let Some(view) = weak.upgrade() {
                view.rebuild();
            }
        });
        if let Some(parts) = view.imp().parts.get() {
            parts.state_changed.replace(Some(observer));
        }
        view.rebuild();
        view
    }

    // The list outlives every window.
    pub(crate) fn shutdown(&self) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        if let Some(observer) = parts.state_changed.take() {
            parts.list.disconnect_state_changed(observer);
        }
        if parts.menu.parent().is_some() {
            parts.menu.popdown();
            parts.menu.unparent();
        }
    }

    pub(crate) fn set_search(&self, text: &str) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let search = ConnectionSearch::new(text);
        if *parts.search.borrow() == search {
            return;
        }
        parts.search.replace(search);
        parts.found_filter.changed(gtk::FilterChange::Different);
        self.refresh_page();
    }

    // Enter in the search: the first match, or with no search the first connection shown, groups skipped.
    pub(crate) fn activate_first(&self) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let first = if parts.searching() {
            parts
                .found_rows
                .item(0)
                .and_downcast::<LibraryNode>()
                .and_then(|node| node.item())
                .and_then(|item| match item {
                    LibraryItem::Connection(id) => Some(id),
                    LibraryItem::Group(_) => None,
                })
        } else {
            // The rows on screen: a connection in a folded group is not offered.
            (0..parts.selection.n_items()).find_map(|at| {
                let node = parts
                    .selection
                    .item(at)
                    .and_downcast::<gtk::TreeListRow>()?
                    .item()
                    .and_downcast::<LibraryNode>()?;
                match node.item()? {
                    LibraryItem::Connection(id) => Some(id),
                    LibraryItem::Group(_) => None,
                }
            })
        };
        if let Some(id) = first {
            self.connect(id);
        }
    }

    // A copy reaches the list after the write that made it, so the focus waits for its row.
    pub(crate) fn focus_connection(&self, id: Uuid) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        parts.focus.set(Some(id));
        self.take_focus();
    }

    fn attach(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        for (list_view, selection, which) in [
            (imp.list_view.get(), &parts.selection, Which::Tree),
            (imp.found_view.get(), &parts.found_selection, Which::Found),
        ] {
            list_view.set_model(Some(selection));
            list_view.set_factory(Some(&self.row_factory(which)));
            let view = self.downgrade();
            list_view.connect_activate(move |_, position| {
                if let Some(view) = view.upgrade() {
                    view.activate(which, position);
                }
            });
            // Activation on a single click selects the row under the pointer, so the selection goes when it leaves.
            let hover = gtk::EventControllerMotion::new();
            let unselecting = selection.downgrade();
            hover.connect_leave(move |_| {
                if let Some(selection) = unselecting.upgrade()
                    && selection.selected() != gtk::INVALID_LIST_POSITION
                {
                    selection.set_selected(gtk::INVALID_LIST_POSITION);
                }
            });
            list_view.add_controller(hover);
        }
        imp.list_view.set_header_factory(Some(&heading_factory()));
        self.take_drops_below_the_rows();
        self.offer_library_menu();
        parts.menu.set_parent(&*imp.stack);
    }

    fn row_factory(&self, which: Which) -> gtk::SignalListItemFactory {
        let factory = gtk::SignalListItemFactory::new();
        let Some(parts) = self.imp().parts.get() else {
            return factory;
        };
        let (source, list) = (self.downgrade(), parts.list.clone());
        factory.connect_setup(move |_, object| {
            if let (Some(item), Some(view)) = (object.downcast_ref::<gtk::ListItem>(), source.upgrade()) {
                library_item(item, view.upcast_ref(), &list, which == Which::Tree);
            }
        });
        let view = self.downgrade();
        factory.connect_bind(move |_, object| {
            let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let view = view.clone();
            bind_row(item, move |row| {
                if let Some(view) = view.upgrade() {
                    view.on_expanded(row);
                }
            });
        });
        factory.connect_unbind(|_, object| {
            if let Some(item) = object.downcast_ref::<gtk::ListItem>() {
                unbind_row(item);
            }
        });
        factory
    }

    // Only the space under the last row: a row that refuses a drop must not hand it to the top level.
    fn take_drops_below_the_rows(&self) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let list_view = self.imp().list_view.get();
        let (rows, list) = (list_view.downgrade(), parts.list.clone());
        crate::ui::library_drag::drop_target(
            &list_view,
            move |y, _| {
                let list_view = rows.upgrade()?;
                below_rows(&list_view, y).then_some((DropSpot::End(LibrarySection::Tree), false))
            },
            move || list.outline(),
        );
    }

    fn offer_library_menu(&self) {
        let list_view = self.imp().list_view.get();
        let gesture = gtk::GestureClick::new();
        gesture.set_button(gdk::BUTTON_SECONDARY);
        let view = self.downgrade();
        gesture.connect_pressed(move |gesture, _, x, y| {
            let Some(view) = view.upgrade() else {
                return;
            };
            let list_view = view.imp().list_view.get();
            if on_a_row(&list_view, x, y) {
                return;
            }
            gesture.set_state(gtk::EventSequenceState::Claimed);
            view.popup_library_menu(&list_view, x, y);
        });
        list_view.add_controller(gesture);
    }

    fn popup_library_menu(&self, list_view: &gtk::ListView, x: f64, y: f64) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let stack = self.imp().stack.get();
        let at = list_view.compute_point(&stack, &graphene::Point::new(x as f32, y as f32));
        let pointing = at.map(|point| gdk::Rectangle::new(point.x() as i32, point.y() as i32, 1, 1));
        parts.menu.set_pointing_to(pointing.as_ref());
        parts.menu.popup();
    }

    fn activate(&self, which: Which, position: u32) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let selection = match which {
            Which::Tree => &parts.selection,
            Which::Found => &parts.found_selection,
        };
        let Some(row) = selection.item(position).and_downcast::<gtk::TreeListRow>() else {
            return;
        };
        match row.item().and_downcast::<LibraryNode>().and_then(|node| node.item()) {
            Some(LibraryItem::Connection(id)) => self.connect(id),
            Some(LibraryItem::Group(_)) => row.set_expanded(!row.is_expanded()),
            None => {}
        }
    }

    fn connect(&self, id: Uuid) {
        let (action, target) = connect_action(id);
        if let Err(error) = self.activate_action(&action, Some(&target)) {
            tracing::warn!(%error, "a connection's row reached no picker");
        }
    }

    fn finds(&self, item: &glib::Object) -> bool {
        let Some(parts) = self.imp().parts.get() else {
            return false;
        };
        let search = parts.search.borrow();
        search.is_empty()
            || item
                .downcast_ref::<LibraryNode>()
                .is_some_and(|node| node.matches(&search, &parts.list.tags()))
    }

    fn rebuild(&self) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let outline = parts.list.outline();
        let held = self.focused_node();
        // A row the keyboard is on keeps the view where it is.
        let at_top = held.is_none() && self.imp().list_scroller.vadjustment().value() <= 0.0;
        let mut pass = Pass::new(parts, &outline);
        let (roots, _) = pass.children(None);
        let favourites: Vec<LibraryNode> = outline
            .favourites()
            .iter()
            .filter_map(|id| pass.connection(LibrarySection::Favourites, *id))
            .collect();
        store_sync::sync(&parts.favourites, &favourites);
        let recent: Vec<LibraryNode> = outline
            .recent()
            .iter()
            .filter_map(|id| pass.connection(LibrarySection::Recent, *id))
            .collect();
        store_sync::sync(&parts.recent, &recent);
        // The sections above the tree first: GtkListView keeps its scroll anchor on a row, so rows
        // added above a filled tree would scroll the list away from its top.
        store_sync::sync(&parts.roots, &roots);
        store_sync::sync(&parts.found, &pass.found());
        let kept = pass.kept;
        parts.nodes.borrow_mut().retain(|key, _| kept.contains(key));
        self.reopen();
        parts.found_filter.changed(gtk::FilterChange::Different);
        self.refresh_page();
        self.restore_focus(held);
        self.take_focus();
        if at_top {
            self.go_home();
        }
        self.look_up_host_paths();
    }

    // GtkListView anchors its first row to the top of the view after a change, which hides the
    // section heading above that row; a list the user had at its top stays there.
    fn go_home(&self) {
        let adjustment = self.imp().list_scroller.vadjustment();
        if adjustment.page_size() <= 0.0 {
            self.imp().home.set(true);
            return;
        }
        glib::idle_add_local_once(move || adjustment.set_value(0.0));
    }

    // Top down: a group's rows exist only once its parent is open.
    fn reopen(&self) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let open = parts.open.borrow().clone();
        let mut rows: Vec<gtk::TreeListRow> = (0..parts.roots.n_items())
            .filter_map(|at| parts.tree.child_row(at))
            .collect();
        while let Some(row) = rows.pop() {
            if group_of(&row).is_some_and(|id| open.contains(&id)) {
                expand(&row);
                rows.extend(child_rows(&row));
            }
        }
    }

    fn on_expanded(&self, row: &gtk::TreeListRow) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let Some(id) = group_of(row).filter(|_| row.is_expandable()) else {
            return;
        };
        if !row.is_expanded() {
            parts.open.borrow_mut().remove(&id);
            return;
        }
        parts.open.borrow_mut().insert(id);
        // A group opened again shows the subgroups that were open inside it.
        let open = parts.open.borrow().clone();
        let mut rows = child_rows(row);
        while let Some(child) = rows.pop() {
            if group_of(&child).is_some_and(|id| open.contains(&id)) {
                expand(&child);
                rows.extend(child_rows(&child));
            }
        }
    }

    fn refresh_page(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        // A list still loading, or one that cannot be read, shows no promise to add to it; the banner says why.
        let empty = matches!(parts.list.state(), ConnectionListState::Ready(_)) && parts.list.outline().is_empty();
        let page = if empty {
            EMPTY
        } else if !parts.searching() {
            LIST
        } else if parts.found_rows.n_items() == 0 {
            NO_RESULTS
        } else {
            FOUND
        };
        if imp.stack.visible_child_name().as_deref() != Some(page) {
            imp.stack.set_visible_child_name(page);
        }
    }

    // The row the keyboard is on, and the expander that holds the focus for it.
    fn focused_node(&self) -> Option<(LibraryNode, gtk::Widget)> {
        let list_view = self.imp().list_view.get();
        let mut widget = list_view.root()?.focus();
        while let Some(current) = widget {
            if current == *list_view.upcast_ref::<gtk::Widget>() {
                return None;
            }
            if let Some(expander) = current.downcast_ref::<gtk::TreeExpander>() {
                let node = expander.child().and_downcast::<LibraryRow>()?.node()?;
                return Some((node, current));
            }
            widget = current.parent();
        }
        None
    }

    // A moved row is a new row with a new widget, which GTK does not focus.
    fn restore_focus(&self, held: Option<(LibraryNode, gtk::Widget)>) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let Some((node, expander)) = held else {
            return;
        };
        if self
            .focused_node()
            .is_some_and(|(now, widget)| now == node && widget == expander)
        {
            return;
        }
        if let Some(position) = position_of(&parts.selection, &node) {
            self.imp().list_view.scroll_to(
                position,
                gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
                None,
            );
        }
    }

    fn take_focus(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let Some(id) = parts.focus.get() else {
            return;
        };
        let (list_view, position) = if parts.searching() {
            let node = parts.found_nodes.borrow().get(&id).cloned();
            let position = node.and_then(|node| position_of(&parts.found_selection, &node));
            (imp.found_view.get(), position)
        } else {
            let node = parts
                .nodes
                .borrow()
                .get(&(LibrarySection::Tree, LibraryItem::Connection(id)))
                .cloned();
            if node.is_some() {
                self.reveal(id);
            }
            let position = node.and_then(|node| position_of(&parts.selection, &node));
            (imp.list_view.get(), position)
        };
        let Some(position) = position else {
            return;
        };
        parts.focus.set(None);
        list_view.scroll_to(position, gtk::ListScrollFlags::FOCUS, None);
    }

    // Open the groups the connection `id` sits in, outermost first.
    fn reveal(&self, id: Uuid) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let outline = parts.list.outline();
        let mut chain = Vec::new();
        let mut at = outline.parent_of(LibraryItem::Connection(id)).flatten();
        while let Some(group) = at {
            chain.push(group);
            at = outline.parent_of(LibraryItem::Group(group)).flatten();
        }
        let mut rows: Vec<gtk::TreeListRow> = (0..parts.roots.n_items())
            .filter_map(|at| parts.tree.child_row(at))
            .collect();
        for group in chain.into_iter().rev() {
            let Some(row) = rows.iter().find(|row| group_of(row) == Some(group)).cloned() else {
                return;
            };
            parts.open.borrow_mut().insert(group);
            expand(&row);
            rows = child_rows(&row);
        }
    }

    fn look_up_host_paths(&self) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let Some(tasks) = parts.tasks.clone() else {
            return;
        };
        let model = parts.list.model();
        let mut present = HashSet::new();
        for object in (0..model.n_items()).filter_map(|at| model.item(at).and_downcast::<SavedConnectionObject>()) {
            let Some(saved) = object.saved() else {
                continue;
            };
            present.insert(saved.id);
            let path = PathBuf::from(&saved.database);
            let asked = parts
                .host_paths
                .borrow()
                .get(&saved.id)
                .is_some_and(|held| held.database() == saved.database);
            if asked || !object.file_based() || !file_location::is_portal_path(&path) {
                continue;
            }
            parts
                .host_paths
                .borrow_mut()
                .insert(saved.id, HostPath::Looking(saved.database.clone()));
            let looking = tasks.spawn_blocking_task(move || file_location::portal_host_path_blocking(&path));
            let (view, id, database) = (self.downgrade(), saved.id, saved.database.clone());
            glib::spawn_future_local(async move {
                let found = looking.await.ok().flatten();
                if let Some(view) = view.upgrade() {
                    view.found_host_path(id, database, found);
                }
            });
        }
        parts.host_paths.borrow_mut().retain(|id, _| present.contains(id));
    }

    // An answer for a file the connection no longer opens is dropped.
    fn found_host_path(&self, id: Uuid, database: String, found: Option<PathBuf>) {
        let Some(parts) = self.imp().parts.get() else {
            return;
        };
        let asked = matches!(
            parts.host_paths.borrow().get(&id),
            Some(HostPath::Looking(held)) if *held == database
        );
        if !asked {
            return;
        }
        let named = found.is_some();
        parts
            .host_paths
            .borrow_mut()
            .insert(id, HostPath::Found(database, found));
        if named {
            self.rebuild();
        }
    }
}

fn flat(model: &impl IsA<gio::ListModel>) -> gtk::TreeListModel {
    gtk::TreeListModel::new(model.clone(), false, false, |_| None)
}

fn selection_of(model: &impl IsA<gio::ListModel>) -> gtk::SingleSelection {
    let selection = gtk::SingleSelection::new(Some(model.clone()));
    selection.set_autoselect(false);
    selection.set_can_unselect(true);
    selection
}

fn section_title(section: LibrarySection) -> String {
    match section {
        LibrarySection::Favourites => crate::i18n::gettext("Favourites"),
        LibrarySection::Recent => crate::i18n::gettext("Recent"),
        LibrarySection::Tree => crate::i18n::gettext("Connections"),
    }
}

// Small, bold and dim, as the window's sidebar heads its sections.
fn heading_factory() -> gtk::SignalListItemFactory {
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
    factory.connect_bind(|_, object| {
        let Some(header) = object.downcast_ref::<gtk::ListHeader>() else {
            return;
        };
        let section = header
            .item()
            .and_downcast::<gtk::TreeListRow>()
            .and_then(|row| row.item())
            .and_downcast::<LibraryNode>()
            .and_then(|node| node.section());
        if let (Some(title), Some(section)) = (header.child().and_downcast::<gtk::Label>(), section) {
            title.set_label(&section_title(section));
        }
    });
    factory
}

fn group_of(row: &gtk::TreeListRow) -> Option<Uuid> {
    match row.item().and_downcast::<LibraryNode>()?.item()? {
        LibraryItem::Group(id) => Some(id),
        LibraryItem::Connection(_) => None,
    }
}

fn child_rows(row: &gtk::TreeListRow) -> Vec<gtk::TreeListRow> {
    let count = row.children().map_or(0, |children| children.n_items());
    (0..count).filter_map(|at| row.child_row(at)).collect()
}

fn expand(row: &gtk::TreeListRow) {
    if !row.is_expanded() {
        row.set_expanded(true);
    }
}

fn position_of(selection: &gtk::SingleSelection, node: &LibraryNode) -> Option<u32> {
    let node = node.upcast_ref::<glib::Object>();
    (0..selection.n_items()).find(|&at| {
        selection
            .item(at)
            .and_downcast::<gtk::TreeListRow>()
            .and_then(|row| row.item())
            .is_some_and(|item| item == *node)
    })
}

fn on_a_row(list_view: &gtk::ListView, x: f64, y: f64) -> bool {
    let mut widget = list_view.pick(x, y, gtk::PickFlags::DEFAULT);
    while let Some(current) = widget {
        if current.is::<gtk::TreeExpander>() {
            return true;
        }
        if current == *list_view.upcast_ref::<gtk::Widget>() {
            return false;
        }
        widget = current.parent();
    }
    false
}

fn below_rows(list_view: &gtk::ListView, y: f64) -> bool {
    let mut bottom = 0.0_f32;
    let mut child = list_view.first_child();
    while let Some(widget) = child {
        if widget.is_child_visible()
            && let Some(bounds) = widget.compute_bounds(list_view)
        {
            bottom = bottom.max(bounds.y() + bounds.height());
        }
        child = widget.next_sibling();
    }
    y > f64::from(bottom)
}

#[cfg(test)]
impl WelcomeView {
    // What the page on screen lists, each row indented two spaces a level, and a found list untitled.
    pub(crate) fn sections(&self) -> Vec<(String, Vec<String>)> {
        let Some(parts) = self.imp().parts.get() else {
            return Vec::new();
        };
        let page = self.visible_page();
        let models: Vec<gio::ListModel> = match page.as_deref() {
            Some(LIST) => parts
                .selection
                .model()
                .and_downcast::<gtk::FlattenListModel>()
                .and_then(|flat| flat.model())
                .map(|models| {
                    (0..models.n_items())
                        .filter_map(|at| models.item(at).and_downcast::<gio::ListModel>())
                        .collect()
                })
                .unwrap_or_default(),
            Some(FOUND) => parts.found_selection.model().into_iter().collect(),
            _ => Vec::new(),
        };
        models
            .iter()
            .filter_map(|model| {
                let rows: Vec<(Option<LibrarySection>, String)> = (0..model.n_items())
                    .filter_map(|at| model.item(at).and_downcast::<gtk::TreeListRow>())
                    .filter_map(|row| {
                        let node = row.item().and_downcast::<LibraryNode>()?;
                        let depth = usize::try_from(row.depth()).unwrap_or_default();
                        Some((node.section(), format!("{}{}", "  ".repeat(depth), node.title())))
                    })
                    .collect();
                let section = rows.first()?.0?;
                let title = if page.as_deref() == Some(FOUND) {
                    String::new()
                } else {
                    section_title(section)
                };
                Some((title, rows.into_iter().map(|(_, shown)| shown).collect()))
            })
            .collect()
    }

    pub(crate) fn visible_page(&self) -> Option<String> {
        self.imp().stack.visible_child_name().map(|name| name.to_string())
    }

    pub(crate) fn node(&self, section: LibrarySection, title: &str) -> Option<LibraryNode> {
        let parts = self.imp().parts.get()?;
        let nodes = parts.nodes.borrow();
        nodes
            .iter()
            .find(|((held, _), node)| *held == section && node.title() == title)
            .map(|(_, node)| node.clone())
    }

    pub(crate) fn found_node(&self, title: &str) -> Option<LibraryNode> {
        let parts = self.imp().parts.get()?;
        let nodes = parts.found_nodes.borrow();
        nodes.values().find(|node| node.title() == title).cloned()
    }

    pub(crate) fn tree_row(&self, title: &str) -> Option<gtk::TreeListRow> {
        let parts = self.imp().parts.get()?;
        (0..parts.tree.n_items())
            .filter_map(|at| parts.tree.item(at).and_downcast::<gtk::TreeListRow>())
            .find(|row| {
                row.item()
                    .and_downcast::<LibraryNode>()
                    .is_some_and(|node| node.title() == title)
            })
    }

    // The row on screen that shows `title` in `section`.
    pub(crate) fn row(&self, section: LibrarySection, title: &str) -> Option<LibraryRow> {
        crate::test_support::descendants(self)
            .into_iter()
            .filter_map(|widget| widget.downcast::<LibraryRow>().ok())
            .find(|row| {
                row.is_mapped()
                    && row
                        .node()
                        .is_some_and(|node| node.section() == Some(section) && node.title() == title)
            })
    }
}
