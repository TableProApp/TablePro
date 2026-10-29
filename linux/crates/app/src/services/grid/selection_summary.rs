use std::borrow::Cow;
use std::cmp::Ordering;

use num_bigint::BigInt;
use tablepro_core::Value;
use tablepro_core::value::SqlDecimal;

use super::value_order::decimal_of;
use super::{CellDisplay, GridColumn};

const AVERAGE_EXTRA_DIGITS: u32 = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SummaryRule {
    /// `scale` is the column's declared one, which its cells are padded to.
    /// A value that is not a number, such as NaN, is counted as one.
    Numeric { scale: u32 },
    /// No declared type, so text that reads as a number is one. Typed text
    /// holds identifiers like ZIP codes and is never summed.
    NumericIfParsable,
    CountOnly,
}

impl SummaryRule {
    pub fn for_column(column: &GridColumn) -> Self {
        let kind = &column.column_type.kind;
        if kind.is_untyped() {
            return Self::NumericIfParsable;
        }
        match column.display() {
            CellDisplay::Number => Self::Numeric {
                scale: kind.decimal_scale().unwrap_or(0),
            },
            _ => Self::CountOnly,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelectionSummary {
    pub value_count: u64,
    pub empty_count: u64,
    pub not_a_number_count: u64,
    pub numbers: Option<NumberFigures>,
}

/// Plain decimal text with no grouping, as SQL and a spreadsheet read it
/// in any locale. Sum, minimum and maximum keep the widest scale, so cents
/// stay cents; the average carries four more digits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NumberFigures {
    pub count: u64,
    pub sum: String,
    pub average: String,
    pub minimum: String,
    pub maximum: String,
}

/// `values` as their cells show them, with a cell left to its default as
/// NULL. `None` once `cancelled` says so. It asks before every value: one
/// of 100,000 digits takes milliseconds alone.
pub fn summarize<'a>(
    values: impl IntoIterator<Item = &'a Value>,
    rule: SummaryRule,
    cancelled: &dyn Fn() -> bool,
) -> Option<SelectionSummary> {
    let mut tally = Tally::default();
    for value in values {
        if cancelled() {
            return None;
        }
        tally.add(value, rule);
    }
    Some(tally.finish(rule))
}

#[derive(Default)]
struct Tally {
    value_count: u64,
    empty_count: u64,
    not_a_number_count: u64,
    count: u64,
    sum: Exact,
    minimum: Option<Exact>,
    maximum: Option<Exact>,
}

impl Tally {
    fn add(&mut self, value: &Value, rule: SummaryRule) {
        if value.is_null() {
            self.empty_count += 1;
            return;
        }
        self.value_count += 1;
        if rule == SummaryRule::CountOnly {
            return;
        }
        match number_of(value) {
            Some(number) => self.add_number(number),
            None if rule != SummaryRule::NumericIfParsable => self.not_a_number_count += 1,
            None => {}
        }
    }

    fn add_number(&mut self, number: Exact) {
        self.count += 1;
        self.sum = self.sum.plus(&number);
        if self
            .minimum
            .as_ref()
            .is_none_or(|minimum| number.compare(minimum) == Ordering::Less)
        {
            self.minimum = Some(number.clone());
        }
        if self
            .maximum
            .as_ref()
            .is_none_or(|maximum| number.compare(maximum) == Ordering::Greater)
        {
            self.maximum = Some(number);
        }
    }

    fn finish(self, rule: SummaryRule) -> SelectionSummary {
        let declared = match rule {
            SummaryRule::Numeric { scale } => scale,
            SummaryRule::NumericIfParsable | SummaryRule::CountOnly => 0,
        };
        let numbers = match (self.minimum, self.maximum) {
            (Some(minimum), Some(maximum)) => {
                let scale = self.sum.scale.max(declared);
                let average = self.sum.divided(self.count, scale + AVERAGE_EXTRA_DIGITS);
                Some(NumberFigures {
                    count: self.count,
                    sum: self.sum.text(scale),
                    average: average.trimmed().text(0),
                    minimum: minimum.text(scale),
                    maximum: maximum.text(scale),
                })
            }
            _ => None,
        };
        SelectionSummary {
            value_count: self.value_count,
            empty_count: self.empty_count,
            not_a_number_count: self.not_a_number_count,
            numbers,
        }
    }
}

/// A number type's value, or text that reads as a number, at its exact
/// decimal. A float is the decimal its shortest text spells, which is
/// what its cell shows, so `0.1 + 0.2` is `0.3`.
fn number_of(value: &Value) -> Option<Exact> {
    let decimal = match value {
        Value::Int(n) => return Some(Exact::integer(BigInt::from(*n))),
        Value::UInt(n) => return Some(Exact::integer(BigInt::from(*n))),
        Value::Text(text) => Cow::Owned(text.parse::<SqlDecimal>().ok()?),
        Value::Other(other) => Cow::Owned(other.text.parse::<SqlDecimal>().ok()?),
        _ => decimal_of(value)?,
    };
    let (negative, digits, scale) = decimal.parts()?;
    let magnitude = BigInt::parse_bytes(digits.as_bytes(), 10)?;
    Some(Exact {
        mantissa: if negative { -magnitude } else { magnitude },
        scale,
    })
}

/// `mantissa × 10^-scale`, with the arithmetic `SqlDecimal` leaves out.
#[derive(Debug, Clone, Default)]
struct Exact {
    mantissa: BigInt,
    scale: u32,
}

impl Exact {
    fn integer(mantissa: BigInt) -> Self {
        Self { mantissa, scale: 0 }
    }

