use std::collections::{BTreeSet, HashMap};

use tablepro_core::meta::{IndexInfo, IndexKey, TableRef};
use tablepro_core::{ColumnInfo, ForeignKeyInfo};

/// One table as the read brought it back: its columns, its own foreign
/// keys and its indexes, from one connection lease.
#[derive(Debug, Clone)]
pub(crate) struct TableRead {
    pub table: TableRef,
    pub columns: Vec<ColumnInfo>,
    pub foreign_keys: Vec<ForeignKeyInfo>,
    pub indexes: Vec<IndexInfo>,
}

/// A schema's tables and the foreign keys between them.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct SchemaDiagram {
    /// Sorted by name, so the same schema always draws the same way.
    pub tables: Vec<DiagramTable>,
    pub relations: Vec<DiagramRelation>,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct DiagramTable {
    pub table: TableRef,
    pub columns: Vec<DiagramColumn>,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct DiagramColumn {
    pub name: String,
    pub type_name: String,
    pub primary_key: bool,
    pub foreign_key: bool,
    pub nullable: bool,
}

/// A foreign key from `from` to `to`, both indexes into `tables`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DiagramRelation {
    pub name: String,
    pub from: usize,
    pub from_columns: Vec<usize>,
    pub to: usize,
    pub to_columns: Vec<usize>,
    /// A key column takes NULL, so a row need not point anywhere.
    pub optional: bool,
    /// The key columns are the table's primary key or a unique index, so
    /// at most one row points at each referenced row.
    pub unique: bool,
}

impl SchemaDiagram {
    /// The diagram of what the read found. A table with no column the
    /// account can read was dropped after the list was read, so it is
    /// left out. A key to a table outside the read is not drawn: the
    /// diagram shows one schema.
    pub(crate) fn build(mut reads: Vec<TableRead>) -> Self {
        reads.retain(|read| !read.columns.is_empty());
        reads.sort_by(|a, b| {
            a.table
                .name
                .cmp(&b.table.name)
                .then_with(|| a.table.schema.cmp(&b.table.schema))
        });
        let index: HashMap<&TableRef, usize> = reads.iter().enumerate().map(|(at, read)| (&read.table, at)).collect();
        let mut relations = Vec::new();
        for (from, read) in reads.iter().enumerate() {
            for key in &read.foreign_keys {
                let target = TableRef::new(
                    key.ref_schema.clone().or_else(|| read.table.schema.clone()),
                    key.ref_table.clone(),
                );
                let Some(&to) = index.get(&target) else {
                    continue;
                };
                let Some(referenced) = reads.get(to) else {
                    continue;
                };
                relations.push(DiagramRelation {
                    name: key.name.clone(),
                    from,
                    from_columns: positions(&read.columns, &key.columns),
                    to,
                    to_columns: positions(&referenced.columns, &key.ref_columns),
                    optional: key.columns.iter().any(|name| {
                        read.columns
                            .iter()
                            .any(|column| &column.name == name && column.nullable)
                    }),
                    unique: is_unique(read, &key.columns),
                });
            }
        }
        let tables = reads
            .into_iter()
            .map(|read| {
                let keyed: BTreeSet<&str> = read
                    .foreign_keys
                    .iter()
                    .flat_map(|key| key.columns.iter().map(String::as_str))
                    .collect();
                let columns = read
                    .columns
                    .iter()
                    .map(|column| DiagramColumn {
                        name: column.name.clone(),
                        type_name: column.column_type.name.clone(),
                        primary_key: column.primary_key,
                        foreign_key: keyed.contains(column.name.as_str()),
                        nullable: column.nullable,
                    })
                    .collect();
                DiagramTable {
                    table: read.table,
                    columns,
                }
            })
            .collect();
        Self { tables, relations }
    }

    /// The tables `table` points at and the tables that point at it, each
    /// once, by name.
    pub(crate) fn neighbours(&self, table: usize) -> (Vec<&str>, Vec<&str>) {
        let names = |indexes: BTreeSet<usize>| -> Vec<&str> {
            let mut names: Vec<&str> = indexes
                .into_iter()
                .filter_map(|at| self.tables.get(at))
                .map(|found| found.table.name.as_str())
                .collect();
            names.sort_unstable();
            names
        };
        let references = self
            .relations
            .iter()
            .filter(|relation| relation.from == table && relation.to != table)
            .map(|relation| relation.to)
            .collect();
        let referenced_by = self
            .relations
            .iter()
            .filter(|relation| relation.to == table && relation.from != table)
            .map(|relation| relation.from)
            .collect();
        (names(references), names(referenced_by))
    }

