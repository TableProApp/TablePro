use std::cell::{Cell, OnceCell, RefCell};
use std::path::Path;

use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_storage::{ConnectionColor, ConnectionGroup, ConnectionIcon, ConnectionTag, GroupIcon, SavedConnection};
use uuid::Uuid;

use crate::services::connection_search::ConnectionSearch;
use crate::services::library_outline::{LibraryItem, LibrarySection};
use crate::services::saved_connection_object::subtitle_for;
use crate::ui::connection_appearance::{color_class, tags_description};
use crate::ui::icons;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct NodeLook {
    pub(crate) title: String,
    pub(crate) subtitle: String,
    pub(crate) icon_name: String,
    pub(crate) color: Option<ConnectionColor>,
    pub(crate) description: String,
    pub(crate) favourite: bool,
    pub(crate) tags: Vec<ConnectionTag>,
}

// What the list knows about a connection beyond its entry.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Seen<'a> {
    pub(crate) file_based: bool,
    pub(crate) host_path: Option<&'a Path>,
    pub(crate) path: Option<&'a str>,
    pub(crate) tags: &'a [ConnectionTag],
    pub(crate) favourite: bool,
}

mod imp {
    use super::*;

    #[derive(Default, glib::Properties)]
    #[properties(wrapper_type = super::LibraryNode)]
    pub struct LibraryNode {
        pub(super) place: OnceCell<(LibrarySection, LibraryItem)>,
        pub(super) children: OnceCell<gio::ListStore>,
        pub(super) saved: RefCell<Option<SavedConnection>>,
        pub(super) path: RefCell<Option<String>>,
        pub(super) color: Cell<Option<ConnectionColor>>,
        pub(super) tags: RefCell<Vec<ConnectionTag>>,
        #[property(get)]
        pub(super) title: RefCell<String>,
        #[property(get)]
        pub(super) subtitle: RefCell<String>,
        #[property(get)]
        pub(super) icon_name: RefCell<String>,
        #[property(get)]
        pub(super) color_class: RefCell<String>,
        #[property(get)]
        pub(super) description: RefCell<String>,
        #[property(get)]
        pub(super) favourite: Cell<bool>,
        #[property(get)]
        pub(super) revision: Cell<u64>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for LibraryNode {
        const NAME: &'static str = "TableProLibraryNode";
        type Type = super::LibraryNode;
    }

    #[glib::derived_properties]
    impl ObjectImpl for LibraryNode {}
}

glib::wrapper! {
    pub struct LibraryNode(ObjectSubclass<imp::LibraryNode>);
}

impl LibraryNode {
    // Every group, empty or not, lists through its own store, which lives as long as the node.
    pub(crate) fn group(id: Uuid) -> Self {
        let node = Self::placed(LibrarySection::Tree, LibraryItem::Group(id));
        let _ = node.imp().children.set(gio::ListStore::new::<LibraryNode>());
        node
    }

    pub(crate) fn connection(section: LibrarySection, id: Uuid) -> Self {
        Self::placed(section, LibraryItem::Connection(id))
    }

    fn placed(section: LibrarySection, item: LibraryItem) -> Self {
        let node: Self = glib::Object::new();
        let _ = node.imp().place.set((section, item));
        node
    }

    pub(crate) fn section(&self) -> Option<LibrarySection> {
        self.imp().place.get().map(|(section, _)| *section)
    }

    pub(crate) fn item(&self) -> Option<LibraryItem> {
        self.imp().place.get().map(|(_, item)| *item)
    }

    pub(crate) fn children(&self) -> Option<gio::ListStore> {
        self.imp().children.get().cloned()
    }

    pub(crate) fn color(&self) -> Option<ConnectionColor> {
        self.imp().color.get()
    }

    pub(crate) fn tags(&self) -> Vec<ConnectionTag> {
        self.imp().tags.borrow().clone()
    }

    // The entry and group path the search reads.
    pub(crate) fn set_source(&self, saved: &SavedConnection, path: Option<&str>) {
        let imp = self.imp();
        if imp.saved.borrow().as_ref() != Some(saved) {
            imp.saved.replace(Some(saved.clone()));
        }
        if imp.path.borrow().as_deref() != path {
            imp.path.replace(path.map(str::to_owned));
        }
    }

