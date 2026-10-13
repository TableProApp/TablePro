use std::cmp::Ordering;

use sqlparser::ast::{BinaryOperator, Expr, UnaryOperator, Value};

struct NumericLiteral {
    negative: bool,
    digits: String,
    order: i64,
}

impl NumericLiteral {
    fn parse(value: &str) -> Option<Self> {
        let (negative, value) = match value.strip_prefix('-') {
            Some(value) => (true, value),
            None => (false, value.strip_prefix('+').unwrap_or(value)),
        };
        let exponent_index = value.find(['e', 'E']);
        let (mantissa, exponent) = match exponent_index {
            Some(index) => (&value[..index], value[index + 1..].parse::<i64>().ok()?),
            None => (value, 0),
        };
        if mantissa.bytes().any(|byte| matches!(byte, b'e' | b'E')) {
            return None;
        }
        let (whole, fraction) = match mantissa.split_once('.') {
            Some(parts) => parts,
            None => (mantissa, ""),
        };
        if whole.is_empty() && fraction.is_empty()
            || !whole.bytes().all(|byte| byte.is_ascii_digit())
            || !fraction.bytes().all(|byte| byte.is_ascii_digit())
        {
            return None;
        }
        let digits = format!("{whole}{fraction}");
        let significant = digits.trim_start_matches('0');
        if significant.is_empty() {
            return Some(Self {
                negative: false,
                digits: String::from("0"),
                order: 0,
            });
        }
        let trimmed = significant.trim_end_matches('0');
        let removed_zeros = i64::try_from(significant.len() - trimmed.len()).ok()?;
        let fraction_len = i64::try_from(fraction.len()).ok()?;
        let exponent = exponent.checked_sub(fraction_len)?.checked_add(removed_zeros)?;
        let digits = trimmed.to_owned();
        let order = i64::try_from(digits.len()).ok()?.checked_add(exponent)?;
        Some(Self {
            negative,
            digits,
            order,
        })
    }

    fn is_zero(&self) -> bool {
        self.digits == "0"
    }

    fn compare(&self, other: &Self) -> Ordering {
        if self.negative != other.negative {
            return if self.negative {
                Ordering::Less
            } else {
                Ordering::Greater
            };
        }
        let order = self.decimal_order().cmp(&other.decimal_order());
        let magnitude = if order != Ordering::Equal {
            order
        } else {
            self.compare_digits(other)
        };
        if self.negative { magnitude.reverse() } else { magnitude }
    }

    fn decimal_order(&self) -> i64 {
        self.order
    }

    fn compare_digits(&self, other: &Self) -> Ordering {
        let width = self.digits.len().max(other.digits.len());
        for index in 0..width {
            let left = self.digits.as_bytes().get(index).copied().unwrap_or(b'0');
            let right = other.digits.as_bytes().get(index).copied().unwrap_or(b'0');
            match left.cmp(&right) {
                Ordering::Equal => {}
                ordering => return ordering,
            }
        }
        Ordering::Equal
    }
}

pub(crate) fn is_constant_true(expr: &Expr) -> bool {
    if let Some(value) = numeric_truth(expr) {
        return value;
    }
    match expr {
        Expr::Value(value) => matches!(&value.value, Value::Boolean(true)),
        Expr::Nested(inner) => is_constant_true(inner),
        Expr::UnaryOp {
            op: UnaryOperator::Not,
            expr,
        } => is_constant_false(expr),
        Expr::BinaryOp {
            left,
            op:
                op @ (BinaryOperator::Eq
                | BinaryOperator::NotEq
                | BinaryOperator::Lt
                | BinaryOperator::LtEq
                | BinaryOperator::Gt
                | BinaryOperator::GtEq),
            right,
        } => compare_literals(left, op, right),
        Expr::BinaryOp {
            left,
            op: BinaryOperator::And,
            right,
        } => is_constant_true(left) && is_constant_true(right),
        Expr::BinaryOp {
            left,
            op: BinaryOperator::Or,
            right,
        } => is_constant_true(left) || is_constant_true(right),
        _ => false,
    }
}

fn is_constant_false(expr: &Expr) -> bool {
    if let Some(value) = numeric_truth(expr) {
        return !value;
    }
    match expr {
        Expr::Value(value) => matches!(value.value, Value::Boolean(false)),
        Expr::Nested(inner) => is_constant_false(inner),
        Expr::UnaryOp {
            op: UnaryOperator::Not,
            expr,
        } => is_constant_true(expr),
        _ => false,
    }
}

fn literal(expr: &Expr) -> Option<&Value> {
    match expr {
        Expr::Value(value) => Some(&value.value),
        Expr::Nested(inner) => literal(inner),
        _ => None,
    }
}

