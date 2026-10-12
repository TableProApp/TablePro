use sqlparser::ast::{BinaryOperator, Expr, UnaryOperator, Value};

pub(crate) fn is_constant_true(expr: &Expr) -> bool {
    match expr {
        Expr::Value(value) => match &value.value {
            Value::Boolean(true) => true,
            Value::Number(number, _) => number.parse::<f64>().is_ok_and(|n| n != 0.0),
            _ => false,
        },
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
    let ordering = match (literal(left), literal(right)) {
        (Some(Value::Number(a, _)), Some(Value::Number(b, _))) => match (a.parse::<f64>(), b.parse::<f64>()) {
            (Ok(a), Ok(b)) => a.partial_cmp(&b),
            _ => None,
        },
        (Some(Value::SingleQuotedString(a)), Some(Value::SingleQuotedString(b))) => Some(a.cmp(b)),
        _ => None,
    };
    let Some(ordering) = ordering else { return false };
    match op {
        BinaryOperator::Eq => ordering.is_eq(),
        BinaryOperator::NotEq => ordering.is_ne(),
        BinaryOperator::Lt => ordering.is_lt(),
        BinaryOperator::LtEq => ordering.is_le(),
        BinaryOperator::Gt => ordering.is_gt(),
        _ => ordering.is_ge(),
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
