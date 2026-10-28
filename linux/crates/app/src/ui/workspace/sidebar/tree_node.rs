use std::cell::{Cell, RefCell};

use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_session::SessionKey;

use super::sidebar_list::SidebarList;

/// What a row of the connection tree above the tables stands for.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) enum NodeKind {
    /// A group the user filed connections under.
    #[default]
    Group,
    /// A saved connection, or one the window opens or connects to that
    /// no saved connection names.
    Connection,
    /// One schema, or database, of an open connection.
    Schema,
    /// Says an open connection lists nothing.
    Placeholder,
}

mod imp {
    use super::*;

    #[derive(Default, glib::Properties)]
    #[properties(wrapper_type = super::TreeNode)]
    pub struct TreeNode {
        pub(super) kind: Cell<NodeKind>,
        pub(super) key: RefCell<Option<SessionKey>>,
        /// The schema a schema row lists. `None` for the objects an
        /// engine lists with no schema.
        pub(super) schema: RefCell<Option<String>>,
        /// What the tree lists under the row.
        pub(super) children: RefCell<Option<gio::ListModel>>,
        /// A schema's tables the search finds.
        pub(super) found: RefCell<Option<gio::ListModel>>,
        #[property(get, set)]
        pub(super) title: RefCell<String>,
        #[property(get, set)]
        pub(super) icon_name: RefCell<String>,
        /// The connection's colour, as the class `connection_appearance`
        /// names it, or empty for none.
        #[property(get, set)]
        pub(super) color_class: RefCell<String>,
        /// The connection has a session open in this window.
        #[property(get, set)]
        pub(super) open: Cell<bool>,
        /// The connection is connecting, or its session is busy.
        #[property(get, set)]
        pub(super) busy: Cell<bool>,
        /// Why the connection could not connect, or what its session
        /// lost, or empty.
        #[property(get, set)]
        pub(super) problem: RefCell<String>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for TreeNode {
        const NAME: &'static str = "TableProTreeNode";
        type Type = super::TreeNode;
    }

    #[glib::derived_properties]
    impl ObjectImpl for TreeNode {}
}

glib::wrapper! {
    pub struct TreeNode(ObjectSubclass<imp::TreeNode>);
}

impl TreeNode {
    fn of(kind: NodeKind, title: &str) -> Self {
        let node: Self = glib::Object::builder().property("title", title).build();
        node.imp().kind.set(kind);
        node
    }

    pub(crate) fn group(title: &str) -> Self {
        let node = Self::of(NodeKind::Group, title);
        node.imp()
            .children
            .replace(Some(gio::ListStore::new::<TreeNode>().upcast()));
        node
    }

    /// A connection's row, which lists nothing until its session opens.
    pub(crate) fn connection(key: SessionKey, title: &str) -> Self {
        let node = Self::of(NodeKind::Connection, title);
        node.imp().key.replace(Some(key));
        node
    }

    /// A schema's row, over its tables and the ones the search finds.
    pub(crate) fn schema(title: &str, schema: Option<String>) -> Self {
        let node = Self::of(NodeKind::Schema, title);
        let imp = node.imp();
        imp.schema.replace(schema);
        imp.children.replace(Some(SidebarList::new().upcast()));
        imp.found.replace(Some(SidebarList::new().upcast()));
        node
    }

    pub(crate) fn placeholder(title: &str) -> Self {
        Self::of(NodeKind::Placeholder, title)
    }

    pub(crate) fn kind(&self) -> NodeKind {
        self.imp().kind.get()
    }

    pub(crate) fn key(&self) -> Option<SessionKey> {
        self.imp().key.borrow().clone()
    }

    pub(crate) fn schema_name(&self) -> Option<String> {
        self.imp().schema.borrow().clone()
    }

    pub(crate) fn set_schema_name(&self, schema: Option<String>) {
        self.imp().schema.replace(schema);
    }

    pub(crate) fn children(&self) -> Option<gio::ListModel> {
        self.imp().children.borrow().clone()
    }

    pub(crate) fn found(&self) -> Option<gio::ListModel> {
        self.imp().found.borrow().clone()
    }

    pub(crate) fn set_found(&self, found: SidebarList) {
        self.imp().found.replace(Some(found.upcast()));
    }

    /// What an open connection lists in the tree; none once it closes.
    pub(crate) fn set_children(&self, children: Option<gio::ListModel>) {
        self.imp().children.replace(children);
    }

    /// The store of a group's connections.
    pub(crate) fn child_store(&self) -> Option<gio::ListStore> {
        self.children().and_downcast::<gio::ListStore>()
    }

    /// A schema's tables.
    pub(crate) fn rows(&self) -> Option<SidebarList> {
        self.children().and_downcast::<SidebarList>()
    }

    /// The schema's tables the search finds.
    pub(crate) fn found_rows(&self) -> Option<SidebarList> {
        self.found().and_downcast::<SidebarList>()
    }

    /// Change the properties that differ, so a row on screen redraws and
    /// says again only what changed.
    pub(crate) fn update(&self, title: &str, icon_name: &str, color_class: &str) {
        if self.title() != title {
            self.set_title(title);
        }
        if self.icon_name() != icon_name {
            self.set_icon_name(icon_name);
        }
        if self.color_class() != color_class {
            self.set_color_class(color_class);
        }
    }

    pub(crate) fn update_state(&self, open: bool, busy: bool, problem: &str) {
        if self.open() != open {
            self.set_open(open);
        }
        if self.busy() != busy {
            self.set_busy(busy);
        }
        if self.problem() != problem {
            self.set_problem(problem);
        }
    }
}
