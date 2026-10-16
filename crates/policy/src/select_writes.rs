use sqlparser::ast::{
    Expr, Function, FunctionArg, FunctionArgExpr, FunctionArguments, JoinConstraint, JoinOperator, Select, SelectItem,
    TableFactor,
};

use sqlparser::dialect::Dialect;
use sqlparser::keywords::Keyword;
use sqlparser::tokenizer::{Token, Tokenizer};

use crate::classify::{StatementClass, StatementFacts, classify_query};

pub(crate) fn select_writes(select: &Select) -> bool {
    select.into.is_some()
        || select.from.iter().any(|t| {
            std::iter::once(&t.relation)
                .chain(t.joins.iter().map(|j| &j.relation))
                .any(|factor| matches!(factor, TableFactor::Derived { subquery, .. } if classify_query(subquery).class.is_write()))
        })
        || select
            .from
            .iter()
            .flat_map(|t| t.joins.iter())
            .any(|join| join_constraint(&join.join_operator).is_some_and(expr_writes))
        || select.selection.as_ref().is_some_and(expr_writes)
        || select.having.as_ref().is_some_and(expr_writes)
        || select.projection.iter().any(|item| match item {
            SelectItem::ExprWithAlias { expr, .. } | SelectItem::UnnamedExpr(expr) => expr_writes(expr),
            _ => false,
        })
}

pub(crate) fn with_locking_backstop(mut facts: StatementFacts, sql: &str, dialect: &dyn Dialect) -> StatementFacts {
    if facts.class == StatementClass::Select && has_locking_clause(sql, dialect) {
        facts.class = StatementClass::Other;
    }
    facts
}

fn has_locking_clause(sql: &str, dialect: &dyn Dialect) -> bool {
    let Ok(tokens) = Tokenizer::new(dialect, sql).tokenize() else {
        return true;
    };
    let keywords: Vec<Option<Keyword>> = tokens
        .iter()
        .filter(|token| !matches!(token, Token::Whitespace(_)))
        .map(|token| match token {
            Token::Word(word) if word.quote_style.is_none() => Some(word.keyword),
            _ => None,
        })
        .collect();
    keywords.windows(2).enumerate().any(|(at, pair)| match pair {
        [Some(Keyword::FOR), Some(Keyword::UPDATE | Keyword::SHARE)] => true,
        [Some(Keyword::FOR), Some(Keyword::NO | Keyword::KEY)] => matches!(
            keywords.get(at + 2),
            Some(Some(Keyword::KEY | Keyword::SHARE | Keyword::UPDATE))
        ),
        _ => false,
    })
}

fn join_constraint(operator: &JoinOperator) -> Option<&Expr> {
    let constraint = match operator {
        JoinOperator::Join(c)
        | JoinOperator::Inner(c)
        | JoinOperator::Left(c)
        | JoinOperator::LeftOuter(c)
        | JoinOperator::Right(c)
        | JoinOperator::RightOuter(c)
        | JoinOperator::FullOuter(c)
        | JoinOperator::Semi(c)
        | JoinOperator::LeftSemi(c)
        | JoinOperator::RightSemi(c)
        | JoinOperator::Anti(c)
        | JoinOperator::LeftAnti(c)
        | JoinOperator::RightAnti(c) => c,
        _ => return None,
    };
    match constraint {
        JoinConstraint::On(expr) => Some(expr),
        _ => None,
    }
}

pub(crate) fn expr_writes(expr: &Expr) -> bool {
    match expr {
        Expr::Subquery(q) => classify_query(q).class.is_write(),
        Expr::BinaryOp { left, right, .. } => expr_writes(left) || expr_writes(right),
        Expr::UnaryOp { expr, .. } => expr_writes(expr),
        Expr::Nested(e) => expr_writes(e),
        Expr::Exists { subquery, .. } => classify_query(subquery).class.is_write(),
        Expr::InSubquery { expr, subquery, .. } => expr_writes(expr) || classify_query(subquery).class.is_write(),
        Expr::InList { expr, list, .. } => expr_writes(expr) || list.iter().any(expr_writes),
        Expr::Between { expr, low, high, .. } => expr_writes(expr) || expr_writes(low) || expr_writes(high),
        Expr::Cast { expr, .. }
        | Expr::IsNull(expr)
        | Expr::IsNotNull(expr)
        | Expr::IsTrue(expr)
        | Expr::IsFalse(expr)
        | Expr::IsNotTrue(expr)
        | Expr::IsNotFalse(expr)
        | Expr::Collate { expr, .. } => expr_writes(expr),
        Expr::Like { expr, pattern, .. }
        | Expr::ILike { expr, pattern, .. }
        | Expr::SimilarTo { expr, pattern, .. } => expr_writes(expr) || expr_writes(pattern),
        Expr::IsDistinctFrom(left, right) | Expr::IsNotDistinctFrom(left, right) => {
            expr_writes(left) || expr_writes(right)
        }
        Expr::Tuple(items) => items.iter().any(expr_writes),
        Expr::Function(function) => function_writes(function),
        Expr::Case {
            operand,
            conditions,
            else_result,
            ..
        } => {
            operand.as_ref().is_some_and(|e| expr_writes(e))
                || conditions
                    .iter()
                    .any(|c| expr_writes(&c.condition) || expr_writes(&c.result))
                || else_result.as_ref().is_some_and(|e| expr_writes(e))
        }
        _ => false,
    }
}