    fn rescaled(&self, scale: u32) -> BigInt {
        match scale.checked_sub(self.scale) {
            Some(0) | None => self.mantissa.clone(),
            Some(more) => &self.mantissa * pow10(more),
        }
    }

    fn plus(&self, other: &Self) -> Self {
        let scale = self.scale.max(other.scale);
        Self {
            mantissa: self.rescaled(scale) + other.rescaled(scale),
            scale,
        }
    }

    fn compare(&self, other: &Self) -> Ordering {
        let scale = self.scale.max(other.scale);
        self.rescaled(scale).cmp(&other.rescaled(scale))
    }

    /// `self ÷ count` to `scale` digits, half away from zero.
    fn divided(&self, count: u64, scale: u32) -> Self {
        let numerator = self.rescaled(scale);
        let denominator = BigInt::from(count);
        let quotient = &numerator / &denominator;
        let remainder = &numerator % &denominator;
        let rounds_away = remainder.magnitude() * 2u32 >= *denominator.magnitude();
        let mantissa = match rounds_away {
            true if numerator < BigInt::ZERO => quotient - 1,
            true => quotient + 1,
            false => quotient,
        };
        Self { mantissa, scale }
    }

    fn trimmed(&self) -> Self {
        let digits = self.mantissa.magnitude().to_string();
        let zeros = digits.bytes().rev().take_while(|digit| *digit == b'0').count();
        let drop = u32::try_from(zeros).unwrap_or(u32::MAX).min(self.scale);
        Self {
            mantissa: &self.mantissa / pow10(drop),
            scale: self.scale - drop,
        }
    }

