use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};

use super::sidebar_index::{KEY_RANK, SidebarIndex, kind_rank};
use super::sidebar_list_imp as imp;

glib::wrapper! {
    /// One schema's rows of the session's sidebar: every table of the
    /// schema, or the ones a search found there. A row's object is made
    /// when the tree first asks for it, so the GTK thread pays for the
    /// rows on screen, not for the catalog.
    pub struct SidebarList(ObjectSubclass<imp::SidebarList>)
        @implements gio::ListModel;
}

/// The index's entries a list shows: a whole section's run, the
/// entries a search picked from it, or a run set under a heading for
/// each kind, in list order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Entries {
    Run(u32, u32),
    Picked(Vec<u32>),
    Grouped(Vec<Segment>),
}

/// The entries of one kind in a run: `start..end` of the index, under
/// the heading of the kind's `rank`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Segment {
    pub(crate) rank: u8,
    pub(crate) start: u32,
    pub(crate) end: u32,
}

/// What a position of a list holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Row {
    /// The heading of the kind with this rank.
    Heading(u8),
    Entry(u32),
}

impl Default for Entries {
    fn default() -> Self {
        Self::Picked(Vec::new())
    }
}

impl Entries {
    /// A run of `index`, under a heading for each kind it holds. A key
    /// listing has one kind of row and no headings.
    pub(crate) fn grouped(index: &SidebarIndex, start: u32, end: u32) -> Self {
        let mut segments: Vec<Segment> = Vec::new();
        for at in start..end {
            let Some(entry) = index.entry(at) else {
                break;
            };
            let rank = kind_rank(entry.object.kind);
            if rank == KEY_RANK {
                return Self::Run(start, end);
            }
            match segments.last_mut() {
                Some(last) if last.rank == rank => last.end = at + 1,
                _ => segments.push(Segment {
                    rank,
                    start: at,
                    end: at + 1,
                }),
            }
        }
        Self::Grouped(segments)
    }

    pub(crate) fn len(&self) -> u32 {
        match self {
            Self::Run(start, end) => end.saturating_sub(*start),
            Self::Picked(entries) => u32::try_from(entries.len()).unwrap_or(u32::MAX),
            Self::Grouped(segments) => segments
                .iter()
                .map(|segment| 1 + segment.end.saturating_sub(segment.start))
                .sum(),
        }
    }

    pub(crate) fn get(&self, position: u32) -> Option<Row> {
        match self {
            Self::Run(start, end) => start.checked_add(position).filter(|entry| entry < end).map(Row::Entry),
            Self::Picked(entries) => entries.get(position as usize).copied().map(Row::Entry),
            Self::Grouped(segments) => {
                let mut left = position;
                for segment in segments {
                    let size = 1 + segment.end.saturating_sub(segment.start);
                    if left < size {
                        return Some(if left == 0 {
                            Row::Heading(segment.rank)
                        } else {
                            Row::Entry(segment.start + left - 1)
                        });
                    }
                    left -= size;
                }
                None
            }
        }
    }

    /// Where the index's `entry` is among these.
    pub(crate) fn position_of(&self, entry: u32) -> Option<u32> {
        match self {
            Self::Run(start, end) => entry.checked_sub(*start).filter(|_| entry < *end),
            Self::Picked(entries) => entries
                .binary_search(&entry)
                .ok()
                .and_then(|position| u32::try_from(position).ok()),
            Self::Grouped(segments) => {
                let mut before = 0;
                for segment in segments {
                    if (segment.start..segment.end).contains(&entry) {
                        return Some(before + 1 + entry - segment.start);
                    }
                    before += 1 + segment.end - segment.start;
                }
                None
            }
        }
    }
}

impl SidebarList {
    pub(crate) fn new() -> Self {
        glib::Object::new()
    }

    /// Where the index's `entry` is shown, if the list shows it.
    pub(crate) fn position_of_entry(&self, entry: u32) -> Option<u32> {
        self.imp().entries.borrow().position_of(entry)
    }

    /// Whether the list shows `entries` of `index` already.
    pub(crate) fn shows(&self, index: &Arc<SidebarIndex>, entries: &Entries) -> bool {
        let imp = self.imp();
        Arc::ptr_eq(&imp.index.borrow(), index) && *imp.entries.borrow() == *entries
    }

    /// Show `entries` of `index`, taking every row out, then putting the
    /// new ones in. GtkListView looks for the rows it tracks, its scroll
    /// anchor among them, through every row a change adds in place of
    /// them, which would make an object for each; a change that only
    /// removes or only adds has nothing to look through. The same rows
    /// of the same index change nothing.
    pub(crate) fn show(&self, index: &Arc<SidebarIndex>, entries: Entries) {
        if self.shows(index, &entries) {
            return;
        }
        let imp = self.imp();
        imp.objects.borrow_mut().clear();
        imp.made.set(0);
        if !Arc::ptr_eq(&imp.index.borrow(), index) {
            imp.index.replace(index.clone());
        }
        let removed = imp.entries.take().len();
        if removed > 0 {
            self.items_changed(0, removed, 0);
        }
        let added = entries.len();
        imp.entries.replace(entries);
        if added > 0 {
            self.items_changed(0, 0, added);
        }
    }

    /// Make up to `count` more rows, ahead of a tree that asks for every
    /// row of a schema it opens. True once every row is made.
    pub(crate) fn make_rows(&self, count: u32) -> bool {
        let imp = self.imp();
        let n_items = imp.entries.borrow().len();
        let mut at = imp.made.get();
        let mut made = 0;
        while at < n_items && made < count {
            if imp.objects.borrow().get(at as usize).is_none_or(Option::is_none) {
                let _ = imp.item(at);
                made += 1;
            }
            at += 1;
        }
        imp.made.set(at);
        at >= n_items
    }
}