fn function_writes(function: &Function) -> bool {
    let arguments = match &function.args {
        FunctionArguments::Subquery(query) => return classify_query(query).class.is_write(),
        FunctionArguments::List(list) => &list.args,
        FunctionArguments::None => return false,
    };
    arguments.iter().any(|argument| {
        let value = match argument {
            FunctionArg::Named { arg, .. } | FunctionArg::ExprNamed { arg, .. } | FunctionArg::Unnamed(arg) => arg,
        };
        matches!(value, FunctionArgExpr::Expr(expr) if expr_writes(expr))
    }) || function.filter.as_deref().is_some_and(expr_writes)
}

#[cfg(test)]
mod tests {
    use crate::classify::{StatementClass, classify};

    #[test]
    fn select_into_creates_a_table_and_is_a_write() {
        for (sql, driver) in [
            ("SELECT * INTO backup FROM accounts", "postgres"),
            ("SELECT id INTO TEMP scratch FROM accounts", "postgres"),
            ("SELECT * INTO backup FROM accounts", "mssql"),
        ] {
            let facts = classify(sql, driver);
            assert!(facts.writes(), "{sql} must be classified as a write");
            assert_ne!(facts.class, StatementClass::Select, "{sql}");
        }
        assert!(!classify("SELECT * FROM accounts", "postgres").writes());
    }

    #[test]
    fn locking_reads_are_writes_because_a_read_only_session_refuses_them() {
        for sql in [
            "SELECT * FROM users WHERE id = 1 FOR UPDATE",
            "SELECT * FROM users FOR SHARE",
            "SELECT * FROM users FOR NO KEY UPDATE SKIP LOCKED",
            "WITH u AS (SELECT * FROM users FOR UPDATE) SELECT * FROM u",
            "SELECT * FROM (SELECT id FROM users FOR UPDATE) AS s",
        ] {
            assert!(classify(sql, "postgres").writes(), "{sql}");
        }
    }

    #[test]
    fn a_locking_read_nested_anywhere_in_a_select_is_a_write() {
        for (sql, driver) in [
            ("SELECT 1 WHERE EXISTS (SELECT 1 FROM accounts FOR UPDATE)", "postgres"),
            (
                "SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM accounts FOR UPDATE)",
                "postgres",
            ),
            (
                "SELECT * FROM t WHERE id IN (SELECT id FROM accounts FOR UPDATE)",
                "postgres",
            ),
            (
                "SELECT * FROM t WHERE id = (SELECT id FROM accounts LIMIT 1 FOR UPDATE)",
                "postgres",
            ),
            ("SELECT coalesce((SELECT id FROM accounts FOR UPDATE), 0)", "postgres"),
            ("SELECT CAST((SELECT id FROM accounts FOR UPDATE) AS text)", "postgres"),
            (
                "SELECT count(*) FROM t GROUP BY a HAVING max(a) > (SELECT 1 FROM accounts FOR UPDATE)",
                "postgres",
            ),
            (
                "SELECT * FROM t WHERE (SELECT 1 FROM accounts FOR UPDATE) IS NOT NULL",
                "postgres",
            ),
            (
                "SELECT * FROM t WHERE a BETWEEN 0 AND (SELECT 1 FROM accounts FOR UPDATE)",
                "postgres",
            ),
            (
                "SELECT * FROM t WHERE a IN (1, (SELECT 1 FROM accounts FOR UPDATE))",
                "postgres",
            ),
            (
                "SELECT * FROM t JOIN u ON u.id = (SELECT 1 FROM accounts FOR UPDATE)",
                "postgres",
            ),
            (
                "SELECT 1 FROM dual WHERE EXISTS (SELECT 1 FROM accounts FOR UPDATE)",
                "mysql",
            ),
            (
                "SELECT * FROM t WHERE id = ANY (SELECT id FROM accounts FOR UPDATE)",
                "postgres",
            ),
            (
                "SELECT * FROM t ORDER BY (SELECT 1 FROM accounts FOR UPDATE)",
                "postgres",
            ),
            (
                "SELECT a.id FROM a STRAIGHT_JOIN b ON b.id = (SELECT 1 FROM accounts FOR UPDATE)",
                "mysql",
            ),
            ("SELECT CONVERT((SELECT id FROM accounts FOR UPDATE), CHAR)", "mysql"),
            (
                "SELECT * FROM t WHERE id = ANY (SELECT id FROM accounts FOR NO KEY UPDATE)",
                "postgres",
            ),
            (
                "SELECT * FROM t WHERE id IN (SELECT id FROM accounts FOR KEY SHARE)",
                "postgres",
            ),
        ] {
            let facts = classify(sql, driver);
            assert!(facts.writes(), "{driver}: {sql}");
            assert_ne!(facts.class, StatementClass::Select, "{driver}: {sql}");
        }
        assert!(
            classify(
                "SELECT 1 WHERE EXISTS (SELECT 1 FROM accounts LOCK IN SHARE MODE)",
                "mysql"
            )
            .writes(),
            "an unparseable locking read still fails closed"
        );
        for sql in [
            "SELECT 'FOR UPDATE' AS note",
            "SELECT 1 /* FOR UPDATE */",
            "SELECT substring(name FROM 1 FOR 3) FROM t",
            "SELECT 1 WHERE EXISTS (SELECT 1 FROM accounts)",
            "SELECT coalesce((SELECT id FROM accounts LIMIT 1), 0)",
            "SELECT * FROM t WHERE id IN (SELECT id FROM accounts)",
        ] {
            assert!(!classify(sql, "postgres").writes(), "{sql}");
        }
    }
}
