//! The statements a dump writes for what the catalog holds. The file
//! empties `search_path`, so every name is quoted and schema-qualified.

use postgres_protocol::escape::escape_identifier;

use super::catalog_rows::{
    Collation, Column, Constraint, Domain, DomainCheck, Extension, Sequence, SequenceOwner, Table, Trigger,
    UserCollation, View,
};
use crate::dialect::quoted as literal;

pub(super) fn quote(name: &str) -> String {
    escape_identifier(name)
}

pub(super) fn qualified(schema: &str, name: &str) -> String {
    format!("{}.{}", quote(schema), quote(name))
}

fn collate(collation: &Collation) -> String {
    format!(" COLLATE {}", qualified(&collation.schema, &collation.name))
}

/// As pg_dump writes one. `None` for a provider this does not know.
pub(super) fn create_collation(collation: &UserCollation) -> Option<String> {
    let provider = match collation.provider.as_str() {
        "c" => "libc",
        "i" => "icu",
        "b" => "builtin",
        _ => return None,
    };
    let mut options = vec![format!("provider = {provider}")];
    if !collation.deterministic {
        options.push("deterministic = false".to_owned());
    }
    match (provider, collation.collate.as_deref(), collation.ctype.as_deref()) {
        ("libc", Some(collate), Some(ctype)) if collate == ctype => {
            options.push(format!("locale = {}", literal(collate)))
        }
        ("libc", Some(collate), Some(ctype)) => {
            options.push(format!("lc_collate = {}", literal(collate)));
            options.push(format!("lc_ctype = {}", literal(ctype)));
        }
        ("libc", ..) => return None,
        // Before 15 an ICU collation kept its locale in collcollate.
        _ => {
            let locale = collation.locale.as_deref().or(collation.collate.as_deref())?;
            options.push(format!("locale = {}", literal(locale)));
        }
    }
    if let Some(rules) = &collation.rules {
        options.push(format!("rules = {}", literal(rules)));
    }
    Some(format!(
        "CREATE COLLATION {} ({})",
        qualified(&collation.schema, &collation.name),
        options.join(", ")
    ))
}

pub(super) fn create_schema(name: &str) -> String {
    format!("CREATE SCHEMA IF NOT EXISTS {}", quote(name))
}

pub(super) fn create_extension(extension: &Extension) -> String {
    format!(
        "CREATE EXTENSION IF NOT EXISTS {} WITH SCHEMA {}",
        quote(&extension.name),
        quote(&extension.schema)
    )
}

pub(super) fn create_enum(schema: &str, name: &str, labels: &[String]) -> String {
    let labels: Vec<String> = labels.iter().map(|label| format!("    {}", literal(label))).collect();
    format!(
        "CREATE TYPE {} AS ENUM (\n{}\n)",
        qualified(schema, name),
        labels.join(",\n")
    )
}

/// The CREATE first, then each check as an ALTER DOMAIN, which the dump
/// runs once the routines exist: a check can call one, and the server
/// resolves it when the check is added. One the values have not all been
/// held to stays NOT VALID.
pub(super) fn create_domain(schema: &str, name: &str, domain: &Domain, checks: &[&DomainCheck]) -> Vec<String> {
    let mut create = format!("CREATE DOMAIN {} AS {}", qualified(schema, name), domain.base);
    if let Some(collation) = &domain.collation {
        create.push_str(&collate(collation));
    }
    if let Some(default) = &domain.default {
        create.push_str(&format!(" DEFAULT {default}"));
    }
    if domain.not_null {
        create.push_str(" NOT NULL");
    }
    let mut statements = vec![create];
    statements.extend(checks.iter().map(|check| {
        format!(
            "ALTER DOMAIN {} ADD CONSTRAINT {} {}",
            qualified(schema, name),
            quote(&check.name),
            check.definition
        )
    }));
    statements
}

fn column_head(column: &Column) -> String {
    let mut head = format!("{} {}", quote(&column.name), column.type_sql);
    if let Some(collation) = &column.collation {
        head.push_str(&collate(collation));
    }
    head
}

