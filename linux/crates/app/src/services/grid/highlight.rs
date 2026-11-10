use std::borrow::Cow;

use serde::{Deserialize, Serialize};
use tablepro_core::column::ColumnKind;
use tablepro_core::filter::{FilterOp, FilterValue};
use tablepro_core::value::SqlDecimal;
use uuid::Uuid;

use super::GridColumn;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HighlightColor {
    Red,
    Orange,
    Yellow,
    Green,
    Blue,
    Purple,
    Gray,
}

impl HighlightColor {
    pub const ALL: [Self; 7] = [
        Self::Red,
        Self::Orange,
        Self::Yellow,
        Self::Green,
        Self::Blue,
        Self::Purple,
        Self::Gray,
    ];

    pub fn css_class(self) -> &'static str {
        match self {
            Self::Red => "tp-hl-red",
            Self::Orange => "tp-hl-orange",
            Self::Yellow => "tp-hl-yellow",
            Self::Green => "tp-hl-green",
            Self::Blue => "tp-hl-blue",
            Self::Purple => "tp-hl-purple",
            Self::Gray => "tp-hl-gray",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HighlightTarget {
    Row,
    Cell,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HighlightRule {
    pub id: Uuid,
    pub enabled: bool,
    pub column: String,
    #[serde(default)]
    pub column_occurrence: usize,
    pub op: FilterOp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<FilterValue>,
    pub case_sensitive: bool,
    pub color: HighlightColor,
    pub target: HighlightTarget,
}

impl HighlightRule {
    pub fn new(column: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            enabled: true,
            column: column.into(),
            column_occurrence: 0,
            op: FilterOp::Eq,
            value: Some(FilterValue::Single(String::new())),
            case_sensitive: false,
            color: HighlightColor::Yellow,
            target: HighlightTarget::Row,
        }
    }

    pub fn is_valid(&self) -> bool {
        match (self.op, &self.value) {
            (FilterOp::IsNull | FilterOp::IsNotNull, _) => true,
            (FilterOp::In | FilterOp::NotIn, Some(FilterValue::List(items))) => !items.is_empty(),
            (FilterOp::Between, Some(FilterValue::Pair(low, high))) => !low.is_empty() && !high.is_empty(),
            (FilterOp::In | FilterOp::NotIn | FilterOp::Between, _) => false,
            (_, Some(FilterValue::Single(text))) => !text.is_empty(),
            _ => false,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RowHighlight {
    pub row: Option<HighlightColor>,
    pub cells: Vec<(usize, HighlightColor)>,
}

impl RowHighlight {
    #[cfg(test)]
    pub fn is_none(&self) -> bool {
        self.row.is_none() && self.cells.is_empty()
    }

    pub fn color_of(&self, column: usize) -> Option<HighlightColor> {
        self.cells
            .iter()
            .find(|(at, _)| *at == column)
            .map(|(_, color)| *color)
            .or(self.row)
    }
}

#[derive(Debug, Clone)]
pub enum HighlightValue<'a> {
    Unavailable,
    Null,
    NonText,
    Text(Cow<'a, str>),
}

struct Compiled {
    column: usize,
    kind: ColumnKind,
    rule: HighlightRule,
}

#[derive(Default)]
pub struct HighlightRules {
    compiled: Vec<Compiled>,
    columns: Vec<usize>,
}

impl HighlightRules {
    pub fn compile(rules: &[HighlightRule], columns: &[GridColumn]) -> Self {
        let compiled: Vec<Compiled> = rules
            .iter()
            .filter(|rule| rule.enabled && rule.is_valid())
            .filter_map(|rule| {
                columns
                    .iter()
                    .enumerate()
                    .filter(|(_, column)| column.name == rule.column)
                    .nth(rule.column_occurrence)
                    .map(|(column, definition)| Compiled {
                        column,
                        kind: definition.column_type.kind.clone(),
                        rule: rule.clone(),
                    })
            })
            .collect();
        let mut columns: Vec<usize> = compiled.iter().map(|rule| rule.column).collect();
        columns.sort_unstable();
        columns.dedup();
        Self { compiled, columns }
    }

    pub fn is_empty(&self) -> bool {
        self.compiled.is_empty()
    }

    pub fn columns(&self) -> impl Iterator<Item = usize> + '_ {
        self.columns.iter().copied()
    }

    pub fn highlight(&self, cells: &[HighlightValue<'_>]) -> RowHighlight {
        let mut found = RowHighlight::default();
        for compiled in &self.compiled {
            let Some(value) = cells.get(compiled.column) else {
                continue;
            };
            if !matches(&compiled.rule, &compiled.kind, value) {
                continue;
            }
            match compiled.rule.target {
                HighlightTarget::Row if found.row.is_none() => found.row = Some(compiled.rule.color),
                HighlightTarget::Cell if !found.cells.iter().any(|(at, _)| *at == compiled.column) => {
                    found.cells.push((compiled.column, compiled.rule.color));
                }
                _ => {}
            }
        }
        found
    }
}

fn matches(rule: &HighlightRule, kind: &ColumnKind, value: &HighlightValue<'_>) -> bool {
    let text = match value {
        HighlightValue::Unavailable => return false,
        HighlightValue::Null => return rule.op == FilterOp::IsNull,
        HighlightValue::NonText => return rule.op == FilterOp::IsNotNull,
        HighlightValue::Text(text) => text.as_ref(),
    };
    let sensitive = rule.case_sensitive;
    let same = |a: &str, b: &str| compare(a, b, sensitive, kind.is_numeric()) == std::cmp::Ordering::Equal;
    let single = || match &rule.value {
        Some(FilterValue::Single(operand)) => Some(operand.as_str()),
        _ => None,
    };
    match rule.op {
        FilterOp::IsNull => false,
        FilterOp::IsNotNull => true,
        FilterOp::Eq => single().is_some_and(|operand| same(text, operand)),
        FilterOp::NotEq => single().is_some_and(|operand| !same(text, operand)),
        FilterOp::Lt => single().is_some_and(|operand| compare(text, operand, sensitive, true).is_lt()),
        FilterOp::LtEq => single().is_some_and(|operand| compare(text, operand, sensitive, true).is_le()),
        FilterOp::Gt => single().is_some_and(|operand| compare(text, operand, sensitive, true).is_gt()),
        FilterOp::GtEq => single().is_some_and(|operand| compare(text, operand, sensitive, true).is_ge()),
        FilterOp::Contains => single().is_some_and(|operand| fold(text, sensitive).contains(&fold(operand, sensitive))),
        FilterOp::StartsWith => {
            single().is_some_and(|operand| fold(text, sensitive).starts_with(&fold(operand, sensitive)))
        }
        FilterOp::EndsWith => {
            single().is_some_and(|operand| fold(text, sensitive).ends_with(&fold(operand, sensitive)))
        }
        FilterOp::Like => single().is_some_and(|pattern| like(text, pattern, sensitive)),
        FilterOp::NotLike => single().is_some_and(|pattern| !like(text, pattern, sensitive)),
        FilterOp::Ilike => single().is_some_and(|pattern| like(text, pattern, false)),
        FilterOp::In => match &rule.value {
            Some(FilterValue::List(items)) => items.iter().any(|item| same(text, item)),
            _ => false,
        },
        FilterOp::NotIn => match &rule.value {
            Some(FilterValue::List(items)) => !items.is_empty() && !items.iter().any(|item| same(text, item)),
            _ => false,
        },
        FilterOp::Between => match &rule.value {
            Some(FilterValue::Pair(low, high)) => {
                compare(text, low, sensitive, true).is_ge() && compare(text, high, sensitive, true).is_le()
            }
            _ => false,
        },
    }
}

fn fold(text: &str, sensitive: bool) -> String {
    if sensitive {
        text.to_owned()
    } else {
        text.to_lowercase()
    }
}

fn compare(a: &str, b: &str, sensitive: bool, numeric: bool) -> std::cmp::Ordering {
    if numeric && let (Ok(x), Ok(y)) = (a.trim().parse::<SqlDecimal>(), b.trim().parse::<SqlDecimal>()) {
        return x.cmp_numeric(&y);
    }
    fold(a, sensitive).cmp(&fold(b, sensitive))
}

fn like(text: &str, pattern: &str, sensitive: bool) -> bool {
    let text = fold(text, sensitive);
    let pattern: Vec<char> = fold(pattern, sensitive).chars().collect();
    // Each prefix is visited once per character, so repeated wildcards cannot branch exponentially.
    let mut reachable = vec![false; pattern.len() + 1];
    reachable[0] = true;
    for (index, token) in pattern.iter().enumerate() {
        reachable[index + 1] = *token == '%' && reachable[index];
    }
    for character in text.chars() {
        let mut diagonal = reachable[0];
        reachable[0] = false;
        for (index, token) in pattern.iter().enumerate() {
            let above = reachable[index + 1];
            reachable[index + 1] = match token {
                '%' => reachable[index] || above,
                '_' => diagonal,
                literal => diagonal && *literal == character,
            };
            diagonal = above;
        }
    }
    reachable[pattern.len()]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::grid::test_columns::{grid, info};

    fn columns(names: &[&str]) -> Vec<GridColumn> {
        names.iter().map(|name| grid(info(name, "numeric"))).collect()
    }

    fn cells<'a>(texts: &[Option<&'a str>]) -> Vec<HighlightValue<'a>> {
        texts
            .iter()
            .map(|text| match text {
                Some(text) => HighlightValue::Text(Cow::Borrowed(text)),
                None => HighlightValue::Null,
            })
            .collect()
    }

    fn rule(op: FilterOp, value: Option<FilterValue>) -> HighlightRule {
        HighlightRule {
            op,
            value,
            ..HighlightRule::new("status")
        }
    }

    fn single(text: &str) -> Option<FilterValue> {
        Some(FilterValue::Single(text.to_owned()))
    }

    fn highlights(rule: HighlightRule, text: Option<&str>) -> bool {
        let rules = HighlightRules::compile(&[rule], &columns(&["status"]));
        !rules.highlight(&cells(&[text])).is_none()
    }

    #[test]
    fn equal_ignores_case_unless_asked_and_compares_numbers_as_numbers() {
        assert!(highlights(rule(FilterOp::Eq, single("Active")), Some("active")));
        let mut exact = rule(FilterOp::Eq, single("Active"));
        exact.case_sensitive = true;
        assert!(!highlights(exact, Some("active")));
        assert!(highlights(rule(FilterOp::Eq, single("10")), Some("10.0")));
        assert!(
            highlights(rule(FilterOp::Gt, single("9")), Some("10")),
            "10 is more than 9 as numbers"
        );
        assert!(!highlights(rule(FilterOp::Lt, single("9")), Some("10")));
    }

    #[test]
    fn text_operators_match_what_the_cell_shows() {
        assert!(highlights(rule(FilterOp::Contains, single("RR")), Some("error")));
        assert!(highlights(rule(FilterOp::StartsWith, single("er")), Some("error")));
        assert!(highlights(rule(FilterOp::EndsWith, single("OR")), Some("error")));
        assert!(highlights(rule(FilterOp::Like, single("e%r")), Some("error")));
        assert!(highlights(rule(FilterOp::Like, single("e_ror")), Some("error")));
        assert!(!highlights(rule(FilterOp::NotLike, single("e%")), Some("error")));
    }

    #[test]
    fn lists_and_ranges() {
        let list = Some(FilterValue::List(vec!["a".to_owned(), "b".to_owned()]));
        assert!(highlights(rule(FilterOp::In, list.clone()), Some("B")));
        assert!(!highlights(rule(FilterOp::NotIn, list), Some("b")));
        let range = Some(FilterValue::Pair("5".to_owned(), "10".to_owned()));
        assert!(highlights(rule(FilterOp::Between, range.clone()), Some("7")));
        assert!(highlights(rule(FilterOp::Between, range.clone()), Some("10")));
        assert!(!highlights(rule(FilterOp::Between, range), Some("11")));
    }

    #[test]
    fn null_meets_only_the_null_test() {
        assert!(highlights(rule(FilterOp::IsNull, None), None));
        assert!(!highlights(rule(FilterOp::IsNotNull, None), None));
        assert!(!highlights(rule(FilterOp::NotEq, single("x")), None));
        assert!(highlights(rule(FilterOp::IsNotNull, None), Some("")));
    }

    #[test]
    fn a_row_rule_paints_the_row_and_a_cell_rule_its_cell_first() {
        let mut row = HighlightRule::new("status");
        row.value = single("error");
        row.color = HighlightColor::Red;
        let mut cell = HighlightRule::new("amount");
        cell.op = FilterOp::Gt;
        cell.value = single("100");
        cell.target = HighlightTarget::Cell;
        cell.color = HighlightColor::Green;
        let columns = columns(&["status", "amount"]);
        let rules = HighlightRules::compile(&[row, cell], &columns);

        let found = rules.highlight(&cells(&[Some("error"), Some("250")]));

        assert_eq!(found.row, Some(HighlightColor::Red));
        assert_eq!(
            found.color_of(1),
            Some(HighlightColor::Green),
            "the cell's own rule wins"
        );
        assert_eq!(found.color_of(0), Some(HighlightColor::Red));
        assert!(rules.highlight(&cells(&[Some("ok"), Some("5")])).is_none());
    }

    #[test]
    fn a_disabled_invalid_or_unresolved_rule_paints_nothing() {
        let mut off = rule(FilterOp::Eq, single("x"));
        off.enabled = false;
        let blank = rule(FilterOp::Eq, single(""));
        let mut elsewhere = rule(FilterOp::Eq, single("x"));
        elsewhere.column = "missing".to_owned();

        let rules = HighlightRules::compile(&[off, blank, elsewhere], &columns(&["status"]));

        assert!(rules.is_empty());
    }

    #[test]
    fn the_first_rule_that_holds_decides_a_colour() {
        let mut first = rule(FilterOp::Contains, single("a"));
        first.color = HighlightColor::Blue;
        let mut second = rule(FilterOp::Contains, single("a"));
        second.color = HighlightColor::Red;
        let rules = HighlightRules::compile(&[first, second], &columns(&["status"]));

        assert_eq!(rules.highlight(&cells(&[Some("a")])).row, Some(HighlightColor::Blue));
    }

    #[test]
    fn a_rule_round_trips_through_json() {
        let original = rule(
            FilterOp::Between,
            Some(FilterValue::Pair("1".to_owned(), "2".to_owned())),
        );

        let text = serde_json::to_string(&original).expect("encode");

        assert_eq!(serde_json::from_str::<HighlightRule>(&text).expect("decode"), original);
    }

    #[test]
    fn repeated_wildcards_do_not_branch_exponentially() {
        assert!(!like(&"a".repeat(1_000), "%a%a%a%b", true));
        assert!(like("é界", "__", true));
        assert!(like("", "%%%", true));
        assert!(!like("", "_", true));
        assert!(like("error", "%r", true));
        assert!(!like("errors", "%r", true));
    }

    #[test]
    fn numeric_rules_preserve_large_integer_and_decimal_digits() {
        let smaller = "9007199254740992";
        let larger = "9007199254740993";
        assert!(!highlights(rule(FilterOp::Eq, single(smaller)), Some(larger)));
        assert!(highlights(rule(FilterOp::Gt, single(smaller)), Some(larger)));
        assert!(!highlights(
            rule(FilterOp::In, Some(FilterValue::List(vec![smaller.into()]))),
            Some(larger)
        ));
        assert!(!highlights(
            rule(
                FilterOp::Between,
                Some(FilterValue::Pair(smaller.into(), smaller.into()))
            ),
            Some(larger)
        ));
        assert!(highlights(
            rule(FilterOp::Gt, single("0.12345678901234567890")),
            Some("0.12345678901234567891")
        ));
    }

    #[test]
    fn text_equality_keeps_numeric_looking_strings_distinct() {
        let columns = [grid(info("status", "text"))];
        let equal = HighlightRules::compile(&[rule(FilterOp::Eq, single("1"))], &columns);
        assert!(equal.highlight(&cells(&[Some("01")])).is_none());
        let order = HighlightRules::compile(&[rule(FilterOp::Gt, single("9"))], &columns);
        assert!(!order.highlight(&cells(&[Some("10")])).is_none());
    }

    #[test]
    fn duplicate_names_resolve_by_occurrence_and_wait_if_missing() {
        let mut second = rule(FilterOp::Eq, single("2"));
        second.column_occurrence = 1;
        second.target = HighlightTarget::Cell;
        let rules = HighlightRules::compile(std::slice::from_ref(&second), &columns(&["status", "status"]));
        let found = rules.highlight(&cells(&[Some("1"), Some("2")]));
        assert_eq!(found.color_of(0), None);
        assert_eq!(found.color_of(1), Some(HighlightColor::Yellow));
        assert!(HighlightRules::compile(&[second], &columns(&["status"])).is_empty());
    }

    #[test]
    fn unavailable_and_missing_values_are_not_null() {
        let rules = HighlightRules::compile(&[rule(FilterOp::IsNull, None)], &columns(&["status"]));
        assert!(rules.highlight(&[]).is_none());
        assert!(rules.highlight(&[HighlightValue::Unavailable]).is_none());
        assert!(rules.highlight(&[HighlightValue::NonText]).is_none());
        assert!(!rules.highlight(&[HighlightValue::Null]).is_none());
        let rules = HighlightRules::compile(&[rule(FilterOp::IsNotNull, None)], &columns(&["status"]));
        assert!(!rules.highlight(&[HighlightValue::NonText]).is_none());
        assert!(rules.highlight(&[HighlightValue::Unavailable]).is_none());
    }

    #[test]
    fn matching_uses_full_values_and_never_binary_placeholders() {
        let long = format!("{}tail", "x".repeat(2_000));
        assert!(highlights(rule(FilterOp::EndsWith, single("tail")), Some(&long)));
        let rules = HighlightRules::compile(&[rule(FilterOp::Contains, single("byte"))], &columns(&["status"]));
        assert!(rules.highlight(&[HighlightValue::NonText]).is_none());
    }

    #[test]
    fn an_empty_column_name_is_still_addressable() {
        let mut rule = rule(FilterOp::Eq, single("1"));
        rule.column.clear();
        let rules = HighlightRules::compile(&[rule], &columns(&[""]));
        assert!(!rules.highlight(&cells(&[Some("1")])).is_none());
    }

    #[test]
    fn rules_read_each_column_only_once() {
        let rules = HighlightRules::compile(
            &[rule(FilterOp::Eq, single("1")), rule(FilterOp::Gt, single("2"))],
            &columns(&["status"]),
        );
        assert_eq!(rules.columns().collect::<Vec<_>>(), [0]);
    }
}
