//! A PostgreSQL database or schema as a SQL dump, in pg_dump's plain
//! order: structure, rows, then sequence positions, keys and indexes,
//! then views, then triggers. Ownership, grants, policies, rules,
//! publications and event triggers are left out, as with
//! `pg_dump --no-owner --no-acl`.

mod catalog_rows;
pub(crate) mod catalog_sql;
mod statements;

use std::collections::{HashMap, HashSet};

use tablepro_core::DriverError;
use tablepro_core::dump::{
    DumpCatalog, DumpDialect, DumpObject, DumpObjectKind, DumpScope, DumpSection, DumpSkip, DumpSkipReason,
    DumpStatement, DumpTable,
};
use tablepro_core::meta::TableRef;
use tokio_postgres::{Client, Row};

use crate::errors::map_error;
use crate::metadata::text_rows;
use catalog_rows::{
    Column, Constraint, DomainCheck, Extension, Index, Routine, Sequence, Table, Trigger, TypeShape, UserType, View,
};
use catalog_sql::{
    COLUMNS_SQL, CONSTRAINTS_SQL, DOMAIN_CHECKS_SQL, EXTENSIONS_SQL, FUNCTIONS_SQL, FUNCTIONS_SQL_BEFORE_14,
    INDEXES_SQL, SCHEMAS_SQL, SEQUENCES_SQL, TABLES_SQL, TRIGGERS_SQL, TYPES_SQL, VIEWS_SQL,
};
use statements::qualified;

/// pg_dump's session settings, less `SET transaction_timeout`, which a
/// server before 17 refuses. An empty `search_path` makes every name in
/// the file resolve as written.
const HEADER: &str = "
SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;
";

/// Plain SQL, no COPY and no psql command, so the file loads through a
/// driver as well as through psql of any release. Apart from `PgDialect`,
/// whose `SqlDialect` has an `identity_insert` of its own.
#[derive(Debug)]
pub(crate) struct PgDump;

impl DumpDialect for PgDump {
    fn header(&self) -> String {
        HEADER.to_owned()
    }

    fn transactional_ddl(&self) -> bool {
        true
    }
}

/// The catalog prints every name but pg_catalog's with its schema only
/// while the search path is empty.
const EMPTY_SEARCH_PATH: &str = "SELECT pg_catalog.set_config('search_path', '', true)";

/// Run inside the read's own transaction, which ends with it.
pub(crate) async fn read_dump_catalog(
    client: &Client,
    scope: &DumpScope,
    sql_bodies: bool,
) -> Result<DumpCatalog, DriverError> {
    client
        .batch_execute(EMPTY_SEARCH_PATH)
        .await
        .map_err(|error| map_error(&error))?;
    let params = match scope {
        DumpScope::Database => ["all", ""],
        DumpScope::Schema(schema) => ["schema", schema.as_str()],
    };
    let functions_sql = match sql_bodies {
        true => FUNCTIONS_SQL,
        false => FUNCTIONS_SQL_BEFORE_14,
    };
    let (
        schemas,
        extensions,
        types,
        domain_checks,
        routines,
        sequences,
        tables,
        columns,
        constraints,
        indexes,
        views,
        triggers,
    ) = futures_util::try_join!(
        text_rows(client, SCHEMAS_SQL, &params),
        text_rows(client, EXTENSIONS_SQL, &params),
        text_rows(client, TYPES_SQL, &params),
        text_rows(client, DOMAIN_CHECKS_SQL, &params),
        text_rows(client, functions_sql, &params),
        text_rows(client, SEQUENCES_SQL, &params),
        text_rows(client, TABLES_SQL, &params),
        text_rows(client, COLUMNS_SQL, &params),
        text_rows(client, CONSTRAINTS_SQL, &params),
        text_rows(client, INDEXES_SQL, &params),
        text_rows(client, VIEWS_SQL, &params),
        text_rows(client, TRIGGERS_SQL, &params),
    )?;
    let facts = CatalogFacts {
        schemas: decoded(&schemas, catalog_rows::schema_name)?,
        extensions: decoded(&extensions, catalog_rows::extension)?,
        types: decoded(&types, catalog_rows::user_type)?,
        domain_checks: decoded(&domain_checks, catalog_rows::domain_check)?,
        routines: decoded(&routines, catalog_rows::routine)?,
        sequences: decoded(&sequences, catalog_rows::sequence)?,
        tables: decoded(&tables, catalog_rows::table)?,
        columns: decoded(&columns, catalog_rows::column)?,
        constraints: decoded(&constraints, catalog_rows::constraint)?,
        indexes: decoded(&indexes, catalog_rows::index)?,
        views: decoded(&views, catalog_rows::view)?,
        triggers: decoded(&triggers, catalog_rows::trigger)?,
    };
    Ok(assemble(&facts))
}