fn compare_literals(left: &Expr, op: &BinaryOperator, right: &Expr) -> bool {
    if numeric_literal_text(left).is_some() && numeric_literal_text(right).is_some() {
        let (Some(left), Some(right)) = (numeric_literal(left), numeric_literal(right)) else {
            return true;
        };
        return comparison_is_true(left.compare(&right), op);
    }
    let ordering = match (literal(left), literal(right)) {
        (Some(Value::SingleQuotedString(a)), Some(Value::SingleQuotedString(b))) => Some(a.cmp(b)),
        _ => None,
    };
    let Some(ordering) = ordering else { return false };
    comparison_is_true(ordering, op)
}

fn comparison_is_true(ordering: Ordering, op: &BinaryOperator) -> bool {
    match op {
        BinaryOperator::Eq => ordering.is_eq(),
        BinaryOperator::NotEq => ordering.is_ne(),
        BinaryOperator::Lt => ordering.is_lt(),
        BinaryOperator::LtEq => ordering.is_le(),
        BinaryOperator::Gt => ordering.is_gt(),
        _ => ordering.is_ge(),
    }
}

fn numeric_truth(expr: &Expr) -> Option<bool> {
    let value = numeric_literal_text(expr)?;
    Some(NumericLiteral::parse(value).is_none_or(|number| !number.is_zero()))
}

fn numeric_literal_text(expr: &Expr) -> Option<&str> {
    match expr {
        Expr::Value(value) => match &value.value {
            Value::Number(number, _) => Some(number),
            _ => None,
        },
        Expr::Nested(inner)
        | Expr::UnaryOp {
            op: UnaryOperator::Minus | UnaryOperator::Plus,
            expr: inner,
        } => numeric_literal_text(inner),
        _ => None,
    }
}

fn numeric_literal(expr: &Expr) -> Option<NumericLiteral> {
    match expr {
        Expr::Value(value) => match &value.value {
            Value::Number(number, _) => NumericLiteral::parse(number),
            _ => None,
        },
        Expr::Nested(inner)
        | Expr::UnaryOp {
            op: UnaryOperator::Plus,
            expr: inner,
        } => numeric_literal(inner),
        Expr::UnaryOp {
            op: UnaryOperator::Minus,
            expr: inner,
        } => {
            let mut number = numeric_literal(inner)?;
            if !number.is_zero() {
                number.negative = !number.negative;
            }
            Some(number)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use crate::classify::classify;

    fn unscoped(sql: &str) -> bool {
        classify(sql, "postgres").contains_unscoped_dml
    }

    #[test]
    fn a_constant_true_predicate_is_unscoped() {
        for sql in [
            "DELETE FROM t WHERE true",
            "DELETE FROM t WHERE 1=1",
            "DELETE FROM t WHERE (1 = 1)",
            "DELETE FROM t WHERE 'a' = 'a'",
            "DELETE FROM t WHERE id = 1 OR true",
            "DELETE FROM t WHERE NOT false",
            "DELETE FROM t WHERE true AND 1 = 1",
            "DELETE FROM t WHERE 1 <> 2",
            "DELETE FROM t WHERE 2 > 1",
            "DELETE FROM t WHERE 9007199254740992 < 9007199254740993",
            "DELETE FROM t WHERE 9007199254740993 > 9007199254740992",
            "DELETE FROM t WHERE 0.10000000000000001 > 0.1",
            "DELETE FROM t WHERE -1 < 0",
            "DELETE FROM t WHERE 1e-1000",
            "DELETE FROM t WHERE 'a' < 'b'",
            "DELETE FROM t WHERE 1",
            "UPDATE t SET a = 1 WHERE true",
            "UPDATE t SET a = 1 WHERE 1=1",
        ] {
            assert!(unscoped(sql), "{sql}");
        }
    }

    #[test]
    fn a_real_predicate_is_scoped() {
        for sql in [
            "DELETE FROM t WHERE id = 1",
            "DELETE FROM t WHERE 1 = 2",
            "DELETE FROM t WHERE 9007199254740993 < 9007199254740992",
            "DELETE FROM t WHERE 0.10000000000000001 = 0.1",
            "DELETE FROM t WHERE -2 > -1",
            "DELETE FROM t WHERE 0e-1000",
            "DELETE FROM t WHERE 0",
            "DELETE FROM t WHERE 2 < 1",
            "DELETE FROM t WHERE false",
            "DELETE FROM t WHERE id = 1 AND true",
            "UPDATE t SET a = 1 WHERE id = 1",
        ] {
            assert!(!unscoped(sql), "{sql}");
        }
    }

    #[test]
    fn a_statement_without_a_predicate_is_still_unscoped() {
        assert!(unscoped("DELETE FROM t"));
        assert!(unscoped("UPDATE t SET a = 1"));
    }
}