impl Default for SidebarList {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use tablepro_core::meta::{ObjectInfo, ObjectKind, SchemaInfo};

    use super::super::sidebar_index::search_key;
    use super::super::sidebar_object::SidebarObject;
    use super::*;

    fn index(objects: &[(&str, &str)]) -> Arc<SidebarIndex> {
        let objects: Vec<ObjectInfo> = objects
            .iter()
            .map(|(schema, name)| ObjectInfo {
                schema: Some((*schema).to_owned()),
                name: (*name).to_owned(),
                kind: ObjectKind::Table,
                parent_table: None,
            })
            .collect();
        let schemas = [SchemaInfo {
            name: "public".to_owned(),
            is_default: true,
            is_system: false,
        }];
        Arc::new(SidebarIndex::build(&objects, &schemas))
    }

    fn names(list: &SidebarList) -> Vec<String> {
        (0..list.n_items())
            .filter_map(|at| list.item(at).and_downcast::<SidebarObject>())
            .map(|object| object.name())
            .collect()
    }

    fn changes(list: &SidebarList) -> Rc<RefCell<Vec<(u32, u32, u32)>>> {
        let seen = Rc::new(RefCell::new(Vec::new()));
        let log = seen.clone();
        list.connect_items_changed(move |_, position, removed, added| {
            log.borrow_mut().push((position, removed, added));
        });
        seen
    }

    #[gtk4::test]
    fn a_run_shows_one_sections_rows() {
        let index = index(&[
            ("sales", "orders"),
            ("public", "users"),
            ("sales", "carts"),
            ("public", "accounts"),
        ]);
        let list = SidebarList::new();

        list.show(&index, Entries::Run(2, 4));

        assert_eq!(names(&list), ["carts", "orders"]);
        assert_eq!(list.position_of_entry(3), Some(1));
        assert_eq!(list.position_of_entry(1), None);
        assert_eq!(list.item(2), None, "past the end");
    }

    #[gtk4::test]
    fn a_grouped_run_counts_a_heading_for_each_kind() {
        let objects: Vec<ObjectInfo> = [
            ("users", ObjectKind::Table),
            ("recent", ObjectKind::View),
            ("ids", ObjectKind::Sequence),
        ]
        .into_iter()
        .map(|(name, kind)| ObjectInfo {
            schema: Some("public".to_owned()),
            name: name.to_owned(),
            kind,
            parent_table: None,
        })
        .collect();
        let index = Arc::new(SidebarIndex::build(&objects, &[]));
        let list = SidebarList::new();

        list.show(&index, Entries::grouped(&index, 0, 3));

        assert_eq!(list.n_items(), 6);
        let rows: Vec<(bool, String)> = (0..6)
            .filter_map(|at| list.item(at).and_downcast::<SidebarObject>())
            .map(|object| (object.is_heading(), object.name()))
            .collect();
        assert_eq!(
            rows,
            [
                (true, "Tables".to_owned()),
                (false, "users".to_owned()),
                (true, "Views".to_owned()),
                (false, "recent".to_owned()),
                (true, "Sequences".to_owned()),
                (false, "ids".to_owned()),
            ]
        );
        assert_eq!(list.position_of_entry(0), Some(1));
        assert_eq!(list.position_of_entry(2), Some(5));
        assert_eq!(list.item(6), None, "past the end");
    }

    #[gtk4::test]
    fn a_row_keeps_its_object_while_the_list_shows_it() {
        let first_index = index(&[("public", "users"), ("public", "orders")]);
        let list = SidebarList::new();
        list.show(&first_index, Entries::Run(0, 2));
        let first = list.item(0);

        list.show(&first_index, Entries::Run(0, 2));

        assert_eq!(list.item(0), first, "the same rows made the row anew");
        list.show(&index(&[("public", "users"), ("public", "orders")]), Entries::Run(0, 2));
        assert_ne!(list.item(0), first, "a new index kept an old row");
    }

    #[gtk4::test]
    fn rows_are_made_a_batch_at_a_time_and_kept() {
        let index = index(&[("public", "a"), ("public", "b"), ("public", "c")]);
        let list = SidebarList::new();
        list.show(&index, Entries::Run(0, 3));
        let asked = list.item(1);

        assert!(!list.make_rows(1));
        assert!(list.make_rows(1), "a row the tree asked for was made again");
        assert_eq!(list.item(1), asked);
        list.show(&index, Entries::Run(0, 2));
        assert!(!list.make_rows(1), "a new list kept the old one's progress");
    }

    #[gtk4::test]
    fn a_search_is_one_change_and_none_when_the_rows_stay() {
        let index = index(&[("public", "users"), ("public", "orders"), ("public", "user_log")]);
        let list = SidebarList::new();
        list.show(&index, Entries::Run(0, 3));
        let seen = changes(&list);

        list.show(&index, Entries::Picked(index.matching(&search_key("user"))));
        list.show(&index, Entries::Picked(index.matching(&search_key("user"))));
        list.show(&index, Entries::Picked(index.matching(&search_key("users"))));

        assert_eq!(*seen.borrow(), [(0, 3, 0), (0, 0, 2), (0, 2, 0), (0, 0, 1)]);
    }

    #[gtk4::test]
    fn an_empty_list_replacing_an_empty_one_changes_nothing() {
        let list = SidebarList::new();
        let seen = changes(&list);

        list.show(&index(&[]), Entries::default());

        assert!(seen.borrow().is_empty());
        assert_eq!(list.n_items(), 0);
    }
}
