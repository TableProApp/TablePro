use crate::column::ColumnInfo;
use crate::dialect::{BindTarget, LikeForm, SqlDialect};
use crate::edit::parse_filter_text;
use crate::statement::StatementBuilder;
use crate::value::Value;

use super::{
    BuildFilterError, Combinator, FilterOp, FilterRule, FilterSet, FilterValue, operators_for, validate_raw_predicate,
};

/// Write the predicate for a filter set into `builder`.
///
/// Returns whether anything was written, so the caller knows whether a
/// WHERE belongs in front of it. Every value the user typed is parsed
/// as the column's type and bound; only the raw SQL predicate, which
/// the user wrote as SQL on purpose, is written verbatim, and only once
/// it parses as one expression. On an error the builder holds part of
/// the predicate and should be dropped.
pub fn build_filter(
    builder: &mut StatementBuilder,
    dialect: &dyn SqlDialect,
    columns: &[ColumnInfo],
    filter: &FilterSet,
) -> Result<bool, BuildFilterError> {
    if filter.is_empty() {
        return Ok(false);
    }
    let raw = filter.raw_predicate();
    if let Some(raw) = raw {
        validate_raw_predicate(dialect, raw).map_err(BuildFilterError::RawPredicate)?;
    }

    let mut clauses = Vec::with_capacity(filter.len());
    for rule in &filter.rules {
        let column = columns
            .iter()
            .find(|column| column.name == rule.column)
            .ok_or_else(|| BuildFilterError::UnknownColumn(rule.column.clone()))?;
        if !operators_for(&column.column_type.kind).contains(&rule.op) {
            return Err(BuildFilterError::OperatorNotAllowed {
                column: rule.column.clone(),
                op: rule.op,
            });
        }
        clauses.push(rule_sql(builder, dialect, column, rule)?);
    }
    if let Some(raw) = raw {
        clauses.push(format!("({raw})"));
    }

    let joiner = match filter.combinator {
        Combinator::And => " AND ",
        Combinator::Or => " OR ",
    };
    builder.push_sql(&clauses.join(joiner));
    Ok(true)
}

fn rule_sql(
    builder: &mut StatementBuilder,
    dialect: &dyn SqlDialect,
    column: &ColumnInfo,
    rule: &FilterRule,
) -> Result<String, BuildFilterError> {
    let column_sql = dialect.quote_identifier(&column.name);
    match rule.op {
        // A null test has no value to bind, so it never takes a marker.
        FilterOp::IsNull => Ok(format!("{column_sql} IS NULL")),
        FilterOp::IsNotNull => Ok(format!("{column_sql} IS NOT NULL")),
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Lt | FilterOp::LtEq | FilterOp::Gt | FilterOp::GtEq => {
            let marker = bind_typed(builder, dialect, column, require_single(rule)?)?;
            Ok(format!("{column_sql} {} {marker}", comparison_operator(rule.op)))
        }
        FilterOp::Contains | FilterOp::StartsWith | FilterOp::EndsWith => {
            // The app is building the pattern, so what the user typed
            // is data: a search for "50%" must not match everything.
            let escaped = dialect.escape_like_text(require_single(rule)?);
            let pattern = match rule.op {
                FilterOp::Contains => format!("%{escaped}%"),
                FilterOp::StartsWith => format!("{escaped}%"),
                _ => format!("%{escaped}"),
            };
            let marker = builder.bind(dialect, Value::Text(pattern), BindTarget::Pattern)?;
            Ok(dialect.like_predicate(&column_sql, &marker, LikeForm::contains()))
        }
        FilterOp::Like | FilterOp::NotLike => {
            // The user typed the wildcards, so they stay.
            let pattern = Value::Text(require_single(rule)?.clone());
            let marker = builder.bind(dialect, pattern, BindTarget::Pattern)?;
            let form = LikeForm::raw(rule.op == FilterOp::NotLike);
            Ok(dialect.like_predicate(&column_sql, &marker, form))
        }
        FilterOp::Ilike => {
            let pattern = Value::Text(require_single(rule)?.clone());
            let marker = builder.bind(dialect, pattern, BindTarget::Pattern)?;
            Ok(dialect.like_predicate(&column_sql, &marker, LikeForm::insensitive(false)))
        }
        FilterOp::In | FilterOp::NotIn => {
            let list = require_list(rule)?;
            if list.is_empty() {
                return Err(BuildFilterError::EmptyInList);
            }
            let markers = list
                .iter()
                .map(|text| bind_typed(builder, dialect, column, text))
                .collect::<Result<Vec<_>, _>>()?;
            let keyword = match rule.op {
                FilterOp::In => "IN",
                _ => "NOT IN",
            };
            Ok(format!("{column_sql} {keyword} ({})", markers.join(", ")))
        }
        FilterOp::Between => {
            let (low, high) = require_pair(rule)?;
            let low = bind_typed(builder, dialect, column, low)?;
            let high = bind_typed(builder, dialect, column, high)?;
            Ok(format!("{column_sql} BETWEEN {low} AND {high}"))
        }
    }
}

