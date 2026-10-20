use serde::{Deserialize, Serialize};
use sqlparser::ast::{
    CopySource, CopyTarget, Cte, Delete, Expr, FromTable, FunctionArg, FunctionArgExpr, FunctionArguments,
    GrantObjects, Insert, ObjectName, Query, SelectItem, SetExpr, Statement, TableFactor, TableObject, UtilityOption,
};
use sqlparser::dialect::{Dialect, GenericDialect, MsSqlDialect, MySqlDialect, PostgreSqlDialect, SQLiteDialect};
use sqlparser::parser::Parser;

use crate::admin_functions::is_administrative_function_name;
use crate::constant_predicate::is_constant_true;
use crate::effects::Effects;
use crate::effects_classification::{merge_script_class, sql_effects_from_tokens, statement_effects, truncate_facts};
use crate::explain_options::analyze_option_enabled;
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
    pub(crate) rolls_back_to_savepoint: bool,
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

    if let Some(reason) = crate::input_refusal::refusal(trimmed, driver_id, dialect.as_ref()) {
        return failed_analysis(reason);
    }

    let statements = match Parser::parse_sql(dialect.as_ref(), trimmed) {
        Ok(s) => s,
        Err(e) => return failed_analysis(e.to_string()),
    };

    if statements.is_empty() {
        return failed_analysis("no statements parsed");
    }

    let (effects, contains_administrative_call) = sql_effects_from_tokens(trimmed, dialect.as_ref(), driver_id);
    let facts = crate::select_writes::with_locking_backstop(
        classify_statements(&statements, effects, contains_administrative_call),
        trimmed,
        dialect.as_ref(),
    );
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
        rolls_back_to_savepoint: statements
            .iter()
            .any(|statement| matches!(statement, Statement::Rollback { savepoint: Some(_), .. })),
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
        rolls_back_to_savepoint: false,
        blast_radius: None,
        sensitive_positions: None,
        known_statement_rows: Vec::new(),
    }
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
        Statement::Update(update) => StatementDetails {
            effects: Effects::EMPTY,
            class: StatementClass::Update,
            tables: table_factor_names(&update.table.relation),
            has_where: update.selection.is_some(),
            contains_unscoped_dml: update.selection.as_ref().is_none_or(is_constant_true),
        },
        Statement::Delete(delete) => classify_delete(delete),
        Statement::CreateTable(c) => ddl_on(object_name_strings(&c.name)),
        Statement::CreateView(view) => ddl_on(object_name_strings(&view.name)),
        Statement::CreateIndex(c) => ddl_on(match &c.name {
            Some(n) => object_name_strings(n),
            None => object_name_strings(&c.table_name),
        }),
        Statement::AlterTable(alter) => ddl_on(object_name_strings(&alter.name)),
        Statement::RenameTable(renames) => ddl_on(
            renames
                .iter()
                .flat_map(|rename| object_name_strings(&rename.old_name))
                .collect(),
        ),
        Statement::Drop { names, .. } => ddl_on(names.iter().flat_map(object_name_strings).collect()),
        Statement::Truncate(truncate) => truncate_facts(truncate.table_names.iter().map(|table| &table.name)),
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
        Statement::Grant(grant) => ddl_facts(grant.objects.as_ref().map(grant_object_names).unwrap_or_default()),
        Statement::Revoke(revoke) => ddl_facts(revoke.objects.as_ref().map(grant_object_names).unwrap_or_default()),
        Statement::Merge(merge) => StatementDetails {
            effects: Effects::EMPTY,
            class: StatementClass::Other,
            tables: table_factor_names(&merge.table),
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
        TableObject::TableQuery(query) => classify_query(query).tables,
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
        contains_unscoped_dml: delete.selection.as_ref().is_none_or(is_constant_true),
    }
}

fn from_table_names(from: &FromTable) -> Vec<String> {
    let list = match from {
        FromTable::WithFromKeyword(t) | FromTable::WithoutKeyword(t) => t,
    };
    list.iter().flat_map(|t| table_factor_names(&t.relation)).collect()
}

pub(crate) fn classify_query(query: &Query) -> StatementDetails {
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
    writes |= administrative || !query.locks.is_empty();
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
        SetExpr::Insert(_) | SetExpr::Update(_) | SetExpr::Delete(_) | SetExpr::Merge(_) => true,
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
        SetExpr::Insert(s) | SetExpr::Update(s) | SetExpr::Delete(s) | SetExpr::Merge(s) => {
            classify_statement(s).tables
        }
        _ => Vec::new(),
    }
}

fn ddl_on(tables: Vec<String>) -> StatementDetails {
    StatementDetails {
        effects: Effects::EMPTY,
        class: StatementClass::Ddl,
        tables,
        has_where: true,
        contains_unscoped_dml: false,
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
mod tests;
