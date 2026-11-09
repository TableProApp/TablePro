use std::collections::HashMap;

use gtk4::glib;
use tablepro_core::meta::{ObjectInfo, ObjectKind, SchemaInfo};

use super::object_target::ObjectTarget;

/// The order sections show in: the default schema, the others, then the
/// engine's own.
const DEFAULT_RANK: u32 = 0;
const OTHER_RANK: u32 = 1;
const SYSTEM_RANK: u32 = 2;

/// The sidebar's objects in list order, with the text the search matches.
/// Built away from the GTK thread: a collation key costs about a
/// microsecond, and a catalog of 50,000 tables needs one each.
#[derive(Debug, Default)]
pub(crate) struct SidebarIndex {
    entries: Vec<IndexEntry>,
    sections: Vec<Section>,
    /// Each section's id, in list order.
    order: Vec<u32>,
    /// Every entry's `search_key` of `schema.name`, then a trigger's of
    /// `schema.table` after a U+0001, in list order, each ended by a NUL.
    /// No name or typed search holds either, so no match spans two. A
    /// search is one pass over it rather than one per table.
    search: String,
    /// Where each entry's text starts in `search`.
    starts: Vec<usize>,
    positions: HashMap<ObjectTarget, u32>,
    /// Each section's entries, in list order.
    runs: Vec<SectionRun>,
}

/// One section's entries, which the list order keeps together: from
/// `start` to before `end`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SectionRun {
    pub(crate) section: u32,
    pub(crate) start: u32,
    pub(crate) end: u32,
}

#[derive(Debug)]
pub(crate) struct IndexEntry {
    pub(crate) object: ObjectInfo,
    /// Its section, in `SidebarIndex::section`.
    pub(crate) section: u32,
}

/// A schema's heading. Objects with no schema share the default
/// schema's, under its name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Section {
    pub(crate) title: String,
    pub(crate) rank: u32,
    /// The schema its actions name: the one the session lists, or the
    /// one its objects name when the session lists none of that name.
    /// None where the engine lists the default schema's objects with no
    /// schema, as SQLite does its main, so its actions name none too.
    pub(crate) schema: Option<String>,
    /// Whether the list offers to drop the schema: the session lists it
    /// as one of the user's own, it is not the default, and nothing
    /// withheld it.
    pub(crate) droppable: bool,
}

impl SidebarIndex {
    /// The objects the grid can page through, then the routines,
    /// sequences and triggers, in their sections: by rank, then by title,
    /// then by kind and name. Titles and names sort by the locale's
    /// collation ignoring case, ties in the order the server listed them.
    pub(crate) fn build(objects: &[ObjectInfo], schemas: &[SchemaInfo]) -> Self {
        Self::build_titled(objects, schemas, crate::i18n::gettext("Tables"))
    }

    /// A key-value engine's keys, under the one heading of the database
    /// they are in.
    pub(crate) fn keys(keys: &[ObjectInfo], heading: String) -> Self {
        Self::build_titled(keys, &[], heading)
    }

