use std::cell::{Cell, RefCell};

use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_session::SessionKey;
use tablepro_storage::{ConnectionColor, ConnectionIcon};

/// What a row of the connection tree above the tables stands for.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) enum NodeKind {
    /// A group the user filed connections under.
    #[default]
    Group,
    /// A saved connection, or a file the window has open.
    Connection,
    /// One schema, or database, of an open connection.
    Schema,
}

mod imp {
    use super::*;

    #[derive(Default, glib::Properties)]
    #[properties(wrapper_type = super::TreeNode)]
    pub struct TreeNode {
        pub(super) kind: Cell<NodeKind>,
        pub(super) title: RefCell<String>,
        pub(super) key: RefCell<Option<SessionKey>>,
        /// The schema a schema row lists. `None` for the objects an
        /// engine lists with no schema.
        pub(super) schema: RefCell<Option<String>>,
        pub(super) color: Cell<Option<ConnectionColor>>,
        pub(super) icon: Cell<Option<ConnectionIcon>>,
        pub(super) file_based: Cell<bool>,
        pub(super) children: RefCell<Option<gio::ListModel>>,
        /// The connection has a session open in this window.
        #[property(get, set)]
        pub(super) open: Cell<bool>,
        /// The connection is connecting in this window.
        #[property(get, set)]
        pub(super) connecting: Cell<bool>,
        /// Counts the changes to the row's name, colour and icon, so a
        /// row on screen follows a connection edited while it shows.
        #[property(get)]
        pub(super) appearance: Cell<u32>,
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
    pub(crate) fn group(title: &str) -> Self {
        let node: Self = glib::Object::new();
        let imp = node.imp();
        imp.kind.set(NodeKind::Group);
        imp.title.replace(title.to_owned());
        imp.children.replace(Some(gio::ListStore::new::<TreeNode>().upcast()));
        node
    }

    /// A connection's row. Its children are its schemas while it is open,
    /// and none until then; the row can still be expanded, which connects.
    pub(crate) fn connection(key: SessionKey) -> Self {
        let node: Self = glib::Object::new();
        let imp = node.imp();
        imp.kind.set(NodeKind::Connection);
        imp.key.replace(Some(key));
        imp.children.replace(Some(gio::ListStore::new::<TreeNode>().upcast()));
        node
    }

    pub(crate) fn schema(title: &str, schema: Option<String>, objects: gio::ListModel) -> Self {
        let node: Self = glib::Object::new();
        let imp = node.imp();
        imp.kind.set(NodeKind::Schema);
        imp.title.replace(title.to_owned());
        imp.schema.replace(schema);
        imp.children.replace(Some(objects));
        node
    }

    pub(crate) fn kind(&self) -> NodeKind {
        self.imp().kind.get()
    }

    pub(crate) fn title(&self) -> String {
        self.imp().title.borrow().clone()
    }

    pub(crate) fn key(&self) -> Option<SessionKey> {
        self.imp().key.borrow().clone()
    }

    pub(crate) fn schema_name(&self) -> Option<String> {
        self.imp().schema.borrow().clone()
    }

    pub(crate) fn color(&self) -> Option<ConnectionColor> {
        self.imp().color.get()
    }

    pub(crate) fn connection_icon(&self) -> Option<ConnectionIcon> {
        self.imp().icon.get()
    }

    pub(crate) fn file_based(&self) -> bool {
        self.imp().file_based.get()
    }

    /// Name the connection's row after the saved connection as it is now.
    pub(crate) fn describe(
        &self,
        title: &str,
        color: Option<ConnectionColor>,
        icon: Option<ConnectionIcon>,
        file_based: bool,
    ) {
        let imp = self.imp();
        let changed = *imp.title.borrow() != title
            || imp.color.get() != color
            || imp.icon.get() != icon
            || imp.file_based.get() != file_based;
        if !changed {
            return;
        }
        imp.title.replace(title.to_owned());
        imp.color.set(color);
        imp.icon.set(icon);
        imp.file_based.set(file_based);
        imp.appearance.set(imp.appearance.get().wrapping_add(1));
        self.notify_appearance();
    }

    pub(crate) fn children(&self) -> Option<gio::ListModel> {
        self.imp().children.borrow().clone()
    }

    /// The store of a group's connections or a connection's schemas.
    pub(crate) fn child_store(&self) -> Option<gio::ListStore> {
        self.children().and_downcast::<gio::ListStore>()
    }
}
