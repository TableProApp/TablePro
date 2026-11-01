use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::gio;
use gtk4::prelude::*;
use tablepro_core::meta::{ObjectKind, TableRef};

use super::sidebar_index::{SidebarIndex, search_key};
use super::sidebar_list::{Entries, SidebarList};
use super::store_sync;
use super::tree_node::TreeNode;

/// What the search asks of the session's list.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) enum Search {
    /// No search: the results list nothing.
    #[default]
    None,
    /// Every row is a result: the server already matched the search.
    Everything,
    /// The rows whose `schema.name` holds this, as `search_key` gave it.
    Text(String),
}

/// The session's tables as the connection tree lists them: a schema
/// node per section of the index, each over its tables and over the
/// ones the search finds. A new index or search is worked out into rows
/// apart from the lists. A schema's tables take their rows in place; a
/// schema whose results change gets a new list of them, which the tree
/// swaps in with every other schema's in one change. A list of what the
/// search found makes objects only for the rows on screen.
pub(crate) struct SidebarModel {
    /// Every section's schema, in list order.
    schemas: gio::ListStore,
    /// Holds `nothing` once a list landed with no table in it.
    empty: gio::ListStore,
    rows: gtk::FlattenListModel,
    nothing: TreeNode,
    /// The index last given, which the lists show once its rows land.
    index: RefCell<Arc<SidebarIndex>>,
    /// The index the lists show now.
    shown: RefCell<Arc<SidebarIndex>>,
    search: RefCell<Search>,
    /// Counts the indexes and searches given, so rows worked out for an
    /// older one never replace a newer one's.
    asked: Cell<u64>,
    /// The last one whose rows the lists show.
    answered: Cell<u64>,
}

/// The rows to work out for the index and search last given.
pub(crate) struct RowsAsked {
    index: Arc<SidebarIndex>,
    search: Search,
    asked: u64,
}

impl RowsAsked {
    pub(crate) fn work_out(self) -> RowsWorkedOut {
        let found = match &self.search {
            Search::None => Found::Nothing,
            Search::Everything => Found::Everything,
            Search::Text(query) => Found::Picked(self.index.split_by_run(&self.index.matching(query))),
        };
        RowsWorkedOut {
            index: self.index,
            found,
            asked: self.asked,
        }
    }
}

#[derive(Debug)]
enum Found {
    Nothing,
    Everything,
    /// Each run's entries the search finds, in run order.
    Picked(Vec<Vec<u32>>),
}

#[derive(Debug)]
pub(crate) struct RowsWorkedOut {
    index: Arc<SidebarIndex>,
    found: Found,
    asked: u64,
}

impl SidebarModel {
    pub(crate) fn new() -> Self {
        let schemas = gio::ListStore::new::<TreeNode>();
        let empty = gio::ListStore::new::<TreeNode>();
        let index: Arc<SidebarIndex> = Arc::default();
        Self {
            rows: flatten(&schemas, &empty),
            schemas,
            empty,
            nothing: TreeNode::placeholder(&crate::i18n::gettext("No Tables")),
            index: RefCell::new(index.clone()),
            shown: RefCell::new(index),
            search: RefCell::new(Search::None),
            asked: Cell::new(0),
            answered: Cell::new(0),
        }
    }

    /// Say what the placeholder says: no tables, keys or collections.
    pub(crate) fn name_placeholder(&self, nothing: &str) {
        self.nothing.set_title(nothing);
    }

    pub(crate) fn replace(&self, index: SidebarIndex) -> RowsAsked {
        self.index.replace(Arc::new(index));
        self.ask()
    }

    /// The search typed, as the lists filter it. None when it is the one
    /// already given.
    pub(crate) fn set_query(&self, query: &str) -> Option<RowsAsked> {
        let query = query.trim();
        let search = if query.is_empty() {
            Search::None
        } else {
            Search::Text(search_key(query))
        };
        self.set_search(search)
    }

    pub(crate) fn set_search(&self, search: Search) -> Option<RowsAsked> {
        if *self.search.borrow() == search {
            return None;
        }
        self.search.replace(search);
        Some(self.ask())
    }