    /// `untitled` heads the objects with no schema when no schema is the
    /// default one. Every schema of the user's own the session lists has
    /// a section, empty or not, so its menu reaches it; the engine's own
    /// have one only for what they hold.
    fn build_titled(objects: &[ObjectInfo], schemas: &[SchemaInfo], untitled: String) -> Self {
        let placement = Placement::new(schemas, untitled);
        let mut sections: Vec<Section> = Vec::new();
        let mut section_ids: HashMap<(u32, &str), u32> = HashMap::new();
        for schema in schemas.iter().filter(|schema| !schema.is_system) {
            let (title, rank) = placement.section_of(Some(schema.name.as_str()));
            section_ids.entry((rank, title)).or_insert_with(|| {
                add_section(
                    &mut sections,
                    Section {
                        title: title.to_owned(),
                        rank,
                        schema: Some(schema.name.clone()),
                        droppable: !schema.is_default,
                    },
                )
            });
        }
        let mut keyed: Vec<(u32, glib::CollationKey, String, IndexEntry)> = Vec::new();
        for object in objects
            .iter()
            .filter(|object| object.kind.is_browsable() || object.kind.is_key() || object.kind.has_definition())
        {
            let (title, rank) = placement.section_of(object.schema.as_deref());
            let section = *section_ids.entry((rank, title)).or_insert_with(|| {
                add_section(
                    &mut sections,
                    Section {
                        title: title.to_owned(),
                        rank,
                        schema: object.schema.clone(),
                        droppable: false,
                    },
                )
            });
            if object.schema.is_none()
                && let Some(placed) = sections.get_mut(section as usize)
            {
                placed.schema = None;
            }
            let mut search = search_key(&qualified(object.schema.as_deref(), &object.name).to_lowercase());
            if let Some(table) = &object.parent_table {
                search.push('\u{1}');
                search.push_str(&search_key(&qualified(object.schema.as_deref(), table).to_lowercase()));
            }
            keyed.push((
                section,
                sort_key(&object.name),
                search,
                IndexEntry {
                    object: object.clone(),
                    section,
                },
            ));
        }
        let order = section_order(&sections);
        let mut place = vec![0; sections.len()];
        for (at, &id) in order.iter().enumerate() {
            place[id as usize] = at;
        }
        keyed.sort_by(
            |(left, left_name, _, left_entry), (right, right_name, _, right_entry)| {
                place[*left as usize]
                    .cmp(&place[*right as usize])
                    .then_with(|| kind_rank(left_entry.object.kind).cmp(&kind_rank(right_entry.object.kind)))
                    .then_with(|| left_name.cmp(right_name))
            },
        );
        let mut index = Self {
            sections,
            order,
            ..Self::default()
        };
        for (_, _, search, entry) in keyed {
            let at = u32::try_from(index.entries.len()).unwrap_or(u32::MAX);
            index.starts.push(index.search.len());
            index.search.push_str(&search);
            index.search.push('\0');
            index.positions.entry(ObjectTarget::of(&entry.object)).or_insert(at);
            match index.runs.last_mut() {
                Some(run) if run.section == entry.section => run.end = at + 1,
                _ => index.runs.push(SectionRun {
                    section: entry.section,
                    start: at,
                    end: at + 1,
                }),
            }
            index.entries.push(entry);
        }
        index
    }

    pub(crate) fn entry(&self, index: u32) -> Option<&IndexEntry> {
        self.entries.get(index as usize)
    }

    #[cfg(test)]
    pub(crate) fn section(&self, section: u32) -> Option<&Section> {
        self.sections.get(section as usize)
    }

    /// Where `target` is in the list order.
    pub(crate) fn find(&self, target: &ObjectTarget) -> Option<u32> {
        self.positions.get(target).copied()
    }

    /// Every section's entries, in list order.
    #[cfg(test)]
    pub(crate) fn runs(&self) -> &[SectionRun] {
        &self.runs
    }

    /// Every section in list order, with its run and the run's place
    /// among the runs when it holds anything. A search's picks are split
    /// by run, so an empty section never takes another's.
    pub(crate) fn listed_sections(&self) -> impl Iterator<Item = (&Section, Option<(usize, SectionRun)>)> {
        let mut runs = self.runs.iter().copied().enumerate().peekable();
        self.order.iter().filter_map(move |&id| {
            let section = self.sections.get(id as usize)?;
            Some((section, runs.next_if(|(_, run)| run.section == id)))
        })
    }

    /// Stop offering to drop each schema `kept` names: the database the
    /// session opened, or one the engine keeps for itself.
    pub(crate) fn withhold_drops(&mut self, kept: impl Fn(&str) -> bool) {
        for section in &mut self.sections {
            if section.schema.as_deref().is_none_or(&kept) {
                section.droppable = false;
            }
        }
    }

    /// Have the actions of `schema`'s section name no schema, where the
    /// engine lists that schema's objects with none.
    pub(crate) fn unqualify(&mut self, schema: &str) {
        for section in &mut self.sections {
            if section.schema.as_deref() == Some(schema) {
                section.schema = None;
            }
        }
    }

    /// Whether the list offers to drop the schema `name`.
    pub(crate) fn droppable(&self, name: &str) -> bool {
        self.sections
            .iter()
            .any(|section| section.droppable && section.schema.as_deref() == Some(name))
    }

