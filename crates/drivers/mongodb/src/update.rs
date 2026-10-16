use mongodb::bson::{Bson, Document, doc};
use sqlparser::ast::{
    AssignmentTarget, BinaryOperator, Expr, FromTable, FunctionArg, FunctionArgExpr, FunctionArguments, GroupByExpr,
    LimitClause, ObjectNamePart, OrderByKind, OrderBySort, Query, Select, SelectItem, SetExpr, Statement, TableFactor,
    Update, Value as SqlValue,
};
use sqlparser::dialect::GenericDialect;
use sqlparser::parser::Parser;

use super::codec::value_to_bson;
use tablepro_core::{DriverError, Value};

pub(super) struct KeyedUpdate {
    pub(super) collection: String,
    pub(super) filter: Document,
    pub(super) set: Document,
}

pub(super) struct KeyedDelete {
    pub(super) collection: String,
    pub(super) filter: Document,
}

pub(super) struct KeyedValueSelect {
    pub(super) collection: String,
    pub(super) column: String,
    pub(super) key: Bson,
}

pub(super) struct BrowsePageSelect {
    pub(super) collection: String,
    pub(super) filter: Document,
    pub(super) key: Option<Bson>,
    pub(super) sort: Document,
    pub(super) limit: i64,
    pub(super) offset: u64,
}

pub(super) fn parse_browse_page_select(
    sql: &str,
    params: &[Value],
    database: &str,
) -> Result<Option<BrowsePageSelect>, DriverError> {
    let statements = Parser::parse_sql(&GenericDialect {}, sql)
        .map_err(|error| DriverError::Unsupported(format!("invalid MongoDB browse page query: {error}")))?;
    let [Statement::Query(query)] = statements.as_slice() else {
        return Ok(None);
    };
    let Some((select, limit, offset)) = browse_page_query(query) else {
        return Ok(None);
    };
    let Some(mut sort) = browse_sort(query) else {
        return Ok(None);
    };
    if sort.is_empty() {
        sort.insert("_id", 1);
    }
    if !matches!(select.projection.as_slice(), [SelectItem::Wildcard(_)]) {
        return Ok(None);
    }
    let relation = &select.from[0];
    if !relation.joins.is_empty() {
        return Ok(None);
    }
    let Some(collection) = collection_named(&relation.relation, database) else {
        return Ok(None);
    };
    let (filter, key) = match select.selection.as_ref() {
        Some(selection) => {
            let Some((filter, key)) = browse_filter(selection, params, sort == doc! { "_id": 1 })? else {
                return Ok(None);
            };
            (filter, key)
        }
        None if params.is_empty() => (Document::new(), None),
        None => return Ok(None),
    };
    if key.is_some() && offset != 0 {
        return Ok(None);
    }
    Ok(Some(BrowsePageSelect {
        collection,
        filter,
        key,
        sort,
        limit,
        offset,
    }))
}

fn browse_filter(
    selection: &Expr,
    params: &[Value],
    extract_keyset: bool,
) -> Result<Option<(Document, Option<Bson>)>, DriverError> {
    let mut predicates = Vec::new();
    collect_and_predicates(selection, &mut predicates);
    if extract_keyset && predicates.iter().filter(|expr| keyset_cursor(expr).is_some()).count() > 1 {
        return Ok(None);
    }
    let mut filter = Document::new();
    let mut key = None;
    let mut index = 0;
    for predicate in predicates {
        if extract_keyset && let Some(cursor) = keyset_cursor(predicate) {
            if key.is_some() {
                return Ok(None);
            }
            key = Some(take_placeholder(cursor, params, &mut index)?);
        } else {
            filter = merge_browse_selectors(filter, browse_selector_from_expr(predicate, params, &mut index)?);
        }
    }
    if index != params.len() {
        return Ok(None);
    }
    Ok(Some((filter, key)))
}

fn browse_selector_from_expr(expr: &Expr, params: &[Value], index: &mut usize) -> Result<Document, DriverError> {
    match expr {
        Expr::Nested(inner) => browse_selector_from_expr(inner, params, index),
        Expr::BinaryOp {
            left,
            op: BinaryOperator::And,
            right,
        } => Ok(merge_browse_selectors(
            browse_selector_from_expr(left, params, index)?,
            browse_selector_from_expr(right, params, index)?,
        )),
        Expr::BinaryOp {
            left,
            op: BinaryOperator::Or,
            right,
        } => Ok(doc! {
            "$or": [
                browse_selector_from_expr(left, params, index)?,
                browse_selector_from_expr(right, params, index)?,
            ]
        }),
        _ => browse_leaf_selector(expr, params, index),
    }
}