fn decoded<T>(rows: &[Row], decode: fn(&Row) -> Result<T, DriverError>) -> Result<Vec<T>, DriverError> {
    rows.iter().map(decode).collect()
}

/// What the catalog reads returned, each list in schema and name order.
#[derive(Debug, Default)]
struct CatalogFacts {
    schemas: Vec<String>,
    extensions: Vec<Extension>,
    types: Vec<UserType>,
    domain_checks: Vec<DomainCheck>,
    routines: Vec<Routine>,
    sequences: Vec<Sequence>,
    tables: Vec<Table>,
    columns: Vec<Column>,
    constraints: Vec<Constraint>,
    indexes: Vec<Index>,
    views: Vec<View>,
    triggers: Vec<Trigger>,
}

type Key<'a> = (&'a str, &'a str);

/// Each item under the schema and name of the relation it belongs to,
/// in the order it came.
fn by_relation<'a, T>(items: &'a [T], key: impl Fn(&'a T) -> Key<'a>) -> HashMap<Key<'a>, Vec<&'a T>> {
    let mut grouped: HashMap<Key<'a>, Vec<&'a T>> = HashMap::new();
    for item in items {
        grouped.entry(key(item)).or_default().push(item);
    }
    grouped
}

fn listed<'m, 'a, T>(grouped: &'m HashMap<Key<'a>, Vec<&'a T>>, key: Key<'a>) -> &'m [&'a T] {
    grouped.get(&key).map(Vec::as_slice).unwrap_or_default()
}

fn plain(sql: impl IntoIterator<Item = String>) -> Vec<DumpStatement> {
    sql.into_iter().map(DumpStatement::new).collect()
}

fn skip(kind: DumpObjectKind, schema: &str, name: &str) -> DumpSkip {
    DumpSkip {
        kind,
        schema: Some(schema.to_owned()),
        name: name.to_owned(),
        reason: DumpSkipReason::NotSupported,
    }
}

/// A table the dump writes: a regular or partitioned table or a
/// partition. A foreign table's rows live elsewhere, a child by INHERITS
/// has no statement that makes it again here, and its parent's rows
/// would carry the child's.
fn written(table: &Table) -> bool {
    matches!(table.kind.as_str(), "r" | "p") && !table.inherits
}

/// The catalog grouped by the relation or type each part belongs to.
struct Lookup<'a> {
    columns: HashMap<Key<'a>, Vec<&'a Column>>,
    constraints: HashMap<Key<'a>, Vec<&'a Constraint>>,
    indexes: HashMap<Key<'a>, Vec<&'a Index>>,
    checks: HashMap<Key<'a>, Vec<&'a DomainCheck>>,
    written: HashSet<Key<'a>>,
    /// A written table's identity sequences, by table and column.
    identities: HashMap<(&'a str, &'a str, &'a str), &'a Sequence>,
    /// The sequences a written table's columns own.
    serials: HashMap<Key<'a>, Vec<&'a Sequence>>,
}

impl<'a> Lookup<'a> {
    fn new(facts: &'a CatalogFacts) -> Self {
        let written: HashSet<Key<'a>> = facts
            .tables
            .iter()
            .filter(|table| written(table))
            .map(|table| (table.schema.as_str(), table.name.as_str()))
            .collect();
        let mut identities = HashMap::new();
        let mut serials: HashMap<Key<'a>, Vec<&'a Sequence>> = HashMap::new();
        for sequence in &facts.sequences {
            let Some(owner) = &sequence.owner else {
                continue;
            };
            let table = (owner.schema.as_str(), owner.table.as_str());
            match (written.contains(&table), owner.identity) {
                (false, _) => {}
                (true, true) => {
                    identities.insert((table.0, table.1, owner.column.as_str()), sequence);
                }
                (true, false) => serials.entry(table).or_default().push(sequence),
            }
        }
        Self {
            columns: by_relation(&facts.columns, |column| (column.schema.as_str(), column.table.as_str())),
            constraints: by_relation(&facts.constraints, |constraint| {
                (constraint.schema.as_str(), constraint.table.as_str())
            }),
            indexes: by_relation(&facts.indexes, |index| (index.schema.as_str(), index.table.as_str())),
            checks: by_relation(&facts.domain_checks, |check| {
                (check.schema.as_str(), check.domain.as_str())
            }),
            written,
            identities,
            serials,
        }
    }

