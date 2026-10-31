use std::cell::{OnceCell, RefCell};

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{glib, pango};
use libadwaita as adw;

use super::sidebar_object::SidebarObject;
use super::tree_menu::DISCONNECT_SESSION;
use super::tree_node::{NodeKind, TreeNode};

/// The class every connection's icon carries, which its colour's rule
/// in style.css needs beside the colour's class.
const CONNECTION_ICON: &str = "tp-connection-icon";

mod imp {
    use super::*;

    pub struct TreeRow {
        pub(in super::super) icon: gtk::Image,
        pub(in super::super) name: gtk::Label,
        /// A key's type, as a dim suffix: its icon alone would leave the
        /// user to learn which picture means a sorted set.
        pub(super) kind: OnceCell<gtk::Label>,
        pub(super) status: OnceCell<Status>,
        /// The list item the row is in, which a screen reader describes.
        pub(crate) item: glib::WeakRef<gtk::ListItem>,
        /// The node the row shows, and its watches.
        pub(super) watched: RefCell<Option<(TreeNode, Vec<glib::SignalHandlerId>)>>,
        pub(super) bindings: RefCell<Vec<glib::Binding>>,
    }

    // A widget's accessible role is fixed once it is made, so the parts a
    // screen reader skips are built with theirs.
    impl Default for TreeRow {
        fn default() -> Self {
            Self {
                icon: gtk::Image::builder()
                    .pixel_size(16)
                    .accessible_role(gtk::AccessibleRole::Presentation)
                    .build(),
                name: gtk::Label::builder()
                    .xalign(0.0)
                    .hexpand(true)
                    .ellipsize(pango::EllipsizeMode::End)
                    .build(),
                kind: OnceCell::new(),
                status: OnceCell::new(),
                item: glib::WeakRef::new(),
                watched: RefCell::new(None),
                bindings: RefCell::new(Vec::new()),
            }
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for TreeRow {
        const NAME: &'static str = "TableProTreeRow";
        type Type = super::TreeRow;
        type ParentType = gtk::Box;
    }

    impl ObjectImpl for TreeRow {
        fn constructed(&self) {
            self.parent_constructed();
            let row = self.obj();
            row.set_spacing(8);
            // Asked for on hover: setting a tooltip queries the pointer's
            // position, and a search binds two hundred rows at once.
            row.set_has_tooltip(true);
            row.connect_query_tooltip(|row, _, _, _, tooltip| {
                let Some(object) = row.shown().and_downcast::<SidebarObject>() else {
                    return false;
                };
                tooltip.set_text(Some(&object.qualified_name()));
                true
            });
            row.append(&self.icon);
            row.append(&self.name);
        }
    }

    impl WidgetImpl for TreeRow {}
    impl BoxImpl for TreeRow {}
}

/// What a connection is doing, made for the first connection a row shows:
/// most rows show tables, and opening a schema makes two hundred rows at
/// once.
pub(super) struct Status {
    pub(super) spinner: adw::Spinner,
    /// Disconnects an open connection, as GNOME Files ejects a mount.
    pub(super) eject: gtk::Button,
    /// Says why the connection could not connect, or what it lost.
    pub(super) problem: gtk::Image,
}

impl Status {
    fn new() -> Self {
        let eject = gtk::Button::builder()
            .icon_name(crate::ui::icons::MEDIA_EJECT)
            .valign(gtk::Align::Center)
            .visible(false)
            .build();
        eject.add_css_class("flat");
        crate::ui::a11y::describe_icon_button(&eject, &crate::i18n::gettext("Disconnect"), None);
        // The target first, or GTK warns that the action takes one.
        eject.set_action_target_value(Some(&String::new().to_variant()));
        eject.set_action_name(Some(DISCONNECT_SESSION));
        Self {
            spinner: adw::Spinner::builder().visible(false).build(),
            eject,
            problem: gtk::Image::builder()
                .icon_name(crate::ui::icons::NETWORK_ERROR)
                .accessible_role(gtk::AccessibleRole::Presentation)
                .visible(false)
                .build(),
        }
    }
}

glib::wrapper! {
    /// One row of the connection tree: an icon and a name, a key's type,
    /// and for a connection what it is doing.
    pub struct TreeRow(ObjectSubclass<imp::TreeRow>)
        @extends gtk::Box, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget, gtk::Orientable;
}

impl TreeRow {
    pub(crate) fn new(item: &gtk::ListItem) -> Self {
        let row: Self = glib::Object::new();
        row.imp().item.set(Some(item));
        row
    }