fn browse_leaf_selector(expr: &Expr, params: &[Value], index: &mut usize) -> Result<Document, DriverError> {
    match expr {
        Expr::BinaryOp {
            left,
            op:
                operator @ (BinaryOperator::Eq
                | BinaryOperator::Gt
                | BinaryOperator::GtEq
                | BinaryOperator::Lt
                | BinaryOperator::LtEq
                | BinaryOperator::NotEq),
            right,
        } => comparison_selector(left, operator, right, params, index),
        Expr::Like {
            negated,
            any: false,
            expr,
            pattern,
            escape_char,
        } => pattern_selector(expr, pattern, escape_char.as_deref(), *negated, false, params, index),
        Expr::ILike {
            negated,
            any: false,
            expr,
            pattern,
            escape_char,
        } => pattern_selector(expr, pattern, escape_char.as_deref(), *negated, true, params, index),
        Expr::Between {
            expr,
            negated: false,
            low,
            high,
        } => between_selector(expr, low, high, params, index),
        Expr::InList { expr, list, negated } => in_list_selector(expr, list, *negated, params, index),
        Expr::IsNull(inner) => {
            let Some(field) = identifier_from_expr(inner) else {
                return Err(browse_filter_error());
            };
            Ok(explicit_null_selector(field))
        }
        Expr::IsNotNull(inner) => {
            let Some(field) = identifier_from_expr(inner) else {
                return Err(browse_filter_error());
            };
            Ok(doc! { field: { "$exists": true, "$ne": Bson::Null } })
        }
        _ => Err(browse_filter_error()),
    }
}

fn merge_browse_selectors(mut left: Document, right: Document) -> Document {
    if right.keys().any(|field| left.contains_key(field)) {
        return doc! { "$and": [left, right] };
    }
    left.extend(right);
    left
}

fn comparison_selector(
    left: &Expr,
    operator: &BinaryOperator,
    right: &Expr,
    params: &[Value],
    index: &mut usize,
) -> Result<Document, DriverError> {
    let Some(field) = identifier_from_expr(left) else {
        return Err(browse_filter_error());
    };
    let value = value_to_bson(&take_placeholder_value(right, params, index)?)?;
    if *operator == BinaryOperator::Eq && matches!(value, Bson::Null) {
        return Ok(explicit_null_selector(field));
    }
    if matches!(value, Bson::Null) {
        return Err(browse_filter_error());
    }
    if *operator == BinaryOperator::NotEq {
        return Ok(doc! { field: { "$exists": true, "$nin": [value, Bson::Null] } });
    }
    let operator = match operator {
        BinaryOperator::Eq => "$eq",
        BinaryOperator::Gt => "$gt",
        BinaryOperator::GtEq => "$gte",
        BinaryOperator::Lt => "$lt",
        BinaryOperator::LtEq => "$lte",
        _ => return Err(browse_filter_error()),
    };
    Ok(doc! { field: { operator: value } })
}

fn between_selector(
    expr: &Expr,
    low: &Expr,
    high: &Expr,
    params: &[Value],
    index: &mut usize,
) -> Result<Document, DriverError> {
    let Some(field) = identifier_from_expr(expr) else {
        return Err(browse_filter_error());
    };
    let low = value_to_bson(&take_placeholder_value(low, params, index)?)?;
    let high = value_to_bson(&take_placeholder_value(high, params, index)?)?;
    if matches!(low, Bson::Null) || matches!(high, Bson::Null) {
        return Err(browse_filter_error());
    }
    Ok(doc! { field: { "$gte": low, "$lte": high } })
}

fn in_list_selector(
    expr: &Expr,
    list: &[Expr],
    negated: bool,
    params: &[Value],
    index: &mut usize,
) -> Result<Document, DriverError> {
    let Some(field) = identifier_from_expr(expr) else {
        return Err(browse_filter_error());
    };
    let values = list
        .iter()
        .map(|item| value_to_bson(&take_placeholder_value(item, params, index)?))
        .collect::<Result<Vec<_>, _>>()?;
    let has_null = values.iter().any(|value| matches!(value, Bson::Null));
    let values = values
        .into_iter()
        .filter(|value| !matches!(value, Bson::Null))
        .collect::<Vec<_>>();
    if (negated && has_null) || values.is_empty() {
        return Ok(doc! { "_id": { "$in": [] } });
    }
    if negated {
        let mut excluded = values;
        excluded.push(Bson::Null);
        Ok(doc! { field: { "$exists": true, "$nin": excluded } })
    } else {
        Ok(doc! { field: { "$in": values } })
    }
}