    /// An identity sequence goes with its table, so one whose table the
    /// dump leaves out has no position to set.
    fn makes(&self, sequence: &Sequence) -> bool {
        match &sequence.owner {
            Some(owner) if owner.identity => self.written.contains(&(owner.schema.as_str(), owner.table.as_str())),
            _ => true,
        }
    }
}

/// What follows the rows, in the order it runs.
#[derive(Default)]
struct AfterData {
    values: Vec<DumpObject>,
    keys: Vec<DumpObject>,
    indexes: Vec<DumpObject>,
    comments: Vec<DumpObject>,
    foreign_keys: Vec<DumpObject>,
}

impl AfterData {
    fn into_objects(self) -> impl Iterator<Item = DumpObject> {
        self.values
            .into_iter()
            .chain(self.keys)
            .chain(self.indexes)
            .chain(self.comments)
            .chain(self.foreign_keys)
    }
}

fn assemble(facts: &CatalogFacts) -> DumpCatalog {
    let lookup = Lookup::new(facts);
    let mut catalog = DumpCatalog::default();
    let mut before = namespaces(facts);
    before.extend(types(facts, &lookup, &mut catalog.skipped));
    let (routines_before, mut programs) = routines(facts, &mut catalog.skipped);
    before.extend(routines_before);
    before.extend(sequences(facts));
    let mut after = AfterData {
        values: sequence_values(facts, &lookup),
        ..AfterData::default()
    };
    for table in &facts.tables {
        if !written(table) {
            catalog
                .skipped
                .push(skip(DumpObjectKind::Table, &table.schema, &table.name));
            continue;
        }
        before.push(create_table(table, &lookup));
        table_after_data(table, &lookup, &mut after);
        catalog.tables.push(dump_table(table));
    }
    programs.extend(views(facts, &lookup));
    let triggers = triggers(facts, &lookup);
    catalog.objects = before
        .into_iter()
        .chain(after.into_objects())
        .chain(programs)
        .chain(triggers)
        .collect();
    catalog
}

fn namespaces(facts: &CatalogFacts) -> Vec<DumpObject> {
    let schemas = facts.schemas.iter().map(|schema| {
        DumpObject::new(
            DumpObjectKind::Schema,
            DumpSection::BeforeData,
            None,
            schema.clone(),
            plain([statements::create_schema(schema)]),
        )
    });
    let extensions = facts.extensions.iter().map(|extension| {
        DumpObject::new(
            DumpObjectKind::Extension,
            DumpSection::BeforeData,
            None,
            extension.name.clone(),
            plain([statements::create_extension(extension)]),
        )
    });
    schemas.chain(extensions).collect()
}

fn types(facts: &CatalogFacts, lookup: &Lookup<'_>, skipped: &mut Vec<DumpSkip>) -> Vec<DumpObject> {
    let mut objects = Vec::new();
    for user_type in &facts.types {
        let key = (user_type.schema.as_str(), user_type.name.as_str());
        let sql = match &user_type.shape {
            TypeShape::Enum(labels) => vec![statements::create_enum(key.0, key.1, labels)],
            TypeShape::Domain(domain) => statements::create_domain(key.0, key.1, domain, listed(&lookup.checks, key)),
            TypeShape::Composite => vec![statements::create_composite(key.0, key.1, listed(&lookup.columns, key))],
            TypeShape::Other => {
                skipped.push(skip(DumpObjectKind::Type, key.0, key.1));
                continue;
            }
        };
        objects.push(DumpObject::new(
            DumpObjectKind::Type,
            DumpSection::BeforeData,
            Some(user_type.schema.clone()),
            user_type.name.clone(),
            plain(sql),
        ));
    }
    objects
}

