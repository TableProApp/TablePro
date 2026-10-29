use std::cmp::Ordering;

use num_bigint::BigInt;
use tablepro_core::Value;

use super::{CellDisplay, GridColumn};

/// An exponent past this reads as text, not a number: `1e999999` would
/// otherwise take megabytes of digits to add up.
const MAX_EXPONENT: i64 = 400;
/// The most digits a value may write out and still add up as a number,
/// PostgreSQL's widest numeric. A longer text cell of an untyped column
/// is text: adding a million-digit fraction would hold the main thread.
const MAX_DIGITS: usize = 1_000;
/// The average carries this many digits past the column's own, and drops
/// the zeros it does not need.
const AVERAGE_EXTRA_DIGITS: u32 = 4;

/// How a column's values add up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SummaryRule {
    /// A number type: a value that is not a number is counted as one.
    Numeric,
    /// No declared type, so text that reads as a number is one. Typed
    /// text holds identifiers like ZIP codes and is never summed.
    NumericIfParsable,
    CountOnly,
}

impl SummaryRule {
    pub fn for_column(column: &GridColumn) -> Self {
        if column.column_type.kind.is_untyped() {
            return Self::NumericIfParsable;
        }
        match column.display() {
            CellDisplay::Number => Self::Numeric,
            _ => Self::CountOnly,
        }
    }
}

/// A decimal number held exactly, as `mantissa × 10^-scale`, so a sum of
/// cents stays in cents and `0.1 + 0.2` is `0.3`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExactNumber {
    mantissa: BigInt,
    scale: u32,
}

impl ExactNumber {
    /// Plain decimal text, an optional sign and exponent included, with
    /// ASCII blanks around it. `None` for anything else, `NaN` and
    /// `Infinity` among them.
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim_ascii();
        let (negative, rest) = match text.as_bytes().first()? {
            b'-' => (true, &text[1..]),
            b'+' => (false, &text[1..]),
            _ => (false, text),
        };
        let (number, exponent) = match rest.find(['e', 'E']) {
            Some(at) => (&rest[..at], rest[at + 1..].parse::<i64>().ok()?),
            None => (rest, 0),
        };
        if !(-MAX_EXPONENT..=MAX_EXPONENT).contains(&exponent) {
            return None;
        }
        let (whole, fraction) = number.split_once('.').unwrap_or((number, ""));
        if whole.is_empty() && fraction.is_empty() {
            return None;
        }
        if whole.len() + fraction.len() > MAX_DIGITS
            || !whole.bytes().chain(fraction.bytes()).all(|byte| byte.is_ascii_digit())
        {
            return None;
        }
        let digits = format!("{whole}{fraction}");
        let mut mantissa: BigInt = digits.parse().ok()?;
        if negative {
            mantissa = -mantissa;
        }
        let scale = i64::try_from(fraction.len()).ok()? - exponent;
        Some(match u32::try_from(scale) {
            Ok(scale) => Self { mantissa, scale },
            Err(_) => Self {
                mantissa: mantissa * pow10(u32::try_from(-scale).ok()?),
                scale: 0,
            },
        })
    }

    /// The number of a value that is one, by its exact text.
    pub fn of_value(value: &Value) -> Option<Self> {
        match value {
            Value::Int(n) => Some(Self::integer(BigInt::from(*n))),
            Value::UInt(n) => Some(Self::integer(BigInt::from(*n))),
            Value::WideInt(n) => Self::parse(&n.to_string()),
            Value::Decimal(n) => Self::parse(&n.to_string()),
            // The shortest text that reads back as the same float, so a
            // 0.1 stored as a double adds as the 0.1 the cell shows.
            Value::Float32(n) if n.is_finite() => Self::parse(&n.to_string()),
            Value::Float64(n) if n.is_finite() => Self::parse(&n.to_string()),
            Value::Text(text) => Self::parse(text),
            _ => None,
        }
    }

    fn integer(mantissa: BigInt) -> Self {
        Self { mantissa, scale: 0 }
    }

    pub fn scale(&self) -> u32 {
        self.scale
    }

    fn rescaled(&self, scale: u32) -> BigInt {
        match scale.checked_sub(self.scale) {
            Some(0) | None => self.mantissa.clone(),
            Some(more) => &self.mantissa * pow10(more),
        }
    }

    fn add(&self, other: &Self) -> Self {
        let scale = self.scale.max(other.scale);
        Self {
            mantissa: self.rescaled(scale) + other.rescaled(scale),
            scale,
        }
    }

    fn cmp_value(&self, other: &Self) -> Ordering {
        let scale = self.scale.max(other.scale);
        self.rescaled(scale).cmp(&other.rescaled(scale))
    }

    /// `self ÷ count` to `scale` digits, half away from zero.
    fn divided(&self, count: u64, scale: u32) -> Self {
        let numerator = self.rescaled(scale);
        let denominator = BigInt::from(count);
        let quotient: BigInt = &numerator / &denominator;
        let remainder: BigInt = &numerator % &denominator;
        let doubled_remainder = remainder.magnitude() * 2u32;
        let rounded = match doubled_remainder >= *denominator.magnitude() {
            true if self.mantissa < BigInt::ZERO => quotient - 1,
            true => quotient + 1,
            false => quotient,
        };
        Self {
            mantissa: rounded,
            scale,
        }
    }

    /// The same number with no trailing fraction zeros, counted from its
    /// digits and divided out at once.
    fn trimmed(&self) -> Self {
        if self.mantissa == BigInt::ZERO {
            return Self::integer(BigInt::ZERO);
        }
        let digits = self.mantissa.magnitude().to_string();
        let zeros = digits.bytes().rev().take_while(|digit| *digit == b'0').count();
        let drop = u32::try_from(zeros).unwrap_or(u32::MAX).min(self.scale);
        Self {
            mantissa: &self.mantissa / pow10(drop),
            scale: self.scale - drop,
        }
    }

    /// The number written out with at least `scale` fraction digits and
    /// no grouping, as SQL and a spreadsheet read it in any locale.
    pub fn plain_text(&self, scale: u32) -> String {
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
    BigInt::from(10).pow(exponent)
}

