use serde::{Deserialize, Serialize};
use sqlparser::ast::{
    CopySource, CopyTarget, Cte, Delete, Expr, FromTable, FunctionArg, FunctionArgExpr, FunctionArguments,
    GrantObjects, Insert, ObjectName, Query, SelectItem, SetExpr, Statement, TableFactor, TableObject, UtilityOption,
    Value,
};
use sqlparser::dialect::{Dialect, GenericDialect, MsSqlDialect, MySqlDialect, PostgreSqlDialect, SQLiteDialect};
use sqlparser::parser::Parser;
use sqlparser::tokenizer::{Token, Tokenizer, Whitespace};

use crate::admin_functions::is_administrative_function_name;
use crate::effects::Effects;
use crate::effects_classification::{merge_script_class, sql_effects_from_tokens, statement_effects, truncate_facts};
use crate::select_writes::select_writes;
use crate::{blast_radius, sensitive_projection};

/// Coarse statement class used by policy rules.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StatementClass {
    Select,
    Insert,
    Update,
    Delete,
    Ddl,
    Administrative,
    Transaction,
    Other,
    /// Parser rejected the SQL. Fail closed: treated as a write.
    Unparseable,
}

impl StatementClass {
    pub fn is_write(self) -> bool {
        !matches!(self, Self::Select | Self::Transaction)
    }
}

/// Policy metadata and effects extracted from one SQL string.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatementFacts {
    pub class: StatementClass,
    pub(crate) effects: Effects,
    pub tables: Vec<String>,
    pub has_where: bool,
    pub contains_unscoped_dml: bool,
    pub is_multi_statement: bool,
    pub parse_error: Option<String>,
}

pub(crate) struct StatementDetails {
    pub(crate) class: StatementClass,
    pub(crate) effects: Effects,
    pub(crate) tables: Vec<String>,
    pub(crate) has_where: bool,
    pub(crate) contains_unscoped_dml: bool,
}

pub(crate) struct StatementAnalysis {
    pub(crate) facts: StatementFacts,
    pub(crate) blast_radius: Option<blast_radius::BlastRadiusRewrite>,
    pub(crate) sensitive_positions: Option<Vec<bool>>,
    pub(crate) known_statement_rows: Vec<Option<u64>>,
}

impl StatementFacts {
    pub fn writes(&self) -> bool {
        self.class.is_write()
    }

    pub fn contains_ddl(&self) -> bool {
        self.effects.contains(Effects::WRITES_SCHEMA)
    }

    pub fn contains_mutating_dml(&self) -> bool {
        self.effects.contains(Effects::WRITES_ROWS)
    }

    pub fn contains_unknown_write(&self) -> bool {
        self.effects.contains(Effects::UNKNOWN)
    }

    pub fn unparseable(message: impl Into<String>) -> Self {
        Self {
            class: StatementClass::Unparseable,
            effects: Effects::UNKNOWN,
            tables: Vec::new(),
            has_where: false,
            contains_unscoped_dml: false,
            is_multi_statement: false,
            parse_error: Some(message.into()),
        }
    }
}

pub fn statement_requires_write_capability(sql: &str, driver_id: &str) -> bool {
    classify(sql, driver_id).writes()
}

pub fn classify(sql: &str, driver_id: &str) -> StatementFacts {
    analyze_statement_inner(sql, driver_id, &[], false).facts
}

pub(crate) fn analyze_statement(sql: &str, driver_id: &str, patterns: &[String]) -> StatementAnalysis {
    analyze_statement_inner(sql, driver_id, patterns, true)
}

fn analyze_statement_inner(
    sql: &str,
    driver_id: &str,
    patterns: &[String],
    include_execution_plans: bool,
) -> StatementAnalysis {
    let dialect = dialect_for(driver_id);
    let trimmed = sql.trim();
    if trimmed.is_empty() {
        return failed_analysis("empty SQL");
    }

    if driver_id == "mysql" && sql_contains_mysql_executable_comment(trimmed, dialect.as_ref()) {
        return failed_analysis("MySQL executable comments are not safely classified");
    }

    let statements = match Parser::parse_sql(dialect.as_ref(), trimmed) {
        Ok(s) => s,
        Err(e) => return failed_analysis(e.to_string()),
    };

    if statements.is_empty() {
        return failed_analysis("no statements parsed");
    }

    let (effects, contains_administrative_call) = sql_effects_from_tokens(trimmed, dialect.as_ref(), driver_id);
    let facts = classify_statements(&statements, effects, contains_administrative_call);
    let (blast_radius, sensitive_positions, known_statement_rows) = if include_execution_plans {
        let (blast_radius, known_statement_rows) = blast_radius::analyze_blast_radius(&statements, driver_id);
        (
            blast_radius,
            sensitive_projection::projection_from_statements(&statements, patterns),
            known_statement_rows,
        )
    } else {
        (None, None, Vec::new())
    };
    StatementAnalysis {
        facts,
        blast_radius,
        sensitive_positions,
        known_statement_rows,
    }
}

