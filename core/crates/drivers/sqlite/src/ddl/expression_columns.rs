//! The columns an expression of a table's own definition names: a
//! CHECK, a generated column, an index key or an index's WHERE. These
//! name only the table's own columns, so what is left to settle is which
//! words are names, and SQLite's grammar settles it (parse.y): a word
//! before `(` calls a function, one after COLLATE is a collation, the
//! words after AS in a CAST are a type, and a word that is also a
//! keyword is a name only where the keyword does not fit, as its
//! `%fallback ID` list says.

use std::collections::HashSet;

use tablepro_core::sql_syntax::script::ScriptTokenKind;

use super::create_table_source::{Token, tokens, unquote};

/// The keywords that are a name only when quoted: SQLite's keywords
/// outside `%fallback ID` and the JOIN_KW and INDEXED classes (parse.y
/// and tool/mkkeywordhash.c, 3.46). FILTER, OVER and WINDOW are left
/// out, since the tokenizer reads them as names unless a window follows.
const RESERVED: &[&str] = &[
    "ADD",
    "ALL",
    "ALTER",
    "AND",
    "AS",
    "AUTOINCREMENT",
    "BETWEEN",
    "CASE",
    "CHECK",
    "COLLATE",
    "COMMIT",
    "CONSTRAINT",
    "CREATE",
    "DEFAULT",
    "DEFERRABLE",
    "DELETE",
    "DISTINCT",
    "DROP",
    "ELSE",
    "ESCAPE",
    "EXCEPT",
    "EXISTS",
    "FOREIGN",
    "FROM",
    "GROUP",
    "HAVING",
    "IN",
    "INDEX",
    "INSERT",
    "INTERSECT",
    "INTO",
    "IS",
    "ISNULL",
    "JOIN",
    "LIMIT",
    "NOT",
    "NOTHING",
    "NOTNULL",
    "NULL",
    "ON",
    "OR",
    "ORDER",
    "PRIMARY",
    "REFERENCES",
    "RETURNING",
    "SELECT",
    "SET",
    "TABLE",
    "THEN",
    "TO",
    "TRANSACTION",
    "UNION",
    "UNIQUE",
    "UPDATE",
    "USING",
    "VALUES",
    "WHEN",
    "WHERE",
];

/// How the terms of a list read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Terms {
    /// One expression, as a CHECK holds.
    Expression,
    /// Index keys, where a string standing alone names a column (build.c,
    /// `sqlite3StringToId`).
    Keys,
}

/// The columns `tokens` name, folded to ASCII lowercase.
pub(super) fn named_columns(sql: &str, tokens: &[Token], terms: Terms) -> HashSet<String> {
    Reader { sql, tokens, terms }.read()
}

/// The tokens between the first `(` and the `)` that closes it.
pub(super) fn first_group(tokens: &[Token]) -> Option<&[Token]> {
    let open = tokens
        .iter()
        .position(|token| token.kind == ScriptTokenKind::OpenParen)?;
    let close = closing(tokens, open)?;
    tokens.get(open + 1..close)
}

/// The columns a CREATE INDEX names in its keys and its WHERE. `None`
/// when the text does not read.
pub(super) fn index_columns(sql: &str) -> Option<HashSet<String>> {
    let tokens = tokens(sql).ok()?;
    let open = tokens
        .iter()
        .position(|token| token.kind == ScriptTokenKind::OpenParen)?;
    let close = closing(&tokens, open)?;
    let mut names = named_columns(sql, tokens.get(open + 1..close)?, Terms::Keys);
    let reader = Reader {
        sql,
        tokens: &tokens,
        terms: Terms::Expression,
    };
    if reader.word(close + 1, "WHERE") {
        let end = tokens
            .iter()
            .position(|token| token.kind == ScriptTokenKind::Semicolon)
            .unwrap_or(tokens.len());
        names.extend(named_columns(sql, tokens.get(close + 2..end)?, Terms::Expression));
    }
    Some(names)
}

/// The `)` that closes the `(` at `open`.
fn closing(tokens: &[Token], open: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (index, token) in tokens.iter().enumerate().skip(open) {
        match token.kind {
            ScriptTokenKind::OpenParen => depth += 1,
            ScriptTokenKind::CloseParen => {
                depth -= 1;
                if depth == 0 {
                    return Some(index);
                }
            }
            _ => {}
        }
    }
    None
}

struct Reader<'s> {
    sql: &'s str,
    tokens: &'s [Token],
    terms: Terms,
}

