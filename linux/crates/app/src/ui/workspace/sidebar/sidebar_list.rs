use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};

use super::sidebar_index::SidebarIndex;
use super::sidebar_list_imp as imp;

glib::wrapper! {
    /// The sidebar's rows: the index's entries the search keeps, in
    /// their sections. A row's object is made when the list view first
    /// asks for it, so the GTK thread pays for the rows on screen, not
    /// for the catalog.
    pub struct SidebarList(ObjectSubclass<imp::SidebarList>)
        @implements gio::ListModel, gtk::SectionModel;
}

impl SidebarList {
    pub(crate) fn new() -> Self {
        glib::Object::new()
    }

    pub(crate) fn index(&self) -> Rc<SidebarIndex> {
        self.imp().index.borrow().clone()
    }

    /// Show `index`, its entries matching `query` as `search_key` gave
    /// it, every one when it is empty.
    pub(crate) fn replace(&self, index: SidebarIndex, query: &str) {
        let index = Rc::new(index);
        let shown = matching(&index, query);
        let imp = self.imp();
        imp.objects.borrow_mut().clear();
        imp.index.replace(index);
        self.show(shown, true);
    }

    /// Show the entries matching `query`.
    pub(crate) fn filter(&self, query: &str) {
        let shown = matching(&self.index(), query);
        self.show(shown, false);
    }

    /// How many rows were made since the index was last replaced.
    #[cfg(test)]
    pub(crate) fn made(&self) -> usize {
        self.imp().objects.borrow().len()
    }

    /// Where the index's `entry` is shown, if the search keeps it.
    pub(crate) fn position_of_entry(&self, entry: u32) -> Option<u32> {
        let shown = self.imp().shown.borrow();
        shown
            .binary_search(&entry)
            .ok()
            .and_then(|position| u32::try_from(position).ok())
    }

    /// Take every row out, then put the new ones in. GtkListView looks
    /// for the rows it tracks, its scroll anchor among them, through
    /// every row a change adds in place of them, which would make an
    /// object for each; a change that only removes or only adds has
    /// nothing to look through. The list opens at its first row, as a
    /// new list or a new search should.
    fn show(&self, shown: Vec<u32>, replaced: bool) {
        let imp = self.imp();
        if !replaced && *imp.shown.borrow() == shown {
            return;
        }
        let runs = runs(&self.index(), &shown);
        let removed = u32::try_from(imp.shown.take().len()).unwrap_or(u32::MAX);
        imp.runs.take();
        if removed > 0 {
            self.items_changed(0, removed, 0);
        }
        let added = u32::try_from(shown.len()).unwrap_or(u32::MAX);
        imp.shown.replace(shown);
        imp.runs.replace(runs);
        if added > 0 {
            self.items_changed(0, 0, added);
        }
    }
}

impl Default for SidebarList {
    fn default() -> Self {
        Self::new()
    }
}

fn matching(index: &SidebarIndex, query: &str) -> Vec<u32> {
    if query.is_empty() {
        return (0..u32::try_from(index.len()).unwrap_or(u32::MAX)).collect();
    }
    index.matching(query)
}