fn classify_statements(
    statements: &[Statement],
    mut effects: Effects,
    contains_administrative_call: bool,
) -> StatementFacts {
    let is_multi = statements.len() > 1;
    let mut class = StatementClass::Select;
    let mut writes = false;
    let mut tables = Vec::new();
    let mut has_where = true;
    let mut contains_unscoped_dml = false;
    for stmt in statements {
        let facts = classify_statement(stmt);
        effects = effects.union(facts.effects);
        writes |= facts.class.is_write();
        contains_unscoped_dml |= facts.contains_unscoped_dml;
        class = merge_script_class(class, facts.class);
        for t in facts.tables {
            if !tables.iter().any(|x| x == &t) {
                tables.push(t);
            }
        }
        if facts.class == StatementClass::Update || facts.class == StatementClass::Delete {
            has_where &= facts.has_where;
        }
    }

    if contains_administrative_call {
        class = StatementClass::Administrative;
        writes = true;
    }

    if writes && class == StatementClass::Select {
        class = StatementClass::Other;
    }

    StatementFacts {
        class,
        effects,
        tables,
        has_where,
        contains_unscoped_dml,
        is_multi_statement: is_multi,
        parse_error: None,
    }
}

fn failed_analysis(message: impl Into<String>) -> StatementAnalysis {
    StatementAnalysis {
        facts: StatementFacts::unparseable(message),
        blast_radius: None,
        sensitive_positions: None,
        known_statement_rows: Vec::new(),
    }
}

fn sql_contains_mysql_executable_comment(sql: &str, dialect: &dyn Dialect) -> bool {
    let Ok(tokens) = Tokenizer::new(dialect, sql).tokenize() else {
        return false;
    };

    tokens.iter().any(|token| {
        matches!(token, Token::Whitespace(Whitespace::MultiLineComment(comment))
            if comment.starts_with('!') || comment.starts_with("M!"))
    })
}

/// Detect administrative calls anywhere in a successfully parsed statement.
/// Token inspection complements the AST walk so calls hidden in predicates,
/// ordering expressions, or less-common expression wrappers still fail closed,
/// while names inside literals and comments remain harmless. Function names
/// must be followed by an opening parenthesis; stored procedures are invoked
/// without one and are matched on the name alone.
pub(crate) fn dialect_for(driver_id: &str) -> Box<dyn Dialect> {
    match driver_id {
        "postgres" => Box::new(PostgreSqlDialect {}),
        "mysql" => Box::new(MySqlDialect {}),
        "sqlite" => Box::new(SQLiteDialect {}),
        "mssql" => Box::new(MsSqlDialect {}),
        _ => Box::new(GenericDialect {}),
    }
}

fn classify_statement(stmt: &Statement) -> StatementDetails {
    let mut facts = classify_statement_details(stmt);
    facts.effects = facts.effects.union(statement_effects(stmt, &facts));
    facts
}