fn pattern_selector(
    expr: &Expr,
    pattern: &Expr,
    escape_char: Option<&Expr>,
    negated: bool,
    insensitive: bool,
    params: &[Value],
    index: &mut usize,
) -> Result<Document, DriverError> {
    let Some(field) = identifier_from_expr(expr) else {
        return Err(browse_filter_error());
    };
    let pattern = match take_placeholder_value(pattern, params, index)? {
        Value::Text(pattern) => pattern,
        Value::Null => return Ok(doc! { "_id": { "$in": [] } }),
        _ => return Err(browse_filter_error()),
    };
    let escape = match escape_char {
        Some(Expr::Value(value)) => Some(value.value.clone().into_string().ok_or_else(browse_filter_error)?),
        Some(_) => return Err(browse_filter_error()),
        None => None,
    };
    let escape = match escape {
        None => '\\',
        Some(escape) => {
            let mut chars = escape.chars();
            let Some(ch) = chars.next() else {
                return Err(browse_filter_error());
            };
            if chars.next().is_some() {
                return Err(browse_filter_error());
            }
            ch
        }
    };
    Ok(doc! {
        field: like_regex_selector(&pattern, escape, negated, insensitive)
    })
}

fn like_regex_selector(pattern: &str, escape: char, negated: bool, insensitive: bool) -> Document {
    let mut regex = String::with_capacity(pattern.len() + 2);
    regex.push('^');
    let mut escaped = false;
    for ch in pattern.chars() {
        if escaped {
            push_regex_literal(&mut regex, ch);
            escaped = false;
        } else if ch == escape {
            escaped = true;
        } else {
            match ch {
                '%' => regex.push_str("[\\s\\S]*"),
                '_' => regex.push_str("[\\s\\S]"),
                _ => push_regex_literal(&mut regex, ch),
            }
        }
    }
    if escaped {
        push_regex_literal(&mut regex, escape);
    }
    regex.push('$');
    let mut expression = doc! { "$regex": regex };
    if insensitive {
        expression.insert("$options", "i");
    }
    if negated {
        doc! { "$type": "string", "$not": expression }
    } else {
        expression.insert("$type", "string");
        expression
    }
}

fn push_regex_literal(regex: &mut String, ch: char) {
    if matches!(
        ch,
        '\\' | '.' | '^' | '$' | '|' | '?' | '*' | '+' | '(' | ')' | '[' | ']' | '{' | '}'
    ) {
        regex.push('\\');
    }
    regex.push(ch);
}

fn browse_filter_error() -> DriverError {
    DriverError::Unsupported(
        "MongoDB browse filters support comparison, range, pattern, set-membership, and null predicates".into(),
    )
}

fn collect_and_predicates<'a>(expr: &'a Expr, predicates: &mut Vec<&'a Expr>) {
    match expr {
        Expr::Nested(inner) => collect_and_predicates(inner, predicates),
        Expr::BinaryOp {
            left,
            op: BinaryOperator::And,
            right,
        } => {
            collect_and_predicates(left, predicates);
            collect_and_predicates(right, predicates);
        }
        _ => predicates.push(expr),
    }
}

fn keyset_cursor(expr: &Expr) -> Option<&Expr> {
    let Expr::BinaryOp {
        left,
        op: BinaryOperator::Gt,
        right,
    } = expr
    else {
        return None;
    };
    (identifier_from_expr(left).as_deref() == Some("_id")).then_some(right)
}

fn browse_page_query(query: &Query) -> Option<(&Select, i64, u64)> {
    let mut unpaged_query = query.clone();
    unpaged_query.limit_clause = None;
    unpaged_query.order_by = None;
    simple_value_select(&unpaged_query)?;
    let Some(LimitClause::LimitOffset {
        limit: Some(Expr::Value(limit)),
        offset: Some(offset),
        limit_by,
    }) = &query.limit_clause
    else {
        return None;
    };
    let SqlValue::Number(limit, _) = &limit.value else {
        return None;
    };
    let limit = limit.parse::<i64>().ok()?;
    let offset = offset.value.to_string().parse().ok()?;
    if limit <= 0 || !limit_by.is_empty() {
        return None;
    }
    let SetExpr::Select(select) = query.body.as_ref() else {
        return None;
    };
    Some((select, limit, offset))
}

fn browse_sort(query: &Query) -> Option<Document> {
    let Some(order_by) = &query.order_by else {
        return Some(Document::new());
    };
    if order_by.interpolate.is_some() {
        return None;
    }
    let OrderByKind::Expressions(expressions) = &order_by.kind else {
        return None;
    };
    if expressions.is_empty() {
        return None;
    }
    let mut sort = Document::new();
    for item in expressions {
        let field = identifier_from_expr(&item.expr)?;
        if field.starts_with('$')
            || field.contains('.')
            || item.options.nulls_first.is_some()
            || item.with_fill.is_some()
        {
            return None;
        }
        let direction = match item.options.sort {
            None | Some(OrderBySort::Asc) => 1,
            Some(OrderBySort::Desc) => -1,
            Some(OrderBySort::Using(_)) => return None,
        };
        sort.insert(field, direction);
    }
    Some(sort)
}