impl Reader<'_> {
    fn read(&self) -> HashSet<String> {
        let mut names = HashSet::new();
        // Whether an operand may start here rather than an operator.
        let mut operand = true;
        let mut depth = 0usize;
        // The depth of each CASE still open, and inside each CAST's
        // parentheses.
        let mut cases: Vec<usize> = Vec::new();
        let mut casts: Vec<usize> = Vec::new();
        let mut index = 0;
        while let Some(kind) = self.kind(index) {
            match kind {
                ScriptTokenKind::OpenParen => {
                    depth += 1;
                    operand = true;
                }
                ScriptTokenKind::CloseParen => {
                    if casts.last() == Some(&depth) {
                        casts.pop();
                    }
                    depth = depth.saturating_sub(1);
                    operand = false;
                }
                ScriptTokenKind::Number => operand = false,
                ScriptTokenKind::Word | ScriptTokenKind::QuotedIdentifier | ScriptTokenKind::StringLiteral => {
                    let qualified = self.punct(index.wrapping_sub(1), ".");
                    let qualifies = self.punct(index + 1, ".");
                    if self.word(index.wrapping_sub(1), "COLLATE") {
                        operand = false;
                    } else if kind == ScriptTokenKind::StringLiteral {
                        if qualified || (!qualifies && self.key_alone(index, depth)) {
                            names.extend(self.name(index));
                        }
                        operand = false;
                    } else if kind == ScriptTokenKind::Word
                        && !qualified
                        && self.is_keyword(index, operand, cases.last() == Some(&depth))
                    {
                        let word = self.text(index).to_ascii_uppercase();
                        match word.as_str() {
                            "CASE" => {
                                cases.push(depth);
                                operand = true;
                            }
                            "END" => {
                                cases.pop();
                                operand = false;
                            }
                            "AS" if casts.last() == Some(&depth) => {
                                // The type runs to the CAST's `)`, read next.
                                match closing_from(self.tokens, index) {
                                    Some(close) => {
                                        index = close;
                                        continue;
                                    }
                                    None => break,
                                }
                            }
                            "CAST" => {
                                if self.kind(index + 1) == Some(ScriptTokenKind::OpenParen) {
                                    casts.push(depth + 1);
                                }
                                operand = true;
                            }
                            "NULL" | "ISNULL" | "NOTNULL" | "ASC" | "DESC" | "CURRENT_DATE" | "CURRENT_TIME"
                            | "CURRENT_TIMESTAMP" => operand = false,
                            // A NOT after an operand starts NOT LIKE, NOT
                            // IN or NOT NULL, and before one negates it.
                            "NOT" => {}
                            _ => operand = true,
                        }
                    } else if self.kind(index + 1) == Some(ScriptTokenKind::OpenParen) || qualifies {
                        // A function's name, or the table before a column.
                        operand = true;
                    } else {
                        names.extend(self.name(index));
                        operand = false;
                    }
                }
                _ => operand = true,
            }
            index += 1;
        }
        names
    }

    /// Whether the word at `index` is a keyword where it stands: always
    /// for a reserved one, and for one SQLite also takes as a name, only
    /// where the keyword fits, as the parser tries it first.
    fn is_keyword(&self, index: usize, operand: bool, case_open: bool) -> bool {
        let word = self.text(index).to_ascii_uppercase();
        if RESERVED.contains(&word.as_str()) {
            return true;
        }
        match word.as_str() {
            "CAST" | "RAISE" | "CURRENT_DATE" | "CURRENT_TIME" | "CURRENT_TIMESTAMP" => operand,
            "LIKE" | "GLOB" | "REGEXP" | "MATCH" | "ASC" | "DESC" => !operand,
            "END" => !operand && case_open,
            _ => false,
        }
    }

    /// Whether the string at `index` is a whole index key.
    fn key_alone(&self, index: usize, depth: usize) -> bool {
        let starts = index == 0 || self.punct(index - 1, ",");
        let ends = self.kind(index + 1).is_none()
            || self.punct(index + 1, ",")
            || ["COLLATE", "ASC", "DESC"].iter().any(|word| self.word(index + 1, word));
        self.terms == Terms::Keys && depth == 0 && starts && ends
    }

    fn kind(&self, index: usize) -> Option<ScriptTokenKind> {
        self.tokens.get(index).map(|token| token.kind)
    }

    fn text(&self, index: usize) -> &str {
        self.tokens
            .get(index)
            .and_then(|token| self.sql.get(token.range.clone()))
            .unwrap_or_default()
    }

    fn word(&self, index: usize, word: &str) -> bool {
        self.kind(index) == Some(ScriptTokenKind::Word) && self.text(index).eq_ignore_ascii_case(word)
    }

    fn punct(&self, index: usize, punct: &str) -> bool {
        self.kind(index) == Some(ScriptTokenKind::Punct) && self.text(index) == punct
    }

    fn name(&self, index: usize) -> Option<String> {
        match self.kind(index)? {
            ScriptTokenKind::Word => Some(self.text(index).to_ascii_lowercase()),
            ScriptTokenKind::QuotedIdentifier | ScriptTokenKind::StringLiteral => {
                Some(unquote(self.text(index)).to_ascii_lowercase())
            }
            _ => None,
        }
    }
}