    pub(crate) fn matches(&self, search: &ConnectionSearch, tags: &[ConnectionTag]) -> bool {
        let imp = self.imp();
        let (saved, path) = (imp.saved.borrow(), imp.path.borrow());
        saved
            .as_ref()
            .is_some_and(|saved| search.matches(saved, path.as_deref(), tags))
    }

    // Notifies only what changed, then the revision once, so a bound row redraws once.
    pub(crate) fn show(&self, look: NodeLook) {
        let imp = self.imp();
        let mut changed = false;
        if replace(&imp.title, look.title) {
            self.notify_title();
            changed = true;
        }
        if replace(&imp.subtitle, look.subtitle) {
            self.notify_subtitle();
            changed = true;
        }
        if replace(&imp.icon_name, look.icon_name) {
            self.notify_icon_name();
            changed = true;
        }
        let class = look.color.map(color_class).unwrap_or_default();
        if imp.color.get() != look.color || *imp.color_class.borrow() != class {
            imp.color.set(look.color);
            imp.color_class.replace(class.to_owned());
            self.notify_color_class();
            changed = true;
        }
        if replace(&imp.description, look.description) {
            self.notify_description();
            changed = true;
        }
        if imp.favourite.get() != look.favourite {
            imp.favourite.set(look.favourite);
            self.notify_favourite();
            changed = true;
        }
        if *imp.tags.borrow() != look.tags {
            imp.tags.replace(look.tags);
            changed = true;
        }
        if changed {
            imp.revision.set(imp.revision.get().wrapping_add(1));
            self.notify_revision();
        }
    }
}

fn replace(cell: &RefCell<String>, value: String) -> bool {
    if *cell.borrow() == value {
        return false;
    }
    cell.replace(value);
    true
}

pub(crate) fn connection_look(saved: &SavedConnection, section: LibrarySection, seen: Seen<'_>) -> NodeLook {
    let mut subtitle = subtitle_for(saved, seen.file_based, seen.host_path);
    // Outside the tree a row does not sit under its group, so it names the group.
    if section != LibrarySection::Tree
        && let Some(path) = seen.path
    {
        subtitle = format!("{subtitle} · {path}");
    }
    let tags: Vec<ConnectionTag> = seen
        .tags
        .iter()
        .filter(|tag| saved.tags.contains(&tag.id))
        .cloned()
        .collect();
    let description = match tags_description(&tags) {
        Some(said) => crate::i18n::gettext_f("{subtitle}. {tags}", &[("subtitle", &subtitle), ("tags", &said)]),
        None => subtitle.clone(),
    };
    NodeLook {
        title: saved.name.clone(),
        subtitle,
        icon_name: connection_icon(saved.icon, seen.file_based).to_owned(),
        color: saved.color,
        description,
        favourite: seen.favourite,
        tags,
    }
}

// `count` is every connection in the group and the groups inside it.
pub(crate) fn group_look(group: &ConnectionGroup, count: u32) -> NodeLook {
    let shown = count.to_string();
    let icon = match &group.icon {
        Some(GroupIcon::Named(icon)) => icons::connection_icon(*icon),
        // A macOS symbol has no Linux icon.
        Some(GroupIcon::Symbol(_)) | None => icons::FOLDER,
    };
    NodeLook {
        title: group.name.as_str().to_owned(),
        subtitle: String::new(),
        icon_name: icon.to_owned(),
        color: group.color,
        // Translators: a group row as a screen reader describes it.
        description: crate::i18n::ngettext_f(
            "Group, {count} connection",
            "Group, {count} connections",
            count,
            &[("count", &shown)],
        ),
        favourite: false,
        tags: Vec::new(),
    }
}

fn connection_icon(icon: Option<ConnectionIcon>, file_based: bool) -> &'static str {
    match icon {
        Some(icon) => icons::connection_icon(icon),
        None if file_based => icons::TEXT_X_GENERIC,
        None => icons::NETWORK_SERVER,
    }
}

#[cfg(test)]
mod tests {
    use tablepro_storage::{ConnectionGroupName, ConnectionTagName};

    use super::*;
    use crate::test_support::saved_connection;

    fn tag(name: &str, color: ConnectionColor) -> ConnectionTag {
        ConnectionTag::new(ConnectionTagName::new(name).expect("a tag name"), color)
    }

    fn seen<'a>(tags: &'a [ConnectionTag], path: Option<&'a str>) -> Seen<'a> {
        Seen {
            file_based: false,
            host_path: None,
            path,
            tags,
            favourite: false,
        }
    }

