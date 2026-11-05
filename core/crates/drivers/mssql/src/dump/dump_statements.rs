use tablepro_core::ForeignKeyInfo;
use tablepro_core::ddl::ddl_sql::{foreign_key_sql, index_keys_sql, parenthesized};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::dump::DumpStatement;
use tablepro_core::meta::{IndexInfo, TableRef};
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptToken, ScriptTokenKind};
use tablepro_core::sql_syntax::{SqlGrammar, qualify_created_name};

use crate::catalog::{CatalogFacts, SqlServerType};
use crate::ddl::whole_number;
use crate::dialect::{MssqlDialect, national_literal, quote};

/// CREATE SCHEMA must open a batch, so it runs as dynamic SQL behind the
/// check that keeps a load into a database that has the schema going.
pub(super) fn create_schema(name: &str) -> String {
    let create = format!("CREATE SCHEMA {}", quote(name));
    format!(
        "IF SCHEMA_ID({}) IS NULL EXEC({})",
        national_literal(name),
        national_literal(&create)
    )
}

/// An alias type's base as `sys.types` gives it, with the length in
/// bytes.
pub(super) struct AliasBase<'a> {
    pub(super) system_type: &'a str,
    pub(super) max_length: i64,
    pub(super) precision: i64,
    pub(super) scale: i64,
    pub(super) nullable: bool,
}

pub(super) fn create_alias_type(qualified: &str, base: &AliasBase<'_>) -> String {
    let declaration = SqlServerType::from_catalog(CatalogFacts {
        type_name: base.system_type,
        base_type: base.system_type,
        type_schema: None,
        user_defined: false,
        alias: false,
        user_clr: false,
        max_length: base.max_length,
        precision: base.precision,
        scale: base.scale,
        foreign_code_page: false,
    })
    .declaration();
    let null = if base.nullable { "" } else { " NOT NULL" };
    format!("CREATE TYPE {qualified} FROM {declaration}{null}")
}

/// Where a sequence stands, in the text the catalogue gives its numbers.
pub(super) struct SequencePosition<'a> {
    pub(super) start: &'a str,
    pub(super) current: &'a str,
    pub(super) increment: &'a str,
    pub(super) minimum: &'a str,
    pub(super) maximum: &'a str,
    pub(super) cycles: bool,
    /// Whether NEXT VALUE FOR ever ran: before, `current` is the start,
    /// which is still to come.
    pub(super) used: bool,
}

/// The value the sequence hands out next, which a new sequence takes as
/// its START WITH.
pub(super) fn next_unused(position: &SequencePosition<'_>) -> String {
    if !position.used {
        return position.start.to_owned();
    }
    let number = |text: &str| text.parse::<i128>().ok();
    let (Some(current), Some(increment), Some(minimum), Some(maximum)) = (
        number(position.current),
        number(position.increment),
        number(position.minimum),
        number(position.maximum),
    ) else {
        return position.current.to_owned();
    };
    match current.checked_add(increment) {
        Some(next) if (minimum..=maximum).contains(&next) => next.to_string(),
        _ if position.cycles && increment > 0 => minimum.to_string(),
        _ if position.cycles => maximum.to_string(),
        // An exhausted sequence has no next value; a new one cannot start
        // past its own bounds.
        _ => current.to_string(),
    }
}

/// The identity's next number as it was on the server the dump was read
/// from. A table that took rows since it was made hands out the reseeded
/// number plus the increment, and one that took none the reseeded number
/// itself, so an empty table, as after a load of no rows, is reseeded one
/// increment further.
pub(super) fn reseed(relation: &str, last_value: &str, increment: &str) -> Option<String> {
    if !whole_number(last_value) || !whole_number(increment) {
        return None;
    }
    let next = last_value
        .parse::<i128>()
        .ok()?
        .checked_add(increment.parse::<i128>().ok()?)?;
    let name = national_literal(relation);
    Some(format!(
        "IF EXISTS (SELECT 1 FROM {relation}) DBCC CHECKIDENT ({name}, RESEED, {last_value}) WITH NO_INFOMSGS \
         ELSE DBCC CHECKIDENT ({name}, RESEED, {next}) WITH NO_INFOMSGS"
    ))
}

/// Whether the server checks a constraint, as SMO restates it: an
/// untrusted one is added without checking the rows, and a disabled one
/// is turned off after.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Enforcement {
    pub(super) trusted: bool,
    pub(super) disabled: bool,
}

impl Enforcement {
    fn with(self) -> &'static str {
        match self.trusted {
            true => "WITH CHECK",
            false => "WITH NOCHECK",
        }
    }

    fn after(self, relation: &str, name: &str) -> Option<String> {
        self.disabled
            .then(|| format!("ALTER TABLE {relation} NOCHECK CONSTRAINT {}", quote(name)))
    }
}

