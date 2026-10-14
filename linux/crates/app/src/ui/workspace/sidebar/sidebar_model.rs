use gtk4 as gtk;
use gtk4::gio;
use gtk4::prelude::*;
use tablepro_core::meta::{ObjectInfo, ObjectKind, SchemaInfo, TableRef};

use super::sidebar_object::SidebarObject;

/// The sidebar's objects, sorted into schema sections and filtered by
/// the search. A new object list replaces the store in one splice, and a
/// search changes only the filter, so neither builds a widget per table.
pub(crate) struct SidebarModel {
    store: gio::ListStore,
    filter: gtk::StringFilter,
    filtered: gtk::FilterListModel,
    selection: gtk::SingleSelection,
}

impl SidebarModel {
    pub(crate) fn new() -> Self {
        let store = gio::ListStore::new::<SidebarObject>();
        let by_name = gtk::StringSorter::new(Some(property("name")));
        by_name.set_ignore_case(true);
        let sorted = gtk::SortListModel::new(Some(store.clone()), Some(by_name));
        let sections = gtk::MultiSorter::new();
        sections.append(gtk::NumericSorter::new(Some(property("section-rank"))));
        sections.append(gtk::StringSorter::new(Some(property("section-title"))));
        sorted.set_section_sorter(Some(&sections));
        let filter = gtk::StringFilter::new(Some(property("search-text")));
        filter.set_match_mode(gtk::StringFilterMatchMode::Substring);
        filter.set_ignore_case(true);
        let filtered = gtk::FilterListModel::new(Some(sorted), Some(filter.clone()));
        let selection = gtk::SingleSelection::new(Some(filtered.clone()));
        selection.set_autoselect(false);
        selection.set_can_unselect(true);
        Self {
            store,
            filter,
            filtered,
            selection,
        }
    }

    /// Show `objects`, keeping only what the grid can page through.
    pub(crate) fn replace(&self, objects: &[ObjectInfo], schemas: &[SchemaInfo]) {
        let shown: Vec<SidebarObject> = objects
            .iter()
            .filter(|object| object.kind.is_browsable())
            .map(|object| SidebarObject::new(object, schemas))
            .collect();
        self.store.splice(0, self.store.n_items(), &shown);
    }

    pub(crate) fn set_query(&self, query: &str) {
        let query = query.trim();
        if self.filter.search().as_deref().unwrap_or_default() == query {
            return;
        }
        self.filter.set_search(Some(query).filter(|query| !query.is_empty()));
    }

    pub(crate) fn has_query(&self) -> bool {
        self.filter.search().is_some_and(|search| !search.is_empty())
    }

    /// Where `table` shows under the search, if it does.
    pub(crate) fn position_of(&self, table: &TableRef) -> Option<u32> {
        (0..self.filtered.n_items()).find(|&position| {
            self.object_at(position)
                .is_some_and(|object| object.table_ref() == *table)
        })
    }

    /// The kind of `table` when it is listed at all, searched for or not.
    pub(crate) fn kind_of(&self, table: &TableRef) -> Option<ObjectKind> {
        (0..self.store.n_items()).find_map(|position| {
            self.store
                .item(position)
                .and_downcast::<SidebarObject>()
                .filter(|object| object.table_ref() == *table)
                .map(|object| object.kind())
        })
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
        self.filtered.item(position).and_downcast::<SidebarObject>()
    }

    pub(crate) fn selection(&self) -> &gtk::SingleSelection {
        &self.selection
    }

    pub(crate) fn shown(&self) -> u32 {
        self.filtered.n_items()
    }

    #[cfg(test)]
    pub(crate) fn store(&self) -> &gio::ListStore {
        &self.store
    }
}

fn property(name: &str) -> gtk::PropertyExpression {
    gtk::PropertyExpression::new(SidebarObject::static_type(), None::<&gtk::Expression>, name)
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

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

        model.replace(
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
    fn replace_emits_one_items_changed() {
        let model = SidebarModel::new();
        model.replace(&[object("public", "old")], &[]);
        let objects: Vec<ObjectInfo> = (0..5_000)
            .map(|index| object(if index % 2 == 0 { "public" } else { "sales" }, &format!("t{index}")))
            .collect();
        let stored = Rc::new(Cell::new(0));
        let shown = Rc::new(Cell::new(0));
        let count = stored.clone();
        model
            .store()
            .connect_items_changed(move |_, _, _, _| count.set(count.get() + 1));
        let count = shown.clone();
        model
            .selection()
            .connect_items_changed(move |_, _, _, _| count.set(count.get() + 1));

        model.replace(&objects, &[schema("public", true, false)]);

        assert_eq!(stored.get(), 1, "the store changed more than once");
        assert_eq!(shown.get(), 1, "the list view was told more than once");
        assert_eq!(model.shown(), 5_000);
    }

    #[gtk4::test]
    fn search_filters_case_insensitively_without_touching_store() {
        let model = SidebarModel::new();
        model.replace(
            &[
                object("public", "Users"),
                object("auth", "tokens"),
                object("public", "orders"),
            ],
            &[schema("public", true, false)],
        );
        let changed = Rc::new(Cell::new(0));
        let count = changed.clone();
        model
            .store()
            .connect_items_changed(move |_, _, _, _| count.set(count.get() + 1));

        model.set_query("USE");
        let names = |model: &SidebarModel| -> Vec<String> {
            (0..model.shown())
                .filter_map(|at| model.object_at(at))
                .map(|object| object.name())
                .collect()
        };
        assert_eq!(names(&model), ["Users"]);
        model.set_query("auth.TOK");
        assert_eq!(names(&model), ["tokens"]);
        model.set_query("auth");
        assert_eq!(names(&model), ["tokens"], "the schema matches too");
        model.set_query("");
        assert_eq!(model.shown(), 3);

        assert_eq!(changed.get(), 0, "a search rebuilt the store");
        assert_eq!(model.store().n_items(), 3);
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

        model.replace(&[object("public", "users"), routine, view], &[]);

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
    fn select_finds_the_table_under_the_search_or_clears() {
        let model = SidebarModel::new();
        model.replace(&[object("public", "orders"), object("public", "users")], &[]);
        let users = TableRef::new(Some("public".to_owned()), "users");

        model.select(Some(&users));
        assert_eq!(model.selection().selected(), 1);

        model.set_query("ord");
        model.select(Some(&users));
        assert_eq!(model.selection().selected(), gtk::INVALID_LIST_POSITION);

        model.set_query("");
        model.select(Some(&users));
        model.select(None);
        assert_eq!(model.selection().selected(), gtk::INVALID_LIST_POSITION);
    }
}