    #[test]
    fn a_row_outside_the_tree_names_the_groups_path() {
        let saved = saved_connection("api");

        let tree = connection_look(&saved, LibrarySection::Tree, seen(&[], Some("Work / Staging")));
        let favourite = connection_look(&saved, LibrarySection::Favourites, seen(&[], Some("Work / Staging")));

        assert_eq!(tree.subtitle, "postgres · postgres@db:5432");
        assert_eq!(favourite.subtitle, "postgres · postgres@db:5432 · Work / Staging");
        assert_eq!(favourite.description, favourite.subtitle);
    }

    #[test]
    fn the_description_says_where_it_connects_then_its_tags_in_the_lists_order() {
        let (acme, production) = (
            tag("acme", ConnectionColor::Blue),
            tag("production", ConnectionColor::Red),
        );
        let saved = SavedConnection {
            tags: vec![production.id, acme.id],
            color: Some(ConnectionColor::Red),
            ..saved_connection("acme-prod")
        };
        let tags = [
            acme.clone(),
            production.clone(),
            tag("staging", ConnectionColor::Yellow),
        ];

        let look = connection_look(&saved, LibrarySection::Tree, seen(&tags, None));

        assert_eq!(look.tags, [acme, production]);
        assert_eq!(look.description, "postgres · postgres@db:5432. Tags: acme, production");
        assert_eq!(look.color, Some(ConnectionColor::Red));
    }

    #[test]
    fn a_connection_shows_its_icon_or_its_engines() {
        let picked = SavedConnection {
            icon: Some(ConnectionIcon::Cloud),
            ..saved_connection("cloud")
        };
        let plain = saved_connection("plain");
        let file = Seen {
            file_based: true,
            ..seen(&[], None)
        };

        assert_eq!(
            connection_look(&picked, LibrarySection::Tree, seen(&[], None)).icon_name,
            icons::connection_icon(ConnectionIcon::Cloud)
        );
        assert_eq!(
            connection_look(&plain, LibrarySection::Tree, seen(&[], None)).icon_name,
            icons::NETWORK_SERVER
        );
        assert_eq!(
            connection_look(&plain, LibrarySection::Tree, file).icon_name,
            icons::TEXT_X_GENERIC
        );
    }

    #[test]
    fn a_group_says_how_many_connections_it_holds() {
        let group = ConnectionGroup::new(ConnectionGroupName::new("Work").expect("a group name"), None);

        assert_eq!(group_look(&group, 1).description, "Group, 1 connection");
        assert_eq!(group_look(&group, 3).description, "Group, 3 connections");
        assert_eq!(group_look(&group, 0).icon_name, icons::FOLDER);
        let named = ConnectionGroup {
            icon: Some(GroupIcon::Named(ConnectionIcon::Star)),
            ..group
        };
        assert_eq!(
            group_look(&named, 0).icon_name,
            icons::connection_icon(ConnectionIcon::Star)
        );
    }

    #[gtk4::test]
    fn a_change_moves_the_revision_once_and_an_unchanged_look_not_at_all() {
        let node = LibraryNode::connection(LibrarySection::Tree, Uuid::new_v4());
        let look = connection_look(&saved_connection("api"), LibrarySection::Tree, seen(&[], None));
        node.show(look.clone());
        let before = node.revision();

        node.show(look.clone());
        assert_eq!(node.revision(), before, "an unchanged look redrew the row");
        node.show(NodeLook {
            title: "web".to_owned(),
            subtitle: "elsewhere".to_owned(),
            ..look
        });

        assert_eq!(node.revision(), before.wrapping_add(1));
        assert_eq!(node.title(), "web");
        assert_eq!(node.subtitle(), "elsewhere");
    }

    #[gtk4::test]
    fn a_node_finds_by_a_word_of_its_groups_path() {
        let node = LibraryNode::connection(LibrarySection::Recent, Uuid::new_v4());
        node.set_source(&saved_connection("api"), Some("Clients / Acme"));

        assert!(node.matches(&ConnectionSearch::new("acme"), &[]));
        assert!(!node.matches(&ConnectionSearch::new("globex"), &[]));
        node.set_source(&saved_connection("api"), None);
        assert!(!node.matches(&ConnectionSearch::new("acme"), &[]));
    }
}