pub(super) fn parse_keyed_value_select(
    sql: &str,
    params: &[Value],
    database: &str,
) -> Result<Option<KeyedValueSelect>, DriverError> {
    let statements = Parser::parse_sql(&GenericDialect {}, sql)
        .map_err(|error| DriverError::Unsupported(format!("invalid parameterized MongoDB value query: {error}")))?;
    let [Statement::Query(query)] = statements.as_slice() else {
        return Ok(None);
    };
    let Some(select) = simple_value_select(query) else {
        return Ok(None);
    };
    let [SelectItem::UnnamedExpr(Expr::Identifier(column))] = select.projection.as_slice() else {
        return Ok(None);
    };
    if column.value.starts_with('$') || column.value.contains('.') {
        return Ok(None);
    }
    let relation = &select.from[0];
    if !relation.joins.is_empty() {
        return Ok(None);
    }
    let Some(collection) = collection_named(&relation.relation, database) else {
        return Ok(None);
    };
    let Some(Expr::BinaryOp {
        left,
        op: BinaryOperator::Eq,
        right,
    }) = select.selection.as_ref()
    else {
        return Ok(None);
    };
    if identifier_from_expr(left).as_deref() != Some("_id") || params.len() != 1 {
        return Ok(None);
    }
    let mut index = 0;
    let key = take_placeholder(right, params, &mut index)?;
    if index != params.len() {
        return Ok(None);
    }
    Ok(Some(KeyedValueSelect {
        collection,
        column: column.value.clone(),
        key,
    }))
}

fn simple_value_select(query: &Query) -> Option<&Select> {
    if query.with.is_some()
        || query.order_by.is_some()
        || query.limit_clause.is_some()
        || query.fetch.is_some()
        || !query.locks.is_empty()
        || query.for_clause.is_some()
        || query.settings.is_some()
        || query.format_clause.is_some()
        || !query.pipe_operators.is_empty()
    {
        return None;
    }
    let SetExpr::Select(select) = query.body.as_ref() else {
        return None;
    };
    if select.distinct.is_some()
        || select.top.is_some()
        || select.exclude.is_some()
        || select.into.is_some()
        || select.from.len() != 1
        || !select.lateral_views.is_empty()
        || select.prewhere.is_some()
        || !matches!(&select.group_by, GroupByExpr::Expressions(expressions, _) if expressions.is_empty())
        || !select.cluster_by.is_empty()
        || !select.distribute_by.is_empty()
        || !select.sort_by.is_empty()
        || select.having.is_some()
        || !select.named_window.is_empty()
        || select.qualify.is_some()
        || select.value_table_mode.is_some()
        || !select.connect_by.is_empty()
    {
        return None;
    }
    Some(select)
}

fn plain_keyed_update_selection(update: &Update) -> Option<&Expr> {
    if update.from.is_some()
        || !update.table.joins.is_empty()
        || update.returning.is_some()
        || update.or.is_some()
        || update.output.is_some()
        || update.limit.is_some()
        || !update.order_by.is_empty()
        || !update.optimizer_hints.is_empty()
    {
        return None;
    }
    update.selection.as_ref()
}

pub(super) fn parse_keyed_update(
    sql: &str,
    params: &[Value],
    database: &str,
) -> Result<Option<KeyedUpdate>, DriverError> {
    let statements = Parser::parse_sql(&GenericDialect {}, sql)
        .map_err(|error| DriverError::Unsupported(format!("invalid parameterized MongoDB update: {error}")))?;
    let [Statement::Update(update)] = statements.as_slice() else {
        return Ok(None);
    };
    let Some(selection) = plain_keyed_update_selection(update) else {
        return Ok(None);
    };
    let table = &update.table;
    let assignments = &update.assignments;
    let Some(collection) = collection_named(&table.relation, database) else {
        return Ok(None);
    };
    if assignments.is_empty() {
        return Ok(None);
    }

    let mut parameter_index = 0;
    let mut set = Document::new();
    for assignment in assignments {
        let AssignmentTarget::ColumnName(column) = &assignment.target else {
            return Ok(None);
        };
        let Some(column) = single_identifier(column) else {
            return Ok(None);
        };
        let value = take_placeholder(&assignment.value, params, &mut parameter_index)?;
        if set.insert(column, value).is_some() {
            return Ok(None);
        }
    }
    let filter = selector_from_expr(selection, params, &mut parameter_index)?;
    if parameter_index != params.len() || filter.is_empty() {
        return Ok(None);
    }
    Ok(Some(KeyedUpdate {
        collection,
        filter,
        set,
    }))
}