/// The `)` that closes the parentheses `index` stands in.
fn closing_from(tokens: &[Token], index: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (at, token) in tokens.iter().enumerate().skip(index + 1) {
        match token.kind {
            ScriptTokenKind::OpenParen => depth += 1,
            ScriptTokenKind::CloseParen if depth == 0 => return Some(at),
            ScriptTokenKind::CloseParen => depth -= 1,
            _ => {}
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn expression(sql: &str) -> Vec<String> {
        let tokens = tokens(sql).expect("the expression reads");
        sorted(named_columns(sql, &tokens, Terms::Expression))
    }

    fn sorted(names: HashSet<String>) -> Vec<String> {
        let mut names: Vec<String> = names.into_iter().collect();
        names.sort();
        names
    }

    #[test]
    fn a_function_collation_type_or_keyword_is_not_a_column() {
        assert_eq!(expression("date(created) IS NOT NULL"), ["created"]);
        assert_eq!(expression("CAST(a AS text) <> '' COLLATE nocase"), ["a"]);
        assert_eq!(expression("CAST(a AS VARCHAR(10)) = b"), ["a", "b"]);
        assert_eq!(expression("CASE WHEN a THEN 1 ELSE 2 END > 0"), ["a"]);
        assert_eq!(
            expression("current_time IS NOT NULL AND b NOT LIKE 'x%' ESCAPE '!'"),
            ["b"]
        );
        assert_eq!(expression("b GLOB 'x' OR b MATCH 'y' OR b REGEXP 'z'"), ["b"]);
        assert_eq!(
            expression("a IS NOT DISTINCT FROM b AND c BETWEEN 1 AND 2"),
            ["a", "b", "c"]
        );
        assert_eq!(
            expression("abs(a) + json_extract(b, '$.c') -> '$.d' || 'e'"),
            ["a", "b"]
        );
    }

    #[test]
    fn a_keyword_is_a_column_where_only_a_name_fits() {
        assert_eq!(expression("CASE WHEN a THEN end END > 0"), ["a", "end"]);
        assert_eq!(
            expression("CASE (CASE a WHEN 1 THEN 2 END) WHEN end THEN 1 END"),
            ["a", "end"]
        );
        assert_eq!(expression("like > 0 AND b like 'x'"), ["b", "like"]);
        assert_eq!(expression("key IS NULL OR desc > 0 OR true"), ["desc", "key", "true"]);
        assert_eq!(expression("end > 0"), ["end"]);
    }

    #[test]
    fn a_quoted_or_qualified_name_is_a_column() {
        assert_eq!(
            expression("\"a\" <> 'b' AND t.c > [d] AND main.t.`e` = 1 AND 'f'.'g' = 2"),
            ["a", "c", "d", "e", "g"]
        );
    }

    #[test]
    fn index_keys_and_their_where_name_columns() {
        assert_eq!(
            index_columns(
                "CREATE INDEX i ON t (a COLLATE nocase DESC, lower(b), 'c', desc, e ASC, \"f\" COLLATE 'x') WHERE \
                 g IS NOT NULL AND end > 0"
            )
            .map(sorted),
            Some(
                ["a", "b", "c", "desc", "e", "end", "f", "g"]
                    .map(str::to_owned)
                    .to_vec()
            )
        );
        assert_eq!(
            index_columns("CREATE UNIQUE INDEX IF NOT EXISTS main.i ON t (lower(a) || 'b')").map(sorted),
            Some(vec!["a".to_owned()])
        );
        assert_eq!(index_columns("CREATE INDEX i ON t (a"), None);
    }

    #[test]
    fn the_first_group_is_what_its_parentheses_hold() {
        let sql = "CONSTRAINT positive CHECK (a > (b + 1)) ON CONFLICT ABORT";
        let tokens = tokens(sql).expect("reads");

        let group = first_group(&tokens).expect("a group");

        assert_eq!(sorted(named_columns(sql, group, Terms::Expression)), ["a", "b"]);
    }
}