fn classify_statement_details(stmt: &Statement) -> StatementDetails {
    match stmt {
        Statement::Query(q) => classify_query(q),
        Statement::Insert(insert) => classify_insert(insert),
        Statement::Update { table, selection, .. } => StatementDetails {
            effects: Effects::EMPTY,
            class: StatementClass::Update,
            tables: table_factor_names(&table.relation),
            has_where: selection.is_some(),
            contains_unscoped_dml: selection.is_none(),
        },
        Statement::Delete(delete) => classify_delete(delete),
        Statement::CreateTable(c) => StatementDetails {
            effects: Effects::EMPTY,
            class: StatementClass::Ddl,
            tables: object_name_strings(&c.name),
            has_where: true,
            contains_unscoped_dml: false,
        },
        Statement::CreateView { name, .. } => StatementDetails {
            effects: Effects::EMPTY,
            class: StatementClass::Ddl,
            tables: object_name_strings(name),
            has_where: true,
            contains_unscoped_dml: false,
        },
        Statement::CreateIndex(c) => StatementDetails {
            effects: Effects::EMPTY,
            class: StatementClass::Ddl,
            tables: match &c.name {
                Some(n) => object_name_strings(n),
                None => object_name_strings(&c.table_name),
            },
            has_where: true,
            contains_unscoped_dml: false,
        },
        Statement::AlterTable { name, .. } => StatementDetails {
            effects: Effects::EMPTY,
            class: StatementClass::Ddl,
            tables: object_name_strings(name),
            has_where: true,
            contains_unscoped_dml: false,
        },
        Statement::Drop { names, .. } => StatementDetails {
            effects: Effects::EMPTY,
            class: StatementClass::Ddl,
            tables: names.iter().flat_map(object_name_strings).collect(),
            has_where: true,
            contains_unscoped_dml: false,
        },
        Statement::Truncate { table_names, .. } => truncate_facts(table_names.iter().map(|table| &table.name)),
        Statement::CreateVirtualTable { .. }
        | Statement::CreateRole { .. }
        | Statement::CreateSecret { .. }
        | Statement::CreateServer(_)
        | Statement::CreatePolicy { .. }
        | Statement::CreateConnector(_)
        | Statement::AlterIndex { .. }
        | Statement::AlterView { .. }
        | Statement::AlterType(_)
        | Statement::AlterRole { .. }
        | Statement::AlterPolicy { .. }
        | Statement::AlterConnector { .. }
        | Statement::DropFunction { .. }
        | Statement::DropDomain(_)
        | Statement::DropProcedure { .. }
        | Statement::DropSecret { .. }
        | Statement::DropPolicy { .. }
        | Statement::DropConnector { .. }
        | Statement::CreateExtension { .. }
        | Statement::DropExtension { .. }
        | Statement::Comment { .. }
        | Statement::CreateSchema { .. }
        | Statement::CreateDatabase { .. }
        | Statement::CreateTrigger { .. }
        | Statement::DropTrigger { .. }
        | Statement::CreateProcedure { .. }
        | Statement::CreateMacro { .. }
        | Statement::CreateStage { .. }
        | Statement::Deny(_)
        | Statement::CreateSequence { .. }
        | Statement::CreateDomain(_)
        | Statement::CreateType { .. } => ddl_facts(Vec::new()),
        Statement::CreateFunction(f) => ddl_facts(object_name_strings(&f.name)),
        Statement::Grant { objects, .. } | Statement::Revoke { objects, .. } => {
            ddl_facts(objects.as_ref().map(grant_object_names).unwrap_or_default())
        }
        Statement::Merge { table, .. } => StatementDetails {
            effects: Effects::EMPTY,
            class: StatementClass::Other,
            tables: table_factor_names(table),
            has_where: true,
            contains_unscoped_dml: false,
        },
        Statement::Kill { .. } => StatementDetails {
            effects: Effects::EMPTY,
            class: StatementClass::Administrative,
            tables: Vec::new(),
            has_where: true,
            contains_unscoped_dml: false,
        },
        Statement::StartTransaction { .. } | Statement::Commit { .. } | Statement::Rollback { .. } => {
            StatementDetails {
                effects: Effects::EMPTY,
                class: StatementClass::Transaction,
                tables: Vec::new(),
                has_where: true,
                contains_unscoped_dml: false,
            }
        }
        Statement::Explain {
            analyze,
            statement,
            options,
            ..
        } => classify_explain(*analyze, statement, options.as_deref()),
        Statement::ExplainTable { table_name, .. } => StatementDetails {
            effects: Effects::EMPTY,
            class: StatementClass::Select,
            tables: object_name_strings(table_name),
            has_where: true,
            contains_unscoped_dml: false,
        },
        Statement::Copy { target, source, .. } => {
            let reaches_the_host = matches!(target, CopyTarget::File { .. } | CopyTarget::Program { .. });
            let tables = match source {
                CopySource::Table { table_name, .. } => object_name_strings(table_name),
                CopySource::Query(query) => classify_query(query).tables,
            };
            StatementDetails {
                effects: Effects::EMPTY,
                class: if reaches_the_host {
                    StatementClass::Administrative
                } else {
                    StatementClass::Other
                },
                tables,
                has_where: true,
                contains_unscoped_dml: false,
            }
        }
        _ => StatementDetails {
            effects: Effects::EMPTY,
            class: StatementClass::Other,
            tables: Vec::new(),
            has_where: true,
            contains_unscoped_dml: false,
        },
    }
}

fn classify_explain(analyze: bool, statement: &Statement, options: Option<&[UtilityOption]>) -> StatementDetails {
    if analyze || options.is_some_and(analyze_option_enabled) {
        return classify_statement(statement);
    }
    let inner = classify_statement(statement);
    StatementDetails {
        effects: Effects::EMPTY,
        class: StatementClass::Select,
        tables: inner.tables,
        has_where: true,
        contains_unscoped_dml: false,
    }
}

fn analyze_option_enabled(options: &[UtilityOption]) -> bool {
    options.iter().any(|option| {
        option.name.value.eq_ignore_ascii_case("analyze") && !option.arg.as_ref().is_some_and(is_disabled_option_arg)
    })
}

fn is_disabled_option_arg(arg: &Expr) -> bool {
    match arg {
        Expr::Value(value) => match &value.value {
            Value::Boolean(flag) => !flag,
            Value::Number(number, _) => number.parse::<f64>().is_ok_and(|n| n == 0.0),
            Value::SingleQuotedString(text) | Value::DoubleQuotedString(text) => is_disabled_word(text),
            _ => false,
        },
        Expr::Identifier(ident) => is_disabled_word(&ident.value),
        _ => false,
    }
}

fn is_disabled_word(text: &str) -> bool {
    matches!(text.to_ascii_lowercase().as_str(), "false" | "off" | "0" | "no")
}

fn ddl_facts(tables: Vec<String>) -> StatementDetails {
    StatementDetails {
        effects: Effects::EMPTY,
        class: StatementClass::Ddl,
        tables,
        has_where: true,
        contains_unscoped_dml: false,
    }
}