pub(super) fn create_composite(schema: &str, name: &str, attributes: &[&Column]) -> String {
    let attributes: Vec<String> = attributes
        .iter()
        .map(|attribute| format!("    {}", column_head(attribute)))
        .collect();
    format!(
        "CREATE TYPE {} AS (\n{}\n)",
        qualified(schema, name),
        attributes.join(",\n")
    )
}

fn sequence_options(sequence: &Sequence) -> Vec<String> {
    let mut options = vec![
        format!("START WITH {}", sequence.start),
        format!("INCREMENT BY {}", sequence.increment),
        format!("MINVALUE {}", sequence.min),
        format!("MAXVALUE {}", sequence.max),
        format!("CACHE {}", sequence.cache),
    ];
    if sequence.cycle {
        options.push("CYCLE".to_owned());
    }
    options
}

/// Without OWNED BY: the column it names does not exist yet.
pub(super) fn create_sequence(sequence: &Sequence) -> String {
    let kind = match sequence.unlogged {
        true => "UNLOGGED SEQUENCE",
        false => "SEQUENCE",
    };
    let mut lines = vec![format!("AS {}", sequence.data_type)];
    lines.extend(sequence_options(sequence));
    format!(
        "CREATE {kind} {}\n    {}",
        qualified(&sequence.schema, &sequence.name),
        lines.join("\n    ")
    )
}

/// The identity's sequence keeps its name and settings, so its position
/// can be set by name after the rows.
fn identity(column: &Column, sequence: Option<&Sequence>) -> String {
    let when = match column.identity.as_str() {
        "a" => "ALWAYS",
        _ => "BY DEFAULT",
    };
    match sequence {
        Some(sequence) => {
            let mut options = vec![format!("SEQUENCE NAME {}", qualified(&sequence.schema, &sequence.name))];
            options.extend(sequence_options(sequence));
            format!("GENERATED {when} AS IDENTITY ({})", options.join(" "))
        }
        None => format!("GENERATED {when} AS IDENTITY"),
    }
}

pub(super) fn column_sql(column: &Column, identity_sequence: Option<&Sequence>) -> String {
    let mut sql = column_head(column);
    match (column.generated.as_str(), column.identity.as_str(), &column.default) {
        ("s", _, Some(expression)) => sql.push_str(&format!(" GENERATED ALWAYS AS ({expression}) STORED")),
        ("v", _, Some(expression)) => sql.push_str(&format!(" GENERATED ALWAYS AS ({expression}) VIRTUAL")),
        (_, "a" | "d", _) => {
            sql.push(' ');
            sql.push_str(&identity(column, identity_sequence));
        }
        (_, _, Some(default)) => sql.push_str(&format!(" DEFAULT {default}")),
        _ => {}
    }
    if column.not_null {
        sql.push_str(" NOT NULL");
    }
    sql
}

/// `columns` are the column clauses; a partition takes its columns from
/// its parent and states only its own checks.
pub(super) fn create_table(table: &Table, columns: &[String], checks: &[&Constraint]) -> String {
    let unlogged = match table.unlogged {
        true => "UNLOGGED ",
        false => "",
    };
    let name = qualified(&table.schema, &table.name);
    let checks: Vec<String> = checks
        .iter()
        .map(|check| format!("CONSTRAINT {} {}", quote(&check.name), check.definition))
        .collect();
    let mut sql = match &table.partition {
        Some(partition) => {
            let mut sql = format!(
                "CREATE {unlogged}TABLE {name} PARTITION OF {}",
                qualified(&partition.parent_schema, &partition.parent)
            );
            if !checks.is_empty() {
                sql.push_str(&format!(" (\n    {}\n)", checks.join(",\n    ")));
            }
            sql.push(' ');
            sql.push_str(&partition.bound);
            sql
        }
        None => {
            let mut body = columns.to_vec();
            body.extend(checks);
            format!("CREATE {unlogged}TABLE {name} (\n    {}\n)", body.join(",\n    "))
        }
    };
    if let Some(key) = &table.partition_key {
        sql.push_str(&format!(" PARTITION BY {key}"));
    }
    if let Some(method) = &table.access_method {
        sql.push_str(&format!(" USING {}", quote(method)));
    }
    if let Some(options) = storage_options(&table.options) {
        sql.push_str(&format!(" WITH ({options})"));
    }
    if let Some(tablespace) = &table.tablespace {
        sql.push_str(&format!(" TABLESPACE {}", quote(tablespace)));
    }
    sql
}