pub(super) fn check_constraint(relation: &str, name: &str, definition: &str, enforcement: Enforcement) -> Vec<String> {
    let mut statements = vec![format!(
        "ALTER TABLE {relation} {} ADD CONSTRAINT {} CHECK {}",
        enforcement.with(),
        quote(name),
        parenthesized(definition)
    )];
    statements.extend(enforcement.after(relation, name));
    statements
}

pub(super) fn foreign_key(
    dialect: &MssqlDialect,
    table: &TableRef,
    key: &ForeignKeyInfo,
    enforcement: Enforcement,
) -> Vec<String> {
    let relation = dialect.qualify(table);
    let mut statements = vec![format!(
        "ALTER TABLE {relation} {} ADD {}",
        enforcement.with(),
        foreign_key_sql(dialect, table, key)
    )];
    statements.extend(enforcement.after(&relation, &key.name));
    statements
}

/// A UNIQUE constraint as its index has it. The structure model keeps it
/// as a unique index, which a load would make an index, not a constraint.
pub(super) fn unique_constraint(dialect: &MssqlDialect, relation: &str, index: &IndexInfo, clustered: bool) -> String {
    let kind = match clustered {
        true => "CLUSTERED",
        false => "NONCLUSTERED",
    };
    format!(
        "ALTER TABLE {relation} ADD CONSTRAINT {} UNIQUE {kind} ({})",
        quote(&index.name),
        index_keys_sql(dialect, index)
    )
}

/// How a module was made: the SET options its body reads under.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct ModuleSettings {
    pub(super) ansi_nulls: bool,
    pub(super) quoted_identifier: bool,
}

/// A view, routine or trigger as the server keeps its text, named in its
/// schema, between the SET options it was made under where they are not
/// the file's. The text starts at its first token: the server keeps
/// whatever comment opened the batch, and a load would keep the dump's
/// own comment line as part of the module.
pub(super) fn module_statements(schema: &str, text: &str, settings: ModuleSettings) -> Vec<DumpStatement> {
    let quoted = quote(schema);
    let body = qualified_view(
        &qualify_created_name(&as_create(from_first_token(text)), SqlGrammar::MsSql, &quoted),
        &quoted,
    );
    let mut set = Vec::new();
    if !settings.ansi_nulls {
        set.push("ANSI_NULLS");
    }
    if !settings.quoted_identifier {
        set.push("QUOTED_IDENTIFIER");
    }
    let mut statements: Vec<DumpStatement> = set
        .iter()
        .map(|option| DumpStatement::new(format!("SET {option} OFF")))
        .collect();
    statements.push(DumpStatement::body(body));
    statements.extend(
        set.iter()
            .rev()
            .map(|option| DumpStatement::new(format!("SET {option} ON"))),
    );
    statements
}

/// `qualify_created_name` leaves a view's name as it is, and the server
/// keeps a view's CREATE as it was written, so one made without its
/// schema would land in the loading session's default schema.
fn qualified_view(text: &str, quoted_schema: &str) -> String {
    let grammar = SqlGrammar::MsSql;
    let plan = ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar));
    let tokens: Vec<ScriptToken> = plan
        .tokens(0..text.len())
        .filter(|token| !token.kind.is_trivia())
        .collect();
    let spelled = |at: usize, words: &[&str]| {
        tokens.get(at).is_some_and(|token| {
            token.kind == ScriptTokenKind::Word
                && text
                    .get(token.range.clone())
                    .is_some_and(|word| words.iter().any(|wanted| word.eq_ignore_ascii_case(wanted)))
        })
    };
    let mut at = 1;
    if spelled(at, &["OR"]) {
        at += 2;
    }
    let named = spelled(0, &["CREATE", "ALTER"]) && spelled(at, &["VIEW"]);
    let name = tokens
        .get(at + 1)
        .filter(|token| matches!(token.kind, ScriptTokenKind::Word | ScriptTokenKind::QuotedIdentifier));
    let dotted = tokens
        .get(at + 2)
        .is_some_and(|token| token.kind == ScriptTokenKind::Punct && text.get(token.range.clone()) == Some("."));
    match (named, name, dotted) {
        (true, Some(name), false) => {
            let (head, tail) = text.split_at_checked(name.range.start).unwrap_or((text, ""));
            format!("{head}{quoted_schema}.{tail}")
        }
        _ => text.to_owned(),
    }
}

