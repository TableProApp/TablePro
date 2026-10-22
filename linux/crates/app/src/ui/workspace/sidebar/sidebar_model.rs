use std::cell::{Cell, RefCell};
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use tablepro_core::meta::{ObjectKind, TableRef};

use super::sidebar_index::{SidebarIndex, search_key};
use super::sidebar_list::{SidebarList, SidebarRows};
use super::sidebar_object::SidebarObject;

/// The sidebar's objects in schema sections, filtered by the search. A
/// new index or search is worked out into rows apart from the list, and
/// the list takes them in one change, so neither builds a widget or an
/// object per table.
pub(crate) struct SidebarModel {
    list: SidebarList,
    selection: gtk::SingleSelection,
    /// The index last given, which the list shows once its rows land.
    index: RefCell<Arc<SidebarIndex>>,
    /// The search as `search_key` gave it, empty for none.
    query: RefCell<String>,
    /// Counts the indexes and searches given, so rows worked out for an
    /// older one never replace a newer one's.
    asked: Cell<u64>,
}

/// The rows to work out for the index and search last given.
pub(crate) struct RowsAsked {
    index: Arc<SidebarIndex>,
    query: String,
    asked: u64,
}

impl RowsAsked {
    pub(crate) fn work_out(self) -> RowsWorkedOut {
        RowsWorkedOut {
            rows: SidebarRows::new(self.index, &self.query),
            asked: self.asked,
        }
    }
}

#[derive(Debug)]
pub(crate) struct RowsWorkedOut {
    rows: SidebarRows,
    asked: u64,
}

impl SidebarModel {
    pub(crate) fn new() -> Self {
        let list = SidebarList::new();
        let selection = gtk::SingleSelection::new(Some(list.clone()));
        selection.set_autoselect(false);
        selection.set_can_unselect(true);
        Self {
            index: RefCell::new(list.index()),
            list,
            selection,
            query: RefCell::new(String::new()),
            asked: Cell::new(0),
        }
    }

    pub(crate) fn replace(&self, index: SidebarIndex) -> RowsAsked {
        self.index.replace(Arc::new(index));
        self.ask()
    }

    /// None when the search is the one already given.
    pub(crate) fn set_query(&self, query: &str) -> Option<RowsAsked> {
        let query = query.trim();
        let prepared = if query.is_empty() {
            String::new()
        } else {
            search_key(query)
        };
        if self.query.replace(prepared.clone()) == prepared {
            return None;
        }
        Some(self.ask())
    }

    fn ask(&self) -> RowsAsked {
        let asked = self.asked.get() + 1;
        self.asked.set(asked);
        RowsAsked {
            index: self.index.borrow().clone(),
            query: self.query.borrow().clone(),
            asked,
        }
    }

    /// Show rows worked out for the index and search last given. Rows a
    /// later one overtook change nothing and come back.
    pub(crate) fn show(&self, worked_out: RowsWorkedOut) -> Result<(), RowsWorkedOut> {
        if worked_out.asked != self.asked.get() {
            return Err(worked_out);
        }
        self.unselect();
        self.list.show(worked_out.rows);
        Ok(())
    }

    /// GtkSingleSelection looks for the selected row among every row a
    /// change adds, which would make all of them. The caller selects
    /// again once the list changed.
    fn unselect(&self) {
        self.selection.set_selected(gtk::INVALID_LIST_POSITION);
    }

    /// The index the list shows now.
    pub(crate) fn shown_index(&self) -> Arc<SidebarIndex> {
        self.list.index()
    }

    pub(crate) fn has_query(&self) -> bool {
        !self.query.borrow().is_empty()
    }

    /// Where `table` shows under the search, if it does.
    pub(crate) fn position_of(&self, table: &TableRef) -> Option<u32> {
        let entry = self.list.index().find(table)?;
        self.list.position_of_entry(entry)
    }

    /// The kind of `table` when it is listed at all, searched for or not.
    pub(crate) fn kind_of(&self, table: &TableRef) -> Option<ObjectKind> {
        let index = self.list.index();
        let entry = index.find(table)?;
        index.entry(entry).map(|entry| entry.kind)
    }

