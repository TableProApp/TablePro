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
    sensitive: bool,
    operands: Operands,
}

impl Compiled {
    fn new(column: usize, definition: &GridColumn, rule: &HighlightRule) -> Self {
        // ILIKE ignores case whatever the rule asks.
        let sensitive = rule.case_sensitive && rule.op != FilterOp::Ilike;
        let operand = |typed: &String| Operand::new(typed, sensitive);
        let operands = match &rule.value {
            None => Operands::Absent,
            Some(FilterValue::Single(typed)) => Operands::Single(operand(typed)),
            Some(FilterValue::Pair(low, high)) => Operands::Pair(operand(low), operand(high)),
            Some(FilterValue::List(items)) => Operands::List(items.iter().map(operand).collect()),
        };
        Self {
            column,
            kind: definition.column_type.kind.clone(),
            rule: rule.clone(),
            sensitive,
            operands,
        }
    }
}

/// A rule's operand, read once as the rules compile rather than for
/// every cell they are matched against.
struct Operand {
    folded: String,
    number: Option<SqlDecimal>,
}

impl Operand {
    fn new(typed: &str, sensitive: bool) -> Self {
        Self {
            folded: fold(typed, sensitive).into_owned(),
            number: typed.trim().parse().ok(),
        }
    }
}

enum Operands {
    Absent,
    Single(Operand),
    Pair(Operand, Operand),
    List(Vec<Operand>),
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
                    .map(|(column, definition)| Compiled::new(column, definition, rule))
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
            if !matches(compiled, value) {
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

fn matches(compiled: &Compiled, value: &HighlightValue<'_>) -> bool {
    let text = match value {
        HighlightValue::Unavailable => return false,
        HighlightValue::Null => return compiled.rule.op == FilterOp::IsNull,
        HighlightValue::NonText => return compiled.rule.op == FilterOp::IsNotNull,
        HighlightValue::Text(text) => text.as_ref(),
    };
    let sensitive = compiled.sensitive;
    let numeric = compiled.kind.is_numeric();
    let same = |operand: &Operand| compare(text, operand, sensitive, numeric).is_eq();
    let order = |operand: &Operand| compare(text, operand, sensitive, true);
    let single = || match &compiled.operands {
        Operands::Single(operand) => Some(operand),
        _ => None,
    };
    let list = || match &compiled.operands {
        Operands::List(items) => Some(items),
        _ => None,
    };
    match compiled.rule.op {
        FilterOp::IsNull => false,
        FilterOp::IsNotNull => true,
        FilterOp::Eq => single().is_some_and(same),
        FilterOp::NotEq => single().is_some_and(|operand| !same(operand)),
        FilterOp::Lt => single().is_some_and(|operand| order(operand).is_lt()),
        FilterOp::LtEq => single().is_some_and(|operand| order(operand).is_le()),
        FilterOp::Gt => single().is_some_and(|operand| order(operand).is_gt()),
        FilterOp::GtEq => single().is_some_and(|operand| order(operand).is_ge()),
        FilterOp::Contains => single().is_some_and(|operand| fold(text, sensitive).contains(&operand.folded)),
        FilterOp::StartsWith => single().is_some_and(|operand| fold(text, sensitive).starts_with(&operand.folded)),
        FilterOp::EndsWith => single().is_some_and(|operand| fold(text, sensitive).ends_with(&operand.folded)),
        FilterOp::Like | FilterOp::Ilike => single().is_some_and(|pattern| like(text, &pattern.folded, sensitive)),
        FilterOp::NotLike => single().is_some_and(|pattern| !like(text, &pattern.folded, sensitive)),
        FilterOp::In => list().is_some_and(|items| items.iter().any(same)),
        FilterOp::NotIn => list().is_some_and(|items| !items.is_empty() && !items.iter().any(same)),
        FilterOp::Between => match &compiled.operands {
            Operands::Pair(low, high) => order(low).is_ge() && order(high).is_le(),
            _ => false,
        },
    }
}

fn fold(text: &str, sensitive: bool) -> Cow<'_, str> {
    if sensitive {
        Cow::Borrowed(text)
    } else {
        Cow::Owned(text.to_lowercase())
    }
}

fn compare(text: &str, operand: &Operand, sensitive: bool, numeric: bool) -> std::cmp::Ordering {
    if numeric && let (Ok(x), Some(y)) = (text.trim().parse::<SqlDecimal>(), operand.number.as_ref()) {
        return x.cmp_numeric(y);
    }
    Ord::cmp(&*fold(text, sensitive), operand.folded.as_str())
}

/// `pattern` comes folded as the rule compiled it; only `text` folds here.
fn like(text: &str, pattern: &str, sensitive: bool) -> bool {
    let text = fold(text, sensitive);
    let pattern: Vec<char> = pattern.chars().collect();
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
    fn ilike_ignores_case_even_in_a_case_sensitive_rule() {
        let mut ilike = rule(FilterOp::Ilike, single("ER%"));
        ilike.case_sensitive = true;
        let mut like = rule(FilterOp::Like, single("ER%"));
        like.case_sensitive = true;

        assert!(highlights(ilike, Some("error")));
        assert!(!highlights(like.clone(), Some("error")));
        assert!(highlights(like, Some("ERROR")));
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