fn classify_insert(insert: &Insert) -> StatementDetails {
    let tables = match &insert.table {
        TableObject::TableName(name) => object_name_strings(name),
        TableObject::TableFunction(f) => vec![f.name.to_string()],
    };
    StatementDetails {
        effects: Effects::EMPTY,
        class: StatementClass::Insert,
        tables,
        has_where: true,
        contains_unscoped_dml: false,
    }
}

fn classify_delete(delete: &Delete) -> StatementDetails {
    let mut tables = Vec::new();
    for t in &delete.tables {
        tables.extend(object_name_strings(t));
    }
    tables.extend(from_table_names(&delete.from));
    StatementDetails {
        effects: Effects::EMPTY,
        class: StatementClass::Delete,
        tables,
        has_where: delete.selection.is_some(),
        contains_unscoped_dml: delete.selection.is_none(),
    }
}

fn from_table_names(from: &FromTable) -> Vec<String> {
    let list = match from {
        FromTable::WithFromKeyword(t) | FromTable::WithoutKeyword(t) => t,
    };
    list.iter().flat_map(|t| table_factor_names(&t.relation)).collect()
}

fn classify_query(query: &Query) -> StatementDetails {
    let mut writes = false;
    let mut administrative = false;
    let mut contains_unscoped_dml = false;
    let mut effects = Effects::EMPTY;
    let mut tables = Vec::new();

    if let Some(with) = &query.with {
        for Cte { query: cte_q, .. } in &with.cte_tables {
            let inner = classify_query(cte_q);
            writes |= inner.class.is_write();
            administrative |= inner.class == StatementClass::Administrative;
            effects = effects.union(inner.effects);
            contains_unscoped_dml |= inner.contains_unscoped_dml;
            tables.extend(inner.tables);
        }
    }

    let body_facts = classify_set_expr(query.body.as_ref());
    writes |= body_facts.class.is_write();
    administrative |= body_facts.class == StatementClass::Administrative;
    effects = effects.union(body_facts.effects);
    contains_unscoped_dml |= body_facts.contains_unscoped_dml;
    writes |= administrative;
    tables.extend(body_facts.tables);

    StatementDetails {
        effects,
        class: if administrative {
            StatementClass::Administrative
        } else if writes {
            StatementClass::Other
        } else {
            StatementClass::Select
        },
        tables,
        has_where: !contains_unscoped_dml,
        contains_unscoped_dml,
    }
}

fn classify_set_expr(body: &SetExpr) -> StatementDetails {
    match body {
        SetExpr::Insert(statement) | SetExpr::Update(statement) | SetExpr::Delete(statement) => {
            classify_statement(statement)
        }
        SetExpr::Query(query) => classify_query(query),
        SetExpr::SetOperation { left, right, .. } => {
            let left = classify_set_expr(left);
            let right = classify_set_expr(right);
            StatementDetails {
                class: if left.class == StatementClass::Administrative || right.class == StatementClass::Administrative
                {
                    StatementClass::Administrative
                } else if left.class.is_write() || right.class.is_write() {
                    StatementClass::Other
                } else {
                    StatementClass::Select
                },
                tables: left.tables.into_iter().chain(right.tables).collect(),
                has_where: left.has_where && right.has_where,
                effects: left.effects.union(right.effects),
                contains_unscoped_dml: left.contains_unscoped_dml || right.contains_unscoped_dml,
            }
        }
        _ => {
            let administrative = set_expr_administrative(body);
            let writes = set_expr_writes(body) || administrative;
            StatementDetails {
                effects: if administrative {
                    Effects::ADMIN
                } else if writes {
                    Effects::UNKNOWN
                } else {
                    Effects::READS
                },
                class: if administrative {
                    StatementClass::Administrative
                } else if writes {
                    StatementClass::Other
                } else {
                    StatementClass::Select
                },
                tables: set_expr_tables(body),
                has_where: true,
                contains_unscoped_dml: false,
            }
        }
    }
}

fn set_expr_administrative(body: &SetExpr) -> bool {
    match body {
        SetExpr::Query(query) => classify_query(query).class == StatementClass::Administrative,
        SetExpr::SetOperation { left, right, .. } => set_expr_administrative(left) || set_expr_administrative(right),
        SetExpr::Select(select) => select.projection.iter().any(|item| match item {
            SelectItem::ExprWithAlias { expr, .. } | SelectItem::UnnamedExpr(expr) => expr_is_administrative(expr),
            _ => false,
        }),
        _ => false,
    }
}

fn expr_is_administrative(expr: &Expr) -> bool {
    match expr {
        Expr::Function(function) => {
            is_administrative_function(&function.name) || function_arguments_are_administrative(&function.args)
        }
        Expr::Subquery(query) => classify_query(query).class == StatementClass::Administrative,
        Expr::BinaryOp { left, right, .. } => expr_is_administrative(left) || expr_is_administrative(right),
        Expr::UnaryOp { expr, .. } | Expr::Nested(expr) => expr_is_administrative(expr),
        Expr::Case {
            operand,
            conditions,
            else_result,
            ..
        } => {
            operand.as_ref().is_some_and(|expr| expr_is_administrative(expr))
                || conditions
                    .iter()
                    .any(|case| expr_is_administrative(&case.condition) || expr_is_administrative(&case.result))
                || else_result.as_ref().is_some_and(|expr| expr_is_administrative(expr))
        }
        _ => false,
    }
}

