use std::collections::{HashMap, HashSet};

use gtk4::glib;
use gtk4::glib::prelude::*;
use tablepro_storage::{ConnectionGroup, ConnectionGroupName, ConnectionList, GroupTree, SavedConnection};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum LibrarySection {
    Favourites,
    Recent,
    Tree,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum LibraryItem {
    Connection(Uuid),
    Group(Uuid),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum LibraryMove {
    Connections {
        ids: Vec<Uuid>,
        group: Option<Uuid>,
        before: Option<Uuid>,
    },
    Groups {
        ids: Vec<Uuid>,
        parent: Option<Uuid>,
        before: Option<Uuid>,
    },
    Favourites {
        ids: Vec<Uuid>,
        before: Option<Uuid>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DropSpot {
    Into(Uuid),
    Before(LibrarySection, LibraryItem),
    After(LibrarySection, LibraryItem),
    End(LibrarySection),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Step {
    Up,
    Down,
}

pub(crate) const RECENT_LIMIT: usize = 5;

const CONNECTIONS: &str = "connections";
const GROUPS: &str = "groups";
const FAVOURITES: &str = "favourites";

#[derive(Debug, Clone)]
pub(crate) struct LibraryOutline {
    list: ConnectionList,
    favourites: Vec<Uuid>,
    recent: Vec<Uuid>,
    children: HashMap<Option<Uuid>, Vec<LibraryItem>>,
    parents: HashMap<LibraryItem, Option<Uuid>>,
    groups: Vec<(Uuid, String, usize)>,
    group_at: HashMap<Uuid, usize>,
    connection_at: HashMap<Uuid, usize>,
}

impl LibraryOutline {
    pub(crate) fn new(list: &ConnectionList) -> Self {
        let tree = list.group_tree();
        let walked = tree.walk();
        let mut children = HashMap::with_capacity(walked.len() + 1);
        let mut parents = HashMap::with_capacity(walked.len() + list.connections.len());
        for parent in std::iter::once(None).chain(walked.iter().map(|group| Some(group.id))) {
            let items: Vec<LibraryItem> = tree
                .children(parent)
                .into_iter()
                .map(|group| LibraryItem::Group(group.id))
                .chain(
                    list.connections_in(parent)
                        .into_iter()
                        .map(|saved| LibraryItem::Connection(saved.id)),
                )
                .collect();
            parents.extend(items.iter().map(|item| (*item, parent)));
            children.insert(parent, items);
        }
        let groups = walked
            .iter()
            .filter_map(|group| Some((group.id, tree.label(group.id)?, tree.depth(Some(group.id)))))
            .collect();
        let connection_at = first_positions(list.connections.iter().map(|saved| saved.id));
        let mut listed = HashSet::new();
        let favourites = list
            .favorites
            .iter()
            .copied()
            .filter(|id| connection_at.contains_key(id) && listed.insert(*id))
            .collect();
        Self {
            favourites,
            recent: list.recent(RECENT_LIMIT).into_iter().map(|saved| saved.id).collect(),
            children,
            parents,
            groups,
            group_at: first_positions(list.groups.iter().map(|group| group.id)),
            connection_at,
            list: list.clone(),
        }
    }

    pub(crate) fn favourites(&self) -> &[Uuid] {
        &self.favourites
    }

    pub(crate) fn recent(&self) -> &[Uuid] {
        &self.recent
    }

    pub(crate) fn children(&self, parent: Option<Uuid>) -> Vec<LibraryItem> {
        self.children.get(&parent).cloned().unwrap_or_default()
    }

    pub(crate) fn group(&self, id: Uuid) -> Option<&ConnectionGroup> {
        self.group_at.get(&id).and_then(|at| self.list.groups.get(*at))
    }

    pub(crate) fn connection(&self, id: Uuid) -> Option<&SavedConnection> {
        self.connection_at
            .get(&id)
            .and_then(|at| self.list.connections.get(*at))
    }

    pub(crate) fn parent_of(&self, item: LibraryItem) -> Option<Option<Uuid>> {
        self.parents.get(&item).copied()
    }

    pub(crate) fn label(&self, group: Uuid) -> Option<String> {
        self.groups
            .iter()
            .find(|(id, _, _)| *id == group)
            .map(|(_, label, _)| label.clone())
    }

    pub(crate) fn groups(&self) -> Vec<(Uuid, String, usize)> {
        self.groups.clone()
    }

    pub(crate) fn has_subgroups(&self, group: Uuid) -> bool {
        self.children
            .get(&Some(group))
            .is_some_and(|items| items.iter().any(|item| matches!(item, LibraryItem::Group(_))))
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.list.connections.is_empty() && self.list.groups.is_empty()
    }

    pub(crate) fn can_create_in(&self, parent: Option<Uuid>) -> bool {
        self.tree().can_create_in(parent)
    }

    pub(crate) fn group_targets(&self, group: Uuid) -> Vec<Option<Uuid>> {
        let Some(current) = self.parent_of(LibraryItem::Group(group)) else {
            return Vec::new();
        };
        let tree = self.tree();
        std::iter::once(None)
            .chain(self.groups.iter().map(|(id, _, _)| Some(*id)))
            .filter(|target| *target == current || tree.can_place(group, *target))
            .collect()
    }

    pub(crate) fn sibling_names(&self, parent: Option<Uuid>, except: Option<Uuid>) -> Vec<ConnectionGroupName> {
        self.children
            .get(&parent)
            .into_iter()
            .flatten()
            .filter_map(|item| match item {
                LibraryItem::Group(id) if Some(*id) != except => self.group(*id),
                _ => None,
            })
            .map(|group| group.name.clone())
            .collect()
    }

    pub(crate) fn step(&self, section: LibrarySection, item: LibraryItem, step: Step) -> Option<LibraryMove> {
        let id = item.id();
        match (section, item) {
            (LibrarySection::Favourites, LibraryItem::Connection(_)) => {
                let before = stepped(&self.favourites, id, step)?;
                Some(LibraryMove::Favourites { ids: vec![id], before })
            }
            (LibrarySection::Tree, _) => {
                let parent = self.parent_of(item)?;
                let before = stepped(&self.kin(parent, item), id, step)?;
                Some(moving(item, parent, before))
            }
            _ => None,
        }
    }

    pub(crate) fn resolve_drop(
        &self,
        dragged: (LibrarySection, LibraryItem),
        spot: DropSpot,
        expanded: bool,
    ) -> Option<LibraryMove> {
        let (_, item) = dragged;
        match spot {
            DropSpot::Into(group) => self.moved_into(item, group),
            DropSpot::Before(LibrarySection::Tree, target) => self.beside(item, target, false),
            // The line under an open group sits above its first child.
            DropSpot::After(LibrarySection::Tree, LibraryItem::Group(group))
                if expanded && self.has_children(group) =>
            {
                let before = first_other(&self.kin(Some(group), item), 0, item.id());
                self.placed_at(item, Some(group), before)
            }
            DropSpot::After(LibrarySection::Tree, target) => self.beside(item, target, true),
            DropSpot::End(LibrarySection::Tree) => self.to_top(item),
            DropSpot::Before(LibrarySection::Favourites, _)
            | DropSpot::After(LibrarySection::Favourites, _)
            | DropSpot::End(LibrarySection::Favourites) => self.in_favourites(item, spot),
            DropSpot::Before(LibrarySection::Recent, _)
            | DropSpot::After(LibrarySection::Recent, _)
            | DropSpot::End(LibrarySection::Recent) => None,
        }
    }
}

impl LibraryOutline {
    fn tree(&self) -> GroupTree<'_> {
        self.list.group_tree()
    }

    fn has_children(&self, group: Uuid) -> bool {
        self.children.get(&Some(group)).is_some_and(|items| !items.is_empty())
    }

    fn kin(&self, parent: Option<Uuid>, like: LibraryItem) -> Vec<Uuid> {
        self.children
            .get(&parent)
            .into_iter()
            .flatten()
            .filter(|item| item.same_kind(like))
            .map(|item| item.id())
            .collect()
    }

    fn moved_into(&self, item: LibraryItem, group: Uuid) -> Option<LibraryMove> {
        if self.parent_of(item) == Some(Some(group)) {
            return None;
        }
        self.placed_at(item, Some(group), None)
    }

    fn to_top(&self, item: LibraryItem) -> Option<LibraryMove> {
        self.placed_at(item, None, None)
    }

    fn beside(&self, item: LibraryItem, target: LibraryItem, after: bool) -> Option<LibraryMove> {
        let parent = self.parent_of(target)?;
        let kin = self.kin(parent, item);
        let before = match (target.same_kind(item), item) {
            (true, _) => {
                let at = kin.iter().position(|id| *id == target.id())?;
                first_other(&kin, if after { at + 1 } else { at }, item.id())
            }
            // Groups list before connections: beside a group row is first among the connections,
            (false, LibraryItem::Connection(id)) => first_other(&kin, 0, id),
            // and beside a connection row is last among the groups.
            (false, LibraryItem::Group(_)) => None,
        };
        self.placed_at(item, parent, before)
    }

    fn in_favourites(&self, item: LibraryItem, spot: DropSpot) -> Option<LibraryMove> {
        let LibraryItem::Connection(id) = item else {
            return None;
        };
        self.connection(id)?;
        let at = |target: LibraryItem| {
            self.favourites
                .iter()
                .position(|held| LibraryItem::Connection(*held) == target)
        };
        let before = match spot {
            DropSpot::Before(_, target) => first_other(&self.favourites, at(target)?, id),
            DropSpot::After(_, target) => first_other(&self.favourites, at(target)? + 1, id),
            DropSpot::Into(_) | DropSpot::End(_) => None,
        };
        if placed(&self.favourites, id, before) == self.favourites {
            return None;
        }
        Some(LibraryMove::Favourites { ids: vec![id], before })
    }

    // None when the move is refused or changes nothing.
    fn placed_at(&self, item: LibraryItem, parent: Option<Uuid>, before: Option<Uuid>) -> Option<LibraryMove> {
        let in_place = self.parent_of(item) == Some(parent);
        let allowed = match item {
            LibraryItem::Connection(id) => self.connection(id).is_some(),
            // The core lets a group reorder in place even past the depth limit.
            LibraryItem::Group(id) => self.group(id).is_some() && (in_place || self.tree().can_place(id, parent)),
        };
        if !allowed || parent.is_some_and(|group| self.group(group).is_none()) {
            return None;
        }
        if in_place {
            let kin = self.kin(parent, item);
            if placed(&kin, item.id(), before) == kin {
                return None;
            }
        }
        Some(moving(item, parent, before))
    }
}

impl LibraryItem {
    fn id(self) -> Uuid {
        match self {
            Self::Connection(id) | Self::Group(id) => id,
        }
    }

    fn same_kind(self, other: Self) -> bool {
        std::mem::discriminant(&self) == std::mem::discriminant(&other)
    }
}

impl LibraryMove {
    pub(crate) fn to_variant(&self) -> glib::Variant {
        let (kind, ids, parent, before) = match self {
            Self::Connections { ids, group, before } => (CONNECTIONS, ids, *group, *before),
            Self::Groups { ids, parent, before } => (GROUPS, ids, *parent, *before),
            Self::Favourites { ids, before } => (FAVOURITES, ids, None, *before),
        };
        let ids: Vec<String> = ids.iter().map(Uuid::to_string).collect();
        (kind.to_owned(), ids, id_or_empty(parent), id_or_empty(before)).to_variant()
    }

    pub(crate) fn from_variant(value: &glib::Variant) -> Option<Self> {
        let (kind, ids, parent, before) = value.get::<(String, Vec<String>, String, String)>()?;
        let ids = ids
            .iter()
            .map(|id| Uuid::parse_str(id).ok())
            .collect::<Option<Vec<Uuid>>>()?;
        let (parent, before) = (optional_id(&parent)?, optional_id(&before)?);
        match kind.as_str() {
            CONNECTIONS => Some(Self::Connections {
                ids,
                group: parent,
                before,
            }),
            GROUPS => Some(Self::Groups { ids, parent, before }),
            FAVOURITES if parent.is_none() => Some(Self::Favourites { ids, before }),
            _ => None,
        }
    }
}

fn moving(item: LibraryItem, parent: Option<Uuid>, before: Option<Uuid>) -> LibraryMove {
    match item {
        LibraryItem::Connection(id) => LibraryMove::Connections {
            ids: vec![id],
            group: parent,
            before,
        },
        LibraryItem::Group(id) => LibraryMove::Groups {
            ids: vec![id],
            parent,
            before,
        },
    }
}

// `Some(None)` is a step down to the last place.
fn stepped(ids: &[Uuid], id: Uuid, step: Step) -> Option<Option<Uuid>> {
    let at = ids.iter().position(|held| *held == id)?;
    match step {
        Step::Up => at
            .checked_sub(1)
            .and_then(|above| ids.get(above))
            .map(|above| Some(*above)),
        Step::Down if at + 1 < ids.len() => Some(ids.get(at + 2).copied()),
        Step::Down => None,
    }
}

// The core's own placing: a `before` that is missing or moving puts the item last.
fn placed(ordered: &[Uuid], moving: Uuid, before: Option<Uuid>) -> Vec<Uuid> {
    let mut rest: Vec<Uuid> = ordered.iter().copied().filter(|id| *id != moving).collect();
    let at = before
        .and_then(|before| rest.iter().position(|id| *id == before))
        .unwrap_or(rest.len());
    rest.insert(at, moving);
    rest
}

fn first_other(ids: &[Uuid], from: usize, moving: Uuid) -> Option<Uuid> {
    ids.iter().skip(from).copied().find(|id| *id != moving)
}

fn first_positions(ids: impl Iterator<Item = Uuid>) -> HashMap<Uuid, usize> {
    let mut found = HashMap::new();
    for (at, id) in ids.enumerate() {
        found.entry(id).or_insert(at);
    }
    found
}

fn id_or_empty(id: Option<Uuid>) -> String {
    id.map(|id| id.to_string()).unwrap_or_default()
}

fn optional_id(value: &str) -> Option<Option<Uuid>> {
    if value.is_empty() {
        return Some(None);
    }
    Uuid::parse_str(value).ok().map(Some)
}

#[cfg(test)]
mod tests {
    use chrono::{TimeDelta, Utc};

    use super::LibraryItem::{Connection, Group};
    use super::LibrarySection::{Favourites, Recent, Tree};
    use super::*;
    use crate::test_support::saved_connection;

    struct Library {
        outline: LibraryOutline,
        ids: HashMap<String, Uuid>,
    }

    impl Library {
        fn id(&self, name: &str) -> Uuid {
            self.ids[name]
        }

        fn ids_of(&self, names: &[&str]) -> Vec<Uuid> {
            names.iter().map(|name| self.id(name)).collect()
        }

        fn connection(&self, name: &str) -> LibraryItem {
            Connection(self.id(name))
        }

        fn group(&self, name: &str) -> LibraryItem {
            Group(self.id(name))
        }

        fn dropped(&self, dragged: (LibrarySection, LibraryItem), spot: DropSpot) -> Option<LibraryMove> {
            self.outline.resolve_drop(dragged, spot, false)
        }

        fn connections_move(&self, name: &str, group: Option<&str>, before: Option<&str>) -> Option<LibraryMove> {
            Some(LibraryMove::Connections {
                ids: vec![self.id(name)],
                group: group.map(|name| self.id(name)),
                before: before.map(|name| self.id(name)),
            })
        }

        fn groups_move(&self, name: &str, parent: Option<&str>, before: Option<&str>) -> Option<LibraryMove> {
            Some(LibraryMove::Groups {
                ids: vec![self.id(name)],
                parent: parent.map(|name| self.id(name)),
                before: before.map(|name| self.id(name)),
            })
        }

        fn favourites_move(&self, name: &str, before: Option<&str>) -> Option<LibraryMove> {
            Some(LibraryMove::Favourites {
                ids: vec![self.id(name)],
                before: before.map(|name| self.id(name)),
            })
        }
    }

    fn group(name: &str, parent: Option<&ConnectionGroup>, order: u32) -> ConnectionGroup {
        ConnectionGroup {
            order,
            ..ConnectionGroup::new(
                ConnectionGroupName::new(name).expect("a group name"),
                parent.map(|parent| parent.id),
            )
        }
    }

    fn filed(name: &str, group: Option<&ConnectionGroup>, order: u32) -> SavedConnection {
        SavedConnection {
            group_id: group.map(|group| group.id),
            order,
            ..saved_connection(name)
        }
    }

    // Work > Staging > EU and Work > Prod, an empty Home, Archive > Old, and t1, t2 at the top.
    // Favourites w2, t1, s1. Both lists are out of order, so the outline has to sort.
    fn library() -> Library {
        let work = group("Work", None, 0);
        let staging = group("Staging", Some(&work), 0);
        let eu = group("EU", Some(&staging), 0);
        let prod = group("Prod", Some(&work), 1);
        let home = group("Home", None, 1);
        let archive = group("Archive", None, 2);
        let old = group("Old", Some(&archive), 0);
        let connections = vec![
            filed("w3", Some(&work), 2),
            filed("t2", None, 1),
            filed("w1", Some(&work), 0),
            filed("s1", Some(&staging), 0),
            filed("eu1", Some(&eu), 0),
            filed("w2", Some(&work), 1),
            filed("s2", Some(&staging), 1),
            filed("t1", None, 0),
        ];
        let groups = vec![old, archive, home, prod, eu, staging, work];
        let ids: HashMap<String, Uuid> = groups
            .iter()
            .map(|group| (group.name.as_str().to_owned(), group.id))
            .chain(connections.iter().map(|saved| (saved.name.clone(), saved.id)))
            .collect();
        let favourites = vec![ids["w2"], ids["t1"], ids["s1"]];
        let list = ConnectionList::new(connections, Vec::new())
            .with_groups(groups)
            .with_favorites(favourites);
        Library {
            outline: LibraryOutline::new(&list),
            ids,
        }
    }

    #[test]
    fn children_list_groups_first_then_connections_by_order() {
        let lib = library();
        let children = |parent: Option<&str>| lib.outline.children(parent.map(|name| lib.id(name)));

        assert_eq!(
            children(None),
            [
                lib.group("Work"),
                lib.group("Home"),
                lib.group("Archive"),
                lib.connection("t1"),
                lib.connection("t2"),
            ]
        );
        assert_eq!(
            children(Some("Work")),
            [
                lib.group("Staging"),
                lib.group("Prod"),
                lib.connection("w1"),
                lib.connection("w2"),
                lib.connection("w3"),
            ]
        );
        assert_eq!(
            children(Some("Staging")),
            [lib.group("EU"), lib.connection("s1"), lib.connection("s2")]
        );
        assert_eq!(children(Some("EU")), [lib.connection("eu1")]);
        assert!(children(Some("Home")).is_empty(), "an empty group has children");
        assert!(lib.outline.children(Some(Uuid::new_v4())).is_empty());
    }

    #[test]
    fn groups_read_by_path_and_depth_in_walk_order() {
        let lib = library();
        let groups = lib.outline.groups();
        let read: Vec<(&str, usize)> = groups
            .iter()
            .map(|(_, label, depth)| (label.as_str(), *depth))
            .collect();

        assert_eq!(
            read,
            [
                ("Work", 1),
                ("Work / Staging", 2),
                ("Work / Staging / EU", 3),
                ("Work / Prod", 2),
                ("Home", 1),
                ("Archive", 1),
                ("Archive / Old", 2),
            ]
        );
        assert_eq!(
            groups.iter().map(|(id, _, _)| *id).collect::<Vec<_>>(),
            lib.ids_of(&["Work", "Staging", "EU", "Prod", "Home", "Archive", "Old"])
        );
        assert_eq!(lib.outline.label(lib.id("EU")).as_deref(), Some("Work / Staging / EU"));
        assert_eq!(lib.outline.label(Uuid::new_v4()), None);
        assert_eq!(
            lib.outline.group(lib.id("Prod")).map(|group| group.name.as_str()),
            Some("Prod")
        );
        assert_eq!(
            lib.outline.connection(lib.id("s2")).map(|saved| saved.name.as_str()),
            Some("s2")
        );
        assert!(lib.outline.connection(Uuid::new_v4()).is_none());
    }

    #[test]
    fn each_item_knows_its_parent_and_each_group_its_subgroups() {
        let lib = library();

        assert_eq!(
            lib.outline.parent_of(lib.connection("s1")),
            Some(Some(lib.id("Staging")))
        );
        assert_eq!(lib.outline.parent_of(lib.connection("t2")), Some(None));
        assert_eq!(lib.outline.parent_of(lib.group("EU")), Some(Some(lib.id("Staging"))));
        assert_eq!(lib.outline.parent_of(lib.group("Work")), Some(None));
        assert_eq!(lib.outline.parent_of(Connection(Uuid::new_v4())), None);
        assert!(lib.outline.has_subgroups(lib.id("Work")));
        assert!(lib.outline.has_subgroups(lib.id("Staging")));
        assert!(
            !lib.outline.has_subgroups(lib.id("EU")),
            "a connection is not a subgroup"
        );
        assert!(!lib.outline.has_subgroups(lib.id("Home")));
    }

    #[test]
    fn sibling_names_leave_out_the_group_being_renamed() {
        let lib = library();
        let names = |parent: Option<&str>, except: Option<&str>| -> Vec<String> {
            lib.outline
                .sibling_names(parent.map(|name| lib.id(name)), except.map(|name| lib.id(name)))
                .iter()
                .map(|name| name.as_str().to_owned())
                .collect()
        };

        assert_eq!(names(None, None), ["Work", "Home", "Archive"]);
        assert_eq!(names(Some("Work"), None), ["Staging", "Prod"]);
        assert_eq!(names(Some("Work"), Some("Staging")), ["Prod"]);
        assert!(names(Some("Home"), None).is_empty());
    }

    #[test]
    fn favourites_keep_the_lists_order_and_only_saved_ids() {
        let (a, b) = (saved_connection("a"), saved_connection("b"));
        let list = ConnectionList::new(vec![a.clone(), b.clone()], Vec::new()).with_favorites(vec![
            b.id,
            Uuid::new_v4(),
            a.id,
            b.id,
        ]);

        assert_eq!(LibraryOutline::new(&list).favourites(), [b.id, a.id]);
    }

    #[test]
    fn recent_leaves_favourites_out_and_keeps_the_five_newest() {
        let now = Utc::now();
        let opened: Vec<SavedConnection> = (0..7)
            .map(|hours| SavedConnection {
                last_opened_at: Some(now - TimeDelta::hours(hours)),
                ..saved_connection(&format!("c{hours}"))
            })
            .collect();
        let mut connections = vec![saved_connection("never opened")];
        connections.extend(opened.iter().rev().cloned());
        let list = ConnectionList::new(connections, Vec::new()).with_favorites(vec![opened[1].id]);

        let expected: Vec<Uuid> = [0, 2, 3, 4, 5].iter().map(|at| opened[*at].id).collect();
        assert_eq!(LibraryOutline::new(&list).recent(), expected);
    }

    #[test]
    fn a_library_is_empty_only_with_no_connection_and_no_group() {
        assert!(LibraryOutline::new(&ConnectionList::default()).is_empty());
        let one_group = ConnectionList::default().with_groups(vec![group("Work", None, 0)]);
        assert!(
            !LibraryOutline::new(&one_group).is_empty(),
            "an empty group was not counted"
        );
        assert!(!library().outline.is_empty());
    }

    #[test]
    fn a_subgroup_can_be_made_only_above_the_depth_limit() {
        let lib = library();

        assert!(lib.outline.can_create_in(None));
        assert!(lib.outline.can_create_in(Some(lib.id("Work"))));
        assert!(lib.outline.can_create_in(Some(lib.id("Staging"))));
        assert!(!lib.outline.can_create_in(Some(lib.id("EU"))), "a fourth level");
        assert!(!lib.outline.can_create_in(Some(Uuid::new_v4())), "a deleted parent");
    }

    #[test]
    fn group_targets_leave_out_the_group_its_subtree_and_places_past_the_depth_limit() {
        let lib = library();
        let targets = |name: &str| lib.outline.group_targets(lib.id(name));
        let expected = |names: &[Option<&str>]| -> Vec<Option<Uuid>> {
            names.iter().map(|name| name.map(|name| lib.id(name))).collect()
        };

        assert_eq!(
            targets("Staging"),
            expected(&[None, Some("Work"), Some("Home"), Some("Archive")])
        );
        assert_eq!(
            targets("Prod"),
            expected(&[
                None,
                Some("Work"),
                Some("Staging"),
                Some("Home"),
                Some("Archive"),
                Some("Old")
            ]),
            "a leaf fits under a depth 2 group and not under a depth 3 one"
        );
        assert_eq!(targets("Work"), expected(&[None]));
        assert_eq!(
            targets("Old"),
            expected(&[
                None,
                Some("Work"),
                Some("Staging"),
                Some("Prod"),
                Some("Home"),
                Some("Archive")
            ])
        );
        assert!(lib.outline.group_targets(Uuid::new_v4()).is_empty());
    }

    #[test]
    fn a_connection_steps_among_its_groups_connections() {
        let lib = library();
        let step = |name: &str, step: Step| lib.outline.step(Tree, lib.connection(name), step);

        assert_eq!(
            step("w2", Step::Up),
            lib.connections_move("w2", Some("Work"), Some("w1"))
        );
        assert_eq!(step("w2", Step::Down), lib.connections_move("w2", Some("Work"), None));
        assert_eq!(
            step("w1", Step::Down),
            lib.connections_move("w1", Some("Work"), Some("w3"))
        );
        assert_eq!(step("w1", Step::Up), None);
        assert_eq!(step("w3", Step::Down), None);
        assert_eq!(step("t1", Step::Up), None, "the groups above are not its siblings");
        assert_eq!(step("t1", Step::Down), lib.connections_move("t1", None, None));
        assert_eq!(lib.outline.step(Tree, Connection(Uuid::new_v4()), Step::Up), None);
    }

    #[test]
    fn a_group_steps_among_its_sibling_groups_only() {
        let lib = library();
        let step = |name: &str, step: Step| lib.outline.step(Tree, lib.group(name), step);

        assert_eq!(step("Staging", Step::Up), None);
        assert_eq!(
            step("Staging", Step::Down),
            lib.groups_move("Staging", Some("Work"), None)
        );
        assert_eq!(
            step("Prod", Step::Up),
            lib.groups_move("Prod", Some("Work"), Some("Staging"))
        );
        assert_eq!(
            step("Prod", Step::Down),
            None,
            "the connections below are not its siblings"
        );
        assert_eq!(step("Home", Step::Up), lib.groups_move("Home", None, Some("Work")));
        assert_eq!(step("Home", Step::Down), lib.groups_move("Home", None, None));
        assert_eq!(step("Archive", Step::Down), None);
    }

    #[test]
    fn favourites_step_in_their_own_order_and_recent_never_moves() {
        let lib = library();
        let step = |section: LibrarySection, item: LibraryItem, step: Step| lib.outline.step(section, item, step);

        assert_eq!(
            step(Favourites, lib.connection("t1"), Step::Up),
            lib.favourites_move("t1", Some("w2"))
        );
        assert_eq!(
            step(Favourites, lib.connection("t1"), Step::Down),
            lib.favourites_move("t1", None)
        );
        assert_eq!(
            step(Favourites, lib.connection("w2"), Step::Down),
            lib.favourites_move("w2", Some("s1"))
        );
        assert_eq!(step(Favourites, lib.connection("w2"), Step::Up), None);
        assert_eq!(step(Favourites, lib.connection("s1"), Step::Down), None);
        assert_eq!(
            step(Favourites, lib.connection("w1"), Step::Up),
            None,
            "not a favourite"
        );
        assert_eq!(step(Favourites, lib.group("Work"), Step::Up), None);
        assert_eq!(step(Recent, lib.connection("t2"), Step::Up), None);
        assert_eq!(step(Recent, lib.connection("t2"), Step::Down), None);
    }

    #[test]
    fn recent_refuses_every_drop_and_favourites_refuse_a_group() {
        let lib = library();
        let w1 = (Tree, lib.connection("w1"));
        let work = (Tree, lib.group("Work"));

        assert_eq!(lib.dropped(w1, DropSpot::Before(Recent, lib.connection("t2"))), None);
        assert_eq!(lib.dropped(w1, DropSpot::After(Recent, lib.connection("t2"))), None);
        assert_eq!(lib.dropped(w1, DropSpot::End(Recent)), None);
        assert_eq!(lib.dropped(work, DropSpot::End(Favourites)), None);
        assert_eq!(
            lib.dropped(work, DropSpot::Before(Favourites, lib.connection("w2"))),
            None
        );
    }

    #[test]
    fn a_connection_dropped_on_favourites_lands_before_the_next_favourite() {
        let lib = library();
        let w1 = (Tree, lib.connection("w1"));

        assert_eq!(
            lib.dropped(w1, DropSpot::Before(Favourites, lib.connection("t1"))),
            lib.favourites_move("w1", Some("t1"))
        );
        assert_eq!(
            lib.dropped(w1, DropSpot::After(Favourites, lib.connection("t1"))),
            lib.favourites_move("w1", Some("s1"))
        );
        assert_eq!(
            lib.dropped(w1, DropSpot::After(Favourites, lib.connection("s1"))),
            lib.favourites_move("w1", None)
        );
        assert_eq!(
            lib.dropped(w1, DropSpot::End(Favourites)),
            lib.favourites_move("w1", None)
        );
        assert_eq!(
            lib.dropped(w1, DropSpot::Before(Favourites, lib.connection("w3"))),
            None,
            "a target that is not a favourite"
        );
    }

    #[test]
    fn a_favourite_dropped_among_favourites_skips_its_own_id_and_refuses_no_change() {
        let lib = library();
        let t1 = (Favourites, lib.connection("t1"));

        assert_eq!(
            lib.dropped(t1, DropSpot::Before(Favourites, lib.connection("t1"))),
            None
        );
        assert_eq!(lib.dropped(t1, DropSpot::After(Favourites, lib.connection("w2"))), None);
        assert_eq!(
            lib.dropped(t1, DropSpot::Before(Favourites, lib.connection("w2"))),
            lib.favourites_move("t1", Some("w2"))
        );
        assert_eq!(
            lib.dropped(t1, DropSpot::After(Favourites, lib.connection("s1"))),
            lib.favourites_move("t1", None)
        );
        assert_eq!(
            lib.dropped((Favourites, lib.connection("s1")), DropSpot::End(Favourites)),
            None
        );
        assert_eq!(
            lib.dropped((Tree, lib.connection("s1")), DropSpot::End(Favourites)),
            None
        );
    }

    #[test]
    fn a_connection_dropped_into_a_group_goes_to_its_end_unless_it_is_there() {
        let lib = library();

        assert_eq!(
            lib.dropped((Tree, lib.connection("t1")), DropSpot::Into(lib.id("Work"))),
            lib.connections_move("t1", Some("Work"), None)
        );
        assert_eq!(
            lib.dropped((Tree, lib.connection("w1")), DropSpot::Into(lib.id("Work"))),
            None,
            "already in it, though not last"
        );
        assert_eq!(
            lib.dropped((Favourites, lib.connection("s1")), DropSpot::Into(lib.id("Home"))),
            lib.connections_move("s1", Some("Home"), None)
        );
        assert_eq!(
            lib.dropped((Tree, lib.connection("t1")), DropSpot::Into(Uuid::new_v4())),
            None
        );
    }

    #[test]
    fn a_group_dropped_into_a_group_goes_under_it_unless_refused() {
        let lib = library();
        let into =
            |dragged: &str, target: &str| lib.dropped((Tree, lib.group(dragged)), DropSpot::Into(lib.id(target)));

        assert_eq!(into("Home", "Staging"), lib.groups_move("Home", Some("Staging"), None));
        assert_eq!(into("Home", "EU"), None, "a fourth level");
        assert_eq!(into("Archive", "Prod"), None, "its subgroup would be a fourth level");
        assert_eq!(into("Archive", "Home"), lib.groups_move("Archive", Some("Home"), None));
        assert_eq!(into("Staging", "Work"), None, "already its parent");
        assert_eq!(into("Work", "Staging"), None, "into its own subgroup");
        assert_eq!(into("Work", "Work"), None, "into itself");
    }

    #[test]
    fn a_connection_dropped_beside_a_connection_takes_its_place() {
        let lib = library();
        let beside =
            |dragged: (LibrarySection, &str), spot: fn(LibrarySection, LibraryItem) -> DropSpot, target: &str| {
                lib.dropped(
                    (dragged.0, lib.connection(dragged.1)),
                    spot(Tree, lib.connection(target)),
                )
            };

        assert_eq!(
            beside((Tree, "w3"), DropSpot::Before, "w1"),
            lib.connections_move("w3", Some("Work"), Some("w1"))
        );
        assert_eq!(
            beside((Tree, "w1"), DropSpot::After, "w2"),
            lib.connections_move("w1", Some("Work"), Some("w3"))
        );
        assert_eq!(
            beside((Tree, "w1"), DropSpot::After, "w3"),
            lib.connections_move("w1", Some("Work"), None)
        );
        assert_eq!(beside((Tree, "w1"), DropSpot::Before, "w2"), None, "its own place");
        assert_eq!(beside((Tree, "w2"), DropSpot::After, "w2"), None, "beside itself");
        assert_eq!(beside((Tree, "w2"), DropSpot::Before, "w2"), None, "beside itself");
        assert_eq!(
            beside((Tree, "t1"), DropSpot::Before, "w2"),
            lib.connections_move("t1", Some("Work"), Some("w2"))
        );
        assert_eq!(
            beside((Tree, "s1"), DropSpot::After, "t2"),
            lib.connections_move("s1", None, None)
        );
        assert_eq!(
            beside((Favourites, "w2"), DropSpot::Before, "t1"),
            lib.connections_move("w2", None, Some("t1"))
        );
    }

    #[test]
    fn a_connection_dropped_beside_a_group_row_lands_first_among_the_connections() {
        let lib = library();
        let beside = |dragged: &str, spot: fn(LibrarySection, LibraryItem) -> DropSpot, target: &str| {
            lib.dropped((Tree, lib.connection(dragged)), spot(Tree, lib.group(target)))
        };

        assert_eq!(
            beside("t2", DropSpot::Before, "Staging"),
            lib.connections_move("t2", Some("Work"), Some("w1"))
        );
        assert_eq!(
            beside("t2", DropSpot::After, "Prod"),
            lib.connections_move("t2", Some("Work"), Some("w1"))
        );
        assert_eq!(beside("w1", DropSpot::Before, "Staging"), None, "already first");
        assert_eq!(
            beside("w2", DropSpot::After, "Prod"),
            lib.connections_move("w2", Some("Work"), Some("w1"))
        );
        assert_eq!(
            beside("w1", DropSpot::After, "EU"),
            lib.connections_move("w1", Some("Staging"), Some("s1")),
            "a folded group is passed by"
        );
        assert_eq!(beside("t1", DropSpot::Before, "Work"), None, "already first");
        assert_eq!(
            beside("w1", DropSpot::Before, "Work"),
            lib.connections_move("w1", None, Some("t1"))
        );
    }

    #[test]
    fn a_group_dropped_beside_a_connection_row_lands_last_among_the_groups() {
        let lib = library();
        let beside = |dragged: &str, spot: fn(LibrarySection, LibraryItem) -> DropSpot, target: &str| {
            lib.dropped((Tree, lib.group(dragged)), spot(Tree, lib.connection(target)))
        };

        assert_eq!(
            beside("Home", DropSpot::Before, "w1"),
            lib.groups_move("Home", Some("Work"), None)
        );
        assert_eq!(beside("Prod", DropSpot::Before, "w1"), None, "already last");
        assert_eq!(
            beside("Staging", DropSpot::After, "w3"),
            lib.groups_move("Staging", Some("Work"), None)
        );
        assert_eq!(beside("Archive", DropSpot::Before, "s1"), None, "a fourth level");
    }

    #[test]
    fn a_group_dropped_beside_a_group_takes_its_place() {
        let lib = library();
        let beside = |dragged: &str, spot: fn(LibrarySection, LibraryItem) -> DropSpot, target: &str| {
            lib.dropped((Tree, lib.group(dragged)), spot(Tree, lib.group(target)))
        };

        assert_eq!(
            beside("Home", DropSpot::Before, "Work"),
            lib.groups_move("Home", None, Some("Work"))
        );
        assert_eq!(
            beside("Work", DropSpot::After, "Home"),
            lib.groups_move("Work", None, Some("Archive"))
        );
        assert_eq!(beside("Home", DropSpot::After, "Work"), None, "its own place");
        assert_eq!(
            beside("Prod", DropSpot::Before, "Staging"),
            lib.groups_move("Prod", Some("Work"), Some("Staging"))
        );
        assert_eq!(
            beside("Home", DropSpot::Before, "EU"),
            lib.groups_move("Home", Some("Staging"), Some("EU"))
        );
        assert_eq!(beside("Work", DropSpot::Before, "EU"), None, "into its own subgroup");
        assert_eq!(beside("Archive", DropSpot::Before, "EU"), None, "a fourth level");
        assert_eq!(
            beside("Staging", DropSpot::Before, "Home"),
            lib.groups_move("Staging", None, Some("Home"))
        );
    }

    #[test]
    fn a_group_past_the_depth_limit_still_reorders_in_place() {
        let a = group("A", None, 0);
        let b = group("B", Some(&a), 0);
        let c = group("C", Some(&b), 0);
        let d = group("D", Some(&c), 0);
        let e = group("E", Some(&c), 1);
        let x = group("X", None, 1);
        let groups = vec![a, b, c.clone(), d.clone(), e.clone(), x.clone()];
        let outline = LibraryOutline::new(&ConnectionList::default().with_groups(groups));
        let before = |dragged: &ConnectionGroup, target: &ConnectionGroup| {
            outline.resolve_drop(
                (Tree, Group(dragged.id)),
                DropSpot::Before(Tree, Group(target.id)),
                false,
            )
        };

        assert_eq!(
            before(&e, &d),
            Some(LibraryMove::Groups {
                ids: vec![e.id],
                parent: Some(c.id),
                before: Some(d.id),
            })
        );
        assert_eq!(before(&x, &d), None, "a group arriving past the limit");
    }

    #[test]
    fn the_bottom_of_an_open_group_with_children_is_its_first_place() {
        let lib = library();
        let below = |dragged: LibraryItem, target: &str, expanded: bool| {
            lib.outline
                .resolve_drop((Tree, dragged), DropSpot::After(Tree, lib.group(target)), expanded)
        };

        assert_eq!(
            below(lib.connection("t1"), "Staging", true),
            lib.connections_move("t1", Some("Staging"), Some("s1"))
        );
        assert_eq!(
            below(lib.connection("t1"), "Staging", false),
            lib.connections_move("t1", Some("Work"), Some("w1")),
            "a folded group is passed by"
        );
        assert_eq!(
            below(lib.group("Home"), "Staging", true),
            lib.groups_move("Home", Some("Staging"), Some("EU"))
        );
        assert_eq!(
            below(lib.connection("w1"), "Home", true),
            lib.connections_move("w1", None, Some("t1")),
            "an open group with no children is passed by"
        );
        assert_eq!(below(lib.connection("s1"), "Staging", true), None, "already first");
        assert_eq!(
            below(lib.connection("s2"), "Staging", true),
            lib.connections_move("s2", Some("Staging"), Some("s1"))
        );
        assert_eq!(below(lib.group("EU"), "Staging", true), None, "already first");
        assert_eq!(below(lib.group("Staging"), "Staging", true), None, "into itself");
    }

    #[test]
    fn the_end_of_the_tree_is_the_top_level() {
        let lib = library();

        assert_eq!(
            lib.dropped((Tree, lib.connection("w1")), DropSpot::End(Tree)),
            lib.connections_move("w1", None, None)
        );
        assert_eq!(
            lib.dropped((Tree, lib.connection("t1")), DropSpot::End(Tree)),
            lib.connections_move("t1", None, None),
            "the last place at the top"
        );
        assert_eq!(lib.dropped((Tree, lib.connection("t2")), DropSpot::End(Tree)), None);
        assert_eq!(
            lib.dropped((Favourites, lib.connection("s1")), DropSpot::End(Tree)),
            lib.connections_move("s1", None, None)
        );
        assert_eq!(
            lib.dropped((Tree, lib.group("Staging")), DropSpot::End(Tree)),
            lib.groups_move("Staging", None, None)
        );
        assert_eq!(
            lib.dropped((Tree, lib.group("Home")), DropSpot::End(Tree)),
            lib.groups_move("Home", None, None)
        );
        assert_eq!(lib.dropped((Tree, lib.group("Archive")), DropSpot::End(Tree)), None);
    }

    #[test]
    fn a_drag_of_a_deleted_item_or_onto_one_resolves_to_nothing() {
        let lib = library();
        let gone = Uuid::new_v4();

        assert_eq!(
            lib.dropped((Tree, Connection(gone)), DropSpot::Into(lib.id("Work"))),
            None
        );
        assert_eq!(lib.dropped((Tree, Connection(gone)), DropSpot::End(Tree)), None);
        assert_eq!(lib.dropped((Tree, Connection(gone)), DropSpot::End(Favourites)), None);
        assert_eq!(lib.dropped((Tree, Group(gone)), DropSpot::Into(lib.id("Home"))), None);
        assert_eq!(
            lib.dropped((Tree, lib.connection("w1")), DropSpot::Before(Tree, Connection(gone))),
            None
        );
    }

    #[test]
    fn a_move_reads_back_from_its_variant() {
        let (a, b, c) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
        let moves = [
            LibraryMove::Connections {
                ids: vec![a, b],
                group: Some(c),
                before: None,
            },
            LibraryMove::Groups {
                ids: vec![a],
                parent: None,
                before: Some(b),
            },
            LibraryMove::Favourites {
                ids: vec![c],
                before: Some(a),
            },
        ];
        for change in moves {
            let value = change.to_variant();
            assert_eq!(value.type_().as_str(), "(sasss)");
            assert_eq!(LibraryMove::from_variant(&value), Some(change));
        }

        let read = |kind: &str, id: &str, parent: &str| {
            LibraryMove::from_variant(
                &(kind.to_owned(), vec![id.to_owned()], parent.to_owned(), String::new()).to_variant(),
            )
        };
        assert_eq!(read("tags", &a.to_string(), ""), None);
        assert_eq!(read("groups", "not an id", ""), None);
        assert_eq!(read("groups", &a.to_string(), "not an id"), None);
        assert_eq!(
            read("favourites", &a.to_string(), &b.to_string()),
            None,
            "a favourite has no parent"
        );
        assert_eq!(LibraryMove::from_variant(&a.to_string().to_variant()), None);
    }
}