/// `reloptions` as `name='value'`, as pg_dump writes them.
fn storage_options(options: &[String]) -> Option<String> {
    let written: Vec<String> = options
        .iter()
        .map(|option| match option.split_once('=') {
            Some((name, value)) => format!("{name}={}", literal(value)),
            None => option.clone(),
        })
        .collect();
    (!written.is_empty()).then(|| written.join(", "))
}

pub(super) fn owned_by(sequence: &Sequence, owner: &SequenceOwner) -> String {
    format!(
        "ALTER SEQUENCE {} OWNED BY {}.{}",
        qualified(&sequence.schema, &sequence.name),
        qualified(&owner.schema, &owner.table),
        quote(&owner.column)
    )
}

/// Where the sequence stands, used or not: a RESTART leaves the next
/// value away from START. `None` where the login could not read it.
pub(super) fn set_value(sequence: &Sequence) -> Option<String> {
    sequence.last_value.map(|value| {
        format!(
            "SELECT pg_catalog.setval({}, {value}, {})",
            literal(&qualified(&sequence.schema, &sequence.name)),
            sequence.is_called.unwrap_or(true)
        )
    })
}

/// ONLY keeps the statement off a regular table's inheritance children;
/// a partitioned table refuses it, and its partitions take the
/// constraint from it.
pub(super) fn add_constraint(constraint: &Constraint) -> String {
    let only = match constraint.partitioned {
        true => "",
        false => "ONLY ",
    };
    format!(
        "ALTER TABLE {only}{} ADD CONSTRAINT {} {}",
        qualified(&constraint.schema, &constraint.table),
        quote(&constraint.name),
        constraint.definition
    )
}

pub(super) fn comment_on(target: &str, name: &str, text: &str) -> String {
    format!("COMMENT ON {target} {name} IS {}", literal(text))
}

pub(super) fn comment_on_column(schema: &str, table: &str, column: &str, text: &str) -> String {
    comment_on(
        "COLUMN",
        &format!("{}.{}", qualified(schema, table), quote(column)),
        text,
    )
}

/// A materialized view is filled as it is made, after the rows it reads.
pub(super) fn create_view(view: &View) -> String {
    let name = qualified(&view.schema, &view.name);
    let definition = view.definition.trim_end().trim_end_matches(';').trim_end();
    if view.materialized {
        let mut head = format!("CREATE MATERIALIZED VIEW {name}");
        if let Some(method) = &view.access_method {
            head.push_str(&format!(" USING {}", quote(method)));
        }
        if let Some(options) = storage_options(&view.options) {
            head.push_str(&format!(" WITH ({options})"));
        }
        if let Some(tablespace) = &view.tablespace {
            head.push_str(&format!(" TABLESPACE {}", quote(tablespace)));
        }
        let data = match view.populated {
            true => "WITH DATA",
            false => "WITH NO DATA",
        };
        return format!("{head} AS\n{definition}\n  {data}");
    }
    let (check, options): (Vec<&String>, Vec<&String>) = view
        .options
        .iter()
        .partition(|option| option.starts_with("check_option="));
    let mut head = format!("CREATE VIEW {name}");
    let options: Vec<String> = options.into_iter().cloned().collect();
    if let Some(options) = storage_options(&options) {
        head.push_str(&format!(" WITH ({options})"));
    }
    let mut sql = format!("{head} AS\n{definition}");
    if let Some(level) = check
        .first()
        .and_then(|option| option.split_once('='))
        .map(|(_, level)| level)
    {
        sql.push_str(&format!("\n  WITH {} CHECK OPTION", level.to_uppercase()));
    }
    sql
}

