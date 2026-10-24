use crate::column::ColumnInfo;
use crate::edit::parse_filter_text;
use crate::filter::{BuildFilterError, Combinator, FilterOp, FilterRule, FilterSet, FilterValue, operators_for};
use crate::sql_syntax::mongo::{ShellValue, is_addressable_field, parse_value};
use crate::value::Value;

use super::shell_params::ShellParams;

/// The filter document a collection's page, count and export read
/// under: one clause per rule, then the document the user typed, joined
/// with `$and` or `$or`. `None` matches every document.
pub(crate) fn filter_document(
    columns: &[ColumnInfo],
    filter: &FilterSet,
    params: &mut ShellParams,
) -> Result<Option<ShellValue>, BuildFilterError> {
    if filter.is_empty() {
        return Ok(None);
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
        if !is_addressable_field(&column.name) {
            return Err(BuildFilterError::UnaddressableField(column.name.clone()));
        }
        clauses.push(field(&column.name, rule_condition(column, rule, params)?));
    }
    if let Some(raw) = filter.raw_predicate() {
        clauses.push(typed_document(raw)?);
    }
    let joiner = match filter.combinator {
        Combinator::And => "$and",
        Combinator::Or => "$or",
    };
    Ok(Some(match clauses.len() {
        1 => clauses.remove(0),
        _ => field(joiner, ShellValue::Array(clauses)),
    }))
}

/// The document typed into the filter strip, which has to be one object.
/// It is read here so a filter that is not one fails before a read.
pub(crate) fn typed_document(text: &str) -> Result<ShellValue, BuildFilterError> {
    let value = parse_value(text).map_err(BuildFilterError::RawDocument)?;
    match value {
        ShellValue::Object(_) => Ok(value),
        _ => Err(BuildFilterError::RawNotDocument),
    }
}

pub(crate) fn field(name: &str, value: ShellValue) -> ShellValue {
    ShellValue::Object(vec![(name.to_owned(), value)])
}

fn operator(name: &str, value: ShellValue) -> ShellValue {
    field(name, value)
}

fn rule_condition(
    column: &ColumnInfo,
    rule: &FilterRule,
    params: &mut ShellParams,
) -> Result<ShellValue, BuildFilterError> {
    let typed = |params: &mut ShellParams, text: &str| -> Result<ShellValue, BuildFilterError> {
        let value = parse_filter_text(text, &column.column_type).map_err(|source| BuildFilterError::Parse {
            column: column.name.clone(),
            source,
        })?;
        Ok(params.bind(value, Some(column))?)
    };
    let pattern = |params: &mut ShellParams, regex: String, options: &str| -> Result<ShellValue, BuildFilterError> {
        Ok(ShellValue::Object(vec![
            ("$regex".to_owned(), params.bind(Value::Text(regex), None)?),
            ("$options".to_owned(), ShellValue::string(options)),
        ]))
    };
    Ok(match rule.op {
        FilterOp::IsNull => ShellValue::Null,
        FilterOp::IsNotNull => operator("$ne", ShellValue::Null),
        FilterOp::Eq => typed(params, single(rule)?)?,
        FilterOp::NotEq => operator("$ne", typed(params, single(rule)?)?),
        FilterOp::Lt => operator("$lt", typed(params, single(rule)?)?),
        FilterOp::LtEq => operator("$lte", typed(params, single(rule)?)?),
        FilterOp::Gt => operator("$gt", typed(params, single(rule)?)?),
        FilterOp::GtEq => operator("$gte", typed(params, single(rule)?)?),
        FilterOp::Contains => pattern(params, regex_escape(single(rule)?), "")?,
        FilterOp::StartsWith => pattern(params, format!("^{}", regex_escape(single(rule)?)), "")?,
        FilterOp::EndsWith => pattern(params, format!("{}$", regex_escape(single(rule)?)), "")?,
        FilterOp::Like => pattern(params, like_regex(single(rule)?), "s")?,
        FilterOp::NotLike => operator("$not", pattern(params, like_regex(single(rule)?), "s")?),
        FilterOp::Ilike => pattern(params, like_regex(single(rule)?), "is")?,
        FilterOp::In | FilterOp::NotIn => {
            let FilterValue::List(items) = rule.value.as_ref().ok_or(BuildFilterError::MissingValue(rule.op))? else {
                return Err(BuildFilterError::WrongValueShape { op: rule.op });
            };
            if items.is_empty() {
                return Err(BuildFilterError::EmptyInList);
            }
            let bound = items
                .iter()
                .map(|item| typed(params, item))
                .collect::<Result<Vec<_>, _>>()?;
            let name = if rule.op == FilterOp::In { "$in" } else { "$nin" };
            operator(name, ShellValue::Array(bound))
        }
        FilterOp::Between => {
            let FilterValue::Pair(low, high) = rule.value.as_ref().ok_or(BuildFilterError::BetweenMissingBound)? else {
                return Err(BuildFilterError::WrongValueShape { op: rule.op });
            };
            ShellValue::Object(vec![
                ("$gte".to_owned(), typed(params, low)?),
                ("$lte".to_owned(), typed(params, high)?),
            ])
        }
    })
}

fn single(rule: &FilterRule) -> Result<&String, BuildFilterError> {
    match &rule.value {
        Some(FilterValue::Single(text)) => Ok(text),
        Some(_) => Err(BuildFilterError::WrongValueShape { op: rule.op }),
        None => Err(BuildFilterError::MissingValue(rule.op)),
    }
}

/// Text the user typed, matched as it is: every ASCII punctuation mark is
/// escaped, which the server's regular expressions read as itself.
fn regex_escape(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for c in text.chars() {
        if c.is_ascii_punctuation() {
            escaped.push('\\');
        }
        escaped.push(c);
    }
    escaped
}

/// A LIKE pattern as a regular expression over the whole value: `%` is
/// any run, `_` any one character and a backslash takes the next one as
/// it is.
fn like_regex(pattern: &str) -> String {
    let mut regex = String::from("^");
    let mut chars = pattern.chars();
    while let Some(c) = chars.next() {
        match c {
            '%' => regex.push_str(".*"),
            '_' => regex.push('.'),
            '\\' => {
                if let Some(next) = chars.next() {
                    regex.push_str(&regex_escape(&next.to_string()));
                }
            }
            other => regex.push_str(&regex_escape(&other.to_string())),
        }
    }
    regex.push('$');
    regex
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pattern_is_the_text_typed_or_the_like_rules() {
        assert_eq!(regex_escape("a.b*(c)"), r"a\.b\*\(c\)");
        assert_eq!(regex_escape("é ü"), "é ü");
        assert_eq!(like_regex("50\\%_x%"), r"^50\%.x.*$");
        assert_eq!(like_regex("a.b"), r"^a\.b$");
    }

    #[test]
    fn a_typed_filter_has_to_be_one_document() {
        assert!(typed_document("{qty: {$gt: 1}}").is_ok());
        assert_eq!(typed_document("[1]"), Err(BuildFilterError::RawNotDocument));
        assert!(matches!(
            typed_document("{qty: "),
            Err(BuildFilterError::RawDocument(_))
        ));
        assert!(matches!(
            typed_document("{a: 1}); db.x.drop("),
            Err(BuildFilterError::RawDocument(_))
        ));
    }
}