/// The routines made before the tables, and those made with the views.
/// A body in standard SQL names tables and views the server must find
/// when it is made; a quoted body is read only when it runs.
fn routines(facts: &CatalogFacts, skipped: &mut Vec<DumpSkip>) -> (Vec<DumpObject>, Vec<DumpObject>) {
    let mut before = Vec::new();
    let mut programs = Vec::new();
    for routine in &facts.routines {
        let kind = match routine.kind.as_str() {
            "p" => DumpObjectKind::Procedure,
            _ => DumpObjectKind::Function,
        };
        let Some(definition) = routine.definition.as_ref().filter(|_| routine.kind != "a") else {
            skipped.push(skip(kind, &routine.schema, &routine.name));
            continue;
        };
        let (section, list) = match routine.sql_body {
            true => (DumpSection::Programs, &mut programs),
            false => (DumpSection::BeforeData, &mut before),
        };
        list.push(DumpObject::new(
            kind,
            section,
            Some(routine.schema.clone()),
            routine.name.clone(),
            vec![DumpStatement::body(definition.clone())],
        ));
    }
    (before, programs)
}

/// Every sequence but an identity's, which its column makes.
fn sequences(facts: &CatalogFacts) -> Vec<DumpObject> {
    facts
        .sequences
        .iter()
        .filter(|sequence| !sequence.owner.as_ref().is_some_and(|owner| owner.identity))
        .map(|sequence| {
            DumpObject::new(
                DumpObjectKind::Sequence,
                DumpSection::BeforeData,
                Some(sequence.schema.clone()),
                sequence.name.clone(),
                plain([statements::create_sequence(sequence)]),
            )
        })
        .collect()
}

fn sequence_values(facts: &CatalogFacts, lookup: &Lookup<'_>) -> Vec<DumpObject> {
    facts
        .sequences
        .iter()
        .filter(|sequence| lookup.makes(sequence))
        .filter_map(|sequence| {
            statements::set_value(sequence).map(|sql| {
                DumpObject::new(
                    DumpObjectKind::SequenceValue,
                    DumpSection::AfterData,
                    Some(sequence.schema.clone()),
                    sequence.name.clone(),
                    plain([sql]),
                )
            })
        })
        .collect()
}

/// The table with its columns and checks, then the sequences its columns
/// own, which need the table to exist.
fn create_table(table: &Table, lookup: &Lookup<'_>) -> DumpObject {
    let key = (table.schema.as_str(), table.name.as_str());
    let columns: Vec<String> = listed(&lookup.columns, key)
        .iter()
        .map(|column| {
            let identity = lookup.identities.get(&(key.0, key.1, column.name.as_str())).copied();
            statements::column_sql(column, identity)
        })
        .collect();
    let checks: Vec<&Constraint> = listed(&lookup.constraints, key)
        .iter()
        .filter(|constraint| constraint.kind == "c" && constraint.validated)
        .copied()
        .collect();
    let mut sql = vec![statements::create_table(table, &columns, &checks)];
    for sequence in listed(&lookup.serials, key) {
        if let Some(owner) = &sequence.owner {
            sql.push(statements::owned_by(sequence, owner));
        }
    }
    DumpObject::table(
        TableRef::new(Some(table.schema.clone()), table.name.clone()),
        plain(sql),
    )
}

/// A partitioned table's rows are its partitions', which come after it.
fn dump_table(table: &Table) -> DumpTable {
    DumpTable {
        references: table
            .partition
            .iter()
            .map(|partition| TableRef::new(Some(partition.parent_schema.clone()), partition.parent.clone()))
            .collect(),
        rows: table.kind != "p",
        ..DumpTable::new(TableRef::new(Some(table.schema.clone()), table.name.clone()))
    }
}