    /// The number with at least `scale` fraction digits.
    fn text(&self, scale: u32) -> String {
        let scale = scale.max(self.scale);
        let mantissa = self.rescaled(scale);
        let digits = mantissa.magnitude().to_string();
        let sign = if mantissa < BigInt::ZERO { "-" } else { "" };
        let scale = scale as usize;
        if scale == 0 {
            return format!("{sign}{digits}");
        }
        let digits = format!("{digits:0>width$}", width = scale + 1);
        let (whole, fraction) = digits.split_at(digits.len() - scale);
        format!("{sign}{whole}.{fraction}")
    }
}

fn pow10(exponent: u32) -> BigInt {
    BigInt::from(10u32).pow(exponent)
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use tablepro_core::column::{ColumnKind, IntegerKind, IntegerWidth, TextLength};
    use tablepro_core::value::{OtherValue, SqlDecimal};
    use tablepro_core::Value;

    use super::{NumberFigures, SelectionSummary, SummaryRule, summarize};
    use crate::services::grid::test_columns::result_only;

    fn summed(values: &[Value], rule: SummaryRule) -> SelectionSummary {
        summarize(values, rule, &|| false).expect("a run nobody cancelled")
    }

    fn numbers(values: &[Value], rule: SummaryRule) -> NumberFigures {
        summed(values, rule).numbers.expect("numbers")
    }

    fn decimal(text: &str) -> Value {
        Value::Decimal(text.parse::<SqlDecimal>().expect("a decimal"))
    }

    const NUMERIC: SummaryRule = SummaryRule::Numeric { scale: 0 };

    #[test]
    fn decimals_add_exactly_and_keep_their_scale() {
        let figures = numbers(&[decimal("0.10"), decimal("0.20"), decimal("19.99")], NUMERIC);

        assert_eq!(figures.count, 3);
        assert_eq!(figures.sum, "20.29");
        assert_eq!(figures.minimum, "0.10");
        assert_eq!(figures.maximum, "19.99");
        assert_eq!(figures.average, "6.763333", "four digits past the cents");
    }

    #[test]
    fn the_declared_scale_pads_the_figures_as_it_pads_the_cells() {
        let figures = numbers(&[decimal("5"), decimal("6")], SummaryRule::Numeric { scale: 2 });

        assert_eq!(figures.sum, "11.00");
        assert_eq!(figures.minimum, "5.00");
        assert_eq!(figures.average, "5.5");
    }

    #[test]
    fn floats_add_as_the_text_the_cell_shows() {
        let figures = numbers(&[Value::Float64(0.1), Value::Float64(0.2)], NUMERIC);
        assert_eq!(figures.sum, "0.3");
        assert_eq!(figures.average, "0.15");

        let figures = numbers(&[Value::Float32(0.1), Value::Float32(0.2)], NUMERIC);
        assert_eq!(figures.sum, "0.3", "a float32 at its own width, not widened");
    }

    #[test]
    fn the_average_rounds_half_away_from_zero_and_drops_its_zeros() {
        assert_eq!(
            numbers(&[Value::Int(2), Value::Int(4), Value::Int(-9)], NUMERIC).average,
            "-1"
        );
        assert_eq!(numbers(&[Value::Int(-1), Value::Int(-2)], NUMERIC).average, "-1.5");
        assert_eq!(
            numbers(&[Value::Int(1), Value::Int(1), Value::Int(0)], NUMERIC).average,
            "0.6667"
        );
        assert_eq!(
            numbers(&[Value::Int(-1), Value::Int(-1), Value::Int(0)], NUMERIC).average,
            "-0.6667"
        );
    }

    #[test]
    fn integers_of_any_width_add_past_i128() {
        let wide = "170141183460469231731687303715884105727"
            .parse()
            .map(Value::WideInt)
            .expect("an i128::MAX");
        let figures = numbers(&[wide.clone(), wide, Value::UInt(u64::MAX)], NUMERIC);

        assert_eq!(figures.sum, "340282366920938463481821351505477763069");
    }

    #[test]
    fn a_decimal_wider_than_a_thousand_digits_is_still_a_number() {
        let wide = format!("1{}", "0".repeat(1_500));
        let summary = summed(&[decimal(&wide), Value::Int(1)], NUMERIC);

        assert_eq!(summary.not_a_number_count, 0);
        assert_eq!(
            summary.numbers.expect("numbers").sum,
            format!("1{}1", "0".repeat(1_499))
        );
    }

    #[test]
    fn nulls_are_empty_and_a_nan_is_not_a_number() {
        let values = [
            Value::Int(5),
            Value::Null,
            Value::Null,
            Value::Decimal(SqlDecimal::nan()),
            Value::Float64(f64::INFINITY),
        ];
        let summary = summed(&values, NUMERIC);

        assert_eq!(summary.value_count, 3);
        assert_eq!(summary.empty_count, 2);
        assert_eq!(summary.not_a_number_count, 2);
        assert_eq!(summary.numbers.expect("numbers").count, 1);
    }

    #[test]
    fn text_is_summed_only_in_a_column_of_no_declared_type() {
        let other = Value::Other(Box::new(OtherValue {
            type_name: "Variant(UInt32, String)".to_owned(),
            text: "4".to_owned(),
        }));
        let values = [
            Value::Text("12".into()),
            Value::Text("\u{a0}3.5 ".into()),
            Value::Text("n/a".into()),
            other,
        ];

        let untyped = summed(&values, SummaryRule::NumericIfParsable);
        assert_eq!(untyped.value_count, 4);
        assert_eq!(untyped.not_a_number_count, 0, "free text in an untyped column is just text");
        assert_eq!(untyped.numbers.expect("numbers").sum, "19.5");

        let typed = summed(&values, SummaryRule::CountOnly);
        assert_eq!(typed.value_count, 4);
        assert!(typed.numbers.is_none());
    }

    #[test]
    fn a_column_of_text_only_counts() {
        let summary = summed(&[Value::Text("a".into()), Value::Null], SummaryRule::NumericIfParsable);

        assert_eq!((summary.value_count, summary.empty_count), (1, 1));
        assert!(summary.numbers.is_none());
    }

    #[test]
    fn the_rule_follows_the_column_type() {
        let integer = ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W64,
            signed: true,
        });
        let cents = ColumnKind::Decimal {
            precision: Some(10),
            scale: Some(2),
        };
        let zip = ColumnKind::Text {
            length: TextLength::Varying(5),
        };

        assert_eq!(
            SummaryRule::for_column(&result_only("n", integer)),
            SummaryRule::Numeric { scale: 0 }
        );
        assert_eq!(
            SummaryRule::for_column(&result_only("price", cents)),
            SummaryRule::Numeric { scale: 2 }
        );
        assert_eq!(SummaryRule::for_column(&result_only("zip", zip)), SummaryRule::CountOnly);
        assert_eq!(
            SummaryRule::for_column(&result_only("x", ColumnKind::Other)),
            SummaryRule::NumericIfParsable
        );
    }

    #[test]
    fn a_cancelled_run_answers_nothing() {
        let asked = Cell::new(0);
        let values = vec![Value::Int(1); 10];

        let answer = summarize(&values, NUMERIC, &|| {
            asked.set(asked.get() + 1);
            asked.get() > 3
        });

        assert_eq!(answer, None);
        assert_eq!(asked.get(), 4, "it stops before the next value");
    }
}