pub(super) fn parse_keyed_delete(
    sql: &str,
    params: &[Value],
    database: &str,
) -> Result<Option<KeyedDelete>, DriverError> {
    let statements = Parser::parse_sql(&GenericDialect {}, sql)
        .map_err(|error| DriverError::Unsupported(format!("invalid parameterized MongoDB delete: {error}")))?;
    let [Statement::Delete(delete)] = statements.as_slice() else {
        return Ok(None);
    };
    if !delete.tables.is_empty()
        || delete.using.is_some()
        || delete.returning.is_some()
        || !delete.order_by.is_empty()
        || delete.limit.is_some()
    {
        return Ok(None);
    }
    let Some(selection) = &delete.selection else {
        return Ok(None);
    };
    let tables = match &delete.from {
        FromTable::WithFromKeyword(tables) | FromTable::WithoutKeyword(tables) => tables,
    };
    let [table] = tables.as_slice() else {
        return Ok(None);
    };
    if !table.joins.is_empty() {
        return Ok(None);
    }
    let Some(collection) = collection_named(&table.relation, database) else {
        return Ok(None);
    };
    let mut parameter_index = 0;
    let filter = selector_from_expr(selection, params, &mut parameter_index)?;
    if parameter_index != params.len() || filter.is_empty() {
        return Ok(None);
    }
    Ok(Some(KeyedDelete { collection, filter }))
}

fn collection_named(relation: &TableFactor, database: &str) -> Option<String> {
    let TableFactor::Table {
        name,
        alias: None,
        args: None,
        ..
    } = relation
    else {
        return None;
    };
    let identifiers = name
        .0
        .iter()
        .map(ObjectNamePart::as_ident)
        .collect::<Option<Vec<_>>>()?;
    match identifiers.as_slice() {
        [collection] => Some(collection.value.clone()),
        [schema, collection] if schema.value == database => Some(collection.value.clone()),
        _ => None,
    }
}

fn single_identifier(name: &sqlparser::ast::ObjectName) -> Option<String> {
    let [ObjectNamePart::Identifier(identifier)] = name.0.as_slice() else {
        return None;
    };
    Some(identifier.value.clone())
}

fn take_placeholder(expr: &Expr, params: &[Value], index: &mut usize) -> Result<Bson, DriverError> {
    value_to_bson(&take_placeholder_value(expr, params, index)?)
}

fn take_placeholder_value(expr: &Expr, params: &[Value], index: &mut usize) -> Result<Value, DriverError> {
    let Expr::Value(value) = expr else {
        return Err(DriverError::Unsupported(
            "MongoDB grid writes require bound values".into(),
        ));
    };
    if !matches!(value.value, SqlValue::Placeholder(_)) {
        return Err(DriverError::Unsupported(
            "MongoDB grid writes require bound values".into(),
        ));
    }
    let Some(value) = params.get(*index) else {
        return Err(DriverError::Unsupported(
            "MongoDB grid write has too few bound values".into(),
        ));
    };
    *index += 1;
    Ok(value.clone())
}

fn selector_from_expr(expr: &Expr, params: &[Value], index: &mut usize) -> Result<Document, DriverError> {
    match expr {
        Expr::Nested(inner) => selector_from_expr(inner, params, index),
        Expr::BinaryOp {
            left,
            op: BinaryOperator::And,
            right,
        } => {
            let mut selector = selector_from_expr(left, params, index)?;
            let right = selector_from_expr(right, params, index)?;
            for (key, value) in right {
                if selector.insert(key, value).is_some() {
                    return Err(DriverError::Unsupported(
                        "MongoDB grid write repeats a key condition".into(),
                    ));
                }
            }
            Ok(selector)
        }
        Expr::BinaryOp {
            left,
            op: BinaryOperator::Eq,
            right,
        } => {
            let Some(field) = identifier_from_expr(left) else {
                return Err(DriverError::Unsupported(
                    "MongoDB grid write has an unsupported key predicate".into(),
                ));
            };
            let raw_value = take_placeholder_value(right, params, index)?;
            if matches!(&raw_value, Value::Undecodable(kind) if kind == "missing BSON field") {
                return Ok(doc! { field: { "$exists": false } });
            }
            let value = value_to_bson(&raw_value)?;
            if matches!(value, Bson::Null) {
                Ok(explicit_null_selector(field))
            } else {
                Ok(doc! { field: value })
            }
        }
        Expr::IsNull(inner) => {
            let Some(field) = identifier_from_expr(inner) else {
                return Err(DriverError::Unsupported(
                    "MongoDB grid write has an unsupported NULL key predicate".into(),
                ));
            };
            Ok(explicit_null_selector(field))
        }
        Expr::Function(function)
            if single_identifier(&function.name).as_deref() == Some("tablepro_mongodb_exact_field_set") =>
        {
            exact_field_set_selector(function, params, index)
        }
        _ => Err(DriverError::Unsupported(
            "MongoDB grid write has an unsupported key predicate".into(),
        )),
    }
}