/// Keys, a check not yet held, indexes, comments and foreign keys.
fn table_after_data(table: &Table, lookup: &Lookup<'_>, after: &mut AfterData) {
    let key = (table.schema.as_str(), table.name.as_str());
    let object = |kind, name: &str, sql: Vec<String>| {
        DumpObject::new(
            kind,
            DumpSection::AfterData,
            Some(table.schema.clone()),
            name.to_owned(),
            plain(sql),
        )
    };
    for constraint in listed(&lookup.constraints, key) {
        let (kind, list) = match constraint.kind.as_str() {
            "f" => (DumpObjectKind::ForeignKey, &mut after.foreign_keys),
            "c" if constraint.validated => continue,
            _ => (DumpObjectKind::Constraint, &mut after.keys),
        };
        list.push(object(
            kind,
            &constraint.name,
            vec![statements::add_constraint(constraint)],
        ));
    }
    for index in listed(&lookup.indexes, key) {
        after.indexes.push(object(
            DumpObjectKind::Index,
            &index.name,
            vec![index.statement.clone()],
        ));
    }
    let mut comments = Vec::new();
    if let Some(comment) = &table.comment {
        comments.push(statements::comment_on("TABLE", &qualified(key.0, key.1), comment));
    }
    comments.extend(column_comments(listed(&lookup.columns, key)));
    if !comments.is_empty() {
        after
            .comments
            .push(object(DumpObjectKind::Comment, &table.name, comments));
    }
}

/// A view with its comments; a materialized view with its indexes too.
fn views(facts: &CatalogFacts, lookup: &Lookup<'_>) -> Vec<DumpObject> {
    let mut objects = Vec::new();
    for view in &facts.views {
        let key = (view.schema.as_str(), view.name.as_str());
        let mut sql = vec![statements::create_view(view)];
        let (kind, target) = match view.materialized {
            true => (DumpObjectKind::MaterializedView, "MATERIALIZED VIEW"),
            false => (DumpObjectKind::View, "VIEW"),
        };
        if view.materialized {
            sql.extend(listed(&lookup.indexes, key).iter().map(|index| index.statement.clone()));
        }
        if let Some(comment) = &view.comment {
            sql.push(statements::comment_on(target, &qualified(key.0, key.1), comment));
        }
        sql.extend(column_comments(listed(&lookup.columns, key)));
        objects.push(DumpObject::new(
            kind,
            DumpSection::Programs,
            Some(view.schema.clone()),
            view.name.clone(),
            plain(sql),
        ));
    }
    objects
}

/// The triggers of the tables and views the dump writes.
fn triggers(facts: &CatalogFacts, lookup: &Lookup<'_>) -> Vec<DumpObject> {
    let views: HashSet<Key<'_>> = facts
        .views
        .iter()
        .filter(|view| !view.materialized)
        .map(|view| (view.schema.as_str(), view.name.as_str()))
        .collect();
    facts
        .triggers
        .iter()
        .filter(|trigger| {
            let target = (trigger.schema.as_str(), trigger.table.as_str());
            lookup.written.contains(&target) || views.contains(&target)
        })
        .map(|trigger| {
            let mut sql = vec![trigger.definition.clone()];
            sql.extend(statements::trigger_state(trigger));
            DumpObject::new(
                DumpObjectKind::Trigger,
                DumpSection::Triggers,
                Some(trigger.schema.clone()),
                trigger.name.clone(),
                plain(sql),
            )
        })
        .collect()
}

