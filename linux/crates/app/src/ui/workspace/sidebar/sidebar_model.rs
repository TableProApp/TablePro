use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::gio;
use gtk4::prelude::*;
use tablepro_core::meta::{ObjectKind, TableRef};

use super::object_target::ObjectTarget;
use super::sidebar_index::{ObjectGroup, SectionRun, SidebarIndex, search_key};
use super::sidebar_list::{Entries, SidebarList};
use super::tree_node::TreeNode;
use crate::ui::store_sync;

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
/// node per section of the index, an empty schema's too, each over its
/// tables and over the ones the search finds. A new index or search is worked out into rows
/// apart from the lists. A schema's tables take their rows in place; a
/// schema whose results change gets a new list of them, which the tree
/// swaps in with every other schema's in one change. A list of what the
/// search found makes objects only for the rows on screen.
pub(crate) struct SidebarModel {
    /// Every section's schema, in list order.
    schemas: gio::ListStore,
    /// Holds `nothing` once a list landed with no schema to show.
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
        for (section, run) in index.listed_sections() {
            let node = titled
                .insert(section.title.as_str())
                .then(|| held.get(&section.title).cloned())
                .flatten()
                .unwrap_or_else(|| TreeNode::schema(&section.title, None));
            node.set_schema_name(section.schema.clone());
            let entries = run.map_or_else(Entries::default, |(_, run)| Entries::Run(run.start, run.end));
            show_groups(&node, &index, run.map(|(_, run)| run));
            let results = match &mut found {
                Found::Nothing => Entries::default(),
                Found::Everything => entries,
                Found::Picked(picked) => Entries::Picked(
                    run.and_then(|(at, _)| picked.get_mut(at))
                        .map(std::mem::take)
                        .unwrap_or_default(),
                ),
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

    /// Whether the list on screen offers to drop the schema `name`.
    pub(crate) fn droppable(&self, name: &str) -> bool {
        self.shown.borrow().droppable(name)
    }

    /// The kind of `target` when it is listed at all, searched for or not.
    pub(crate) fn kind_of(&self, target: &ObjectTarget) -> Option<ObjectKind> {
        let index = self.shown.borrow();
        let entry = index.find(target)?;
        index.entry(entry).map(|entry| entry.object.kind)
    }

    pub(crate) fn locate(&self, table: &TableRef) -> Option<Located> {
        let entry = self.shown.borrow().find(&ObjectTarget::Rows(table.clone()))?;
        nodes_of(&self.schemas).into_iter().find_map(|schema| {
            let groups = schema.groups()?;
            if let Some(offset) = schema.rows().and_then(|rows| rows.position_of_entry(entry)) {
                return Some(Located {
                    offset: groups.n_items() + offset,
                    group: None,
                    schema,
                });
            }
            nodes_of(&groups).into_iter().find_map(|group| {
                let offset = group.rows()?.position_of_entry(entry)?;
                Some(Located {
                    schema: schema.clone(),
                    group: Some(group),
                    offset,
                })
            })
        })
    }

    /// The schema whose found tables hold `table`, and where among them.
    pub(crate) fn locate_found(&self, table: &TableRef) -> Option<(TreeNode, u32)> {
        let entry = self.shown.borrow().find(&ObjectTarget::Rows(table.clone()))?;
        nodes_of(&self.schemas).into_iter().find_map(|node| {
            let offset = node.found_rows()?.position_of_entry(entry)?;
            Some((node, offset))
        })
    }
}

// `offset` is under the group when there is one, else under the schema, after its groups.
#[derive(Debug)]
pub(crate) struct Located {
    pub(crate) schema: TreeNode,
    pub(crate) group: Option<TreeNode>,
    pub(crate) offset: u32,
}

fn nodes_of(store: &impl IsA<gio::ListModel>) -> Vec<TreeNode> {
    (0..store.n_items())
        .filter_map(|at| store.item(at).and_downcast::<TreeNode>())
        .collect()
}

// A group keeps its node across lists, so the tree keeps it open.
fn show_groups(schema: &TreeNode, index: &Arc<SidebarIndex>, run: Option<SectionRun>) {
    let Some(store) = schema.groups() else {
        return;
    };
    let held: HashMap<ObjectGroup, TreeNode> = nodes_of(&store)
        .into_iter()
        .filter_map(|node| Some((node.object_group()?, node)))
        .collect();
    let mut own = Entries::default();
    let mut groups = Vec::new();
    for group_run in run.map(|run| index.group_runs(run)).unwrap_or_default() {
        let entries = Entries::Run(group_run.start, group_run.end);
        let Some(group) = group_run.group else {
            own = entries;
            continue;
        };
        let node = held.get(&group).cloned().unwrap_or_else(|| TreeNode::objects(group));
        if let Some(rows) = node.rows() {
            rows.show(index, entries);
        }
        groups.push(node);
    }
    if let Some(rows) = schema.rows() {
        rows.show(index, own);
    }
    store_sync::sync(&store, &groups);
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
            parent_table: None,
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
                let groups = node.groups().map(|groups| nodes(&groups.upcast())).unwrap_or_default();
                let lists = std::iter::once(node.rows()).chain(groups.iter().map(TreeNode::rows));
                (
                    node.title(),
                    lists.flatten().flat_map(|list| names(&list.upcast())).collect(),
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
        let rows = |name: &str| ObjectTarget::Rows(TableRef::new(Some("public".to_owned()), name));
        assert_eq!(model.kind_of(&rows("refresh")), None);
        assert_eq!(
            model.kind_of(&ObjectTarget::Definition(routine)),
            Some(ObjectKind::Function)
        );
        assert_eq!(
            model.kind_of(&ObjectTarget::Definition(object("public", "users"))),
            None
        );
        assert_eq!(model.kind_of(&rows("active_users")), Some(ObjectKind::View));
    }

    fn under(node: &TreeNode) -> Vec<String> {
        let Some(children) = node.children() else {
            return Vec::new();
        };
        (0..children.n_items())
            .filter_map(|at| children.item(at))
            .filter_map(|item| match item.downcast::<TreeNode>() {
                Ok(group) => Some(group.title()),
                Err(item) => item.downcast::<SidebarObject>().ok().map(|object| object.name()),
            })
            .collect()
    }

    #[gtk4::test]
    fn a_schema_lists_a_group_for_each_other_kind_before_its_tables() {
        let model = SidebarModel::new();
        let of = |kind, name: &str| ObjectInfo {
            kind,
            ..object("public", name)
        };
        let objects = [
            of(ObjectKind::Function, "total"),
            object("public", "users"),
            of(ObjectKind::Sequence, "ids"),
            of(ObjectKind::View, "active_users"),
            object("public", "orders"),
            of(ObjectKind::Function, "add"),
        ];
        replace(&model, &objects, &[]);

        let schema = nodes(&model.schemas()).remove(0);
        assert_eq!(under(&schema), ["Views", "Sequences", "Functions", "orders", "users"]);
        let groups = nodes(&schema.groups().expect("the schema's groups").upcast());
        assert_eq!(under(&groups[2]), ["add", "total"]);
        assert_eq!(groups[0].object_group(), Some(ObjectGroup::Views));

        replace(&model, &objects[..5], &[]);
        let again = nodes(&model.schemas()).remove(0);
        let kept = nodes(&again.groups().expect("the schema's groups").upcast());
        assert_eq!(
            kept[0], groups[0],
            "a new list keeps the group, and the tree keeps it open"
        );
        assert_eq!(under(&kept[2]), ["total"]);

        let view = model
            .locate(&TableRef::new(Some("public".to_owned()), "active_users"))
            .expect("the view");
        assert_eq!(view.group.as_ref(), Some(&kept[0]));
        assert_eq!(view.offset, 0);
        let orders = model
            .locate(&TableRef::new(Some("public".to_owned()), "orders"))
            .expect("the table");
        assert_eq!((orders.group, orders.offset), (None, 3), "after the three groups");
    }

    #[gtk4::test]
    fn a_key_listing_has_no_groups() {
        let model = SidebarModel::new();
        let key = ObjectInfo {
            kind: ObjectKind::Key(tablepro_core::meta::KeyKind::Hash),
            ..object("public", "session:1")
        };
        let asked = model.replace(SidebarIndex::keys(&[key], "Database 0".to_owned()));
        model.show(asked.work_out()).expect("the rows");

        assert_eq!(under(&nodes(&model.schemas()).remove(0)), ["session:1"]);
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

        let located = model.locate(&users).expect("the table in its schema");
        assert_eq!((located.schema.title(), located.offset), ("sales".to_owned(), 0));
        assert!(located.group.is_none());
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

    #[gtk4::test]
    fn an_empty_schema_has_its_node_and_the_placeholder_waits_for_none_at_all() {
        let model = SidebarModel::new();

        replace(
            &model,
            &[],
            &[schema("public", true, false), schema("pg_catalog", false, true)],
        );

        let schemas = nodes(&model.schemas());
        assert_eq!(listed(&model.schemas()), [("public".to_owned(), Vec::new())]);
        assert_eq!(model.rows().n_items(), 1, "a placeholder beside an empty schema");
        assert_eq!(schemas[0].schema_name().as_deref(), Some("public"));
        replace(&model, &[object("public", "orders")], &[schema("public", true, false)]);
        assert_eq!(
            nodes(&model.schemas()),
            schemas,
            "the schema's node went when it filled"
        );
        assert_eq!(
            listed(&model.schemas()),
            [("public".to_owned(), vec!["orders".to_owned()])]
        );
    }

    #[gtk4::test]
    fn what_a_search_finds_stays_under_its_schema_past_an_empty_one() {
        let model = SidebarModel::new();
        replace(
            &model,
            &[object("public", "users"), object("sales", "leads")],
            &[
                schema("public", true, false),
                schema("archive", false, false),
                schema("sales", false, false),
            ],
        );
        assert_eq!(
            nodes(&model.schemas()).iter().map(TreeNode::title).collect::<Vec<_>>(),
            ["public", "archive", "sales"]
        );

        search(&model, "lead");
        assert_eq!(found(&model), [("sales".to_owned(), vec!["leads".to_owned()])]);
        search(&model, "user");
        assert_eq!(found(&model), [("public".to_owned(), vec!["users".to_owned()])]);
        assert!(model.droppable("archive") && model.droppable("sales"));
        assert!(!model.droppable("public"), "the default schema");
    }

    #[gtk4::test]
    fn a_server_search_lists_nothing_under_an_empty_schema() {
        let model = SidebarModel::new();
        model.hold_search(Search::Everything);

        replace(
            &model,
            &[object("sales", "user:1")],
            &[schema("archive", false, false), schema("sales", false, false)],
        );

        assert_eq!(found(&model), [("sales".to_owned(), vec!["user:1".to_owned()])]);
    }
}