fn comparison_operator(op: FilterOp) -> &'static str {
    match op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Lt => "<",
        FilterOp::LtEq => "<=",
        FilterOp::Gt => ">",
        _ => ">=",
    }
}

/// Bind text as the column's own type, so a number compares as a
/// number rather than as its decimal spelling.
fn bind_typed(
    builder: &mut StatementBuilder,
    dialect: &dyn SqlDialect,
    column: &ColumnInfo,
    text: &str,
) -> Result<String, BuildFilterError> {
    let value = parse_filter_text(text, &column.column_type).map_err(|source| BuildFilterError::Parse {
        column: column.name.clone(),
        source,
    })?;
    Ok(builder.bind(dialect, value, BindTarget::Column(column))?)
}

fn require_single(rule: &FilterRule) -> Result<&String, BuildFilterError> {
    match rule.value.as_ref() {
        Some(FilterValue::Single(text)) => Ok(text),
        Some(_) => Err(BuildFilterError::WrongValueShape { op: rule.op }),
        None => Err(BuildFilterError::MissingValue(rule.op)),
    }
}

fn require_pair(rule: &FilterRule) -> Result<(&String, &String), BuildFilterError> {
    match rule.value.as_ref() {
        Some(FilterValue::Pair(low, high)) if low.trim().is_empty() || high.trim().is_empty() => {
            Err(BuildFilterError::BetweenMissingBound)
        }
        Some(FilterValue::Pair(low, high)) => Ok((low, high)),
        Some(_) => Err(BuildFilterError::WrongValueShape { op: rule.op }),
        None => Err(BuildFilterError::MissingValue(rule.op)),
    }
}

fn require_list(rule: &FilterRule) -> Result<&Vec<String>, BuildFilterError> {
    match rule.value.as_ref() {
        Some(FilterValue::List(list)) => Ok(list),
        Some(_) => Err(BuildFilterError::WrongValueShape { op: rule.op }),
        None => Err(BuildFilterError::MissingValue(rule.op)),
    }
}

#[cfg(test)]
mod tests {
    use crate::column::{
        ColumnDefault, ColumnInfo, ColumnKind, ColumnType, IntegerKind, IntegerWidth, ReadForm, TextLength,
    };
    use crate::dialect::{TestDialect, TestMarkers};
    use crate::statement::Statement;

    use super::*;

    fn column(name: &str, kind: ColumnKind) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType {
                name: "t".to_owned(),
                kind,
                catalog: None,
                dynamic_storage: false,
                read_form: ReadForm::Native,
            },
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn columns() -> Vec<ColumnInfo> {
        vec![
            column(
                "name",
                ColumnKind::Text {
                    length: TextLength::Varying(50),
                },
            ),
            column(
                "age",
                ColumnKind::Integer(IntegerKind {
                    width: IntegerWidth::W32,
                    signed: true,
                }),
            ),
            column(
                "photo",
                ColumnKind::Bytes {
                    length: TextLength::Unbounded,
                },
            ),
        ]
    }

    fn rule(column: &str, op: FilterOp, value: Option<FilterValue>) -> FilterSet {
        FilterSet {
            combinator: Combinator::And,
            rules: vec![FilterRule {
                column: column.to_owned(),
                op,
                value,
            }],
            extra_sql: None,
        }
    }

    fn single(column: &str, op: FilterOp, text: &str) -> FilterSet {
        rule(column, op, Some(FilterValue::Single(text.to_owned())))
    }

    fn build_with(dialect: &TestDialect, set: &FilterSet) -> Result<Option<Statement>, BuildFilterError> {
        let mut builder = StatementBuilder::new();
        let wrote = build_filter(&mut builder, dialect, &columns(), set)?;
        Ok(wrote.then(|| builder.finish()))
    }

    fn build(set: &FilterSet) -> Result<Option<Statement>, BuildFilterError> {
        build_with(&TestDialect::exact(), set)
    }

    fn built(set: &FilterSet) -> Statement {
        match build(set) {
            Ok(Some(statement)) => statement,
            other => panic!("expected a predicate, got {other:?}"),
        }
    }

    #[test]
    fn build_filter_skips_where_for_empty_set() {
        let mut builder = StatementBuilder::new();

        let wrote =
            build_filter(&mut builder, &TestDialect::exact(), &columns(), &FilterSet::default()).expect("an empty set");

        assert!(!wrote);
        assert_eq!(builder.finish().sql(), "", "an empty filter wrote SQL");
    }