fn is_administrative_function(name: &ObjectName) -> bool {
    is_administrative_function_name(&name.to_string())
}

fn function_arguments_are_administrative(arguments: &FunctionArguments) -> bool {
    match arguments {
        FunctionArguments::None => false,
        FunctionArguments::Subquery(query) => classify_query(query).class == StatementClass::Administrative,
        FunctionArguments::List(arguments) => arguments.args.iter().any(|argument| {
            let expression = match argument {
                FunctionArg::Named { arg, .. } | FunctionArg::ExprNamed { arg, .. } | FunctionArg::Unnamed(arg) => arg,
            };
            matches!(expression, FunctionArgExpr::Expr(expr) if expr_is_administrative(expr))
        }),
    }
}

fn set_expr_writes(body: &SetExpr) -> bool {
    match body {
        SetExpr::Insert(_) | SetExpr::Update(_) | SetExpr::Delete(_) => true,
        // VALUES is a read-only row constructor. INSERT ... VALUES is already
        // represented by Statement::Insert and classified as a write above.
        SetExpr::Values(_) => false,
        SetExpr::Query(q) => classify_query(q).class.is_write(),
        SetExpr::SetOperation { left, right, .. } => set_expr_writes(left) || set_expr_writes(right),
        SetExpr::Select(select) => select_writes(select),
        SetExpr::Table(_) => false,
    }
}

fn set_expr_tables(body: &SetExpr) -> Vec<String> {
    match body {
        SetExpr::Select(select) => {
            let mut tables = Vec::new();
            for t in &select.from {
                tables.extend(table_factor_names(&t.relation));
                for join in &t.joins {
                    tables.extend(table_factor_names(&join.relation));
                }
            }
            tables
        }
        SetExpr::Query(q) => classify_query(q).tables,
        SetExpr::SetOperation { left, right, .. } => {
            let mut t = set_expr_tables(left);
            t.extend(set_expr_tables(right));
            t
        }
        SetExpr::Insert(stmt) | SetExpr::Update(stmt) | SetExpr::Delete(stmt) => classify_statement(stmt).tables,
        _ => Vec::new(),
    }
}

pub(crate) fn expr_writes(expr: &Expr) -> bool {
    match expr {
        Expr::Subquery(q) => classify_query(q).class.is_write(),
        Expr::BinaryOp { left, right, .. } => expr_writes(left) || expr_writes(right),
        Expr::UnaryOp { expr, .. } => expr_writes(expr),
        Expr::Nested(e) => expr_writes(e),
        Expr::Case {
            operand,
            conditions,
            else_result,
            ..
        } => {
            operand.as_ref().is_some_and(|e| expr_writes(e))
                || conditions
                    .iter()
                    .any(|c| expr_writes(&c.condition) || expr_writes(&c.result))
                || else_result.as_ref().is_some_and(|e| expr_writes(e))
        }
        _ => false,
    }
}

fn object_name_strings(name: &ObjectName) -> Vec<String> {
    vec![name.to_string()]
}

/// Named targets of a GRANT/REVOKE, for the approval dialog's object list.
/// Only the object kinds this project's engines actually have (tables,
/// views, schemas, databases) are named; a broader grant (all tables in a
/// schema, a warehouse, a compute pool, and so on) reports no targets here,
/// same as before this function existed -- the statement is still DDL,
/// still requires approval, and is still denied to agents either way.
fn grant_object_names(objects: &GrantObjects) -> Vec<String> {
    match objects {
        GrantObjects::Tables(names) | GrantObjects::Views(names) | GrantObjects::Schemas(names) => {
            names.iter().flat_map(object_name_strings).collect()
        }
        GrantObjects::Databases(names) => names.iter().flat_map(object_name_strings).collect(),
        _ => Vec::new(),
    }
}

