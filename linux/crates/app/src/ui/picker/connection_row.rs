use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, gio, glib, pango};
use tablepro_storage::ConnectionTag;

use super::connection_menu::{ROW, ROW_MENU, connection_menu};
use super::group_menu::group_menu;
use super::library_node::LibraryNode;
use super::picker_actions::{choice_actions, insert_group_actions};
use crate::application::{ShortcutOwner, local_shortcut_controller};
use crate::services::library_outline::{DropSpot, LibraryItem, LibrarySection};
use crate::services::saved_connection_list::SavedConnectionList;
use crate::ui::a11y::describe_icon_button;
use crate::ui::connection_appearance::{color_name, dot_classes, tag_pills};
use crate::ui::library_drag::{Zone, ZoneKind, drag_source, drop_target, zone};

mod imp {
    use super::*;

    pub struct LibraryRow {
        pub(super) dot: gtk::Box,
        pub(super) icon: gtk::Image,
        pub(super) text: gtk::Box,
        pub(super) title: gtk::Label,
        pub(super) subtitle: gtk::Label,
        pub(super) pills: RefCell<Option<(Vec<ConnectionTag>, gtk::Box)>>,
        pub(super) menu: gtk::MenuButton,
        pub(super) item: glib::WeakRef<gtk::ListItem>,
        pub(super) shown: RefCell<Option<super::Shown>>,
    }

    // A widget's accessible role is fixed once it is made, so the parts a screen reader skips are built with theirs.
    impl Default for LibraryRow {
        fn default() -> Self {
            let subtitle = gtk::Label::builder()
                .xalign(0.0)
                .ellipsize(pango::EllipsizeMode::End)
                .visible(false)
                .build();
            subtitle.add_css_class("caption");
            subtitle.add_css_class("dimmed");
            // Out of the focus chain: GtkTreeExpander gives the keyboard to a focusable child, and
            // Enter there would open the menu instead of the row. Menu and Shift+F10 open it.
            let menu = gtk::MenuButton::builder()
                .icon_name(crate::ui::icons::VIEW_MORE)
                .valign(gtk::Align::Center)
                .can_focus(false)
                .build();
            menu.add_css_class("flat");
            Self {
                dot: gtk::Box::builder()
                    .valign(gtk::Align::Center)
                    .visible(false)
                    .accessible_role(gtk::AccessibleRole::Presentation)
                    .build(),
                icon: gtk::Image::builder()
                    .pixel_size(16)
                    .valign(gtk::Align::Center)
                    .accessible_role(gtk::AccessibleRole::Presentation)
                    .build(),
                text: gtk::Box::builder()
                    .orientation(gtk::Orientation::Vertical)
                    .valign(gtk::Align::Center)
                    .hexpand(true)
                    .margin_top(2)
                    .margin_bottom(2)
                    .build(),
                title: gtk::Label::builder()
                    .xalign(0.0)
                    .ellipsize(pango::EllipsizeMode::End)
                    .build(),
                subtitle,
                pills: RefCell::new(None),
                menu,
                item: glib::WeakRef::new(),
                shown: RefCell::new(None),
            }
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for LibraryRow {
        const NAME: &'static str = "TableProLibraryRow";
        type Type = super::LibraryRow;
        type ParentType = gtk::Box;
    }

    impl ObjectImpl for LibraryRow {
        fn constructed(&self) {
            self.parent_constructed();
            let row = self.obj();
            row.set_spacing(8);
            self.text.append(&self.title);
            self.text.append(&self.subtitle);
            row.append(&self.dot);
            row.append(&self.icon);
            row.append(&self.text);
            row.append(&self.menu);
        }
    }

    impl WidgetImpl for LibraryRow {}
    impl BoxImpl for LibraryRow {}
}

glib::wrapper! {
    pub struct LibraryRow(ObjectSubclass<imp::LibraryRow>)
        @extends gtk::Box, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget, gtk::Orientable;
}

// The node a row shows and the watches it holds while it shows it.
pub(super) struct Shown {
    node: LibraryNode,
    redraw: glib::SignalHandlerId,
    expanded: Option<(gtk::TreeListRow, glib::SignalHandlerId)>,
    children: Option<(gio::ListStore, glib::SignalHandlerId)>,
}

impl LibraryRow {
    fn new(item: &gtk::ListItem) -> Self {
        let row: Self = glib::Object::new();
        row.imp().item.set(Some(item));
        row
    }