    #[test]
    fn contains_escapes_through_dialect() {
        let statement = built(&single("name", FilterOp::Contains, "50%"));

        assert_eq!(statement.sql(), r#""name" LIKE $1 ESCAPE '!'"#);
        assert_eq!(
            statement.params()[0].value(),
            &Value::Text("%50!%%".to_owned()),
            "the user's percent was treated as a wildcard"
        );
    }

    #[test]
    fn like_is_raw_and_unescaped() {
        let statement = built(&single("name", FilterOp::Like, "a%b"));

        assert_eq!(
            statement.sql(),
            r#""name" LIKE $1"#,
            "a user-typed pattern got an ESCAPE clause"
        );
        assert_eq!(statement.params()[0].value(), &Value::Text("a%b".to_owned()));
    }

    #[test]
    fn ilike_uses_insensitive_form() {
        let statement = built(&single("name", FilterOp::Ilike, "abc"));

        assert_eq!(statement.sql(), r#""name" ILIKE $1"#);
    }

    #[test]
    fn in_list_marker_per_element() {
        let set = rule(
            "age",
            FilterOp::In,
            Some(FilterValue::List(vec!["1".to_owned(), "2".to_owned(), "3".to_owned()])),
        );

        let statement = built(&set);

        assert_eq!(statement.sql(), r#""age" IN ($1, $2, $3)"#);
        assert_eq!(statement.params().len(), 3);
        assert_eq!(statement.params()[2].value(), &Value::Int(3));
    }

    #[test]
    fn an_empty_in_list_is_an_error() {
        let set = rule("age", FilterOp::In, Some(FilterValue::List(Vec::new())));

        assert_eq!(build(&set).expect_err("an empty list"), BuildFilterError::EmptyInList);
    }

    #[test]
    fn between_rejects_blank_bound() {
        let set = rule(
            "age",
            FilterOp::Between,
            Some(FilterValue::Pair("1".to_owned(), "  ".to_owned())),
        );

        assert_eq!(
            build(&set).expect_err("a blank bound"),
            BuildFilterError::BetweenMissingBound
        );
    }

    #[test]
    fn operator_not_allowed_for_bytes() {
        let error = build(&single("photo", FilterOp::Contains, "ff")).expect_err("text search on a blob");

        assert!(
            matches!(error, BuildFilterError::OperatorNotAllowed { .. }),
            "{error:?}"
        );
        // The null tests still apply, because a blob can be absent.
        assert!(build(&rule("photo", FilterOp::IsNull, None)).is_ok());
    }

    #[test]
    fn a_value_that_is_not_of_the_columns_type_is_reported_before_the_server_sees_it() {
        let error = build(&single("age", FilterOp::Eq, "seven")).expect_err("text in a number column");

        assert!(matches!(error, BuildFilterError::Parse { .. }), "{error:?}");
    }

    #[test]
    fn a_null_test_binds_nothing() {
        let statement = built(&rule("name", FilterOp::IsNull, None));

        assert_eq!(statement.sql(), r#""name" IS NULL"#);
        assert!(statement.params().is_empty(), "a null test bound a parameter");
    }

    #[test]
    fn raw_sql_is_joined_with_the_rules_and_never_bound() {
        let set = FilterSet {
            combinator: Combinator::Or,
            rules: vec![FilterRule {
                column: "age".to_owned(),
                op: FilterOp::Gt,
                value: Some(FilterValue::Single("18".to_owned())),
            }],
            extra_sql: Some("length(name) > 3".to_owned()),
        };

        let statement = built(&set);

        assert_eq!(statement.sql(), r#""age" > $1 OR (length(name) > 3)"#);
        assert_eq!(statement.params().len(), 1);
    }

    #[test]
    fn raw_sql_that_is_not_one_expression_is_refused() {
        let set = FilterSet {
            extra_sql: Some("1=1); DELETE FROM t; SELECT (1".to_owned()),
            ..FilterSet::default()
        };

        assert!(matches!(
            build(&set).expect_err("a second statement"),
            BuildFilterError::RawPredicate(_)
        ));
    }

    #[test]
    fn a_rule_on_a_column_the_table_lost_is_an_error() {
        let error = build(&single("gone", FilterOp::Eq, "1")).expect_err("a missing column");

        assert!(matches!(error, BuildFilterError::UnknownColumn(_)), "{error:?}");
    }

    #[test]
    fn positional_markers_follow_the_rule_order() {
        let dialect = TestDialect::exact().with_markers(TestMarkers::Positional);
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![
                FilterRule {
                    column: "age".to_owned(),
                    op: FilterOp::Between,
                    value: Some(FilterValue::Pair("1".to_owned(), "9".to_owned())),
                },
                FilterRule {
                    column: "name".to_owned(),
                    op: FilterOp::StartsWith,
                    value: Some(FilterValue::Single("a".to_owned())),
                },
            ],
            extra_sql: None,
        };

        let statement = build_with(&dialect, &set).expect("the filter").expect("a predicate");

        assert_eq!(statement.sql(), r#""age" BETWEEN ? AND ? AND "name" LIKE ? ESCAPE '!'"#);
        let values: Vec<_> = statement.params().iter().map(|param| param.value().clone()).collect();
        assert_eq!(values, vec![Value::Int(1), Value::Int(9), Value::Text("a%".to_owned())]);
    }
}