fn column_comments(columns: &[&Column]) -> Vec<String> {
    columns
        .iter()
        .filter_map(|column| {
            column
                .comment
                .as_ref()
                .map(|comment| statements::comment_on_column(&column.schema, &column.table, &column.name, comment))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use tablepro_core::dialect::SqlDialect;

    use super::catalog_rows::{Domain, Partition, SequenceOwner};
    use super::*;
    use crate::dialect::PgDialect;

    fn table(name: &str, kind: &str) -> Table {
        Table {
            schema: "app".to_owned(),
            name: name.to_owned(),
            kind: kind.to_owned(),
            unlogged: false,
            partition_key: (kind == "p").then(|| "RANGE (k)".to_owned()),
            partition: None,
            inherits: false,
            options: Vec::new(),
            access_method: None,
            tablespace: None,
            comment: None,
        }
    }

    fn column(table: &str, name: &str) -> Column {
        Column {
            schema: "app".to_owned(),
            table: table.to_owned(),
            name: name.to_owned(),
            type_sql: "integer".to_owned(),
            collation: None,
            default: None,
            identity: String::new(),
            generated: String::new(),
            not_null: true,
            comment: None,
        }
    }

    fn sequence(name: &str, owner: Option<(&str, &str, bool)>) -> Sequence {
        Sequence {
            schema: "app".to_owned(),
            name: name.to_owned(),
            data_type: "integer".to_owned(),
            start: 1,
            increment: 1,
            min: 1,
            max: 2_147_483_647,
            cache: 1,
            cycle: false,
            unlogged: false,
            last_value: Some(4),
            owner: owner.map(|(table, column, identity)| SequenceOwner {
                identity,
                schema: "app".to_owned(),
                table: table.to_owned(),
                column: column.to_owned(),
            }),
        }
    }

    fn constraint(table: &str, name: &str, kind: &str, definition: &str) -> Constraint {
        Constraint {
            schema: "app".to_owned(),
            table: table.to_owned(),
            partitioned: false,
            name: name.to_owned(),
            kind: kind.to_owned(),
            definition: definition.to_owned(),
            validated: true,
        }
    }

    fn sections(catalog: &DumpCatalog) -> Vec<(DumpSection, DumpObjectKind, String)> {
        catalog
            .objects
            .iter()
            .map(|object| (object.section, object.kind, object.name.clone()))
            .collect()
    }

    fn sql_of<'a>(catalog: &'a DumpCatalog, name: &str) -> Vec<&'a str> {
        catalog
            .objects
            .iter()
            .filter(|object| object.name == name)
            .flat_map(|object| object.statements.iter().map(|statement| statement.sql.as_str()))
            .collect()
    }

    #[test]
    fn the_header_is_pg_dumps_without_transaction_timeout() {
        let dialect = PgDialect::new(&tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0));
        let header = dialect.dump().map(|dump| dump.header()).unwrap_or_default();

        assert_eq!(header.lines().filter(|line| !line.is_empty()).count(), 10);
        assert!(header.contains("SELECT pg_catalog.set_config('search_path', '', false);\n"));
        assert!(!header.contains("transaction_timeout"));
        assert!(!header.contains('\\'));
    }

    #[test]
    fn serial_and_identity_sequences_are_made_where_their_columns_need_them() {
        let mut id = column("child", "id");
        id.identity = "a".to_owned();
        let mut parent_id = column("parent", "id");
        parent_id.default = Some("nextval('app.parent_id_seq'::regclass)".to_owned());
        let facts = CatalogFacts {
            sequences: vec![
                sequence("child_id_seq", Some(("child", "id", true))),
                sequence("parent_id_seq", Some(("parent", "id", false))),
            ],
            tables: vec![table("child", "r"), table("parent", "r")],
            columns: vec![id, parent_id],
            ..CatalogFacts::default()
        };

        let catalog = assemble(&facts);

        assert_eq!(
            sections(&catalog),
            [
                (
                    DumpSection::BeforeData,
                    DumpObjectKind::Sequence,
                    "parent_id_seq".to_owned()
                ),
                (DumpSection::BeforeData, DumpObjectKind::Table, "child".to_owned()),
                (DumpSection::BeforeData, DumpObjectKind::Table, "parent".to_owned()),
                (
                    DumpSection::AfterData,
                    DumpObjectKind::SequenceValue,
                    "child_id_seq".to_owned()
                ),
                (
                    DumpSection::AfterData,
                    DumpObjectKind::SequenceValue,
                    "parent_id_seq".to_owned()
                ),
            ]
        );
        assert!(sql_of(&catalog, "child")[0].contains("SEQUENCE NAME \"app\".\"child_id_seq\""));
        assert_eq!(
            sql_of(&catalog, "parent")[1],
            "ALTER SEQUENCE \"app\".\"parent_id_seq\" OWNED BY \"app\".\"parent\".\"id\""
        );
    }

    #[test]
    fn keys_and_checks_not_yet_held_follow_the_rows_and_foreign_keys_come_last() {
        let mut pending = constraint("t", "small", "c", "CHECK ((id < 10)) NOT VALID");
        pending.validated = false;
        let facts = CatalogFacts {
            tables: vec![table("t", "r")],
            columns: vec![column("t", "id")],
            constraints: vec![
                constraint("t", "positive", "c", "CHECK ((id > 0))"),
                pending,
                constraint("t", "t_next_fkey", "f", "FOREIGN KEY (id) REFERENCES app.t(id)"),
                constraint("t", "t_pkey", "p", "PRIMARY KEY (id)"),
            ],
            indexes: vec![Index {
                schema: "app".to_owned(),
                table: "t".to_owned(),
                name: "t_id_idx".to_owned(),
                statement: "CREATE INDEX t_id_idx ON app.t USING btree (id)".to_owned(),
            }],
            ..CatalogFacts::default()
        };

        let catalog = assemble(&facts);

        assert_eq!(
            sections(&catalog)
                .into_iter()
                .filter(|(section, ..)| *section == DumpSection::AfterData)
                .map(|(_, _, name)| name)
                .collect::<Vec<_>>(),
            ["small", "t_pkey", "t_id_idx", "t_next_fkey"]
        );
        assert_eq!(
            sql_of(&catalog, "t"),
            [
                "CREATE TABLE \"app\".\"t\" (\n    \"id\" integer NOT NULL,\n    CONSTRAINT \"positive\" CHECK ((id > 0))\n)"
            ]
        );
    }

    #[test]
    fn a_partition_follows_its_parent_whose_rows_are_its_partitions() {
        let mut partition = table("p_2025", "r");
        partition.partition = Some(Partition {
            parent_schema: "app".to_owned(),
            parent: "p".to_owned(),
            bound: "FOR VALUES FROM (1) TO (10)".to_owned(),
        });
        let facts = CatalogFacts {
            tables: vec![table("p", "p"), partition],
            columns: vec![column("p", "k"), column("p_2025", "k")],
            ..CatalogFacts::default()
        };

        let catalog = assemble(&facts);

        let parent = TableRef::new(Some("app".to_owned()), "p");
        assert_eq!(catalog.tables.len(), 2);
        assert!(!catalog.tables[0].rows);
        assert!(catalog.tables[1].rows);
        assert_eq!(catalog.tables[1].references, [parent]);
        assert_eq!(
            sql_of(&catalog, "p_2025"),
            ["CREATE TABLE \"app\".\"p_2025\" PARTITION OF \"app\".\"p\" FOR VALUES FROM (1) TO (10)"]
        );
    }

    #[test]
    fn what_the_dump_cannot_make_again_is_listed_as_left_out() {
        let mut child = table("child", "r");
        child.inherits = true;
        let mut sum = Routine {
            schema: "app".to_owned(),
            name: "total".to_owned(),
            kind: "a".to_owned(),
            definition: None,
            sql_body: false,
        };
        let facts = CatalogFacts {
            types: vec![UserType {
                schema: "app".to_owned(),
                name: "span".to_owned(),
                shape: TypeShape::Other,
            }],
            routines: vec![sum.clone()],
            tables: vec![table("remote", "f"), child],
            triggers: vec![Trigger {
                schema: "app".to_owned(),
                table: "child".to_owned(),
                name: "touch".to_owned(),
                definition: "CREATE TRIGGER touch".to_owned(),
                enabled: "O".to_owned(),
            }],
            ..CatalogFacts::default()
        };

        let catalog = assemble(&facts);

        let skipped: Vec<(DumpObjectKind, &str)> = catalog
            .skipped
            .iter()
            .map(|skip| (skip.kind, skip.name.as_str()))
            .collect();
        assert_eq!(
            skipped,
            [
                (DumpObjectKind::Type, "span"),
                (DumpObjectKind::Function, "total"),
                (DumpObjectKind::Table, "remote"),
                (DumpObjectKind::Table, "child"),
            ]
        );
        assert!(catalog.objects.is_empty());
        assert!(catalog.tables.is_empty());

        sum.kind = "f".to_owned();
        sum.definition = Some("CREATE OR REPLACE FUNCTION app.total()\n RETURNS integer\n".to_owned());
        sum.sql_body = true;
        let catalog = assemble(&CatalogFacts {
            routines: vec![sum],
            ..CatalogFacts::default()
        });
        assert_eq!(catalog.objects[0].section, DumpSection::Programs);
        assert!(catalog.objects[0].statements[0].body);
    }

    #[test]
    fn a_view_carries_its_comments_and_a_materialized_view_its_indexes() {
        let mut labelled = column("v", "id");
        labelled.comment = Some("the key".to_owned());
        let view = |name: &str, materialized: bool| View {
            schema: "app".to_owned(),
            name: name.to_owned(),
            materialized,
            definition: " SELECT 1 AS id;".to_owned(),
            options: Vec::new(),
            populated: true,
            access_method: None,
            tablespace: None,
            comment: Some("shown".to_owned()),
        };
        let facts = CatalogFacts {
            columns: vec![labelled],
            indexes: vec![Index {
                schema: "app".to_owned(),
                table: "m".to_owned(),
                name: "m_id".to_owned(),
                statement: "CREATE UNIQUE INDEX m_id ON app.m USING btree (id)".to_owned(),
            }],
            views: vec![view("m", true), view("v", false)],
            ..CatalogFacts::default()
        };

        let catalog = assemble(&facts);

        assert_eq!(
            sql_of(&catalog, "m")[1..],
            [
                "CREATE UNIQUE INDEX m_id ON app.m USING btree (id)",
                "COMMENT ON MATERIALIZED VIEW \"app\".\"m\" IS 'shown'"
            ]
        );
        assert_eq!(
            sql_of(&catalog, "v")[1..],
            [
                "COMMENT ON VIEW \"app\".\"v\" IS 'shown'",
                "COMMENT ON COLUMN \"app\".\"v\".\"id\" IS 'the key'"
            ]
        );
        assert!(
            catalog
                .objects
                .iter()
                .all(|object| object.section == DumpSection::Programs)
        );
    }

    #[test]
    fn a_domain_and_a_composite_type_are_made_from_their_parts() {
        let mut attribute = column("pair", "a");
        attribute.not_null = false;
        let facts = CatalogFacts {
            types: vec![
                UserType {
                    schema: "app".to_owned(),
                    name: "positive".to_owned(),
                    shape: TypeShape::Domain(Domain {
                        base: "integer".to_owned(),
                        not_null: false,
                        default: None,
                        collation: None,
                    }),
                },
                UserType {
                    schema: "app".to_owned(),
                    name: "pair".to_owned(),
                    shape: TypeShape::Composite,
                },
            ],
            domain_checks: vec![DomainCheck {
                schema: "app".to_owned(),
                domain: "positive".to_owned(),
                name: "positive_check".to_owned(),
                definition: "CHECK ((VALUE > 0))".to_owned(),
                validated: true,
            }],
            columns: vec![attribute],
            ..CatalogFacts::default()
        };

        let catalog = assemble(&facts);

        assert_eq!(
            sql_of(&catalog, "positive"),
            ["CREATE DOMAIN \"app\".\"positive\" AS integer\n    CONSTRAINT \"positive_check\" CHECK ((VALUE > 0))"]
        );
        assert_eq!(
            sql_of(&catalog, "pair"),
            ["CREATE TYPE \"app\".\"pair\" AS (\n    \"a\" integer\n)"]
        );
    }

    #[test]
    fn a_trigger_on_a_table_left_out_is_left_out_with_it() {
        let trigger = |table: &str| Trigger {
            schema: "app".to_owned(),
            table: table.to_owned(),
            name: format!("{table}_touch"),
            definition: format!("CREATE TRIGGER {table}_touch BEFORE INSERT ON app.{table}"),
            enabled: "D".to_owned(),
        };
        let facts = CatalogFacts {
            tables: vec![table("kept", "r"), table("remote", "f")],
            triggers: vec![trigger("kept"), trigger("remote")],
            ..CatalogFacts::default()
        };

        let catalog = assemble(&facts);

        assert_eq!(
            sql_of(&catalog, "kept_touch"),
            [
                "CREATE TRIGGER kept_touch BEFORE INSERT ON app.kept",
                "ALTER TABLE \"app\".\"kept\" DISABLE TRIGGER \"kept_touch\""
            ]
        );
        assert!(sql_of(&catalog, "remote_touch").is_empty());
    }

    #[test]
    fn every_catalog_read_names_its_scope() {
        for sql in [
            SCHEMAS_SQL,
            EXTENSIONS_SQL,
            TYPES_SQL,
            DOMAIN_CHECKS_SQL,
            FUNCTIONS_SQL,
            FUNCTIONS_SQL_BEFORE_14,
            SEQUENCES_SQL,
            TABLES_SQL,
            COLUMNS_SQL,
            CONSTRAINTS_SQL,
            INDEXES_SQL,
            VIEWS_SQL,
            TRIGGERS_SQL,
        ] {
            assert!(sql.contains("$1 = 'all' OR n.nspname = $2"), "{sql}");
        }
    }
}