/// The server keeps the text of the last CREATE or ALTER, so a module
/// changed with ALTER would be altered on load, where nothing exists yet.
fn as_create(text: &str) -> String {
    let grammar = SqlGrammar::MsSql;
    let plan = ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar));
    let mut words = plan
        .tokens(0..text.len())
        .filter(|token| !token.kind.is_trivia())
        .take(2)
        .map(|token| (token.kind, token.range.clone()));
    let first = words.next();
    let second = words.next();
    let word = |token: &Option<(ScriptTokenKind, std::ops::Range<usize>)>, wanted: &[&str]| {
        token.as_ref().is_some_and(|(kind, range)| {
            *kind == ScriptTokenKind::Word
                && text
                    .get(range.clone())
                    .is_some_and(|word| wanted.iter().any(|candidate| word.eq_ignore_ascii_case(candidate)))
        })
    };
    match first {
        Some((_, range))
            if word(&first, &["ALTER"]) && word(&second, &["VIEW", "PROC", "PROCEDURE", "FUNCTION", "TRIGGER"]) =>
        {
            format!("CREATE{}", text.get(range.end..).unwrap_or_default())
        }
        _ => text.to_owned(),
    }
}

fn from_first_token(text: &str) -> &str {
    let grammar = SqlGrammar::MsSql;
    let plan = ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar));
    let start = plan
        .tokens(0..text.len())
        .find(|token| !token.kind.is_trivia())
        .map_or(text.len(), |token| token.range.start);
    text.get(start..).unwrap_or(text)
}

pub(super) fn disable_trigger(schema: &str, name: &str, relation: &str) -> String {
    format!("DISABLE TRIGGER {}.{} ON {relation}", quote(schema), quote(name))
}

#[cfg(test)]
mod tests {
    use tablepro_core::ddl::ReferentialAction;

    #[test]
    fn a_module_last_changed_with_alter_is_made_with_create() {
        assert_eq!(
            super::as_create("ALTER PROCEDURE p AS SELECT 1"),
            "CREATE PROCEDURE p AS SELECT 1"
        );
        assert_eq!(
            super::as_create("alter view v AS SELECT 1"),
            "CREATE view v AS SELECT 1"
        );
        assert_eq!(
            super::as_create("CREATE OR ALTER VIEW v AS SELECT 1"),
            "CREATE OR ALTER VIEW v AS SELECT 1"
        );
        assert_eq!(super::as_create("ALTER TABLE t ADD c int"), "ALTER TABLE t ADD c int");
    }
    use tablepro_core::meta::IndexKey;

    use super::*;