    /// `entries`, in list order, split by the run each one is in: one
    /// list per run, in run order.
    pub(crate) fn split_by_run(&self, entries: &[u32]) -> Vec<Vec<u32>> {
        let mut split: Vec<Vec<u32>> = self.runs.iter().map(|_| Vec::new()).collect();
        let mut run = 0;
        for &entry in entries {
            while self.runs.get(run).is_some_and(|current| current.end <= entry) {
                run += 1;
            }
            if let Some(found) = split.get_mut(run) {
                found.push(entry);
            }
        }
        split
    }

    /// The entries whose `schema.name`, or a trigger's `schema.table`,
    /// holds `query`, which `search_key` prepared, in list order. Matches
    /// come in order, so the entry each one is in only ever moves forward.
    pub(crate) fn matching(&self, query: &str) -> Vec<u32> {
        let mut found: Vec<u32> = Vec::new();
        let mut entry = 0;
        for (at, _) in self.search.match_indices(query) {
            while self.starts.get(entry + 1).is_some_and(|&next| next <= at) {
                entry += 1;
            }
            let entry = u32::try_from(entry).unwrap_or(u32::MAX);
            if found.last() != Some(&entry) {
                found.push(entry);
            }
        }
        found
    }
}

/// Where a schema's objects go, read once rather than per object.
struct Placement<'a> {
    ranks: HashMap<&'a str, u32>,
    default_title: String,
}

impl<'a> Placement<'a> {
    fn new(schemas: &'a [SchemaInfo], untitled: String) -> Self {
        let mut ranks = HashMap::new();
        for schema in schemas {
            let rank = if schema.is_default {
                DEFAULT_RANK
            } else if schema.is_system {
                SYSTEM_RANK
            } else {
                OTHER_RANK
            };
            ranks.entry(schema.name.as_str()).or_insert(rank);
        }
        let default_title = schemas
            .iter()
            .find(|schema| schema.is_default)
            .map_or(untitled, |schema| schema.name.clone());
        Self { ranks, default_title }
    }

    /// An object without a schema is in the connection's default one,
    /// and a schema the list does not name is an ordinary one.
    fn section_of<'b>(&'b self, schema: Option<&'b str>) -> (&'b str, u32) {
        match schema {
            None => (self.default_title.as_str(), DEFAULT_RANK),
            Some(schema) => (schema, self.ranks.get(schema).copied().unwrap_or(OTHER_RANK)),
        }
    }
}

fn qualified(schema: Option<&str>, name: &str) -> String {
    match schema {
        Some(schema) => format!("{schema}.{name}"),
        None => name.to_owned(),
    }
}

/// The kinds in the order the macOS sidebar lists them, so each kind is
/// one run of a section and can sit under a heading of its own. A
/// partitioned table or a dictionary is listed with the tables.
pub(crate) fn kind_rank(kind: ObjectKind) -> u8 {
    match kind {
        ObjectKind::View => 1,
        ObjectKind::MaterializedView => 2,
        ObjectKind::ForeignTable => 3,
        ObjectKind::Sequence => 4,
        ObjectKind::Procedure => 5,
        ObjectKind::Function => 6,
        ObjectKind::Trigger => 7,
        ObjectKind::Key(_) => KEY_RANK,
        _ => 0,
    }
}

/// A key-value engine's keys have no kinds to group by.
pub(crate) const KEY_RANK: u8 = 8;

/// What a heading says of the kind with `rank`.
pub(crate) fn rank_title(rank: u8) -> String {
    use crate::i18n::pgettext;
    match rank {
        1 => pgettext("object kind heading", "Views"),
        2 => pgettext("object kind heading", "Materialized Views"),
        3 => pgettext("object kind heading", "Foreign Tables"),
        4 => pgettext("object kind heading", "Sequences"),
        5 => pgettext("object kind heading", "Procedures"),
        6 => pgettext("object kind heading", "Functions"),
        7 => pgettext("object kind heading", "Triggers"),
        _ => pgettext("object kind heading", "Tables"),
    }
}

