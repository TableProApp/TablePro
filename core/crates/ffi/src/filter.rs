use tablepro_core::ColumnInfo;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::filter::{Combinator, FilterOp, FilterRule, FilterSet, FilterValue};
use tablepro_core::sql_syntax::SqlGrammar;

use crate::error::CoreError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FilterOpTag {
    Eq,
    NotEq,
    Lt,
    LtEq,
    Gt,
    GtEq,
    // The core adds the wildcards and escapes the user's own, so the text matches as typed.
    Contains,
    StartsWith,
    EndsWith,
    // The user's own pattern, wildcards and all.
    Like,
    NotLike,
    Ilike,
    IsNull,
    IsNotNull,
    In,
    NotIn,
    Between,
}

// What a rule compares against, as typed. The core parses it as the column's type and binds it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FilterValueArg {
    Single { value: String },
    Pair { low: String, high: String },
    List { values: Vec<String> },
}

// `value` is None for the null tests.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FilterRuleArg {
    pub column: String,
    pub op: FilterOpTag,
    pub value: Option<FilterValueArg>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CombinatorTag {
    And,
    Or,
}

// `raw_sql` joins the rules as written, so the core reads it as exactly one expression first.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableFilterArg {
    pub combinator: CombinatorTag,
    pub rules: Vec<FilterRuleArg>,
    pub raw_sql: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FilterColumn {
    pub name: String,
    pub operators: Vec<FilterOpTag>,
}

// The operators the engine offers per column, the combinators it has, and whether it takes a raw SQL predicate.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FilterChoices {
    pub columns: Vec<FilterColumn>,
    pub combinators: Vec<CombinatorTag>,
    pub accepts_raw_sql: bool,
}

// A document engine takes a query document in place of SQL, which a field named for SQL would misname.
pub(crate) fn choices(dialect: &dyn SqlDialect, columns: &[ColumnInfo]) -> FilterChoices {
    FilterChoices {
        columns: columns
            .iter()
            .map(|column| FilterColumn {
                name: column.name.clone(),
                operators: dialect
                    .filter_operators(column)
                    .iter()
                    .copied()
                    .map(FilterOpTag::from)
                    .collect(),
            })
            .collect(),
        combinators: dialect
            .filter_combinators()
            .iter()
            .copied()
            .map(CombinatorTag::from)
            .collect(),
        accepts_raw_sql: takes_raw_sql(dialect),
    }
}

// A session file written by hand can hold any text, and an engine that is not SQL reads it in its own language.
pub(crate) fn filter_set(filter: Option<TableFilterArg>, dialect: &dyn SqlDialect) -> Result<FilterSet, CoreError> {
    let Some(filter) = filter else {
        return Ok(FilterSet::default());
    };
    let raw = filter.raw_sql.as_deref().is_some_and(|sql| !sql.trim().is_empty());
    if raw && !takes_raw_sql(dialect) {
        return Err(CoreError::failed(
            "filter.raw_unsupported",
            "this engine takes no SQL condition",
        ));
    }
    Ok(filter.into())
}

fn takes_raw_sql(dialect: &dyn SqlDialect) -> bool {
    SqlGrammar::SQL.contains(&dialect.grammar())
}

impl From<FilterSet> for TableFilterArg {
    fn from(filter: FilterSet) -> Self {
        Self {
            combinator: filter.combinator.into(),
            rules: filter
                .rules
                .into_iter()
                .map(|rule| FilterRuleArg {
                    column: rule.column,
                    op: rule.op.into(),
                    value: rule.value.map(|value| match value {
                        FilterValue::Single(value) => FilterValueArg::Single { value },
                        FilterValue::Pair(low, high) => FilterValueArg::Pair { low, high },
                        FilterValue::List(values) => FilterValueArg::List { values },
                    }),
                })
                .collect(),
            raw_sql: filter.extra_sql,
        }
    }
}

impl From<TableFilterArg> for FilterSet {
    fn from(filter: TableFilterArg) -> Self {
        Self {
            combinator: filter.combinator.into(),
            rules: filter.rules.into_iter().map(FilterRule::from).collect(),
            extra_sql: filter.raw_sql,
        }
    }
}

impl From<FilterRuleArg> for FilterRule {
    fn from(rule: FilterRuleArg) -> Self {
        Self {
            column: rule.column,
            op: rule.op.into(),
            value: rule.value.map(FilterValue::from),
        }
    }
}

impl From<FilterValueArg> for FilterValue {
    fn from(value: FilterValueArg) -> Self {
        match value {
            FilterValueArg::Single { value } => Self::Single(value),
            FilterValueArg::Pair { low, high } => Self::Pair(low, high),
            FilterValueArg::List { values } => Self::List(values),
        }
    }
}

impl From<CombinatorTag> for Combinator {
    fn from(combinator: CombinatorTag) -> Self {
        match combinator {
            CombinatorTag::And => Self::And,
            CombinatorTag::Or => Self::Or,
        }
    }
}

impl From<Combinator> for CombinatorTag {
    fn from(combinator: Combinator) -> Self {
        match combinator {
            Combinator::And => Self::And,
            Combinator::Or => Self::Or,
        }
    }
}