/// A trigger is made enabled; one turned off or set to fire only on a
/// replica is set so again.
pub(super) fn trigger_state(trigger: &Trigger) -> Option<String> {
    let state = match trigger.enabled.as_str() {
        "D" => "DISABLE",
        "R" => "ENABLE REPLICA",
        "A" => "ENABLE ALWAYS",
        _ => return None,
    };
    Some(format!(
        "ALTER TABLE {} {state} TRIGGER {}",
        qualified(&trigger.schema, &trigger.table),
        quote(&trigger.name)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dump::catalog_rows::Partition;

    #[test]
    fn a_collation_is_written_for_each_provider_and_release() {
        let collation =
            |provider: &str, collate: Option<&str>, ctype: Option<&str>, locale: Option<&str>| UserCollation {
                schema: "app".to_owned(),
                name: "sorted".to_owned(),
                provider: provider.to_owned(),
                deterministic: true,
                collate: collate.map(str::to_owned),
                ctype: ctype.map(str::to_owned),
                locale: locale.map(str::to_owned),
                rules: None,
            };

        assert_eq!(
            create_collation(&collation("c", Some("C"), Some("C"), None)).as_deref(),
            Some("CREATE COLLATION \"app\".\"sorted\" (provider = libc, locale = 'C')")
        );
        assert_eq!(
            create_collation(&collation("c", Some("C"), Some("en_US.utf8"), None)).as_deref(),
            Some("CREATE COLLATION \"app\".\"sorted\" (provider = libc, lc_collate = 'C', lc_ctype = 'en_US.utf8')")
        );
        let mut nocase = collation("i", None, None, Some("und-u-ks-level2"));
        nocase.deterministic = false;
        assert_eq!(
            create_collation(&nocase).as_deref(),
            Some(
                "CREATE COLLATION \"app\".\"sorted\" (provider = icu, deterministic = false, locale = 'und-u-ks-level2')"
            )
        );
        assert_eq!(
            create_collation(&collation("i", Some("de-DE"), Some("de-DE"), None)).as_deref(),
            Some("CREATE COLLATION \"app\".\"sorted\" (provider = icu, locale = 'de-DE')")
        );
        assert_eq!(create_collation(&collation("d", None, None, None)), None);
    }

    fn sequence(name: &str) -> Sequence {
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
            is_called: Some(true),
            owner: None,
        }
    }

    fn column(name: &str, type_sql: &str) -> Column {
        Column {
            schema: "app".to_owned(),
            table: "t".to_owned(),
            name: name.to_owned(),
            type_sql: type_sql.to_owned(),
            collation: None,
            default: None,
            identity: String::new(),
            generated: String::new(),
            not_null: false,
            comment: None,
        }
    }

    fn table(name: &str) -> Table {
        Table {
            schema: "app".to_owned(),
            name: name.to_owned(),
            kind: "r".to_owned(),
            unlogged: false,
            partition_key: None,
            partition: None,
            inherits: false,
            filtered: false,
            options: Vec::new(),
            access_method: None,
            tablespace: None,
            comment: None,
        }
    }

    fn check(name: &str, definition: &str) -> Constraint {
        Constraint {
            schema: "app".to_owned(),
            table: "t".to_owned(),
            partitioned: false,
            name: name.to_owned(),
            kind: "c".to_owned(),
            definition: definition.to_owned(),
            validated: true,
        }
    }

    #[test]
    fn a_sequence_states_every_setting_and_no_owner() {
        let mut cycling = sequence("Order Seq");
        cycling.cycle = true;
        cycling.unlogged = true;

        assert_eq!(
            create_sequence(&cycling),
            "CREATE UNLOGGED SEQUENCE \"app\".\"Order Seq\"\n    AS integer\n    START WITH 1\n    INCREMENT BY 1\n    MINVALUE 1\n    MAXVALUE 2147483647\n    CACHE 1\n    CYCLE"
        );
    }

    #[test]
    fn an_identity_keeps_its_sequence_name_and_settings() {
        let mut id = column("id", "integer");
        id.identity = "a".to_owned();
        id.not_null = true;

        assert_eq!(
            column_sql(&id, Some(&sequence("t_id_seq"))),
            "\"id\" integer GENERATED ALWAYS AS IDENTITY (SEQUENCE NAME \"app\".\"t_id_seq\" START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 CACHE 1) NOT NULL"
        );
        id.identity = "d".to_owned();
        assert_eq!(
            column_sql(&id, None),
            "\"id\" integer GENERATED BY DEFAULT AS IDENTITY NOT NULL"
        );
    }

    #[test]
    fn a_column_states_its_collation_default_or_expression() {
        let mut note = column("note", "text");
        note.collation = Some(Collation {
            schema: "pg_catalog".to_owned(),
            name: "C".to_owned(),
        });
        note.default = Some("'none'::text".to_owned());
        assert_eq!(
            column_sql(&note, None),
            "\"note\" text COLLATE \"pg_catalog\".\"C\" DEFAULT 'none'::text"
        );

        let mut total = column("total", "numeric");
        total.generated = "s".to_owned();
        total.default = Some("(qty * price)".to_owned());
        assert_eq!(
            column_sql(&total, None),
            "\"total\" numeric GENERATED ALWAYS AS ((qty * price)) STORED"
        );
    }

    #[test]
    fn a_table_states_its_columns_checks_and_options() {
        let mut readings = table("readings");
        readings.unlogged = true;
        readings.partition_key = Some("RANGE (taken)".to_owned());
        readings.options = vec!["fillfactor=70".to_owned()];

        assert_eq!(
            create_table(
                &readings,
                &["\"taken\" date NOT NULL".to_owned()],
                &[&check("positive", "CHECK ((amount > 0))")]
            ),
            "CREATE UNLOGGED TABLE \"app\".\"readings\" (\n    \"taken\" date NOT NULL,\n    CONSTRAINT \"positive\" CHECK ((amount > 0))\n) PARTITION BY RANGE (taken) WITH (fillfactor='70')"
        );
    }

    #[test]
    fn a_partition_names_its_parent_and_bound_and_no_columns() {
        let mut partition = table("readings_2025");
        partition.partition = Some(Partition {
            parent_schema: "app".to_owned(),
            parent: "readings".to_owned(),
            bound: "FOR VALUES FROM ('2025-01-01') TO ('2026-01-01')".to_owned(),
        });

        assert_eq!(
            create_table(&partition, &["\"taken\" date".to_owned()], &[]),
            "CREATE TABLE \"app\".\"readings_2025\" PARTITION OF \"app\".\"readings\" FOR VALUES FROM ('2025-01-01') TO ('2026-01-01')"
        );
        assert_eq!(
            create_table(&partition, &[], &[&check("own", "CHECK ((amount < 10))")]),
            "CREATE TABLE \"app\".\"readings_2025\" PARTITION OF \"app\".\"readings\" (\n    CONSTRAINT \"own\" CHECK ((amount < 10))\n) FOR VALUES FROM ('2025-01-01') TO ('2026-01-01')"
        );
    }

    #[test]
    fn a_constraint_on_a_partitioned_table_reaches_its_partitions() {
        let mut key = check("t_pkey", "PRIMARY KEY (id)");
        assert_eq!(
            add_constraint(&key),
            "ALTER TABLE ONLY \"app\".\"t\" ADD CONSTRAINT \"t_pkey\" PRIMARY KEY (id)"
        );
        key.partitioned = true;
        assert_eq!(
            add_constraint(&key),
            "ALTER TABLE \"app\".\"t\" ADD CONSTRAINT \"t_pkey\" PRIMARY KEY (id)"
        );
    }

    #[test]
    fn a_sequence_position_is_set_by_its_quoted_name() {
        assert_eq!(
            set_value(&sequence("it's")).as_deref(),
            Some("SELECT pg_catalog.setval('\"app\".\"it''s\"', 4, true)")
        );
        let mut unread = sequence("unread");
        unread.last_value = None;
        assert_eq!(set_value(&unread), None);
        let mut restarted = sequence("restarted");
        restarted.last_value = Some(1000);
        restarted.is_called = Some(false);
        assert_eq!(
            set_value(&restarted).as_deref(),
            Some("SELECT pg_catalog.setval('\"app\".\"restarted\"', 1000, false)")
        );
    }

    #[test]
    fn a_domain_adds_a_check_not_yet_held_after_it() {
        let domain = Domain {
            base: "integer".to_owned(),
            not_null: true,
            default: Some("1".to_owned()),
            collation: None,
        };
        let held = DomainCheck {
            schema: "app".to_owned(),
            domain: "positive".to_owned(),
            name: "positive_check".to_owned(),
            definition: "CHECK ((VALUE > 0))".to_owned(),
            validated: true,
        };
        let pending = DomainCheck {
            name: "small".to_owned(),
            definition: "CHECK ((VALUE < 100)) NOT VALID".to_owned(),
            validated: false,
            ..held.clone()
        };

        assert_eq!(
            create_domain("app", "positive", &domain, &[&held, &pending]),
            [
                "CREATE DOMAIN \"app\".\"positive\" AS integer DEFAULT 1 NOT NULL",
                "ALTER DOMAIN \"app\".\"positive\" ADD CONSTRAINT \"positive_check\" CHECK ((VALUE > 0))",
                "ALTER DOMAIN \"app\".\"positive\" ADD CONSTRAINT \"small\" CHECK ((VALUE < 100)) NOT VALID",
            ]
        );
    }

    #[test]
    fn enum_labels_and_comments_are_literals() {
        assert_eq!(
            create_enum("app", "mood", &["sad".to_owned(), "it's".to_owned()]),
            "CREATE TYPE \"app\".\"mood\" AS ENUM (\n    'sad',\n    'it''s'\n)"
        );
        assert_eq!(
            comment_on_column("app", "t", "note", "a \\ b"),
            "COMMENT ON COLUMN \"app\".\"t\".\"note\" IS E'a \\\\ b'"
        );
    }

    fn view(materialized: bool, options: &[&str]) -> View {
        View {
            schema: "app".to_owned(),
            name: "v".to_owned(),
            materialized,
            definition: " SELECT t.id\n   FROM app.t;".to_owned(),
            options: options.iter().map(|option| (*option).to_owned()).collect(),
            populated: true,
            access_method: None,
            tablespace: None,
            comment: None,
        }
    }

    #[test]
    fn a_view_keeps_its_options_and_check_option_and_drops_the_semicolon() {
        assert_eq!(
            create_view(&view(false, &["security_barrier=true", "check_option=local"])),
            "CREATE VIEW \"app\".\"v\" WITH (security_barrier='true') AS\n SELECT t.id\n   FROM app.t\n  WITH LOCAL CHECK OPTION"
        );
    }

    #[test]
    fn a_materialized_view_fills_itself_only_where_it_was_filled() {
        assert_eq!(
            create_view(&view(true, &[])),
            "CREATE MATERIALIZED VIEW \"app\".\"v\" AS\n SELECT t.id\n   FROM app.t\n  WITH DATA"
        );
        let mut empty = view(true, &[]);
        empty.populated = false;
        assert!(create_view(&empty).ends_with("\n  WITH NO DATA"));
    }

    #[test]
    fn only_a_trigger_not_plainly_enabled_gets_a_state() {
        let mut trigger = Trigger {
            schema: "app".to_owned(),
            table: "t".to_owned(),
            name: "touch".to_owned(),
            definition: String::new(),
            enabled: "O".to_owned(),
        };
        assert_eq!(trigger_state(&trigger), None);
        trigger.enabled = "D".to_owned();
        assert_eq!(
            trigger_state(&trigger).as_deref(),
            Some("ALTER TABLE \"app\".\"t\" DISABLE TRIGGER \"touch\"")
        );
    }
}