    /// Where `table` is, by schema and name.
    pub(crate) fn position_of(&self, table: &TableRef) -> Option<usize> {
        self.tables.iter().position(|found| &found.table == table)
    }
}

fn positions(columns: &[ColumnInfo], names: &[String]) -> Vec<usize> {
    names
        .iter()
        .filter_map(|name| columns.iter().position(|column| &column.name == name))
        .collect()
}

/// Whether no two rows can hold the same key: its columns take in the
/// primary key, or the columns of a unique index that covers every row.
fn is_unique(read: &TableRead, key: &[String]) -> bool {
    let key: BTreeSet<&str> = key.iter().map(String::as_str).collect();
    if key.is_empty() {
        return false;
    }
    let primary: BTreeSet<&str> = read
        .columns
        .iter()
        .filter(|column| column.primary_key)
        .map(|column| column.name.as_str())
        .collect();
    if !primary.is_empty() && primary.is_subset(&key) {
        return true;
    }
    read.indexes.iter().any(|index| {
        if !index.unique || index.predicate.is_some() {
            return false;
        }
        let mut columns = BTreeSet::new();
        for part in &index.keys {
            match part {
                IndexKey::Column { name, .. } => {
                    columns.insert(name.as_str());
                }
                IndexKey::Expression { .. } => return false,
            }
        }
        !columns.is_empty() && columns.is_subset(&key)
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use tablepro_core::column::ColumnType;

    use super::*;

    pub(crate) fn column(name: &str, primary_key: bool, nullable: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::untyped_text("integer"),
            nullable,
            primary_key,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: tablepro_core::column::ColumnDefault::None,
            comment: None,
        }
    }

    pub(crate) fn key(
        name: &str,
        columns: &[&str],
        schema: Option<&str>,
        table: &str,
        refs: &[&str],
    ) -> ForeignKeyInfo {
        ForeignKeyInfo {
            name: name.to_owned(),
            columns: columns.iter().map(|&column| column.to_owned()).collect(),
            ref_schema: schema.map(str::to_owned),
            ref_table: table.to_owned(),
            ref_columns: refs.iter().map(|&column| column.to_owned()).collect(),
            on_delete: None,
            on_update: None,
        }
    }

    pub(crate) fn read(name: &str, columns: Vec<ColumnInfo>, foreign_keys: Vec<ForeignKeyInfo>) -> TableRead {
        TableRead {
            table: TableRef::new(Some("public".to_owned()), name),
            columns,
            foreign_keys,
            indexes: Vec::new(),
        }
    }

    fn shop() -> Vec<TableRead> {
        vec![
            read(
                "orders",
                vec![column("id", true, false), column("customer_id", false, true)],
                vec![key(
                    "orders_customer",
                    &["customer_id"],
                    Some("public"),
                    "customers",
                    &["id"],
                )],
            ),
            read("customers", vec![column("id", true, false)], Vec::new()),
            read(
                "audit",
                vec![column("id", true, false), column("order_id", false, false)],
                vec![
                    key("audit_order", &["order_id"], None, "orders", &["id"]),
                    key("audit_user", &["order_id"], Some("auth"), "users", &["id"]),
                ],
            ),
        ]
    }

    #[test]
    fn tables_sort_by_name_and_keys_resolve_to_them() {
        let diagram = SchemaDiagram::build(shop());

        let names: Vec<&str> = diagram.tables.iter().map(|table| table.table.name.as_str()).collect();
        assert_eq!(names, ["audit", "customers", "orders"]);
        assert_eq!(diagram.relations.len(), 2, "{:?}", diagram.relations);
        let orders = &diagram.relations[1];
        assert_eq!((orders.from, orders.to), (2, 1));
        assert_eq!(orders.from_columns, [1]);
        assert_eq!(orders.to_columns, [0]);
        assert!(orders.optional);
        assert!(!orders.unique);
    }

    #[test]
    fn a_key_to_another_schema_is_not_drawn_but_its_column_is_marked() {
        let diagram = SchemaDiagram::build(shop());

        assert!(
            diagram.relations.iter().all(|relation| relation.name != "audit_user"),
            "a key to auth.users was drawn"
        );
        let audit = &diagram.tables[0];
        assert!(audit.columns[1].foreign_key);
        assert!(!audit.columns[0].foreign_key);
        assert!(audit.columns[0].primary_key);
    }

    #[test]
    fn a_key_without_a_schema_points_into_the_tables_own_schema() {
        let diagram = SchemaDiagram::build(shop());

        let audit = diagram
            .relations
            .iter()
            .find(|relation| relation.name == "audit_order")
            .expect("the key to orders");
        assert_eq!(diagram.tables[audit.to].table.name, "orders");
        assert!(!audit.optional, "order_id is NOT NULL");
    }

    #[test]
    fn a_table_dropped_since_the_list_was_read_is_left_out() {
        let mut reads = shop();
        reads.push(read("gone", Vec::new(), Vec::new()));

        let diagram = SchemaDiagram::build(reads);

        assert!(diagram.tables.iter().all(|table| table.table.name != "gone"));
    }

    #[test]
    fn a_key_on_the_primary_key_or_a_unique_index_is_one_to_one() {
        let profile = read(
            "profiles",
            vec![column("user_id", true, false)],
            vec![key("profile_user", &["user_id"], None, "users", &["id"])],
        );
        let mut badge = read(
            "badges",
            vec![column("id", true, false), column("user_id", false, false)],
            vec![key("badge_user", &["user_id"], None, "users", &["id"])],
        );
        badge.indexes.push(IndexInfo {
            name: "badges_user".to_owned(),
            keys: vec![IndexKey::Column {
                name: "user_id".to_owned(),
                descending: false,
            }],
            unique: true,
            primary: false,
            predicate: None,
        });
        let mut partial = badge.clone();
        partial.table = TableRef::new(Some("public".to_owned()), "partial");
        partial.indexes[0].predicate = Some("user_id > 0".to_owned());
        let users = read("users", vec![column("id", true, false)], Vec::new());

        let diagram = SchemaDiagram::build(vec![profile, badge, partial, users]);

        let unique = |name: &str| {
            diagram
                .relations
                .iter()
                .find(|relation| diagram.tables[relation.from].table.name == name)
                .map(|relation| relation.unique)
        };
        assert_eq!(unique("profiles"), Some(true));
        assert_eq!(unique("badges"), Some(true));
        assert_eq!(unique("partial"), Some(false), "a partial index leaves rows out");
    }

    #[test]
    fn a_composite_key_holding_a_unique_column_is_one_to_one() {
        let mut seats = read(
            "seats",
            vec![
                column("id", true, false),
                column("tenant_id", false, false),
                column("user_id", false, false),
            ],
            vec![key(
                "seat_user",
                &["tenant_id", "user_id"],
                None,
                "members",
                &["tenant_id", "id"],
            )],
        );
        seats.indexes.push(IndexInfo {
            name: "seats_user".to_owned(),
            keys: vec![IndexKey::Column {
                name: "user_id".to_owned(),
                descending: false,
            }],
            unique: true,
            primary: false,
            predicate: None,
        });
        let mut shared = seats.clone();
        shared.table = TableRef::new(Some("public".to_owned()), "shared");
        shared.indexes.clear();
        let members = read(
            "members",
            vec![column("tenant_id", true, false), column("id", true, false)],
            Vec::new(),
        );

        let diagram = SchemaDiagram::build(vec![seats, shared, members]);

        let unique: Vec<(&str, bool)> = diagram
            .relations
            .iter()
            .map(|relation| (diagram.tables[relation.from].table.name.as_str(), relation.unique))
            .collect();
        assert_eq!(unique, [("seats", true), ("shared", false)]);
    }

    #[test]
    fn a_self_reference_is_a_relation_but_not_a_neighbour() {
        let employees = read(
            "employees",
            vec![column("id", true, false), column("manager_id", false, true)],
            vec![key("employee_manager", &["manager_id"], None, "employees", &["id"])],
        );

        let diagram = SchemaDiagram::build(vec![employees]);

        assert_eq!(diagram.relations.len(), 1);
        assert_eq!(diagram.neighbours(0), (Vec::new(), Vec::new()));
    }

    #[test]
    fn neighbours_name_each_table_once() {
        let diagram = SchemaDiagram::build(shop());

        assert_eq!(diagram.neighbours(2), (vec!["customers"], vec!["audit"]));
        assert_eq!(diagram.neighbours(1), (Vec::new(), vec!["orders"]));
    }
}