impl From<FilterOpTag> for FilterOp {
    fn from(op: FilterOpTag) -> Self {
        match op {
            FilterOpTag::Eq => Self::Eq,
            FilterOpTag::NotEq => Self::NotEq,
            FilterOpTag::Lt => Self::Lt,
            FilterOpTag::LtEq => Self::LtEq,
            FilterOpTag::Gt => Self::Gt,
            FilterOpTag::GtEq => Self::GtEq,
            FilterOpTag::Contains => Self::Contains,
            FilterOpTag::StartsWith => Self::StartsWith,
            FilterOpTag::EndsWith => Self::EndsWith,
            FilterOpTag::Like => Self::Like,
            FilterOpTag::NotLike => Self::NotLike,
            FilterOpTag::Ilike => Self::Ilike,
            FilterOpTag::IsNull => Self::IsNull,
            FilterOpTag::IsNotNull => Self::IsNotNull,
            FilterOpTag::In => Self::In,
            FilterOpTag::NotIn => Self::NotIn,
            FilterOpTag::Between => Self::Between,
        }
    }
}

impl From<FilterOp> for FilterOpTag {
    fn from(op: FilterOp) -> Self {
        match op {
            FilterOp::Eq => Self::Eq,
            FilterOp::NotEq => Self::NotEq,
            FilterOp::Lt => Self::Lt,
            FilterOp::LtEq => Self::LtEq,
            FilterOp::Gt => Self::Gt,
            FilterOp::GtEq => Self::GtEq,
            FilterOp::Contains => Self::Contains,
            FilterOp::StartsWith => Self::StartsWith,
            FilterOp::EndsWith => Self::EndsWith,
            FilterOp::Like => Self::Like,
            FilterOp::NotLike => Self::NotLike,
            FilterOp::Ilike => Self::Ilike,
            FilterOp::IsNull => Self::IsNull,
            FilterOp::IsNotNull => Self::IsNotNull,
            FilterOp::In => Self::In,
            FilterOp::NotIn => Self::NotIn,
            FilterOp::Between => Self::Between,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EVERY_OP: [FilterOpTag; 17] = [
        FilterOpTag::Eq,
        FilterOpTag::NotEq,
        FilterOpTag::Lt,
        FilterOpTag::LtEq,
        FilterOpTag::Gt,
        FilterOpTag::GtEq,
        FilterOpTag::Contains,
        FilterOpTag::StartsWith,
        FilterOpTag::EndsWith,
        FilterOpTag::Like,
        FilterOpTag::NotLike,
        FilterOpTag::Ilike,
        FilterOpTag::IsNull,
        FilterOpTag::IsNotNull,
        FilterOpTag::In,
        FilterOpTag::NotIn,
        FilterOpTag::Between,
    ];

    #[test]
    fn every_operator_crosses_and_comes_back_as_itself() {
        for op in EVERY_OP {
            assert_eq!(FilterOpTag::from(FilterOp::from(op)), op);
        }
    }

    #[test]
    fn a_filter_keeps_its_rules_in_order_with_their_values_and_its_sql() {
        let filter = TableFilterArg {
            combinator: CombinatorTag::Or,
            rules: vec![
                FilterRuleArg {
                    column: "age".to_owned(),
                    op: FilterOpTag::Between,
                    value: Some(FilterValueArg::Pair {
                        low: "18".to_owned(),
                        high: "30".to_owned(),
                    }),
                },
                FilterRuleArg {
                    column: "note".to_owned(),
                    op: FilterOpTag::IsNull,
                    value: None,
                },
                FilterRuleArg {
                    column: "id".to_owned(),
                    op: FilterOpTag::In,
                    value: Some(FilterValueArg::List {
                        values: vec!["1".to_owned(), "2".to_owned()],
                    }),
                },
            ],
            raw_sql: Some("length(name) > 3".to_owned()),
        };

        let set = FilterSet::from(filter);

        assert_eq!(set.combinator, Combinator::Or);
        assert_eq!(
            set.rules,
            [
                FilterRule {
                    column: "age".to_owned(),
                    op: FilterOp::Between,
                    value: Some(FilterValue::Pair("18".to_owned(), "30".to_owned())),
                },
                FilterRule {
                    column: "note".to_owned(),
                    op: FilterOp::IsNull,
                    value: None,
                },
                FilterRule {
                    column: "id".to_owned(),
                    op: FilterOp::In,
                    value: Some(FilterValue::List(vec!["1".to_owned(), "2".to_owned()])),
                },
            ]
        );
        assert_eq!(set.raw_predicate(), Some("length(name) > 3"));
    }

    #[cfg(feature = "engines")]
    #[test]
    fn raw_text_reaches_only_an_engine_that_reads_sql() {
        let raw = |sql: &str| TableFilterArg {
            combinator: CombinatorTag::And,
            rules: Vec::new(),
            raw_sql: Some(sql.to_owned()),
        };

        let refused = filter_set(
            Some(raw("{ \"$where\": \"true\" }")),
            &tablepro_driver_mongodb::MongoDialect,
        )
        .unwrap_err();
        let blank = filter_set(Some(raw("  ")), &tablepro_driver_mongodb::MongoDialect).unwrap();

        assert_eq!(refused.code(), "filter.raw_unsupported");
        assert!(blank.is_empty());
    }
}
