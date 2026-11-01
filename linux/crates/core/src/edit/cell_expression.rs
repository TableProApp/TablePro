use crate::column::{ColumnKind, ColumnType};
use crate::dialect::SqlDialect;

/// The kind of column an expression fills.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MomentKind {
    Timestamp,
    Date,
    Time,
}

impl MomentKind {
    pub fn of(column: &ColumnType) -> Option<Self> {
        match column.kind {
            ColumnKind::Timestamp { .. } => Some(Self::Timestamp),
            ColumnKind::Date => Some(Self::Date),
            ColumnKind::Time { .. } => Some(Self::Time),
            _ => None,
        }
    }
}

/// SQL the server evaluates as it writes a cell, such as `NOW()`.
///
/// Only an engine's own list makes one, so the text a user types is
/// matched against that list and never written itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellExpression {
    /// Written into the statement as spelled here.
    pub sql: &'static str,
    pub fills: &'static [MomentKind],
    /// Other spellings that mean this expression, each written as `sql`.
    pub aliases: &'static [&'static str],
}

impl CellExpression {
    pub const fn new(sql: &'static str, fills: &'static [MomentKind], aliases: &'static [&'static str]) -> Self {
        Self { sql, fills, aliases }
    }

    pub fn matches(&self, typed: &str) -> bool {
        self.sql.eq_ignore_ascii_case(typed) || self.aliases.iter().any(|alias| alias.eq_ignore_ascii_case(typed))
    }
}

/// The expressions a cell of `column` may be set to, in menu order.
pub fn cell_expressions(dialect: &dyn SqlDialect, column: &ColumnType) -> Vec<CellExpression> {
    let Some(kind) = MomentKind::of(column) else {
        return Vec::new();
    };
    dialect
        .cell_expressions()
        .iter()
        .filter(|expression| expression.fills.contains(&kind))
        .copied()
        .collect()
}

/// The expression `typed` names for a cell of `column`, in any letter
/// case, if the engine has one.
pub fn typed_cell_expression(dialect: &dyn SqlDialect, column: &ColumnType, typed: &str) -> Option<CellExpression> {
    let typed = typed.trim();
    if typed.is_empty() {
        return None;
    }
    cell_expressions(dialect, column)
        .into_iter()
        .find(|expression| expression.matches(typed))
}

#[cfg(test)]
mod tests {
    use crate::column::{ColumnKind, ColumnType, ReadForm, TemporalZone, TextLength};
    use crate::dialect::TestDialect;

    use super::*;

    fn of_kind(kind: ColumnKind) -> ColumnType {
        ColumnType {
            name: "t".to_owned(),
            kind,
            catalog: None,
            dynamic_storage: false,
            read_form: ReadForm::Native,
        }
    }

    fn timestamp() -> ColumnType {
        of_kind(ColumnKind::Timestamp {
            fractional_digits: None,
            zone: TemporalZone::Naive,
        })
    }

    #[test]
    fn a_typed_expression_matches_in_any_case_and_is_written_as_listed() {
        let dialect = TestDialect::exact();

        let found = typed_cell_expression(&dialect, &timestamp(), "  now() ").map(|expression| expression.sql);
        assert_eq!(found, Some("NOW()"));
        let alias =
            typed_cell_expression(&dialect, &timestamp(), "current_timestamp()").map(|expression| expression.sql);
        assert_eq!(alias, Some("CURRENT_TIMESTAMP"));
    }

    #[test]
    fn only_the_expressions_for_the_columns_kind_are_offered() {
        let dialect = TestDialect::exact();

        assert_eq!(
            typed_cell_expression(&dialect, &of_kind(ColumnKind::Date), "NOW()"),
            None
        );
        assert_eq!(
            cell_expressions(&dialect, &of_kind(ColumnKind::Date))
                .iter()
                .map(|expression| expression.sql)
                .collect::<Vec<_>>(),
            ["CURRENT_DATE"]
        );
        let text = of_kind(ColumnKind::Text {
            length: TextLength::Unbounded,
        });
        assert!(cell_expressions(&dialect, &text).is_empty());
        assert_eq!(typed_cell_expression(&dialect, &text, "NOW()"), None);
    }

    #[test]
    fn text_that_only_contains_an_expression_is_not_one() {
        let dialect = TestDialect::exact();

        for typed in ["NOW(); DROP TABLE t", "NOW() + 1", "", "NOW"] {
            assert_eq!(typed_cell_expression(&dialect, &timestamp(), typed), None, "{typed}");
        }
    }
}