/// What the numbers among the summed values come to. Sum, minimum and
/// maximum keep the widest scale among them, so cents stay cents.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NumberFigures {
    pub count: u64,
    pub sum: ExactNumber,
    pub minimum: ExactNumber,
    pub maximum: ExactNumber,
    pub average: ExactNumber,
    pub scale: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelectionSummary {
    /// The values that are not empty.
    pub value_count: u64,
    /// NULLs, and a new row's cells left to the server's default.
    pub empty_count: u64,
    /// Values of a number column that are not numbers, such as `NaN`.
    pub not_a_number_count: u64,
    pub numbers: Option<NumberFigures>,
}

/// Adds the values of the summarized cells one at a time.
#[derive(Debug, Default)]
pub struct SummaryTally {
    value_count: u64,
    empty_count: u64,
    not_a_number_count: u64,
    count: u64,
    sum: Option<ExactNumber>,
    minimum: Option<ExactNumber>,
    maximum: Option<ExactNumber>,
}

impl SummaryTally {
    /// `default` is a new row's cell left to the server, which holds no
    /// value yet.
    pub fn add(&mut self, value: &Value, default: bool, rule: SummaryRule) {
        if default || value.is_null() {
            self.empty_count += 1;
            return;
        }
        self.value_count += 1;
        let number = match rule {
            SummaryRule::CountOnly => return,
            SummaryRule::Numeric | SummaryRule::NumericIfParsable => ExactNumber::of_value(value),
        };
        match number {
            Some(number) => self.add_number(number),
            None if rule == SummaryRule::Numeric => self.not_a_number_count += 1,
            None => {}
        }
    }

    fn add_number(&mut self, number: ExactNumber) {
        self.count += 1;
        self.sum = Some(match &self.sum {
            Some(sum) => sum.add(&number),
            None => number.clone(),
        });
        if self
            .minimum
            .as_ref()
            .is_none_or(|minimum| number.cmp_value(minimum) == Ordering::Less)
        {
            self.minimum = Some(number.clone());
        }
        if self
            .maximum
            .as_ref()
            .is_none_or(|maximum| number.cmp_value(maximum) == Ordering::Greater)
        {
            self.maximum = Some(number);
        }
    }

