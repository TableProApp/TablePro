//! Highlight rules: a condition on one column that colours the cell or the
//! whole row that meets it, as the macOS grid's Highlight Rules do
//! (`HighlightRuleSet`). The conditions use the filter strip's operators,
//! read here against the text a cell shows, so a rule matches what the user
//! sees.

use serde::{Deserialize, Serialize};
use tablepro_core::filter::{FilterOp, FilterValue};
use uuid::Uuid;

/// The colours a rule can paint, the macOS set.
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

    /// The style class a painted cell wears.
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

/// What a rule paints.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HighlightTarget {
    /// The whole row.
    Row,
    /// The cell of the rule's column alone.
    Cell,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HighlightRule {
    pub id: Uuid,
    pub enabled: bool,
    pub column: String,
    pub op: FilterOp,
    /// `None` for the null tests; the operand for every other operator.
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
            op: FilterOp::Eq,
            value: Some(FilterValue::Single(String::new())),
            case_sensitive: false,
            color: HighlightColor::Yellow,
            target: HighlightTarget::Row,
        }
    }

    /// Whether the rule says something a row can meet: a column, and the
    /// operand its operator takes.
    pub fn is_valid(&self) -> bool {
        if self.column.is_empty() {
            return false;
        }
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

/// What a row meets: a colour for all of it, and colours for single cells.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RowHighlight {
    pub row: Option<HighlightColor>,
    /// By the column's position, the first rule that holds for each.
    pub cells: Vec<(usize, HighlightColor)>,
}

impl RowHighlight {
    #[cfg(test)]
    pub fn is_none(&self) -> bool {
        self.row.is_none() && self.cells.is_empty()
    }

    /// The colour of the cell in column `column`: its own rule's, else the row's.
    pub fn color_of(&self, column: usize) -> Option<HighlightColor> {
        self.cells
            .iter()
            .find(|(at, _)| *at == column)
            .map(|(_, color)| *color)
            .or(self.row)
    }
}

struct Compiled {
    column: usize,
    rule: HighlightRule,
}

/// The rules that apply to a result's columns, ready to read rows with.
#[derive(Default)]
pub struct HighlightRules {
    compiled: Vec<Compiled>,
}

impl HighlightRules {
    /// The enabled, valid rules whose column the result has. A rule for a
    /// column that is not there waits, and meets nothing meanwhile.
    pub fn compile(rules: &[HighlightRule], columns: &[String]) -> Self {
        let compiled = rules
            .iter()
            .filter(|rule| rule.enabled && rule.is_valid())
            .filter_map(|rule| {
                columns
                    .iter()
                    .position(|column| *column == rule.column)
                    .map(|column| Compiled {
                        column,
                        rule: rule.clone(),
                    })
            })
            .collect();
        Self { compiled }
    }

    pub fn is_empty(&self) -> bool {
        self.compiled.is_empty()
    }

    /// The columns the rules read, which is all a row has to say of itself.
    pub fn columns(&self) -> impl Iterator<Item = usize> + '_ {
        self.compiled.iter().map(|compiled| compiled.column)
    }

    /// What `cells` meet, each the text the column shows and `None` for NULL.
    pub fn highlight(&self, cells: &[Option<&str>]) -> RowHighlight {
        let mut found = RowHighlight::default();
        for compiled in &self.compiled {
            let text = cells.get(compiled.column).copied().flatten();
            if !matches(&compiled.rule, text) {
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

fn matches(rule: &HighlightRule, text: Option<&str>) -> bool {
    let Some(text) = text else {
        // NULL meets only the null test.
        return rule.op == FilterOp::IsNull;
    };
    let sensitive = rule.case_sensitive;
    let same = |a: &str, b: &str| compare(a, b, sensitive) == std::cmp::Ordering::Equal;
    let single = || match &rule.value {
        Some(FilterValue::Single(operand)) => Some(operand.as_str()),
        _ => None,
    };
    match rule.op {
        FilterOp::IsNull => false,
        FilterOp::IsNotNull => true,
        FilterOp::Eq => single().is_some_and(|operand| same(text, operand)),
        FilterOp::NotEq => single().is_some_and(|operand| !same(text, operand)),
        FilterOp::Lt => single().is_some_and(|operand| compare(text, operand, sensitive).is_lt()),
        FilterOp::LtEq => single().is_some_and(|operand| compare(text, operand, sensitive).is_le()),
        FilterOp::Gt => single().is_some_and(|operand| compare(text, operand, sensitive).is_gt()),
        FilterOp::GtEq => single().is_some_and(|operand| compare(text, operand, sensitive).is_ge()),
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
                compare(text, low, sensitive).is_ge() && compare(text, high, sensitive).is_le()
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

/// Numbers compare as numbers when both sides read as one, else as text.
fn compare(a: &str, b: &str, sensitive: bool) -> std::cmp::Ordering {
    if let (Ok(x), Ok(y)) = (a.trim().parse::<f64>(), b.trim().parse::<f64>())
        && let Some(order) = x.partial_cmp(&y)
    {
        return order;
    }
    fold(a, sensitive).cmp(&fold(b, sensitive))
}

/// SQL LIKE: `%` is any run of characters and `_` any one.
fn like(text: &str, pattern: &str, sensitive: bool) -> bool {
    let text: Vec<char> = fold(text, sensitive).chars().collect();
    let pattern: Vec<char> = fold(pattern, sensitive).chars().collect();
    fn walk(text: &[char], pattern: &[char]) -> bool {
        match pattern.split_first() {
            None => text.is_empty(),
            Some(('%', rest)) => (0..=text.len()).any(|skip| walk(&text[skip..], rest)),
            Some(('_', rest)) => text.split_first().is_some_and(|(_, tail)| walk(tail, rest)),
            Some((letter, rest)) => text
                .split_first()
                .is_some_and(|(head, tail)| head == letter && walk(tail, rest)),
        }
    }
    walk(&text, &pattern)
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let rules = HighlightRules::compile(&[rule], &["status".to_owned()]);
        !rules.highlight(&[text]).is_none()
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
        let columns = ["status".to_owned(), "amount".to_owned()];
        let rules = HighlightRules::compile(&[row, cell], &columns);

        let found = rules.highlight(&[Some("error"), Some("250")]);

        assert_eq!(found.row, Some(HighlightColor::Red));
        assert_eq!(
            found.color_of(1),
            Some(HighlightColor::Green),
            "the cell's own rule wins"
        );
        assert_eq!(found.color_of(0), Some(HighlightColor::Red));
        assert!(rules.highlight(&[Some("ok"), Some("5")]).is_none());
    }

    #[test]
    fn a_disabled_invalid_or_unresolved_rule_paints_nothing() {
        let mut off = rule(FilterOp::Eq, single("x"));
        off.enabled = false;
        let blank = rule(FilterOp::Eq, single(""));
        let mut elsewhere = rule(FilterOp::Eq, single("x"));
        elsewhere.column = "missing".to_owned();

        let rules = HighlightRules::compile(&[off, blank, elsewhere], &["status".to_owned()]);

        assert!(rules.is_empty());
    }

    #[test]
    fn the_first_rule_that_holds_decides_a_colour() {
        let mut first = rule(FilterOp::Contains, single("a"));
        first.color = HighlightColor::Blue;
        let mut second = rule(FilterOp::Contains, single("a"));
        second.color = HighlightColor::Red;
        let rules = HighlightRules::compile(&[first, second], &["status".to_owned()]);

        assert_eq!(rules.highlight(&[Some("a")]).row, Some(HighlightColor::Blue));
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
}