fn add_section(sections: &mut Vec<Section>, section: Section) -> u32 {
    sections.push(section);
    u32::try_from(sections.len() - 1).unwrap_or(u32::MAX)
}

/// Each section's id, in list order.
fn section_order(sections: &[Section]) -> Vec<u32> {
    let keys: Vec<glib::CollationKey> = sections.iter().map(|section| sort_key(&section.title)).collect();
    let mut ids: Vec<usize> = (0..sections.len()).collect();
    ids.sort_by(|&left, &right| {
        sections[left]
            .rank
            .cmp(&sections[right].rank)
            .then_with(|| keys[left].cmp(&keys[right]))
    });
    ids.into_iter()
        .map(|id| u32::try_from(id).unwrap_or(u32::MAX))
        .collect()
}

/// The key GtkStringSorter sorts by when it ignores case.
fn sort_key(text: &str) -> glib::CollationKey {
    glib::CollationKey::from(glib::casefold(text))
}

/// `text` as GtkStringFilter compares it when it ignores case: in
/// compatibility form, then casefolded. ASCII is already both, past its
/// case.
pub(crate) fn search_key(text: &str) -> String {
    if text.is_ascii() {
        return text.to_ascii_lowercase();
    }
    glib::casefold(glib::normalize(text, glib::NormalizeMode::All)).into()
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::TableRef;

    use super::*;

    fn object(schema: Option<&str>, name: &str, kind: ObjectKind) -> ObjectInfo {
        ObjectInfo {
            schema: schema.map(str::to_owned),
            name: name.to_owned(),
            kind,
            parent_table: None,
        }
    }

    fn table(schema: &str, name: &str) -> ObjectInfo {
        object(Some(schema), name, ObjectKind::Table)
    }

    fn schema(name: &str, is_default: bool, is_system: bool) -> SchemaInfo {
        SchemaInfo {
            name: name.to_owned(),
            is_default,
            is_system,
        }
    }

    fn len(index: &SidebarIndex) -> u32 {
        index.runs().last().map_or(0, |run| run.end)
    }

    /// Each entry's section title and name, in list order.
    fn listed(index: &SidebarIndex) -> Vec<(String, String)> {
        (0..len(index))
            .filter_map(|at| index.entry(at))
            .map(|entry| {
                let title = index
                    .section(entry.section)
                    .map(|section| section.title.clone())
                    .unwrap_or_default();
                (title, entry.object.name.clone())
            })
            .collect()
    }

    #[test]
    fn sections_rank_then_title_then_names_ignoring_case() {
        let schemas = [
            schema("public", true, false),
            schema("pg_catalog", false, true),
            schema("sales", false, false),
            schema("Audit", false, false),
        ];

        let index = SidebarIndex::build(
            &[
                table("sales", "orders"),
                table("pg_catalog", "pg_class"),
                table("public", "users"),
                table("Audit", "log"),
                table("public", "Accounts"),
                table("sales", "Customers"),
                table("archive", "old"),
            ],
            &schemas,
        );

        let pair = |title: &str, name: &str| (title.to_owned(), name.to_owned());
        assert_eq!(
            listed(&index),
            [
                pair("public", "Accounts"),
                pair("public", "users"),
                pair("archive", "old"),
                pair("Audit", "log"),
                pair("sales", "Customers"),
                pair("sales", "orders"),
                pair("pg_catalog", "pg_class"),
            ]
        );
        let ranks: Vec<u32> = ["public", "archive", "pg_catalog"]
            .iter()
            .filter_map(|title| index.sections.iter().find(|section| section.title == *title))
            .map(|section| section.rank)
            .collect();
        assert_eq!(ranks, [DEFAULT_RANK, OTHER_RANK, SYSTEM_RANK]);
    }

    #[test]
    fn an_object_without_a_schema_is_in_the_default_section() {
        let attached = [schema("main", true, false), schema("archive", false, false)];

        let index = SidebarIndex::build(
            &[
                object(None, "notes", ObjectKind::Table),
                table("archive", "old"),
                table("main", "tags"),
            ],
            &attached,
        );
        let bare = SidebarIndex::build(&[object(None, "notes", ObjectKind::Table)], &[]);

        assert_eq!(
            listed(&index),
            [
                ("main".to_owned(), "notes".to_owned()),
                ("main".to_owned(), "tags".to_owned()),
                ("archive".to_owned(), "old".to_owned()),
            ]
        );
        assert_eq!(index.entry(0).map(|entry| entry.object.schema.clone()), Some(None));
        assert_eq!(listed(&bare), [("Tables".to_owned(), "notes".to_owned())]);
    }

    #[test]
    fn routines_sequences_and_triggers_follow_the_tables_of_their_schema() {
        let index = SidebarIndex::build(
            &[
                ObjectInfo::trigger(Some("public".to_owned()), "audit", "users"),
                table("public", "users"),
                object(Some("public"), "refresh", ObjectKind::Function),
                object(Some("public"), "active_users", ObjectKind::View),
                object(Some("public"), "ids", ObjectKind::Sequence),
                object(Some("public"), "archive", ObjectKind::Procedure),
                object(Some("public"), "add", ObjectKind::Function),
                ObjectInfo::trigger(Some("public".to_owned()), "audit", "orders"),
            ],
            &[],
        );

        let kinds: Vec<(String, ObjectKind, Option<String>)> = (0..len(&index))
            .filter_map(|at| index.entry(at))
            .map(|entry| {
                (
                    entry.object.name.clone(),
                    entry.object.kind,
                    entry.object.parent_table.clone(),
                )
            })
            .collect();
        let row = |name: &str, kind, owner: Option<&str>| (name.to_owned(), kind, owner.map(str::to_owned));
        assert_eq!(
            kinds,
            [
                row("users", ObjectKind::Table, None),
                row("active_users", ObjectKind::View, None),
                row("ids", ObjectKind::Sequence, None),
                row("archive", ObjectKind::Procedure, None),
                row("add", ObjectKind::Function, None),
                row("refresh", ObjectKind::Function, None),
                row("audit", ObjectKind::Trigger, Some("users")),
                row("audit", ObjectKind::Trigger, Some("orders")),
            ]
        );
        assert_eq!(index.runs().len(), 1, "every kind shares its schema's section");
    }

    #[test]
    fn a_table_action_never_finds_a_routine_of_the_same_name() {
        let index = SidebarIndex::build(
            &[
                object(Some("public"), "users", ObjectKind::Function),
                table("public", "users"),
            ],
            &[],
        );

        let rows = |name: &str| ObjectTarget::Rows(TableRef::new(Some("public".to_owned()), name));
        let found = index.find(&rows("users"));
        assert_eq!(
            found.and_then(|at| index.entry(at)).map(|entry| entry.object.kind),
            Some(ObjectKind::Table)
        );
        assert_eq!(index.find(&rows("nothing")), None);
    }

    #[test]
    fn a_definition_is_found_by_kind_name_and_table() {
        let on_users = ObjectInfo::trigger(Some("public".to_owned()), "audit", "users");
        let on_orders = ObjectInfo::trigger(Some("public".to_owned()), "audit", "orders");
        let index = SidebarIndex::build(&[on_users.clone(), on_orders.clone(), table("public", "users")], &[]);

        let at = |object: &ObjectInfo| {
            index
                .find(&ObjectTarget::Definition(object.clone()))
                .and_then(|at| index.entry(at))
                .and_then(|entry| entry.object.parent_table.clone())
        };
        assert_eq!(at(&on_users).as_deref(), Some("users"));
        assert_eq!(at(&on_orders).as_deref(), Some("orders"));
        assert_eq!(
            index.find(&ObjectTarget::Definition(table("public", "users"))),
            None,
            "a table has no definition to show"
        );
        assert_eq!(
            at(&ObjectInfo::trigger(Some("public".to_owned()), "audit", "carts")),
            None
        );
    }

    #[test]
    fn a_trigger_is_found_by_its_table() {
        let index = SidebarIndex::build(
            &[
                ObjectInfo::trigger(Some("public".to_owned()), "audit", "orders"),
                table("public", "users"),
            ],
            &[],
        );

        let names = |query: &str| -> Vec<String> {
            index
                .matching(&search_key(query))
                .into_iter()
                .filter_map(|at| index.entry(at))
                .map(|entry| entry.object.name.clone())
                .collect()
        };
        assert_eq!(names("orders"), ["audit"]);
        assert_eq!(
            names("public.audit"),
            ["audit"],
            "schema.name finds a trigger as it finds a table"
        );
        assert_eq!(names("public.orders"), ["audit"]);
        assert_eq!(
            names("orders.aud"),
            Vec::<String>::new(),
            "no table.trigger form to search"
        );
        assert_eq!(names("public.users"), ["users"]);
    }

    #[test]
    fn keys_are_listed_under_their_database() {
        let key = |name: &str, kind| object(None, name, ObjectKind::Key(kind));

        let index = SidebarIndex::keys(
            &[
                key("user:2", tablepro_core::meta::KeyKind::Hash),
                key("User:1", tablepro_core::meta::KeyKind::String),
            ],
            "Database 3".to_owned(),
        );

        assert_eq!(
            listed(&index),
            [
                ("Database 3".to_owned(), "User:1".to_owned()),
                ("Database 3".to_owned(), "user:2".to_owned())
            ]
        );
    }

    #[test]
    fn the_search_matches_schema_and_name_ignoring_case() {
        let index = SidebarIndex::build(
            &[
                table("public", "Users"),
                table("auth", "tokens"),
                table("public", "orders"),
            ],
            &[schema("public", true, false)],
        );
        let names = |query: &str| -> Vec<String> {
            index
                .matching(&search_key(query))
                .into_iter()
                .filter_map(|at| index.entry(at))
                .map(|entry| entry.object.name.clone())
                .collect()
        };

        assert_eq!(names("USE"), ["Users"]);
        assert_eq!(names("auth.TOK"), ["tokens"]);
        assert_eq!(names("auth"), ["tokens"], "the schema matches too");
        assert_eq!(names("."), ["orders", "Users", "tokens"]);
        assert_eq!(names("sp"), Vec::<String>::new(), "a match ran into the next table");
        assert_eq!(
            names("r"),
            ["orders", "Users"],
            "a table with two matches is listed once"
        );
    }

    #[test]
    fn a_search_key_is_casefolded_in_compatibility_form() {
        assert_eq!(search_key("Orders"), "orders");
        assert_eq!(search_key("Straße"), "strasse");
        assert_eq!(search_key("ﬁle"), "file");
        assert_eq!(search_key("ĐƠN_HÀNG"), search_key("đơn_hàng"));
        assert_eq!(
            search_key("Hàng"),
            search_key("ha\u{300}ng"),
            "a composed à matches a decomposed one"
        );
        let index = SidebarIndex::build(&[table("bán", "Đơn_Hàng")], &[]);
        assert_eq!(index.matching(&search_key("HÀNG")), [0]);
    }

    #[test]
    fn each_section_is_one_run_and_a_search_splits_by_run() {
        let index = SidebarIndex::build(
            &[
                table("sales", "orders"),
                table("public", "users"),
                table("sales", "carts"),
                table("public", "accounts"),
            ],
            &[schema("public", true, false)],
        );

        let titles: Vec<(String, u32, u32)> = index
            .runs()
            .iter()
            .map(|run| {
                let title = index
                    .section(run.section)
                    .map(|section| section.title.clone())
                    .unwrap_or_default();
                (title, run.start, run.end)
            })
            .collect();
        assert_eq!(titles, [("public".to_owned(), 0, 2), ("sales".to_owned(), 2, 4)]);
        assert_eq!(
            index.split_by_run(&index.matching(&search_key("r"))),
            [vec![1], vec![2, 3]]
        );
        assert_eq!(index.split_by_run(&[]), [Vec::<u32>::new(), Vec::new()]);
        assert!(SidebarIndex::build(&[], &[]).runs().is_empty());
    }

    #[test]
    fn fifty_thousand_tables_index_in_list_order() {
        let objects: Vec<ObjectInfo> = (0..50_000)
            .rev()
            .map(|at| table(&format!("tenant_{:03}", at % 100), &format!("t{at:05}")))
            .collect();

        let index = SidebarIndex::build(&objects, &[schema("tenant_000", true, false)]);

        assert_eq!(len(&index), 50_000);
        assert_eq!(index.sections.len(), 100);
        let first = listed(&index).into_iter().take(2).collect::<Vec<_>>();
        assert_eq!(
            first,
            [
                ("tenant_000".to_owned(), "t00000".to_owned()),
                ("tenant_000".to_owned(), "t00100".to_owned())
            ]
        );
    }

    /// A section's title, the schema it names, whether it offers a drop,
    /// and its run's place and span.
    type Listed = (String, Option<String>, bool, Option<(usize, u32, u32)>);

    /// Each section as `Listed`, in list order.
    fn sections(index: &SidebarIndex) -> Vec<Listed> {
        index
            .listed_sections()
            .map(|(section, run)| {
                (
                    section.title.clone(),
                    section.schema.clone(),
                    section.droppable,
                    run.map(|(at, run)| (at, run.start, run.end)),
                )
            })
            .collect()
    }

    #[test]
    fn an_empty_main_names_no_schema_where_its_objects_name_none() {
        let mut index = SidebarIndex::build(&[], &[schema("main", true, false)]);

        index.unqualify("main");

        assert_eq!(sections(&index), [("main".to_owned(), None, false, None)]);
    }

    #[test]
    fn every_listed_schema_of_the_users_own_has_a_section_even_empty() {
        let schemas = [
            schema("public", true, false),
            schema("sales", false, false),
            schema("archive", false, false),
            schema("pg_catalog", false, true),
            schema("information_schema", false, true),
        ];

        let index = SidebarIndex::build(
            &[
                table("sales", "orders"),
                table("public", "users"),
                table("information_schema", "tables"),
            ],
            &schemas,
        );

        let named = |name: &str| Some(name.to_owned());
        assert_eq!(
            sections(&index),
            [
                ("public".to_owned(), named("public"), false, Some((0, 0, 1))),
                ("archive".to_owned(), named("archive"), true, None),
                ("sales".to_owned(), named("sales"), true, Some((1, 1, 2))),
                (
                    "information_schema".to_owned(),
                    named("information_schema"),
                    false,
                    Some((2, 2, 3))
                ),
            ],
            "an engine's own schema shows only for what it holds"
        );
        assert_eq!(
            sections(&SidebarIndex::build(&[], &[schema("public", true, false)])),
            [("public".to_owned(), named("public"), false, None)]
        );
    }

    #[test]
    fn a_section_names_its_schema_as_the_engine_names_its_objects() {
        let attached = [schema("main", true, false), schema("archive", false, false)];

        let listed = SidebarIndex::build(
            &[object(None, "notes", ObjectKind::Table), table("other", "old")],
            &attached,
        );
        let empty = SidebarIndex::build(&[], &attached);

        assert_eq!(
            sections(&listed),
            [
                ("main".to_owned(), None, false, Some((0, 0, 1))),
                ("archive".to_owned(), Some("archive".to_owned()), true, None),
                ("other".to_owned(), Some("other".to_owned()), false, Some((1, 1, 2))),
            ],
            "a schema only an object names is not the session's to drop"
        );
        assert_eq!(
            sections(&empty)
                .into_iter()
                .map(|(_, schema, ..)| schema)
                .collect::<Vec<_>>(),
            [Some("main".to_owned()), Some("archive".to_owned())]
        );
    }

    #[test]
    fn a_drop_is_offered_only_for_a_listed_schema_nothing_withheld() {
        let mut index = SidebarIndex::build(
            &[table("public", "users"), table("audit", "log")],
            &[
                schema("public", true, false),
                schema("sales", false, false),
                schema("archive", false, false),
            ],
        );

        index.withhold_drops(|name| name == "sales");

        assert!(index.droppable("archive"));
        assert!(!index.droppable("sales"), "withheld");
        assert!(!index.droppable("public"), "the default schema");
        assert!(!index.droppable("audit"), "not listed by the session");
        assert!(!index.droppable("gone"));
    }
}