fn exact_field_set_selector(
    function: &sqlparser::ast::Function,
    params: &[Value],
    index: &mut usize,
) -> Result<Document, DriverError> {
    let invalid = || DriverError::Unsupported("MongoDB delete has an invalid document field-set guard".into());
    if function.parameters != FunctionArguments::None
        || function.uses_odbc_syntax
        || function.filter.is_some()
        || function.null_treatment.is_some()
        || function.over.is_some()
        || !function.within_group.is_empty()
    {
        return Err(invalid());
    }
    let FunctionArguments::List(arguments) = &function.args else {
        return Err(invalid());
    };
    if arguments.duplicate_treatment.is_some() || !arguments.clauses.is_empty() {
        return Err(invalid());
    }
    let [FunctionArg::Unnamed(FunctionArgExpr::Expr(value))] = arguments.args.as_slice() else {
        return Err(invalid());
    };
    let value = take_placeholder_value(value, params, index)?;
    let Bson::Array(expected_fields) = value_to_bson(&value)? else {
        return Err(invalid());
    };
    if expected_fields.iter().any(|field| !matches!(field, Bson::String(_))) {
        return Err(invalid());
    }
    Ok(doc! {
        "$expr": {
            "$setEquals": [
                { "$map": { "input": { "$objectToArray": "$$ROOT" }, "as": "field", "in": "$$field.k" } },
                expected_fields,
            ]
        }
    })
}

fn explicit_null_selector(field: String) -> Document {
    doc! { field: { "$eq": Bson::Null, "$exists": true, "$not": { "$type": "array" } } }
}

fn identifier_from_expr(expr: &Expr) -> Option<String> {
    match expr {
        Expr::Identifier(identifier) => Some(identifier.value.clone()),
        Expr::CompoundIdentifier(identifiers) if identifiers.len() == 1 => Some(identifiers[0].value.clone()),
        _ => None,
    }
}

#[cfg(test)]
mod value_select_tests {
    use super::*;

    #[test]
    fn value_select_binds_only_the_selected_field_and_native_id() {
        let id = "0123456789abcdef01234567";
        let parsed = parse_keyed_value_select(
            "SELECT \"payload\" FROM \"appdb\".\"records\" WHERE \"_id\" = ?",
            &[Value::Json(serde_json::json!({"$oid": id}))],
            "appdb",
        )
        .unwrap()
        .unwrap();

        assert_eq!(parsed.collection, "records");
        assert_eq!(parsed.column, "payload");
        assert_eq!(parsed.key, Bson::ObjectId(id.parse().unwrap()));
    }

    #[test]
    fn value_select_refuses_extra_predicates_and_query_shapes() {
        for sql in [
            "SELECT payload FROM records WHERE _id = ? AND tenant = ?",
            "SELECT payload FROM records WHERE _id = ? ORDER BY _id",
            "SELECT payload FROM records WHERE _id = ? UNION SELECT payload FROM other",
            "SELECT payload FROM records",
            "SELECT \"nested.value\" FROM records WHERE _id = ?",
            "SELECT \"$value\" FROM records WHERE _id = ?",
            "DELETE FROM records WHERE _id = ?",
        ] {
            assert!(
                parse_keyed_value_select(sql, &[Value::Text("id".into())], "appdb")
                    .unwrap()
                    .is_none(),
                "accepted {sql}"
            );
        }
    }
}

#[cfg(test)]
mod keyset_page_tests {
    use super::*;

    #[test]
    fn keyset_page_binds_one_id_cursor_and_window() {
        let parsed = parse_browse_page_select(
            "SELECT * FROM \"appdb\".\"records\" WHERE \"_id\" > ? LIMIT 50 OFFSET 0",
            &[Value::Text("last".into())],
            "appdb",
        )
        .unwrap()
        .unwrap();

        assert_eq!(parsed.collection, "records");
        assert_eq!(parsed.key, Some(Bson::String("last".into())));
        assert_eq!(parsed.sort, doc! { "_id": 1 });
        assert_eq!(parsed.limit, 50);
        assert_eq!(parsed.offset, 0);
    }