fn table_factor_names(factor: &TableFactor) -> Vec<String> {
    match factor {
        TableFactor::Table { name, .. } => object_name_strings(name),
        TableFactor::Derived { subquery, .. } => classify_query(subquery).tables,
        TableFactor::NestedJoin { table_with_joins, .. } => {
            let mut out = table_factor_names(&table_with_joins.relation);
            for j in &table_with_joins.joins {
                out.extend(table_factor_names(&j.relation));
            }
            out
        }
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn select_is_read() {
        let f = classify("SELECT * FROM users WHERE id = 1", "postgres");
        assert!(!f.writes());
        assert_eq!(f.class, StatementClass::Select);
        assert!(f.tables.iter().any(|t| t.contains("users")));
    }

    #[test]
    fn guard_analysis_supplies_classification_masking_and_blast_radius_from_one_parse() {
        let patterns = vec!["pan".to_owned()];
        let read = analyze_statement("SELECT pan AS p FROM cards", "postgres", &patterns);
        assert!(read.facts.effects.contains(Effects::READS));
        assert_eq!(read.sensitive_positions, Some(vec![true]));
        assert!(read.blast_radius.is_none());

        let mutation = analyze_statement("UPDATE cards SET pan = 'x' WHERE id = 1", "postgres", &patterns);
        assert!(mutation.facts.effects.contains(Effects::WRITES_ROWS));
        assert!(mutation.sensitive_positions.is_none());
        assert!(matches!(
            mutation.blast_radius,
            Some(blast_radius::BlastRadiusRewrite::CountQuery(_))
        ));
        assert_eq!(mutation.known_statement_rows, vec![None]);

        let insert = analyze_statement("INSERT INTO cards (pan) VALUES ('x')", "postgres", &patterns);
        assert_eq!(insert.known_statement_rows, vec![Some(1)]);
        assert_eq!(insert.blast_radius, Some(blast_radius::BlastRadiusRewrite::Known(1)));
    }

    #[test]
    fn insert_is_mutating_dml() {
        let f = classify("INSERT INTO t (a) VALUES (1)", "postgres");
        assert!(f.writes());
        assert_eq!(f.class, StatementClass::Insert);
        assert!(
            f.contains_mutating_dml(),
            "an unbounded INSERT ... SELECT must still be subject to a blast-radius check"
        );
    }

    /// A blank object list in the approval dialog is as bad as no dialog at
    /// all for GRANT, COPY, and MERGE -- the operator can't tell what the
    /// statement actually touches.
    #[test]
    fn grant_copy_and_merge_name_their_targets() {
        let grant = classify("GRANT ALL ON payments TO evil", "postgres");
        assert_eq!(grant.tables, vec!["payments".to_string()]);
        assert_eq!(grant.class, StatementClass::Ddl);

        let revoke = classify("REVOKE ALL ON payments FROM evil", "postgres");
        assert_eq!(revoke.tables, vec!["payments".to_string()]);

        let copy_from = classify("COPY payments FROM '/tmp/x.csv'", "postgres");
        assert_eq!(copy_from.tables, vec!["payments".to_string()]);

        let copy_to = classify("COPY payments TO STDOUT", "postgres");
        assert_eq!(copy_to.tables, vec!["payments".to_string()]);

        let merge = classify(
            "MERGE INTO payments USING staged ON payments.id = staged.id WHEN MATCHED THEN DELETE",
            "postgres",
        );
        assert_eq!(merge.tables, vec!["payments".to_string()]);
        assert!(
            merge.contains_unknown_write(),
            "MERGE stays on the fail-closed catch-all"
        );

        let create_fn = classify(
            "CREATE FUNCTION audit_hook() RETURNS void AS $$ SELECT 1 $$ LANGUAGE sql",
            "postgres",
        );
        assert_eq!(create_fn.tables, vec!["audit_hook".to_string()]);
    }

    #[test]
    fn delete_without_where() {
        let f = classify("DELETE FROM payments", "postgres");
        assert!(f.writes());
        assert_eq!(f.class, StatementClass::Delete);
        assert!(!f.has_where);
    }

    #[test]
    fn update_with_where() {
        let f = classify("UPDATE payments SET status = 'ok' WHERE id = 1", "postgres");
        assert!(f.writes());
        assert_eq!(f.class, StatementClass::Update);
        assert!(f.has_where);
    }

    #[test]
    fn data_modifying_cte_is_write() {
        let sql = "WITH d AS (DELETE FROM payments WHERE id = 1 RETURNING *) SELECT * FROM d";
        let f = classify(sql, "postgres");
        assert!(f.writes(), "data-modifying CTE must report writes=true: {f:?}");
    }

    #[test]
    fn values_and_recursive_values_cte_are_reads() {
        for sql in [
            "VALUES (1), (2)",
            "WITH RECURSIVE counter(value) AS (VALUES(0) UNION ALL SELECT value + 1 FROM counter WHERE value < 10) SELECT sum(value) FROM counter",
        ] {
            let facts = classify(sql, "sqlite");
            assert_eq!(facts.class, StatementClass::Select, "SQL: {sql}, facts: {facts:?}");
            assert!(!facts.writes(), "SQL: {sql}, facts: {facts:?}");
        }
    }

    #[test]
    fn insert_select_cte_write() {
        let sql = "WITH x AS (INSERT INTO t(a) VALUES (1) RETURNING a) SELECT * FROM x";
        let f = classify(sql, "postgres");
        assert!(f.writes());
    }

    #[test]
    fn multi_statement_flagged() {
        let f = classify("SELECT 1; DELETE FROM t", "postgres");
        assert!(f.is_multi_statement);
        assert!(f.writes());
    }

    #[test]
    fn mixed_script_preserves_ddl_in_both_orders() {
        for sql in [
            "DROP TABLE protected_data; INSERT INTO audit_log VALUES (1)",
            "INSERT INTO audit_log VALUES (1); DROP TABLE protected_data",
        ] {
            let facts = classify(sql, "postgres");
            assert!(facts.contains_ddl(), "SQL: {sql}");
        }
    }

    #[test]
    fn mixed_script_preserves_unknown_writes_in_both_orders() {
        for sql in [
            "SET session_replication_role = replica; INSERT INTO jobs(id) VALUES (1)",
            "INSERT INTO jobs(id) VALUES (1); SET session_replication_role = replica",
        ] {
            let facts = classify(sql, "postgres");
            assert!(facts.contains_unknown_write(), "SQL: {sql}");
        }
    }

    #[test]
    fn mixed_script_preserves_unscoped_dml_in_both_orders() {
        for sql in [
            "DELETE FROM protected_data; CREATE TABLE replacement(id integer)",
            "CREATE TABLE replacement(id integer); DELETE FROM protected_data",
        ] {
            let facts = classify(sql, "postgres");
            assert!(facts.contains_mutating_dml(), "SQL: {sql}");
            assert!(facts.contains_unscoped_dml, "SQL: {sql}");
        }
    }

    #[test]
    fn parse_failure_fail_closed() {
        let f = classify("SELECCT * FROM", "postgres");
        assert_eq!(f.class, StatementClass::Unparseable);
        assert!(f.writes());
        assert!(f.parse_error.is_some());
    }

    #[test]
    fn truncate_is_ddl_write() {
        let f = classify("TRUNCATE TABLE payments", "postgres");
        assert!(f.writes() && f.contains_mutating_dml() && f.contains_unscoped_dml);
        assert_eq!(f.class, StatementClass::Ddl);
    }

    #[test]
    fn broader_schema_and_privilege_changes_are_ddl() {
        for sql in [
            "CREATE SCHEMA reporting",
            "CREATE SEQUENCE job_ids",
            "CREATE FUNCTION answer() RETURNS integer LANGUAGE SQL AS 'SELECT 42'",
            "GRANT SELECT ON TABLE jobs TO analyst",
            "REVOKE SELECT ON TABLE jobs FROM analyst",
        ] {
            let facts = classify(sql, "postgres");
            assert!(facts.contains_ddl(), "SQL: {sql}, facts: {facts:?}");
        }
    }

    #[test]
    fn mysql_delete() {
        let f = classify("DELETE FROM t WHERE id = 1", "mysql");
        assert_eq!(f.class, StatementClass::Delete);
        assert!(f.has_where);
    }

    #[test]
    fn mysql_executable_comment_cannot_hide_a_file_write_from_policy() {
        for sql in [
            "SELECT 'payload' /*! INTO OUTFILE '/tmp/bookiee-policy.csv' */",
            "SELECT 1 /*M!100100 INTO OUTFILE '/tmp/bookiee-policy.csv' */",
        ] {
            let facts = classify(sql, "mysql");
            assert_eq!(facts.class, StatementClass::Unparseable, "SQL: {sql}, facts: {facts:?}");
            assert!(facts.writes(), "SQL: {sql}, facts: {facts:?}");
        }

        for sql in [
            "SELECT '/*! INTO OUTFILE ''/tmp/file'' */'",
            "SELECT 1 /* INTO OUTFILE '/tmp/file' */",
        ] {
            let facts = classify(sql, "mysql");
            assert_eq!(facts.class, StatementClass::Select, "SQL: {sql}, facts: {facts:?}");
            assert!(!facts.writes(), "SQL: {sql}, facts: {facts:?}");
        }
    }

    #[test]
    fn mssql_update() {
        let f = classify("UPDATE dbo.t SET a = 1 WHERE a = 2", "mssql");
        assert_eq!(f.class, StatementClass::Update);
        assert!(f.has_where);
    }

    #[test]
    fn postgres_terminate_backend_is_administrative() {
        let facts = classify("SELECT pg_terminate_backend(42)", "postgres");
        assert_eq!(facts.class, StatementClass::Administrative);
        assert!(facts.writes());
    }

    #[test]
    fn postgres_side_effecting_functions_are_administrative() {
        for sql in [
            "SELECT pg_promote()",
            "SELECT nextval('jobs_id_seq')",
            "SELECT setval('jobs_id_seq', 10)",
            "SELECT pg_advisory_lock(42)",
            "SELECT pg_try_advisory_lock(42)",
            "SELECT pg_wal_replay_pause()",
            "SELECT pg_wal_replay_resume()",
            "SELECT set_config('work_mem', '64MB', false)",
            "SELECT pg_file_write('/tmp/x', 'y', false)",
            "SELECT pg_file_unlink('/tmp/x')",
            "SELECT dblink_open('c', 'select 1')",
            "SELECT dblink_fetch('c', 10)",
            "SELECT dblink_connect_u('c', 'dbname=x')",
            "SELECT pg_stat_statements_reset()",
        ] {
            let facts = classify(sql, "postgres");
            assert_eq!(facts.class, StatementClass::Administrative, "SQL: {sql}");
            assert!(facts.writes(), "SQL: {sql}");
        }
    }

    #[test]
    fn sqlite_fileio_functions_are_administrative() {
        for sql in [
            "SELECT writefile('/home/user/.bashrc', 'evil')",
            "SELECT readfile('/etc/shadow')",
            "SELECT load_extension('/tmp/evil.so')",
        ] {
            let facts = classify(sql, "sqlite");
            assert_eq!(facts.class, StatementClass::Administrative, "SQL: {sql}");
            assert!(facts.writes(), "SQL: {sql}");
        }
        // The same names on another engine are ordinary unknown functions,
        // not administrative -- this list is SQLite-specific.
        let facts = classify("SELECT writefile(a, b) FROM t", "postgres");
        assert_ne!(facts.class, StatementClass::Administrative);
    }

    #[test]
    fn administrative_function_nested_in_expression_is_detected() {
        let facts = classify("SELECT coalesce(pg_cancel_backend(42), false)", "postgres");
        assert_eq!(facts.class, StatementClass::Administrative);
        assert!(facts.writes());
    }

    #[test]
    fn administrative_function_in_predicate_is_detected() {
        let facts = classify("SELECT 1 WHERE pg_terminate_backend(42)", "postgres");
        assert_eq!(facts.class, StatementClass::Administrative);
        assert!(facts.writes());
    }

    #[test]
    fn administrative_function_name_in_literal_or_comment_is_not_a_call() {
        for sql in [
            "SELECT 'pg_terminate_backend(42)'",
            "SELECT 1 -- pg_terminate_backend(42)",
            "SELECT 1 /* pg_terminate_backend(42) */",
        ] {
            let facts = classify(sql, "postgres");
            assert_eq!(facts.class, StatementClass::Select, "SQL: {sql}");
            assert!(!facts.writes(), "SQL: {sql}");
        }
    }

    #[test]
    fn mysql_kill_is_administrative() {
        let facts = classify("KILL 42", "mysql");
        assert_eq!(facts.class, StatementClass::Administrative);
        assert!(facts.writes());
    }

    #[test]
    fn plain_explain_of_a_select_is_a_read() {
        let facts = classify("EXPLAIN SELECT id FROM users", "postgres");
        assert_eq!(facts.class, StatementClass::Select);
        assert!(!facts.writes());
        assert!(!facts.contains_unknown_write());
        assert_eq!(facts.tables, vec!["users".to_string()]);
    }

    #[test]
    fn plain_explain_of_a_write_does_not_execute_it() {
        let facts = classify("EXPLAIN DELETE FROM users", "postgres");
        assert_eq!(facts.class, StatementClass::Select);
        assert!(!facts.writes());
        assert!(!facts.contains_mutating_dml());
        assert!(!facts.contains_unscoped_dml);
    }

    #[test]
    fn explain_verbose_of_a_select_is_a_read() {
        let facts = classify("EXPLAIN (VERBOSE) SELECT id FROM users", "postgres");
        assert_eq!(facts.class, StatementClass::Select);
        assert!(!facts.writes());
    }

    #[test]
    fn explain_analyze_keeps_the_inner_statement_facts() {
        let facts = classify("EXPLAIN ANALYZE DELETE FROM users", "postgres");
        assert_eq!(facts.class, StatementClass::Delete);
        assert!(facts.writes());
        assert!(facts.contains_mutating_dml());
        assert!(facts.contains_unscoped_dml);
        assert_eq!(facts.tables, vec!["users".to_string()]);
    }

    #[test]
    fn explain_with_a_parenthesized_analyze_option_is_a_write() {
        let facts = classify("EXPLAIN (ANALYZE) UPDATE users SET name = 'x'", "postgres");
        assert_eq!(facts.class, StatementClass::Update);
        assert!(facts.writes());
        assert!(facts.contains_unscoped_dml);
    }

    #[test]
    fn explain_with_analyze_disabled_is_a_read() {
        for sql in [
            "EXPLAIN (ANALYZE false) DELETE FROM users",
            "EXPLAIN (ANALYZE off) DELETE FROM users",
            "EXPLAIN (ANALYZE 0) DELETE FROM users",
        ] {
            let facts = classify(sql, "postgres");
            assert_eq!(facts.class, StatementClass::Select, "SQL: {sql}");
            assert!(!facts.writes(), "SQL: {sql}");
        }
    }

    #[test]
    fn describe_table_is_a_read() {
        let facts = classify("DESCRIBE users", "mysql");
        assert_eq!(facts.class, StatementClass::Select);
        assert!(!facts.writes());
    }

    #[test]
    fn only_a_provable_read_skips_the_write_capability_check() {
        for sql in ["SELECT 1", "SELECT id FROM t WHERE id = 1"] {
            assert!(!statement_requires_write_capability(sql, "postgres"), "{sql}");
        }
        for sql in [
            "DELETE FROM t WHERE id = 1",
            "CREATE TABLE t (id int)",
            "SELECT pg_read_file('/etc/passwd')",
            "COPY t TO PROGRAM 'sh'",
            "this is not sql at all",
            "",
        ] {
            assert!(statement_requires_write_capability(sql, "postgres"), "{sql}");
        }
    }
}