    /// The search, given with the next index, which asks for both.
    pub(crate) fn hold_search(&self, search: Search) {
        self.search.replace(search);
    }

    fn ask(&self) -> RowsAsked {
        let asked = self.asked.get() + 1;
        self.asked.set(asked);
        RowsAsked {
            index: self.index.borrow().clone(),
            search: self.search.borrow().clone(),
            asked,
        }
    }

    /// Show rows worked out for the index and search last given, and
    /// hand back the index shown before, for the caller to let go of off
    /// the GTK thread. Rows a later one overtook change nothing and come
    /// back.
    pub(crate) fn show(&self, worked_out: RowsWorkedOut) -> Result<Arc<SidebarIndex>, RowsWorkedOut> {
        if worked_out.asked != self.asked.get() {
            return Err(worked_out);
        }
        self.answered.set(worked_out.asked);
        let RowsWorkedOut { index, mut found, .. } = worked_out;
        let held: HashMap<String, TreeNode> = (0..self.schemas.n_items())
            .filter_map(|at| self.schemas.item(at).and_downcast::<TreeNode>())
            .map(|node| (node.title(), node))
            .collect();
        let mut schemas = Vec::new();
        // A schema named as an engine names the objects of none is a
        // section of its own under the same title.
        let mut titled: HashSet<&str> = HashSet::new();
        for (at, run) in index.runs().iter().enumerate() {
            let Some(section) = index.section(run.section) else {
                continue;
            };
            let node = titled
                .insert(section.title.as_str())
                .then(|| held.get(&section.title).cloned())
                .flatten()
                .unwrap_or_else(|| TreeNode::schema(&section.title, None));
            node.set_schema_name(index.entry(run.start).and_then(|entry| entry.table.schema.clone()));
            if let Some(rows) = node.rows() {
                rows.show(&index, Entries::Run(run.start, run.end));
            }
            let results = match &mut found {
                Found::Nothing => Entries::default(),
                Found::Everything => Entries::Run(run.start, run.end),
                Found::Picked(picked) => Entries::Picked(picked.get_mut(at).map(std::mem::take).unwrap_or_default()),
            };
            if node.found_rows().is_none_or(|list| !list.shows(&index, &results)) {
                let list = SidebarList::new();
                list.show(&index, results);
                node.set_found(list);
            }
            schemas.push(node);
        }
        store_sync::sync(&self.schemas, &schemas);
        show_alone(&self.empty, &self.nothing, schemas.is_empty());
        Ok(self.shown.replace(index))
    }

    /// Every schema, as the tree lists them under the connection, then
    /// the placeholder once the list holds none.
    pub(crate) fn rows(&self) -> gio::ListModel {
        self.rows.clone().upcast()
    }

    pub(crate) fn schemas(&self) -> gio::ListModel {
        self.schemas.clone().upcast()
    }

    /// The index the lists show now.
    pub(crate) fn shown_index(&self) -> Arc<SidebarIndex> {
        self.shown.borrow().clone()
    }

    /// Whether the lists show what was last asked for.
    pub(crate) fn settled(&self) -> bool {
        self.answered.get() == self.asked.get()
    }

    /// The kind of `table` when it is listed at all, searched for or not.
    pub(crate) fn kind_of(&self, table: &TableRef) -> Option<ObjectKind> {
        let index = self.shown.borrow();
        let entry = index.find(table)?;
        index.entry(entry).map(|entry| entry.kind)
    }

    /// Whether the list on show holds the routine, sequence or trigger.
    pub(crate) fn lists_definition(&self, object: &tablepro_core::meta::ObjectInfo) -> bool {
        self.shown.borrow().find_definition(object).is_some()
    }

    /// The schema whose tables hold `table`, and where among them.
    pub(crate) fn locate(&self, table: &TableRef) -> Option<(TreeNode, u32)> {
        self.locate_in(table, TreeNode::rows)
    }

    /// The schema whose found tables hold `table`, and where among them.
    pub(crate) fn locate_found(&self, table: &TableRef) -> Option<(TreeNode, u32)> {
        self.locate_in(table, TreeNode::found_rows)
    }

