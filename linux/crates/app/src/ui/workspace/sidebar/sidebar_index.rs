use std::collections::HashMap;

use gtk4::glib;
use tablepro_core::meta::{ObjectInfo, ObjectKind, SchemaInfo, TableRef};

/// The order sections show in: the default schema, the others, then the
/// engine's own.
const DEFAULT_RANK: u32 = 0;
const OTHER_RANK: u32 = 1;
const SYSTEM_RANK: u32 = 2;

/// The sidebar's tables in list order, with the text the search matches.
/// Built away from the GTK thread: a collation key costs about a
/// microsecond, and a catalog of 50,000 tables needs one each.
#[derive(Debug, Default)]
pub(crate) struct SidebarIndex {
    entries: Vec<IndexEntry>,
    sections: Vec<Section>,
    /// Every entry's `search_key` of `schema.name`, in list order, each
    /// ended by a NUL, which no name or typed search holds. A search is
    /// one pass over it rather than one per table.
    search: String,
    /// Where each entry's text starts in `search`.
    starts: Vec<usize>,
    positions: HashMap<TableRef, u32>,
}

#[derive(Debug)]
pub(crate) struct IndexEntry {
    pub(crate) table: TableRef,
    pub(crate) kind: ObjectKind,
    /// Its section, in `SidebarIndex::section`.
    pub(crate) section: u32,
}

/// A schema's heading. Objects with no schema share the default
/// schema's, under its name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Section {
    pub(crate) title: String,
    pub(crate) rank: u32,
}

impl SidebarIndex {
    /// The objects the grid can page through, in their sections: by rank,
    /// then by title, then each section's tables by name. Titles and names
    /// sort by the locale's collation ignoring case, ties in the order the
    /// server listed them.
    pub(crate) fn build(objects: &[ObjectInfo], schemas: &[SchemaInfo]) -> Self {
        let placement = Placement::new(schemas);
        let mut sections: Vec<Section> = Vec::new();
        let mut section_ids: HashMap<(u32, &str), u32> = HashMap::new();
        let mut keyed: Vec<(u32, glib::CollationKey, String, IndexEntry)> = Vec::new();
        for object in objects.iter().filter(|object| object.kind.is_browsable()) {
            let (title, rank) = placement.section_of(object.schema.as_deref());
            let section = *section_ids.entry((rank, title)).or_insert_with(|| {
                sections.push(Section {
                    title: title.to_owned(),
                    rank,
                });
                u32::try_from(sections.len() - 1).unwrap_or(u32::MAX)
            });
            let table = TableRef::new(object.schema.clone(), object.name.clone());
            let qualified = match &table.schema {
                Some(schema) => format!("{schema}.{}", table.name),
                None => table.name.clone(),
            };
            keyed.push((
                section,
                sort_key(&table.name),
                search_key(&qualified.to_lowercase()),
                IndexEntry {
                    table,
                    kind: object.kind,
                    section,
                },
            ));
        }
        let order = section_order(&sections);
        keyed.sort_by(|(left, left_name, ..), (right, right_name, ..)| {
            order[*left as usize]
                .cmp(&order[*right as usize])
                .then_with(|| left_name.cmp(right_name))
        });
        let mut index = Self {
            sections,
            ..Self::default()
        };
        for (_, _, search, entry) in keyed {
            let at = u32::try_from(index.entries.len()).unwrap_or(u32::MAX);
            index.starts.push(index.search.len());
            index.search.push_str(&search);
            index.search.push('\0');
            index.positions.entry(entry.table.clone()).or_insert(at);
            index.entries.push(entry);
        }
        index
    }

    pub(crate) fn len(&self) -> usize {
        self.entries.len()
    }

    pub(crate) fn entry(&self, index: u32) -> Option<&IndexEntry> {
        self.entries.get(index as usize)
    }

    pub(crate) fn section(&self, section: u32) -> Option<&Section> {
        self.sections.get(section as usize)
    }

    /// Where `table` is in the list order.
    pub(crate) fn find(&self, table: &TableRef) -> Option<u32> {
        self.positions.get(table).copied()
    }

    /// The entries whose `schema.name` holds `query`, which `search_key`
    /// prepared, in list order. Matches come in order, so the entry each
    /// one is in only ever moves forward.
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
    fn new(schemas: &'a [SchemaInfo]) -> Self {
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
            .map_or_else(|| crate::i18n::gettext("Tables"), |schema| schema.name.clone());
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

/// Each section's place in the list, by its id.
fn section_order(sections: &[Section]) -> Vec<usize> {
    let keys: Vec<glib::CollationKey> = sections.iter().map(|section| sort_key(&section.title)).collect();
    let mut ids: Vec<usize> = (0..sections.len()).collect();
    ids.sort_by(|&left, &right| {
        sections[left]
            .rank
            .cmp(&sections[right].rank)
            .then_with(|| keys[left].cmp(&keys[right]))
    });
    let mut order = vec![0; sections.len()];
    for (place, id) in ids.into_iter().enumerate() {
        order[id] = place;
    }
    order
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
    use super::*;

    fn object(schema: Option<&str>, name: &str, kind: ObjectKind) -> ObjectInfo {
        ObjectInfo {
            schema: schema.map(str::to_owned),
            name: name.to_owned(),
            kind,
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

    /// Each entry's section title and name, in list order.
    fn listed(index: &SidebarIndex) -> Vec<(String, String)> {
        (0..u32::try_from(index.len()).unwrap_or_default())
            .filter_map(|at| index.entry(at))
            .map(|entry| {
                let title = index
                    .section(entry.section)
                    .map(|section| section.title.clone())
                    .unwrap_or_default();
                (title, entry.table.name.clone())
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
        assert_eq!(index.entry(0).map(|entry| entry.table.schema.clone()), Some(None));
        assert_eq!(listed(&bare), [("Tables".to_owned(), "notes".to_owned())]);
    }

    #[test]
    fn only_what_the_grid_can_page_is_indexed() {
        let index = SidebarIndex::build(
            &[
                table("public", "users"),
                object(Some("public"), "refresh", ObjectKind::Function),
                object(Some("public"), "active_users", ObjectKind::View),
                object(Some("public"), "ids", ObjectKind::Sequence),
            ],
            &[],
        );

        assert_eq!(index.len(), 2);
        let found = index.find(&TableRef::new(Some("public".to_owned()), "active_users"));
        assert_eq!(found, Some(0));
        assert_eq!(
            found.and_then(|at| index.entry(at)).map(|entry| entry.kind),
            Some(ObjectKind::View)
        );
        assert_eq!(index.find(&TableRef::new(Some("public".to_owned()), "refresh")), None);
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
                .map(|entry| entry.table.name.clone())
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
    fn fifty_thousand_tables_index_in_list_order() {
        let objects: Vec<ObjectInfo> = (0..50_000)
            .rev()
            .map(|at| table(&format!("tenant_{:03}", at % 100), &format!("t{at:05}")))
            .collect();

        let index = SidebarIndex::build(&objects, &[schema("tenant_000", true, false)]);

        assert_eq!(index.len(), 50_000);
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
}