    fn position<'a>(current: &'a str, used: bool) -> SequencePosition<'a> {
        SequencePosition {
            start: "100",
            current,
            increment: "5",
            minimum: "1",
            maximum: "120",
            cycles: false,
            used,
        }
    }

    const ENFORCED: Enforcement = Enforcement {
        trusted: true,
        disabled: false,
    };

    #[test]
    fn a_schema_is_made_once_through_dynamic_sql() {
        assert_eq!(
            create_schema("o'k]s"),
            "IF SCHEMA_ID(N'o''k]s') IS NULL EXEC(N'CREATE SCHEMA [o''k]]s]')"
        );
    }

    #[test]
    fn an_alias_type_restates_its_base_in_characters() {
        let base = |system_type, max_length, nullable| AliasBase {
            system_type,
            max_length,
            precision: 0,
            scale: 0,
            nullable,
        };

        assert_eq!(
            create_alias_type("[app].[label]", &base("nvarchar", 80, false)),
            "CREATE TYPE [app].[label] FROM nvarchar(40) NOT NULL"
        );
        assert_eq!(
            create_alias_type("[app].[blob]", &base("varbinary", -1, true)),
            "CREATE TYPE [app].[blob] FROM varbinary(max)"
        );
        let money = AliasBase {
            system_type: "decimal",
            max_length: 9,
            precision: 12,
            scale: 2,
            nullable: true,
        };
        assert_eq!(
            create_alias_type("[app].[amount]", &money),
            "CREATE TYPE [app].[amount] FROM decimal(12,2)"
        );
    }

    #[test]
    fn a_sequence_starts_where_the_old_one_would_hand_out_next() {
        assert_eq!(next_unused(&position("100", false)), "100", "never used");
        assert_eq!(next_unused(&position("110", true)), "115");
        assert_eq!(next_unused(&position("120", true)), "120", "exhausted");
        let cycling = SequencePosition {
            cycles: true,
            ..position("120", true)
        };
        assert_eq!(next_unused(&cycling), "1");
        let down = SequencePosition {
            increment: "-5",
            cycles: true,
            ..position("3", true)
        };
        assert_eq!(next_unused(&down), "120");
        let wide = SequencePosition {
            increment: "1",
            maximum: "99999999999999999999999999999999999999",
            ..position("99999999999999999999999999999999999990", true)
        };
        assert_eq!(next_unused(&wide), "99999999999999999999999999999999999991");
    }

    #[test]
    fn only_a_whole_number_reseeds_and_an_empty_table_one_step_on() {
        assert_eq!(
            reseed("[app].[o'rders]", "20", "5").as_deref(),
            Some(
                "IF EXISTS (SELECT 1 FROM [app].[o'rders]) DBCC CHECKIDENT (N'[app].[o''rders]', RESEED, 20) \
                 WITH NO_INFOMSGS ELSE DBCC CHECKIDENT (N'[app].[o''rders]', RESEED, 25) WITH NO_INFOMSGS"
            )
        );
        assert!(reseed("[t]", "-3", "1").is_some());
        assert_eq!(reseed("[t]", "1; DROP TABLE x", "1"), None);
        assert_eq!(reseed("[t]", "", "1"), None);
    }

    #[test]
    fn a_constraint_keeps_whether_the_server_checks_it() {
        assert_eq!(
            check_constraint("[app].[t]", "ck", "([price]>=(0))", ENFORCED),
            ["ALTER TABLE [app].[t] WITH CHECK ADD CONSTRAINT [ck] CHECK ([price]>=(0))"]
        );
        let off = Enforcement {
            trusted: false,
            disabled: true,
        };
        assert_eq!(
            check_constraint("[app].[t]", "ck", "[a]>(0)", off),
            [
                "ALTER TABLE [app].[t] WITH NOCHECK ADD CONSTRAINT [ck] CHECK ([a]>(0))",
                "ALTER TABLE [app].[t] NOCHECK CONSTRAINT [ck]",
            ]
        );
    }

    #[test]
    fn a_foreign_key_is_added_to_its_table_after_the_rows() {
        let key = ForeignKeyInfo {
            name: "fk_child_parent".to_owned(),
            columns: vec!["parent_id".to_owned()],
            ref_schema: Some("app".to_owned()),
            ref_table: "parent".to_owned(),
            ref_columns: vec!["id".to_owned()],
            on_delete: Some(ReferentialAction::Cascade),
            on_update: None,
        };
        let table = TableRef::new(Some("app".to_owned()), "child");

        assert_eq!(
            foreign_key(&MssqlDialect::new(16), &table, &key, ENFORCED),
            [
                "ALTER TABLE [app].[child] WITH CHECK ADD CONSTRAINT [fk_child_parent] FOREIGN KEY ([parent_id]) \
                 REFERENCES [app].[parent] ([id]) ON DELETE CASCADE"
            ]
        );
    }

    #[test]
    fn a_unique_constraint_stays_a_constraint() {
        let index = IndexInfo {
            name: "uq".to_owned(),
            keys: vec![
                IndexKey::Column {
                    name: "a".to_owned(),
                    descending: false,
                },
                IndexKey::Column {
                    name: "b".to_owned(),
                    descending: true,
                },
            ],
            unique: true,
            primary: false,
            predicate: None,
            definition: None,
        };

        assert_eq!(
            unique_constraint(&MssqlDialect::new(16), "[app].[t]", &index, false),
            "ALTER TABLE [app].[t] ADD CONSTRAINT [uq] UNIQUE NONCLUSTERED ([a], [b] DESC)"
        );
    }

    #[test]
    fn a_module_starts_at_its_create_named_in_its_schema() {
        let settings = ModuleSettings {
            ansi_nulls: true,
            quoted_identifier: true,
        };
        let text = "\n-- View: app.v\n/* note */ CREATE VIEW v AS SELECT 1 AS one; -- kept\n";

        assert_eq!(
            module_statements("app", text, settings),
            [DumpStatement::body("CREATE VIEW [app].v AS SELECT 1 AS one; -- kept\n")]
        );
        assert_eq!(
            module_statements("app", "CREATE VIEW app.v AS SELECT 1", settings),
            [DumpStatement::body("CREATE VIEW app.v AS SELECT 1")]
        );
        assert_eq!(
            module_statements("app", "create or alter view [v w] (a) AS SELECT 1", settings),
            [DumpStatement::body("create or alter view [app].[v w] (a) AS SELECT 1")]
        );
        assert_eq!(
            module_statements("app", "CREATE PROCEDURE p AS SELECT 1", settings),
            [DumpStatement::body("CREATE PROCEDURE [app].p AS SELECT 1")]
        );
    }

    #[test]
    fn a_module_made_under_other_settings_is_framed_in_them() {
        let settings = ModuleSettings {
            ansi_nulls: false,
            quoted_identifier: false,
        };

        let statements = module_statements("dbo", "CREATE PROCEDURE p AS SELECT \"x\"", settings);

        let sql: Vec<&str> = statements.iter().map(|statement| statement.sql.as_str()).collect();
        assert_eq!(
            sql,
            [
                "SET ANSI_NULLS OFF",
                "SET QUOTED_IDENTIFIER OFF",
                "CREATE PROCEDURE [dbo].p AS SELECT \"x\"",
                "SET QUOTED_IDENTIFIER ON",
                "SET ANSI_NULLS ON",
            ]
        );
        assert!(statements[2].body && !statements[0].body);
    }
}