    pub(crate) fn node(&self) -> Option<LibraryNode> {
        self.imp().shown.borrow().as_ref().map(|shown| shown.node.clone())
    }

    pub(crate) fn menu_button(&self) -> gtk::MenuButton {
        self.imp().menu.clone()
    }

    pub(crate) fn popup_menu(&self) {
        self.imp().menu.popup();
    }

    #[cfg(test)]
    pub(crate) fn list_item(&self) -> Option<gtk::ListItem> {
        self.imp().item.upgrade()
    }

    #[cfg(test)]
    pub(crate) fn pill_names(&self) -> Vec<String> {
        crate::test_support::descendants(self)
            .into_iter()
            .filter(|widget| widget.has_css_class("tp-tag-pill") && widget.is_visible())
            .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
            .map(|label| label.label().to_string())
            .collect()
    }

    #[cfg(test)]
    pub(crate) fn shown_text(&self) -> (gtk::Label, gtk::Label, gtk::Image) {
        let imp = self.imp();
        (imp.title.clone(), imp.subtitle.clone(), imp.icon.clone())
    }

    fn bind(&self, node: &LibraryNode, list_row: &gtk::TreeListRow, on_expanded: impl Fn(&gtk::TreeListRow) + 'static) {
        self.unbind();
        let weak = self.downgrade();
        let redraw = node.connect_revision_notify(move |node| {
            if let Some(row) = weak.upgrade() {
                row.draw(node);
            }
        });
        let expander = self.parent().and_downcast::<gtk::TreeExpander>();
        let children = node.children().map(|store| {
            let hiding = expander.as_ref().map(|expander| expander.downgrade());
            let handler = store.connect_items_changed(move |store, _, _, _| {
                if let Some(expander) = hiding.as_ref().and_then(|expander| expander.upgrade()) {
                    expander.set_hide_expander(store.n_items() == 0);
                }
            });
            (store, handler)
        });
        if let Some(expander) = &expander {
            expander.set_hide_expander(children.as_ref().is_some_and(|(store, _)| store.n_items() == 0));
        }
        let expanded = children.as_ref().map(|_| {
            let stating = expander.as_ref().map(|expander| expander.downgrade());
            let handler = list_row.connect_expanded_notify(move |list_row| {
                // A row GTK took out of its tree says it folded; it did not.
                if !list_row.is_expandable() {
                    return;
                }
                // GTK states the change on the expander's arrow, not on the expander a screen reader is on.
                if let Some(expander) = stating.as_ref().and_then(|expander| expander.upgrade()) {
                    expander.update_state(&[gtk::accessible::State::Expanded(Some(list_row.is_expanded()))]);
                }
                on_expanded(list_row);
            });
            (list_row.clone(), handler)
        });
        self.imp().shown.replace(Some(Shown {
            node: node.clone(),
            redraw,
            expanded,
            children,
        }));
        self.draw(node);
    }

    fn unbind(&self) {
        let Some(shown) = self.imp().shown.take() else {
            return;
        };
        shown.node.disconnect(shown.redraw);
        if let Some((list_row, handler)) = shown.expanded {
            list_row.disconnect(handler);
        }
        if let Some((store, handler)) = shown.children {
            store.disconnect(handler);
        }
    }

    // A recycled row usually shows its like again, and setting the same text still redraws or re-announces it.
    fn draw(&self, node: &LibraryNode) {
        let imp = self.imp();
        let title = node.title();
        if imp.title.label().as_str() != title {
            imp.title.set_label(&title);
        }
        let subtitle = node.subtitle();
        if imp.subtitle.label().as_str() != subtitle {
            imp.subtitle.set_label(&subtitle);
        }
        imp.subtitle.set_visible(!subtitle.is_empty());
        let icon = node.icon_name();
        if imp.icon.icon_name().as_deref() != Some(icon.as_str()) {
            imp.icon.set_icon_name(Some(&icon));
        }
        self.draw_dot(node);
        self.draw_pills(node.tags());
        let options = if node.children().is_some() {
            crate::i18n::gettext("Group Options")
        } else {
            crate::i18n::gettext("Connection Options")
        };
        if imp.menu.tooltip_text().as_deref() != Some(options.as_str()) {
            describe_icon_button(&imp.menu, &options, Some(&format!("{ROW}.{ROW_MENU}")));
        }
        if let Some(item) = imp.item.upgrade() {
            describe(&item, &title, &node.description());
        }
    }