    /// Select `table`'s row, or none. A table the search hides selects
    /// none.
    pub(crate) fn select(&self, table: Option<&TableRef>) {
        let position = table
            .and_then(|table| self.position_of(table))
            .unwrap_or(gtk::INVALID_LIST_POSITION);
        if self.selection.selected() != position {
            self.selection.set_selected(position);
        }
    }

    pub(crate) fn object_at(&self, position: u32) -> Option<SidebarObject> {
        self.list.item(position).and_downcast::<SidebarObject>()
    }

    pub(crate) fn selection(&self) -> &gtk::SingleSelection {
        &self.selection
    }

    pub(crate) fn shown(&self) -> u32 {
        self.list.n_items()
    }

    #[cfg(test)]
    pub(crate) fn list(&self) -> &SidebarList {
        &self.list
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use tablepro_core::meta::{ObjectInfo, SchemaInfo};

    use super::*;

    fn object(schema: &str, name: &str) -> ObjectInfo {
        ObjectInfo {
            schema: Some(schema.to_owned()),
            name: name.to_owned(),
            kind: ObjectKind::Table,
        }
    }

    fn schema(name: &str, is_default: bool, is_system: bool) -> SchemaInfo {
        SchemaInfo {
            name: name.to_owned(),
            is_default,
            is_system,
        }
    }

    fn replace(model: &SidebarModel, objects: &[ObjectInfo], schemas: &[SchemaInfo]) {
        let asked = model.replace(SidebarIndex::build(objects, schemas));
        model.show(asked.work_out()).expect("the newest list's rows");
    }

    fn search(model: &SidebarModel, query: &str) {
        if let Some(asked) = model.set_query(query) {
            model.show(asked.work_out()).expect("the newest search's rows");
        }
    }

    /// Each section's title and its rows' names, in list order.
    fn sections(model: &SidebarModel) -> Vec<(String, Vec<String>)> {
        let shown = model.selection();
        let mut found = Vec::new();
        let mut position = 0;
        while position < shown.n_items() {
            let (start, end) = shown.section(position);
            let title = model
                .object_at(start)
                .map(|object| object.section_title())
                .unwrap_or_default();
            let names = (start..end)
                .filter_map(|at| model.object_at(at))
                .map(|object| object.name())
                .collect();
            found.push((title, names));
            position = end;
        }
        found
    }

    #[gtk4::test]
    fn sections_put_default_schema_first_then_alphabetical_then_system() {
        let model = SidebarModel::new();
        let schemas = [
            schema("public", true, false),
            schema("information_schema", false, true),
            schema("sales", false, false),
            schema("audit", false, false),
        ];

        replace(
            &model,
            &[
                object("sales", "orders"),
                object("information_schema", "tables"),
                object("public", "users"),
                object("audit", "log"),
                object("public", "Accounts"),
                object("sales", "Customers"),
            ],
            &schemas,
        );

        assert_eq!(
            sections(&model),
            [
                ("public".to_owned(), vec!["Accounts".to_owned(), "users".to_owned()]),
                ("audit".to_owned(), vec!["log".to_owned()]),
                ("sales".to_owned(), vec!["Customers".to_owned(), "orders".to_owned()]),
                ("information_schema".to_owned(), vec!["tables".to_owned()]),
            ]
        );
    }

    #[gtk4::test]
    fn replace_takes_every_row_out_then_puts_the_new_ones_in() {
        let model = SidebarModel::new();
        replace(&model, &[object("public", "old")], &[]);
        let objects: Vec<ObjectInfo> = (0..5_000)
            .map(|index| object(if index % 2 == 0 { "public" } else { "sales" }, &format!("t{index}")))
            .collect();
        let listed = Rc::new(Cell::new(0));
        let shown = Rc::new(Cell::new(0));
        let count = listed.clone();
        model
            .list()
            .connect_items_changed(move |_, _, _, _| count.set(count.get() + 1));
        let count = shown.clone();
        model
            .selection()
            .connect_items_changed(move |_, _, _, _| count.set(count.get() + 1));

        replace(&model, &objects, &[schema("public", true, false)]);

        assert_eq!(
            listed.get(),
            2,
            "the list did not take the old rows out, then put the new ones in"
        );
        assert_eq!(shown.get(), 2, "the list view was not told of both");
        assert_eq!(model.shown(), 5_000);
    }

    #[gtk4::test]
    fn search_filters_case_insensitively_without_rebuilding_the_index() {
        let model = SidebarModel::new();
        replace(
            &model,
            &[
                object("public", "Users"),
                object("auth", "tokens"),
                object("public", "orders"),
            ],
            &[schema("public", true, false)],
        );
        let index = model.list().index();

        search(&model, "USE");
        let names = |model: &SidebarModel| -> Vec<String> {
            (0..model.shown())
                .filter_map(|at| model.object_at(at))
                .map(|object| object.name())
                .collect()
        };
        assert_eq!(names(&model), ["Users"]);
        search(&model, "auth.TOK");
        assert_eq!(names(&model), ["tokens"]);
        search(&model, "auth");
        assert_eq!(names(&model), ["tokens"], "the schema matches too");
        search(&model, "  ");
        assert!(!model.has_query(), "blank is no search");
        assert_eq!(model.shown(), 3);

        assert!(Arc::ptr_eq(&index, &model.list().index()), "a search rebuilt the index");
    }

    #[gtk4::test]
    fn rows_worked_out_for_an_older_list_or_search_are_dropped() {
        let model = SidebarModel::new();
        replace(&model, &[object("public", "orders")], &[]);
        let names = |model: &SidebarModel| -> Vec<String> {
            (0..model.shown())
                .filter_map(|at| model.object_at(at))
                .map(|object| object.name())
                .collect()
        };

        let listing = model.replace(SidebarIndex::build(
            &[object("public", "orders"), object("public", "users")],
            &[],
        ));
        let older = model.set_query("ord").expect("a new search");
        let newer = model.set_query("us").expect("a new search");

        assert!(
            model.show(newer.work_out()).is_ok(),
            "the last search's rows were dropped"
        );
        assert!(
            model.show(older.work_out()).is_err(),
            "an older search's rows replaced the last"
        );
        assert!(
            model.show(listing.work_out()).is_err(),
            "a list's rows replaced a later search's"
        );
        assert_eq!(names(&model), ["users"], "the search did not filter the new list");
        assert!(
            model.set_query(" US ").is_none(),
            "the same search was worked out again"
        );
    }

    #[gtk4::test]
    fn only_what_the_grid_can_page_is_listed() {
        let model = SidebarModel::new();
        let routine = ObjectInfo {
            kind: ObjectKind::Function,
            ..object("public", "refresh")
        };
        let view = ObjectInfo {
            kind: ObjectKind::View,
            ..object("public", "active_users")
        };

        replace(&model, &[object("public", "users"), routine, view], &[]);

        assert_eq!(model.shown(), 2);
        assert_eq!(
            model.kind_of(&TableRef::new(Some("public".to_owned()), "refresh")),
            None
        );
        assert_eq!(
            model.kind_of(&TableRef::new(Some("public".to_owned()), "active_users")),
            Some(ObjectKind::View)
        );
    }

    #[gtk4::test]
    fn a_selected_row_does_not_make_every_row_of_a_new_list() {
        let model = SidebarModel::new();
        let objects: Vec<ObjectInfo> = (0..5_000).map(|at| object("public", &format!("t{at:05}"))).collect();
        replace(&model, &objects, &[]);
        let last = TableRef::new(Some("public".to_owned()), "t04999");
        model.select(Some(&last));

        replace(&model, &objects, &[]);
        search(&model, "t0");
        search(&model, "t");
        model.select(Some(&last));

        assert_eq!(model.selection().selected(), 4_999);
        assert!(
            model.list().made() < 10,
            "{} rows made for one selected",
            model.list().made()
        );
    }

    #[gtk4::test]
    fn select_finds_the_table_under_the_search_or_clears() {
        let model = SidebarModel::new();
        replace(&model, &[object("public", "orders"), object("public", "users")], &[]);
        let users = TableRef::new(Some("public".to_owned()), "users");

        model.select(Some(&users));
        assert_eq!(model.selection().selected(), 1);

        search(&model, "ord");
        model.select(Some(&users));
        assert_eq!(model.selection().selected(), gtk::INVALID_LIST_POSITION);
        assert_eq!(
            model.kind_of(&users),
            Some(ObjectKind::Table),
            "a hidden table is still listed"
        );

        search(&model, "");
        model.select(Some(&users));
        model.select(None);
        assert_eq!(model.selection().selected(), gtk::INVALID_LIST_POSITION);
    }
}