    #[test]
    fn sorted_keyless_page_accepts_empty_filter_and_deep_offset() {
        let parsed = parse_browse_page_select(
            "SELECT * FROM records ORDER BY rank DESC LIMIT 50 OFFSET 10000",
            &[],
            "appdb",
        )
        .unwrap();

        let parsed = parsed.unwrap();
        assert_eq!(parsed.collection, "records");
        assert!(parsed.filter.is_empty());
        assert_eq!(parsed.key, None);
        assert_eq!(parsed.sort, doc! { "rank": -1 });
        assert_eq!(parsed.limit, 50);
        assert_eq!(parsed.offset, 10_000);
    }

    #[test]
    fn sorted_page_keeps_id_predicate_as_filter_instead_of_keyset_cursor() {
        let parsed = parse_browse_page_select(
            "SELECT * FROM records WHERE _id > ? ORDER BY rank LIMIT 25 OFFSET 10000",
            &[Value::Int(100)],
            "appdb",
        )
        .unwrap()
        .unwrap();

        assert_eq!(parsed.key, None);
        assert_eq!(parsed.filter, doc! { "_id": { "$gt": 100_i64 } });
        assert_eq!(parsed.sort, doc! { "rank": 1 });
        assert_eq!(parsed.offset, 10_000);
    }

    #[test]
    fn filtered_offset_page_binds_filters_and_preserves_offset() {
        let parsed = parse_browse_page_select(
            "SELECT * FROM \"appdb\".\"records\" WHERE \"group\" = ? LIMIT 2 OFFSET 1",
            &[Value::Text("keep".into())],
            "appdb",
        )
        .unwrap()
        .unwrap();

        assert_eq!(parsed.key, None);
        assert_eq!(parsed.sort, doc! { "_id": 1 });
        assert_eq!(parsed.offset, 1);
        assert_eq!(parsed.filter, doc! { "group": { "$eq": "keep" } });
    }

    #[test]
    fn not_equal_excludes_missing_and_null_fields() {
        let parsed = parse_browse_page_select(
            "SELECT * FROM records WHERE value != ? LIMIT 2 OFFSET 0",
            &[Value::Int(7)],
            "appdb",
        )
        .unwrap()
        .unwrap();

        assert_eq!(
            parsed.filter,
            doc! { "value": { "$exists": true, "$nin": [Bson::Int64(7), Bson::Null] } }
        );
    }

    #[test]
    fn comparison_filters_refuse_null_parameters() {
        for (predicate, params) in [
            ("value != ?", vec![Value::Json(serde_json::Value::Null)]),
            ("value > ?", vec![Value::Json(serde_json::Value::Null)]),
            (
                "value BETWEEN ? AND ?",
                vec![Value::Json(serde_json::Value::Null), Value::Int(7)],
            ),
        ] {
            assert!(matches!(
                parse_browse_page_select(
                    &format!("SELECT * FROM records WHERE {predicate} LIMIT 2 OFFSET 0"),
                    &params,
                    "appdb",
                ),
                Err(DriverError::Unsupported(_))
            ));
        }
    }

    #[test]
    fn pattern_filters_translate_wildcards_and_regex_literals() {
        let parsed = parse_browse_page_select(
            "SELECT * FROM records WHERE label LIKE ? LIMIT 2 OFFSET 0",
            &[Value::Text("a.%_".into())],
            "appdb",
        )
        .unwrap()
        .unwrap();

        assert_eq!(
            parsed.filter,
            doc! { "label": { "$regex": r"^a\.[\s\S]*[\s\S]$", "$type": "string" } }
        );
    }

    #[test]
    fn escaped_case_insensitive_negated_pattern_is_string_only() {
        let parsed = parse_browse_page_select(
            "SELECT * FROM records WHERE label NOT ILIKE ? ESCAPE '!' LIMIT 2 OFFSET 0",
            &[Value::Text("A!%".into())],
            "appdb",
        )
        .unwrap()
        .unwrap();

        assert_eq!(
            parsed.filter,
            doc! { "label": { "$type": "string", "$not": { "$regex": "^A%$", "$options": "i" } } }
        );
    }

    #[test]
    fn in_filters_bind_values_and_keep_sql_null_semantics() {
        for (predicate, params, expected) in [
            (
                "value IN (?, ?, ?)",
                vec![Value::Int(4), Value::Json(serde_json::Value::Null), Value::Int(8)],
                doc! { "value": { "$in": [Bson::Int64(4), Bson::Int64(8)] } },
            ),
            (
                "value NOT IN (?, ?)",
                vec![Value::Int(4), Value::Int(8)],
                doc! { "value": { "$exists": true, "$nin": [Bson::Int64(4), Bson::Int64(8), Bson::Null] } },
            ),
            (
                "value NOT IN (?, ?)",
                vec![Value::Int(4), Value::Json(serde_json::Value::Null)],
                doc! { "_id": { "$in": [] } },
            ),
        ] {
            let sql = format!("SELECT * FROM records WHERE {predicate} LIMIT 2 OFFSET 0");
            let parsed = parse_browse_page_select(&sql, &params, "appdb").unwrap().unwrap();
            assert_eq!(parsed.filter, expected);
        }
    }