    fn draw_dot(&self, node: &LibraryNode) {
        let dot = &self.imp().dot;
        let color = node.color();
        let classes = dot_classes(color);
        let held = dot.css_classes();
        if held.len() != classes.len() || held.iter().zip(&classes).any(|(held, wanted)| held.as_str() != *wanted) {
            dot.set_css_classes(&classes);
        }
        dot.set_visible(color.is_some());
        dot.set_tooltip_text(color.map(color_name).as_deref());
    }

    fn draw_pills(&self, tags: Vec<ConnectionTag>) {
        let imp = self.imp();
        if imp.pills.borrow().as_ref().is_some_and(|(shown, _)| *shown == tags) {
            return;
        }
        if let Some((_, old)) = imp.pills.take() {
            self.remove(&old);
        }
        let pills = tag_pills(&tags);
        self.insert_child_after(&pills, Some(&imp.text));
        imp.pills.replace(Some((tags, pills)));
    }
}

// The getter cannot read a label or description a new item lacks; the property can.
fn describe(item: &gtk::ListItem, label: &str, description: &str) {
    if item.property::<Option<String>>("accessible-label").as_deref() != Some(label) {
        item.set_accessible_label(label);
    }
    if item.property::<Option<String>>("accessible-description").as_deref() != Some(description) {
        item.set_accessible_description(description);
    }
}

// Focus sits on the expander, not the list item, so the keys, the menu and the drags hang on it.
pub(crate) fn library_item(item: &gtk::ListItem, source: &gtk::Widget, list: &Rc<SavedConnectionList>, moves: bool) {
    item.set_focusable(false);
    let row = LibraryRow::new(item);
    let expander = gtk::TreeExpander::new();
    expander.set_indent_for_icon(true);
    expander.set_child(Some(&row));
    expander.insert_action_group(ROW, Some(&menu_actions(&row)));
    expander.add_controller(local_shortcut_controller(ShortcutOwner::PickerRow));
    expander.add_controller(secondary_click(&row));
    fill_menu_on_popup(&row, source, list);
    if moves {
        let dragged = item.downgrade();
        drag_source(&expander, move || {
            let node = node_of(&dragged.upgrade()?)?;
            Some((node.section()?, node.item()?))
        });
        let (spot, list) = (item.downgrade(), list.clone());
        drop_target(
            &expander,
            move |y, height| {
                let item = spot.upgrade()?;
                let list_row = item.item().and_downcast::<gtk::TreeListRow>()?;
                drop_spot(&list_row.item().and_downcast::<LibraryNode>()?, &list_row, y, height)
            },
            move || list.outline(),
        );
    }
    item.set_child(Some(&expander));
}

pub(crate) fn bind_row(item: &gtk::ListItem, on_expanded: impl Fn(&gtk::TreeListRow) + 'static) {
    let (Some(expander), Some(list_row)) = (
        item.child().and_downcast::<gtk::TreeExpander>(),
        item.item().and_downcast::<gtk::TreeListRow>(),
    ) else {
        return;
    };
    expander.set_list_row(Some(&list_row));
    if let (Some(row), Some(node)) = (
        expander.child().and_downcast::<LibraryRow>(),
        list_row.item().and_downcast::<LibraryNode>(),
    ) {
        row.bind(&node, &list_row, on_expanded);
    }
}

pub(crate) fn unbind_row(item: &gtk::ListItem) {
    let Some(expander) = item.child().and_downcast::<gtk::TreeExpander>() else {
        return;
    };
    if let Some(row) = expander.child().and_downcast::<LibraryRow>() {
        row.unbind();
    }
    expander.set_list_row(None);
}

fn node_of(item: &gtk::ListItem) -> Option<LibraryNode> {
    item.item()
        .and_downcast::<gtk::TreeListRow>()?
        .item()
        .and_downcast::<LibraryNode>()
}

// Recent is ordered by the last connect, so nothing lands on it.
fn drop_spot(node: &LibraryNode, list_row: &gtk::TreeListRow, y: f64, height: f64) -> Option<(DropSpot, bool)> {
    match (node.section()?, node.item()?) {
        (LibrarySection::Recent, _) => None,
        (LibrarySection::Tree, LibraryItem::Group(id)) => Some(match zone(ZoneKind::Group, y, height) {
            Zone::Before => (DropSpot::Before(LibrarySection::Tree, LibraryItem::Group(id)), false),
            Zone::Into => (DropSpot::Into(id), false),
            Zone::After => (
                DropSpot::After(LibrarySection::Tree, LibraryItem::Group(id)),
                list_row.is_expanded(),
            ),
        }),
        (LibrarySection::Favourites, LibraryItem::Group(_)) => None,
        (section, item @ LibraryItem::Connection(_)) => Some(match zone(ZoneKind::Connection, y, height) {
            Zone::Before | Zone::Into => (DropSpot::Before(section, item), false),
            Zone::After => (DropSpot::After(section, item), false),
        }),
    }
}

fn menu_actions(row: &LibraryRow) -> gio::SimpleActionGroup {
    let actions = gio::SimpleActionGroup::new();
    let menu = gio::SimpleAction::new(ROW_MENU, None);
    let row = row.downgrade();
    menu.connect_activate(move |_, _| {
        if let Some(row) = row.upgrade() {
            row.popup_menu();
        }
    });
    actions.add_action(&menu);
    actions
}

fn secondary_click(row: &LibraryRow) -> gtk::GestureClick {
    let gesture = gtk::GestureClick::new();
    gesture.set_button(gdk::BUTTON_SECONDARY);
    let row = row.downgrade();
    gesture.connect_pressed(move |gesture, _, _, _| {
        gesture.set_state(gtk::EventSequenceState::Claimed);
        if let Some(row) = row.upgrade() {
            row.popup_menu();
        }
    });
    gesture
}

// Built as it opens, from the list as it is then: the row is recycled, and the list changes under it.
fn fill_menu_on_popup(row: &LibraryRow, source: &gtk::Widget, list: &Rc<SavedConnectionList>) {
    let button = row.menu_button();
    let (row, source, list) = (row.downgrade(), source.downgrade(), list.clone());
    button.set_create_popup_func(move |button| {
        let (Some(row), Some(source)) = (row.upgrade(), source.upgrade()) else {
            return;
        };
        if let Some(node) = row.node() {
            fill_menu(button, &source, &node, &list);
        }
    });
}

// The choices go on the button, under the menu, which the row's own Menu key action sits above.
fn fill_menu(button: &gtk::MenuButton, source: &gtk::Widget, node: &LibraryNode, list: &Rc<SavedConnectionList>) {
    let (Some(section), Some(item)) = (node.section(), node.item()) else {
        return;
    };
    let outline = list.outline();
    let reread = {
        let list = list.clone();
        move || list.outline()
    };
    match item {
        LibraryItem::Connection(id) => {
            let Some(saved) = outline.connection(id).cloned() else {
                return;
            };
            let tags = list.tags();
            button.insert_action_group(
                ROW,
                Some(&choice_actions(source, &saved, section, Rc::new(reread), &tags)),
            );
            button.set_menu_model(Some(&connection_menu(id, section, &outline, &tags)));
        }
        LibraryItem::Group(id) => {
            if outline.group(id).is_none() {
                return;
            }
            insert_group_actions(button, source, id, reread);
            button.set_menu_model(Some(&group_menu(id, &outline)));
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use gtk4::AccessibleProperty;
    use tablepro_core::DriverRegistry;
    use tablepro_storage::{
        ConnectionColor, ConnectionGroup, ConnectionGroupName, ConnectionIcon, ConnectionList, ConnectionStore,
        ConnectionTagName, SavedConnection, StoragePaths,
    };

    use super::*;
    use crate::test_support::{OwnedWindow, saved_connection, wait_until};
    use crate::ui::picker::connection_menu::tag_action;
    use crate::ui::picker::library_node::{Seen, connection_look, group_look};

    const WAIT: Duration = Duration::from_secs(10);

    fn tag(name: &str, color: ConnectionColor) -> ConnectionTag {
        ConnectionTag::new(ConnectionTagName::new(name).expect("a tag name"), color)
    }

    // A list of `nodes` drawn by the picker's rows in a window of its own.
    struct Rows {
        window: OwnedWindow<gtk::Window>,
        store: gio::ListStore,
        _list: Rc<SavedConnectionList>,
        _dir: tempfile::TempDir,
    }

    impl Rows {
        fn new(nodes: &[LibraryNode]) -> Self {
            let dir = tempfile::tempdir().expect("a temporary directory");
            let connections = ConnectionStore::new(&StoragePaths::under(dir.path(), "tablepro", crate::config::APP_ID));
            let list = SavedConnectionList::follow(&connections, std::sync::Arc::new(DriverRegistry::new()));
            let store = gio::ListStore::new::<LibraryNode>();
            store.extend_from_slice(nodes);
            let tree = gtk::TreeListModel::new(store.clone(), false, true, |item| {
                item.downcast_ref::<LibraryNode>()?
                    .children()
                    .map(|store| store.upcast())
            });
            let factory = gtk::SignalListItemFactory::new();
            let (source, shared) = (gtk::Box::new(gtk::Orientation::Vertical, 0), list.clone());
            factory.connect_setup(move |_, object| {
                if let Some(item) = object.downcast_ref::<gtk::ListItem>() {
                    library_item(item, source.upcast_ref(), &shared, false);
                }
            });
            factory.connect_bind(|_, object| {
                if let Some(item) = object.downcast_ref::<gtk::ListItem>() {
                    bind_row(item, |_| {});
                }
            });
            factory.connect_unbind(|_, object| {
                if let Some(item) = object.downcast_ref::<gtk::ListItem>() {
                    unbind_row(item);
                }
            });
            let view = gtk::ListView::new(Some(gtk::NoSelection::new(Some(tree))), Some(factory));
            let window = OwnedWindow::presented(gtk::Window::new());
            window.set_child(Some(&view));
            Self {
                window,
                store,
                _list: list,
                _dir: dir,
            }
        }

        fn row(&self, title: &str) -> LibraryRow {
            let mut found = None;
            wait_until(WAIT, || {
                found = crate::test_support::descendants(&*self.window)
                    .into_iter()
                    .filter_map(|widget| widget.downcast::<LibraryRow>().ok())
                    .find(|row| row.node().is_some_and(|node| node.title() == title));
                found.is_some()
            })
            .expect("the row");
            found.expect("the row")
        }
    }

    fn shown(saved: &SavedConnection, tags: &[ConnectionTag]) -> LibraryNode {
        let node = LibraryNode::connection(LibrarySection::Tree, saved.id);
        node.show(connection_look(
            saved,
            LibrarySection::Tree,
            Seen {
                file_based: false,
                host_path: None,
                path: None,
                tags,
                favourite: false,
            },
        ));
        node
    }

    fn item_says(row: &LibraryRow) -> (Option<String>, Option<String>) {
        let item = row.list_item().expect("the row's list item");
        (
            item.property::<Option<String>>("accessible-label"),
            item.property::<Option<String>>("accessible-description"),
        )
    }

    #[gtk4::test]
    fn the_row_shows_its_tags_and_its_item_says_them() {
        let (acme, production) = (
            tag("acme", ConnectionColor::Blue),
            tag("production", ConnectionColor::Red),
        );
        let saved = SavedConnection {
            tags: vec![production.id, acme.id],
            ..saved_connection("acme-prod")
        };
        let tags = [acme, production, tag("staging", ConnectionColor::Yellow)];
        let rows = Rows::new(&[shown(&saved, &tags)]);

        let row = rows.row("acme-prod");

        assert_eq!(row.pill_names(), ["acme", "production"]);
        assert_eq!(
            item_says(&row),
            (
                Some("acme-prod".to_owned()),
                Some("postgres · postgres@db:5432. Tags: acme, production".to_owned())
            )
        );
        let widget = row
            .parent()
            .and_then(|expander| expander.parent())
            .expect("the list's row");
        assert!(gtk::test_accessible_has_property(&widget, AccessibleProperty::Label));
        assert!(gtk::test_accessible_has_property(
            &widget,
            AccessibleProperty::Description
        ));
    }

    #[gtk4::test]
    fn a_row_without_tags_is_described_by_where_it_connects() {
        let saved = saved_connection("plain");
        let rows = Rows::new(&[shown(&saved, &[tag("acme", ConnectionColor::Blue)])]);

        let row = rows.row("plain");

        assert!(row.pill_names().is_empty());
        assert_eq!(
            item_says(&row),
            (Some("plain".to_owned()), Some("postgres · postgres@db:5432".to_owned()))
        );
        let (title, subtitle, _) = row.shown_text();
        assert!(!title.uses_markup());
        assert_eq!(subtitle.label(), "postgres · postgres@db:5432");
    }

    #[gtk4::test]
    fn a_name_is_shown_as_text_not_markup() {
        let saved = saved_connection("R&D <prod>");
        let rows = Rows::new(&[shown(&saved, &[])]);

        let (title, _, _) = rows.row("R&D <prod>").shown_text();

        assert!(!title.uses_markup());
        assert_eq!(title.label(), "R&D <prod>");
    }

    #[gtk4::test]
    fn the_row_shows_the_icon_the_node_names() {
        let saved = SavedConnection {
            icon: Some(ConnectionIcon::Cloud),
            ..saved_connection("cloud")
        };
        let rows = Rows::new(&[shown(&saved, &[])]);

        let (_, _, icon) = rows.row("cloud").shown_text();

        assert_eq!(
            icon.icon_name().as_deref(),
            Some(crate::ui::icons::connection_icon(ConnectionIcon::Cloud))
        );
    }

    #[gtk4::test]
    fn a_group_row_says_how_many_connections_it_holds_and_offers_group_options() {
        let group = ConnectionGroup::new(ConnectionGroupName::new("Work").expect("a group name"), None);
        let node = LibraryNode::group(group.id);
        node.show(group_look(&group, 2));
        let rows = Rows::new(&[node]);

        let row = rows.row("Work");

        assert_eq!(
            item_says(&row),
            (Some("Work".to_owned()), Some("Group, 2 connections".to_owned()))
        );
        assert_eq!(row.menu_button().tooltip_text().as_deref(), Some("Group Options"));
    }

    #[gtk4::test]
    fn an_empty_group_hides_its_expander_until_it_holds_something() {
        let group = ConnectionGroup::new(ConnectionGroupName::new("Work").expect("a group name"), None);
        let node = LibraryNode::group(group.id);
        node.show(group_look(&group, 0));
        let rows = Rows::new(std::slice::from_ref(&node));
        let expander = rows
            .row("Work")
            .parent()
            .and_downcast::<gtk::TreeExpander>()
            .expect("the row's expander");
        assert!(expander.hides_expander());

        let inside = shown(&saved_connection("api"), &[]);
        node.children().expect("the group's store").append(&inside);

        assert!(!expander.hides_expander());
        rows.row("api");
    }

    #[gtk4::test]
    fn a_changed_node_redraws_the_row_and_renames_its_item() {
        let saved = saved_connection("before");
        let node = shown(&saved, &[]);
        let rows = Rows::new(std::slice::from_ref(&node));
        let row = rows.row("before");

        node.show(connection_look(
            &SavedConnection {
                name: "after".to_owned(),
                ..saved
            },
            LibrarySection::Tree,
            Seen {
                file_based: false,
                host_path: None,
                path: None,
                tags: &[],
                favourite: false,
            },
        ));

        assert_eq!(row.shown_text().0.label(), "after");
        assert_eq!(item_says(&row).0.as_deref(), Some("after"));
        assert_eq!(rows.store.n_items(), 1);
    }

    #[gtk4::test]
    fn the_tag_items_are_ticked_at_the_tags_the_connection_has() {
        let (acme, production) = (
            tag("acme", ConnectionColor::Blue),
            tag("production", ConnectionColor::Red),
        );
        let saved = SavedConnection {
            tags: vec![production.id],
            ..saved_connection("acme-prod")
        };
        let outline = Rc::new(crate::services::library_outline::LibraryOutline::new(
            &ConnectionList::new(vec![saved.clone()], vec![acme.clone(), production.clone()]),
        ));
        let group = choice_actions(
            gtk::Box::new(gtk::Orientation::Vertical, 0).upcast_ref(),
            &saved,
            LibrarySection::Tree,
            Rc::new(move || outline.clone()),
            &[acme.clone(), production.clone()],
        );
        let state = |tag: &ConnectionTag| {
            group
                .lookup_action(&tag_action(tag.id))
                .and_then(|action| action.state())
                .and_then(|state| state.get::<bool>())
        };

        assert_eq!(state(&production), Some(true));
        assert_eq!(state(&acme), Some(false));
    }
}