    /// What the row shows: a table, a key, or a node of the tree, under
    /// the tree's row or, in the search's list, as it is.
    fn shown(&self) -> Option<glib::Object> {
        let item = self.imp().item.upgrade()?.item()?;
        match item.downcast::<gtk::TreeListRow>() {
            Ok(row) => row.item(),
            Err(item) => Some(item),
        }
    }

    /// Where the row is in its list, while it shows one.
    pub(crate) fn position(&self) -> Option<u32> {
        let item = self.imp().item.upgrade()?;
        item.item().is_some().then(|| item.position())
    }

    /// The label of a key's type, made for the first key the row shows.
    pub(super) fn kind(&self) -> &gtk::Label {
        let imp = self.imp();
        imp.kind.get_or_init(|| {
            let kind = gtk::Label::builder()
                .accessible_role(gtk::AccessibleRole::Presentation)
                .visible(false)
                .build();
            kind.add_css_class("dimmed");
            kind.add_css_class("caption");
            self.insert_child_after(&kind, Some(&imp.name));
            kind
        })
    }

    pub(super) fn status(&self) -> &Status {
        self.imp().status.get_or_init(|| {
            let status = Status::new();
            self.append(&status.spinner);
            self.append(&status.eject);
            self.append(&status.problem);
            status
        })
    }

    /// Show `object`, the item of the row's list row.
    pub(crate) fn bind(&self, object: &glib::Object) {
        self.unbind();
        let Some(item) = self.imp().item.upgrade() else {
            return;
        };
        if let Some(object) = object.downcast_ref::<SidebarObject>() {
            self.show_object(&item, object);
        } else if let Some(node) = object.downcast_ref::<TreeNode>() {
            self.show_node(&item, node);
        }
    }

    /// Let go of the node the row showed.
    pub(crate) fn unbind(&self) {
        let imp = self.imp();
        for binding in imp.bindings.take() {
            binding.unbind();
        }
        if let Some((node, watches)) = imp.watched.take() {
            for watch in watches {
                node.disconnect(watch);
            }
        }
    }

    fn show_object(&self, item: &gtk::ListItem, object: &SidebarObject) {
        let imp = self.imp();
        // A recycled row usually shows a table again, and setting the
        // same icon or description still redraws or re-announces it.
        let icon = object.icon_name();
        if imp.icon.icon_name().as_deref() != Some(icon) {
            imp.icon.set_icon_name(Some(icon));
        }
        set_classes(&imp.icon, &[]);
        imp.icon.set_visible(true);
        imp.name.set_label(&object.name());
        set_classes(&imp.name, &[]);
        match object.type_label() {
            Some(kind) => {
                let label = self.kind();
                label.set_label(&kind);
                label.set_visible(true);
            }
            None => self.hide_kind(),
        }
        self.show_suffix(false, false, false);
        describe(item, &object.kind_name());
        set_choosable(item, true);
    }

    fn show_node(&self, item: &gtk::ListItem, node: &TreeNode) {
        let imp = self.imp();
        self.hide_kind();
        imp.bindings
            .borrow_mut()
            .push(node.bind_property("title", &imp.name, "label").sync_create().build());
        let placeholder = node.kind() == NodeKind::Placeholder;
        let classes: &[&str] = if placeholder { &["dimmed"] } else { &[] };
        set_classes(&imp.name, classes);
        set_choosable(item, !placeholder);
        imp.icon.set_visible(!placeholder);
        match node.kind() {
            NodeKind::Group => self.show_plain(item, crate::ui::icons::FOLDER, &crate::i18n::gettext("Group")),
            NodeKind::Schema => {
                self.show_plain(item, crate::ui::icons::DRIVE_HARDDISK, &crate::i18n::gettext("Schema"));
            }
            NodeKind::Placeholder => self.show_plain(item, crate::ui::icons::VIEW_GRID, ""),
            NodeKind::Connection => self.show_connection(node),
        }
    }