    #[test]
    fn keyset_page_refuses_other_predicates_projection_and_windows() {
        for sql in [
            "SELECT * FROM records WHERE _id > ? OR _id = ? LIMIT 50 OFFSET 0",
            "SELECT * FROM records JOIN archive ON true WHERE _id > ? LIMIT 50 OFFSET 0",
            "SELECT value FROM records WHERE _id > ? LIMIT 50 OFFSET 0",
            "SELECT * FROM records WHERE _id > ? LIMIT 0 OFFSET 0",
            "SELECT * FROM records WHERE _id > ? LIMIT 50 OFFSET 1",
        ] {
            assert!(matches!(
                parse_browse_page_select(sql, &[Value::Int(1)], "appdb"),
                Ok(None) | Err(DriverError::Unsupported(_))
            ));
        }
    }
}

#[cfg(test)]
mod filter_shape_tests {
    use super::*;

    fn filter(where_clause: &str, params: &[Value]) -> Result<Option<Document>, DriverError> {
        let sql = format!("SELECT * FROM records WHERE {where_clause} LIMIT 10 OFFSET 0");
        Ok(parse_browse_page_select(&sql, params, "appdb")?.map(|parsed| parsed.filter))
    }

    fn text(value: &str) -> Value {
        Value::Text(value.into())
    }

    #[test]
    fn null_checks_between_and_boolean_groups_translate_to_selectors() {
        let explicit_null = filter("note IS NULL", &[]).unwrap().unwrap();
        assert_eq!(explicit_null, explicit_null_selector("note".into()));
        assert_eq!(
            filter("note IS NOT NULL", &[]).unwrap().unwrap(),
            doc! { "note": { "$exists": true, "$ne": Bson::Null } }
        );
        assert_eq!(
            filter("n BETWEEN ? AND ?", &[Value::Int(1), Value::Int(5)])
                .unwrap()
                .unwrap(),
            doc! { "n": { "$gte": 1_i64, "$lte": 5_i64 } }
        );
        assert_eq!(
            filter("(a = ? OR b = ?)", &[text("x"), text("y")]).unwrap().unwrap(),
            doc! { "$or": [{ "a": { "$eq": "x" } }, { "b": { "$eq": "y" } }] }
        );
        assert_eq!(
            filter("(a > ? AND a < ?)", &[Value::Int(1), Value::Int(9)])
                .unwrap()
                .unwrap(),
            doc! { "$and": [{ "a": { "$gt": 1_i64 } }, { "a": { "$lt": 9_i64 } }] },
            "two conditions on one field must not overwrite each other"
        );
    }

    #[test]
    fn unsupported_filter_shapes_are_refused_rather_than_misread() {
        for (clause, params) in [
            ("n BETWEEN ? AND ?", vec![Value::Null, Value::Int(5)]),
            ("1 = ?", vec![text("x")]),
            ("n IS NULL OR 1 IS NULL", vec![]),
            ("lower(n) = ?", vec![text("x")]),
            ("a = ? AND b LIKE ? ESCAPE 'ab'", vec![text("x"), text("y")]),
            ("a LIKE ?", vec![Value::Int(3)]),
            ("NOT (a = ?)", vec![text("x")]),
        ] {
            let outcome = filter(clause, &params);
            assert!(
                matches!(outcome, Err(DriverError::Unsupported(_)) | Ok(None)),
                "{clause} was not refused: {outcome:?}"
            );
        }
    }

    #[test]
    fn a_filter_with_unused_or_missing_parameters_is_not_translated() {
        assert!(filter("a = ?", &[text("x"), text("extra")]).unwrap().is_none());
        assert!(filter("a = ?", &[]).is_err());
    }

    #[test]
    fn a_keyed_update_with_extra_clauses_is_not_translated() {
        let params = [text("new"), text("key")];
        let plain = parse_keyed_update("UPDATE records SET name = ? WHERE _id = ?", &params, "appdb").unwrap();
        assert!(plain.is_some());
        for sql in [
            "UPDATE records SET name = ? WHERE _id = ? LIMIT 1",
            "UPDATE records SET name = ? WHERE _id = ? ORDER BY name LIMIT 1",
            "UPDATE records SET name = ? WHERE _id = ? RETURNING name",
        ] {
            let outcome = parse_keyed_update(sql, &params, "appdb");
            assert!(
                matches!(outcome, Err(DriverError::Unsupported(_)) | Ok(None)),
                "{sql} was translated"
            );
        }
    }
}