/// Each section's rows among `shown`, which keeps the index's order, so
/// a section's rows are next to each other.
fn runs(index: &SidebarIndex, shown: &[u32]) -> Vec<(u32, u32)> {
    let mut runs: Vec<(u32, u32)> = Vec::new();
    let mut current = None;
    for (position, &entry) in shown.iter().enumerate() {
        let position = u32::try_from(position).unwrap_or(u32::MAX);
        let section = index.entry(entry).map(|entry| entry.section);
        match runs.last_mut() {
            Some(run) if section == current => run.1 = position + 1,
            _ => runs.push((position, position + 1)),
        }
        current = section;
    }
    runs
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use tablepro_core::meta::{ObjectInfo, ObjectKind, SchemaInfo};

    use super::super::sidebar_index::search_key;
    use super::super::sidebar_object::SidebarObject;
    use super::*;

    fn index(objects: &[(&str, &str)]) -> SidebarIndex {
        let objects: Vec<ObjectInfo> = objects
            .iter()
            .map(|(schema, name)| ObjectInfo {
                schema: Some((*schema).to_owned()),
                name: (*name).to_owned(),
                kind: ObjectKind::Table,
            })
            .collect();
        let schemas = [SchemaInfo {
            name: "public".to_owned(),
            is_default: true,
            is_system: false,
        }];
        SidebarIndex::build(&objects, &schemas)
    }

    fn sections(list: &SidebarList) -> Vec<(u32, u32)> {
        let mut found = Vec::new();
        let mut position = 0;
        while position < list.n_items() {
            let section = list.section(position);
            found.push(section);
            position = section.1;
        }
        found
    }

    fn changes(list: &SidebarList) -> std::rc::Rc<RefCell<Vec<(u32, u32, u32)>>> {
        let seen = std::rc::Rc::new(RefCell::new(Vec::new()));
        let log = seen.clone();
        list.connect_items_changed(move |_, position, removed, added| {
            log.borrow_mut().push((position, removed, added));
        });
        seen
    }

    #[gtk4::test]
    fn sections_are_the_runs_of_one_schema() {
        let list = SidebarList::new();
        list.replace(
            index(&[
                ("sales", "orders"),
                ("public", "users"),
                ("sales", "carts"),
                ("public", "accounts"),
            ]),
            "",
        );

        assert_eq!(list.n_items(), 4);
        assert_eq!(sections(&list), [(0, 2), (2, 4)]);
        assert_eq!(list.section(9), (4, u32::MAX), "past the end");
        let names: Vec<String> = (0..4)
            .filter_map(|at| list.item(at).and_downcast::<SidebarObject>())
            .map(|object| object.name())
            .collect();
        assert_eq!(names, ["accounts", "users", "carts", "orders"]);
    }

    #[gtk4::test]
    fn a_row_keeps_its_object_until_the_index_is_replaced() {
        let list = SidebarList::new();
        list.replace(index(&[("public", "users"), ("public", "orders")]), "");
        let first = list.item(0);

        list.filter(&search_key("o"));
        list.filter("");

        assert_eq!(list.item(0), first, "a search made the row anew");
        list.replace(index(&[("public", "users"), ("public", "orders")]), "");
        assert_ne!(list.item(0), first, "a new index kept an old row");
    }

    #[gtk4::test]
    fn a_search_is_one_change_and_none_when_the_rows_stay() {
        let list = SidebarList::new();
        list.replace(
            index(&[("public", "users"), ("public", "orders"), ("sales", "user_log")]),
            "",
        );
        let seen = changes(&list);

        list.filter(&search_key("user"));
        list.filter(&search_key("user"));
        list.filter(&search_key("users"));

        assert_eq!(*seen.borrow(), [(0, 3, 0), (0, 0, 2), (0, 2, 0), (0, 0, 1)]);
        assert_eq!(sections(&list), [(0, 1)]);
        assert_eq!(list.position_of_entry(1), Some(0));
        assert_eq!(list.position_of_entry(0), None);
    }

    #[gtk4::test]
    fn an_empty_list_replacing_an_empty_one_changes_nothing() {
        let list = SidebarList::new();
        let seen = changes(&list);

        list.replace(index(&[]), "");

        assert!(seen.borrow().is_empty());
        assert_eq!(list.section(0), (0, u32::MAX));
    }

    #[gtk4::test]
    fn a_new_index_keeps_the_search() {
        let list = SidebarList::new();
        let query = search_key("ord");

        list.replace(
            index(&[("public", "users"), ("public", "orders"), ("public", "carts")]),
            &query,
        );

        assert_eq!(list.n_items(), 1);
        assert_eq!(
            list.item(0).and_downcast::<SidebarObject>().map(|object| object.name()),
            Some("orders".to_owned())
        );
    }
}