    fn show_plain(&self, item: &gtk::ListItem, icon: &str, description: &str) {
        let imp = self.imp();
        if imp.icon.icon_name().as_deref() != Some(icon) {
            imp.icon.set_icon_name(Some(icon));
        }
        set_classes(&imp.icon, &[]);
        self.show_suffix(false, false, false);
        describe(item, description);
    }

    /// A connection's icon and colour, and what it is doing, which follow
    /// the node while the row shows it.
    fn show_connection(&self, node: &TreeNode) {
        let imp = self.imp();
        imp.bindings.borrow_mut().push(
            node.bind_property("icon-name", &imp.icon, "icon-name")
                .sync_create()
                .build(),
        );
        if let Some(key) = node.key() {
            self.status()
                .eject
                .set_action_target_value(Some(&crate::ui::session_target::to_variant(&key)));
        }
        let mut watches = Vec::new();
        for property in ["color-class", "open", "busy", "problem"] {
            let row = self.downgrade();
            watches.push(node.connect_notify_local(Some(property), move |node, _| {
                if let Some(row) = row.upgrade() {
                    row.follow(node);
                }
            }));
        }
        imp.watched.replace(Some((node.clone(), watches)));
        self.follow(node);
    }

    fn follow(&self, node: &TreeNode) {
        let imp = self.imp();
        let color = node.color_class();
        if color.is_empty() {
            set_classes(&imp.icon, &[]);
        } else {
            set_classes(&imp.icon, &[CONNECTION_ICON, color.as_str()]);
        }
        let problem = node.problem();
        let (open, busy, failed) = (node.open(), node.busy(), !problem.is_empty());
        self.show_suffix(busy, open && !busy && !failed, !busy && failed);
        let shown = &self.status().problem;
        if failed && shown.tooltip_text().as_deref() != Some(problem.as_str()) {
            shown.set_tooltip_text(Some(&problem));
        }
        let description = if busy && !open {
            crate::i18n::gettext("Connection, connecting")
        } else if open && failed {
            crate::i18n::gettext_f("Connection, connected. {problem}", &[("problem", &problem)])
        } else if open {
            crate::i18n::gettext("Connection, connected")
        } else if failed {
            crate::i18n::gettext_f("Connection, could not connect. {problem}", &[("problem", &problem)])
        } else {
            crate::i18n::gettext("Connection")
        };
        if let Some(item) = imp.item.upgrade() {
            describe(&item, &description);
        }
    }

    fn show_suffix(&self, busy: bool, eject: bool, problem: bool) {
        let status = match self.imp().status.get() {
            Some(status) => status,
            None if busy || eject || problem => self.status(),
            None => return,
        };
        status.spinner.set_visible(busy);
        status.eject.set_visible(eject);
        status.problem.set_visible(problem);
    }

    fn hide_kind(&self) {
        if let Some(kind) = self.imp().kind.get() {
            kind.set_visible(false);
        }
    }
}

/// The getter's binding cannot read an unset description, which a new
/// row has; the property can.
fn describe(item: &gtk::ListItem, description: &str) {
    if item.property::<Option<String>>("accessible-description").as_deref() != Some(description) {
        item.set_accessible_description(description);
    }
}

/// A placeholder is neither opened nor selected.
fn set_choosable(item: &gtk::ListItem, choosable: bool) {
    if item.is_activatable() != choosable {
        item.set_activatable(choosable);
    }
    if item.is_selectable() != choosable {
        item.set_selectable(choosable);
    }
}

/// Set as a whole list rather than added one by one, so a colour change
/// never leaves the previous colour's class behind.
fn set_classes(widget: &impl IsA<gtk::Widget>, classes: &[&str]) {
    let held = widget.css_classes();
    let same = held.len() == classes.len() && held.iter().zip(classes).all(|(held, wanted)| held.as_str() == *wanted);
    if !same {
        widget.set_css_classes(classes);
    }
}