    pub fn summary(self) -> SelectionSummary {
        let numbers = match (self.sum, self.minimum, self.maximum) {
            (Some(sum), Some(minimum), Some(maximum)) => {
                let scale = sum.scale();
                let average = sum.divided(self.count, scale + AVERAGE_EXTRA_DIGITS).trimmed();
                Some(NumberFigures {
                    count: self.count,
                    sum,
                    minimum,
                    maximum,
                    average,
                    scale,
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

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::column::{ColumnKind, IntegerKind, IntegerWidth, TextLength};
    use tablepro_core::value::SqlDecimal;

    use super::{ExactNumber, SummaryRule, SummaryTally};
    use crate::services::grid::test_columns::result_only;

    fn summed(values: &[Value], rule: SummaryRule) -> super::SelectionSummary {
        let mut tally = SummaryTally::default();
        for value in values {
            tally.add(value, false, rule);
        }
        tally.summary()
    }

    fn plain(number: &ExactNumber, scale: u32) -> String {
        number.plain_text(scale)
    }

    #[test]
    fn decimals_add_exactly_and_keep_their_scale() {
        let cents = |text: &str| Value::Decimal(text.parse::<SqlDecimal>().expect("a decimal"));
        let summary = summed(&[cents("0.10"), cents("0.20"), cents("19.99")], SummaryRule::Numeric);
        let numbers = summary.numbers.expect("numbers");

        assert_eq!(numbers.count, 3);
        assert_eq!(plain(&numbers.sum, numbers.scale), "20.29");
        assert_eq!(plain(&numbers.minimum, numbers.scale), "0.10");
        assert_eq!(plain(&numbers.maximum, numbers.scale), "19.99");
        assert_eq!(plain(&numbers.average, 0), "6.763333", "four digits past the cents");
    }

    #[test]
    fn floats_add_as_the_text_the_cell_shows() {
        let summary = summed(&[Value::Float64(0.1), Value::Float64(0.2)], SummaryRule::Numeric);
        let numbers = summary.numbers.expect("numbers");

        assert_eq!(plain(&numbers.sum, numbers.scale), "0.3");
        assert_eq!(plain(&numbers.average, 0), "0.15");
    }

    #[test]
    fn an_average_with_no_fraction_drops_its_zeros() {
        let summary = summed(&[Value::Int(2), Value::Int(4), Value::Int(-9)], SummaryRule::Numeric);
        let numbers = summary.numbers.expect("numbers");

        assert_eq!(plain(&numbers.sum, numbers.scale), "-3");
        assert_eq!(plain(&numbers.average, 0), "-1");
        assert_eq!(plain(&numbers.minimum, 0), "-9");
        let summary = summed(&[Value::Int(-1), Value::Int(-2)], SummaryRule::Numeric);
        assert_eq!(plain(&summary.numbers.expect("numbers").average, 0), "-1.5");
        let summary = summed(&[Value::Int(-2), Value::Int(-1), Value::Int(0)], SummaryRule::Numeric);
        assert_eq!(plain(&summary.numbers.expect("numbers").average, 0), "-1");
        let summary = summed(&[Value::Int(1), Value::Int(1), Value::Int(0)], SummaryRule::Numeric);
        assert_eq!(
            plain(&summary.numbers.expect("numbers").average, 0),
            "0.6667",
            "half away from zero at the fourth digit"
        );
    }

    #[test]
    fn nulls_are_empty_and_a_nan_is_not_a_number() {
        let nan = Value::Decimal(SqlDecimal::nan());
        let mut tally = SummaryTally::default();
        tally.add(&Value::Int(5), false, SummaryRule::Numeric);
        tally.add(&Value::Null, false, SummaryRule::Numeric);
        tally.add(&Value::Null, true, SummaryRule::Numeric);
        tally.add(&nan, false, SummaryRule::Numeric);
        tally.add(&Value::Float64(f64::INFINITY), false, SummaryRule::Numeric);
        let summary = tally.summary();

        assert_eq!(summary.value_count, 3);
        assert_eq!(summary.empty_count, 2);
        assert_eq!(summary.not_a_number_count, 2);
        assert_eq!(summary.numbers.expect("numbers").count, 1);
    }

    #[test]
    fn text_is_summed_only_in_a_column_of_no_declared_type() {
        let values = [
            Value::Text("12".into()),
            Value::Text(" 3.5 ".into()),
            Value::Text("n/a".into()),
        ];

        let untyped = summed(&values, SummaryRule::NumericIfParsable);
        assert_eq!(untyped.value_count, 3);
        assert_eq!(
            untyped.not_a_number_count, 0,
            "free text in an untyped column is just text"
        );
        let numbers = untyped.numbers.expect("numbers");
        assert_eq!(plain(&numbers.sum, numbers.scale), "15.5");

        let typed = summed(&values, SummaryRule::CountOnly);
        assert_eq!(typed.value_count, 3);
        assert!(typed.numbers.is_none());
    }

    #[test]
    fn the_rule_follows_the_column_type() {
        let integer = ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W64,
            signed: true,
        });
        let zip = ColumnKind::Text {
            length: TextLength::Varying(5),
        };

        assert_eq!(
            SummaryRule::for_column(&result_only("n", integer)),
            SummaryRule::Numeric
        );
        assert_eq!(
            SummaryRule::for_column(&result_only("zip", zip)),
            SummaryRule::CountOnly
        );
        let text = ColumnKind::Text {
            length: TextLength::Unbounded,
        };
        assert_eq!(SummaryRule::for_column(&result_only("t", text)), SummaryRule::CountOnly);
        assert_eq!(
            SummaryRule::for_column(&result_only("x", ColumnKind::Other)),
            SummaryRule::NumericIfParsable
        );
    }

    #[test]
    fn number_text_parses_exactly() {
        let parsed = |text: &str| ExactNumber::parse(text).map(|number| number.plain_text(0));

        assert_eq!(parsed("1e3").as_deref(), Some("1000"));
        assert_eq!(parsed("-2.5E-2").as_deref(), Some("-0.025"));
        assert_eq!(parsed(".5").as_deref(), Some("0.5"));
        assert_eq!(parsed("7.").as_deref(), Some("7"));
        assert_eq!(parsed("1e999999"), None);
        assert_eq!(
            parsed(&format!("0.{}1", "0".repeat(1_000))),
            None,
            "past the widest numeric"
        );
        assert_eq!(parsed(&"9".repeat(1_000)).map(|text| text.len()), Some(1_000));
        for text in ["", "-", ".", "NaN", "inf", "1,5", "0x10", "1e"] {
            assert_eq!(parsed(text), None, "{text:?}");
        }
    }
}