    fn locate_in(
        &self,
        table: &TableRef,
        list: fn(&TreeNode) -> Option<super::sidebar_list::SidebarList>,
    ) -> Option<(TreeNode, u32)> {
        let entry = self.shown.borrow().find(table)?;
        let store = &self.schemas;
        (0..store.n_items())
            .filter_map(|at| store.item(at).and_downcast::<TreeNode>())
            .find_map(|node| {
                let offset = list(&node)?.position_of_entry(entry)?;
                Some((node, offset))
            })
    }
}

fn flatten(first: &gio::ListStore, then: &gio::ListStore) -> gtk::FlattenListModel {
    let models = gio::ListStore::new::<gio::ListModel>();
    models.append(first);
    models.append(then);
    gtk::FlattenListModel::new(Some(models))
}

/// `store` holds `node` alone when `shown`, else nothing.
fn show_alone(store: &gio::ListStore, node: &TreeNode, shown: bool) {
    let held = store.n_items() > 0;
    if shown && !held {
        store.append(node);
    } else if !shown && held {
        store.remove_all();
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::{ObjectInfo, SchemaInfo};

    use super::super::sidebar_object::SidebarObject;
    use super::*;

    fn object(schema: &str, name: &str) -> ObjectInfo {
        ObjectInfo {
            schema: Some(schema.to_owned()),
            name: name.to_owned(),
            kind: ObjectKind::Table,
            table: None,
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

    fn nodes(store: &gio::ListModel) -> Vec<TreeNode> {
        (0..store.n_items())
            .filter_map(|at| store.item(at).and_downcast::<TreeNode>())
            .collect()
    }

    fn names(list: &gio::ListModel) -> Vec<String> {
        (0..list.n_items())
            .filter_map(|at| list.item(at).and_downcast::<SidebarObject>())
            .map(|object| object.name())
            .collect()
    }

    /// Each schema's title and its tables' names.
    fn listed(store: &gio::ListModel) -> Vec<(String, Vec<String>)> {
        nodes(store)
            .into_iter()
            .map(|node| {
                (
                    node.title(),
                    node.children().map(|list| names(&list)).unwrap_or_default(),
                )
            })
            .collect()
    }

    /// Each schema the search found tables in, and their names.
    fn found(model: &SidebarModel) -> Vec<(String, Vec<String>)> {
        nodes(&model.schemas())
            .into_iter()
            .map(|node| (node.title(), node.found().map(|list| names(&list)).unwrap_or_default()))
            .filter(|(_, names)| !names.is_empty())
            .collect()
    }

    #[gtk4::test]
    fn schemas_put_default_first_then_alphabetical_then_system() {
        let model = SidebarModel::new();

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
            &[
                schema("public", true, false),
                schema("information_schema", false, true),
                schema("sales", false, false),
                schema("audit", false, false),
            ],
        );

        let pair = |title: &str, names: &[&str]| (title.to_owned(), names.iter().map(|&n| n.to_owned()).collect());
        assert_eq!(
            listed(&model.schemas()),
            [
                pair("public", &["Accounts", "users"]),
                pair("audit", &["log"]),
                pair("sales", &["Customers", "orders"]),
                pair("information_schema", &["tables"]),
            ]
        );
        assert!(found(&model).is_empty(), "results without a search");
        assert_eq!(model.rows().n_items(), 4, "a placeholder beside the schemas");
    }

    #[gtk4::test]
    fn a_search_fills_the_results_and_leaves_every_schema_as_it_was() {
        let model = SidebarModel::new();
        replace(
            &model,
            &[
                object("public", "users"),
                object("public", "orders"),
                object("sales", "leads"),
            ],
            &[schema("public", true, false)],
        );
        let before = nodes(&model.schemas());
        let all = before.iter().filter_map(TreeNode::rows).collect::<Vec<_>>();
        let changed = std::rc::Rc::new(Cell::new(0));
        for list in &all {
            let count = changed.clone();
            list.connect_items_changed(move |_, _, _, _| count.set(count.get() + 1));
        }

        search(&model, "ORD");

        assert_eq!(found(&model), [("public".to_owned(), vec!["orders".to_owned()])]);
        assert_eq!(nodes(&model.schemas()), before, "a search made the schemas anew");
        assert_eq!(changed.get(), 0, "a search changed a schema's tables");
        search(&model, "  ");
        assert!(found(&model).is_empty(), "no search, yet results");
    }

    #[gtk4::test]
    fn the_placeholder_says_when_there_is_nothing_to_list() {
        let model = SidebarModel::new();
        assert_eq!(model.rows().n_items(), 0, "a placeholder before anything was listed");
        replace(&model, &[], &[]);
        let titles = |list: gio::ListModel| nodes(&list).iter().map(TreeNode::title).collect::<Vec<_>>();
        assert_eq!(titles(model.rows()), ["No Tables"]);

        replace(&model, &[object("public", "orders")], &[]);
        search(&model, "zzz");

        assert_eq!(titles(model.rows()), ["public"]);
        assert!(found(&model).is_empty());
    }

    #[gtk4::test]
    fn rows_worked_out_for_an_older_list_or_search_are_dropped() {
        let model = SidebarModel::new();
        replace(&model, &[object("public", "orders")], &[]);

        let listing = model.replace(SidebarIndex::build(
            &[object("public", "orders"), object("public", "users")],
            &[],
        ));
        let older = model.set_query("ord").expect("a new search");
        let newer = model.set_query("us").expect("a new search");

        assert!(!model.settled());
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
        assert!(model.settled());
        assert_eq!(
            found(&model),
            [("public".to_owned(), vec!["users".to_owned()])],
            "the search did not filter the new list"
        );
        assert!(
            model.set_query(" US ").is_none(),
            "the same search was worked out again"
        );
    }

    #[gtk4::test]
    fn a_routine_is_listed_but_table_actions_never_find_it() {
        let model = SidebarModel::new();
        let routine = ObjectInfo {
            kind: ObjectKind::Function,
            ..object("public", "refresh")
        };
        let view = ObjectInfo {
            kind: ObjectKind::View,
            ..object("public", "active_users")
        };

        replace(&model, &[object("public", "users"), routine.clone(), view], &[]);

        assert_eq!(listed(&model.schemas())[0].1.len(), 3);
        assert_eq!(
            model.kind_of(&TableRef::new(Some("public".to_owned()), "refresh")),
            None
        );
        assert!(model.lists_definition(&routine));
        assert!(!model.lists_definition(&object("public", "users")));
        assert_eq!(
            model.kind_of(&TableRef::new(Some("public".to_owned()), "active_users")),
            Some(ObjectKind::View)
        );
    }

    #[gtk4::test]
    fn a_table_is_located_in_its_schema_and_among_the_results() {
        let model = SidebarModel::new();
        replace(
            &model,
            &[
                object("public", "orders"),
                object("public", "users"),
                object("sales", "users"),
            ],
            &[schema("public", true, false)],
        );
        let users = TableRef::new(Some("sales".to_owned()), "users");

        let (node, offset) = model.locate(&users).expect("the table in its schema");
        assert_eq!((node.title(), offset), ("sales".to_owned(), 0));
        assert!(model.locate_found(&users).is_none(), "found with no search");

        search(&model, "user");
        let (node, offset) = model
            .locate_found(&TableRef::new(Some("public".to_owned()), "users"))
            .expect("found");
        assert_eq!((node.title(), offset), ("public".to_owned(), 0));
        assert_eq!(node.schema_name().as_deref(), Some("public"));
    }

    #[gtk4::test]
    fn a_server_search_lists_every_row_it_returned_as_found() {
        let model = SidebarModel::new();
        model.hold_search(Search::Everything);

        replace(&model, &[object("public", "user:1"), object("public", "user:2")], &[]);

        assert_eq!(
            found(&model),
            [("public".to_owned(), vec!["user:1".to_owned(), "user:2".to_owned()])]
        );
    }
}
