use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

/// What a statement says, with the spacing taken out where spacing
/// cannot change it.
///
/// Two texts with the same list are the same statement written
/// differently, which is the only thing a formatter is allowed to do.
pub fn significant_tokens(text: &str, grammar: SqlGrammar, settings: LexicalSettings) -> Vec<SignificantToken> {
    let plan = ScriptPlan::build(text, grammar, settings);
    let mut tokens: Vec<SignificantToken> = Vec::new();
    let mut spacing = Spacing::default();
    for token in plan.tokens(0..text.len()) {
        let slice = text.get(token.range.clone()).unwrap_or_default();
        if token.kind == ScriptTokenKind::Whitespace {
            spacing.spaced = true;
            spacing.line_break |= slice.contains('\n');
            continue;
        }
        let body = match token.kind {
            // A formatter may move the spaces at the end of a
            // comment without changing what the comment says.
            ScriptTokenKind::LineComment | ScriptTokenKind::BlockComment => slice.trim_end(),
            _ => slice,
        };
        let gap = tokens.last().map_or(Gap::Free, |previous| {
            gap_between(grammar, previous, token.kind, body, spacing)
        });
        tokens.push(SignificantToken {
            kind: token.kind,
            text: body.to_owned(),
            gap,
        });
        spacing = Spacing::default();
    }
    tokens
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignificantToken {
    kind: ScriptTokenKind,
    text: String,
    gap: Gap,
}

/// The space between two tokens, kept only where an engine reads the
/// two differently with and without it.
///
/// The script lexer reads every operator character on its own, where
/// an engine reads `+=` or `->>` as one operator; and it reads `b'01'`
/// as a word and a string, where MySQL reads one bit literal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Gap {
    Free,
    Touching,
    Spaced,
    /// Two string literals with a line break between are one string in
    /// PostgreSQL; on one line they are a syntax error.
    LineBreak,
}

/// Words sqlformat spaces from their paren that MySQL 8.4 and MariaDB
/// 11.4 were checked to read the same either way.
const MYSQL_SPACED_CALLS: [&str; 7] = ["EXISTS", "IF", "IFNULL", "IN", "REPLACE", "USING", "VALUES"];

#[derive(Debug, Clone, Copy, Default)]
struct Spacing {
    spaced: bool,
    line_break: bool,
}

fn gap_between(
    grammar: SqlGrammar,
    previous: &SignificantToken,
    kind: ScriptTokenKind,
    text: &str,
    spacing: Spacing,
) -> Gap {
    let strings = previous.kind == ScriptTokenKind::StringLiteral && kind == ScriptTokenKind::StringLiteral;
    if strings && spacing.line_break {
        return Gap::LineBreak;
    }
    let operator = previous.kind == ScriptTokenKind::Punct
        && kind == ScriptTokenKind::Punct
        && previous.text != ","
        && text != ",";
    // Without IGNORE_SPACE, MySQL reads `count(` as the built-in and
    // `count (` as a stored function named count.
    let call = grammar == SqlGrammar::MySql
        && previous.kind == ScriptTokenKind::Word
        && kind == ScriptTokenKind::OpenParen
        && !MYSQL_SPACED_CALLS
            .iter()
            .any(|word| word.eq_ignore_ascii_case(&previous.text));
    let free = spacing_is_free(previous.kind, &previous.text) || spacing_is_free(kind, text);
    if !strings && !operator && !call && free {
        return Gap::Free;
    }
    if spacing.spaced { Gap::Spaced } else { Gap::Touching }
}

/// Whether spacing next to this token changes nothing an engine reads,
/// outside the pairs `gap_between` checks first: a bracket, a
/// separator, a comment, or an operator character that is never part
/// of a name, a literal or a parameter.
fn spacing_is_free(kind: ScriptTokenKind, text: &str) -> bool {
    match kind {
        ScriptTokenKind::OpenParen
        | ScriptTokenKind::CloseParen
        | ScriptTokenKind::Semicolon
        | ScriptTokenKind::LineComment
        | ScriptTokenKind::BlockComment => true,
        ScriptTokenKind::Punct => matches!(
            text,
            "," | "." | "=" | "<" | ">" | "+" | "-" | "*" | "/" | "%" | "^" | "|" | "!" | "~" | "[" | "]"
        ),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tokens_for(text: &str, grammar: SqlGrammar) -> Vec<SignificantToken> {
        significant_tokens(text, grammar, LexicalSettings::default_for(grammar))
    }

    fn tokens(text: &str) -> Vec<SignificantToken> {
        tokens_for(text, SqlGrammar::PostgreSql)
    }

    #[test]
    fn spacing_alone_does_not_change_a_statement() {
        assert_eq!(tokens("select  a ,b from t"), tokens("select a, b\nfrom t"));
        assert_eq!(tokens("select a=-1,(1,-1)"), tokens("select a =- 1, (1, -1)"));
    }

    #[test]
    fn a_changed_word_changes_the_statement() {
        assert_ne!(tokens("select a from t"), tokens("SELECT a from t"));
    }

    #[test]
    fn a_comment_keeps_its_text_but_not_its_trailing_spaces() {
        assert_eq!(tokens("select 1 -- note  "), tokens("select 1 -- note"));
        assert_ne!(tokens("select 1 -- note"), tokens("select 1 -- other"));
    }

    #[test]
    fn an_operator_split_by_a_space_changes_the_statement() {
        assert_ne!(
            tokens_for("SET @x += 1", SqlGrammar::MsSql),
            tokens_for("SET @x + = 1", SqlGrammar::MsSql)
        );
        assert_ne!(tokens("select a->>'k'"), tokens("select a- >>'k'"));
        assert_eq!(tokens("select a->>'k'"), tokens("select a ->> 'k'"));
    }

    #[test]
    fn a_prefix_split_from_its_string_changes_the_statement() {
        assert_ne!(
            tokens_for("select b'01'", SqlGrammar::MySql),
            tokens_for("select b '01'", SqlGrammar::MySql)
        );
        assert_ne!(
            tokens_for("select @@version", SqlGrammar::MySql),
            tokens_for("select @@ version", SqlGrammar::MySql)
        );
    }

    #[test]
    fn a_space_before_a_mysql_call_changes_the_statement() {
        assert_ne!(
            tokens_for("select count(a) from t", SqlGrammar::MySql),
            tokens_for("select count (a) from t", SqlGrammar::MySql)
        );
        assert_eq!(
            tokens_for("select count(a) from t", SqlGrammar::MySql),
            tokens_for("select\n    count(a)\nfrom t", SqlGrammar::MySql)
        );
        assert_eq!(tokens("select count(a) from t"), tokens("select count (a) from t"));
        assert_eq!(
            tokens_for("select ifnull(a, 0) from t where a in(1)", SqlGrammar::MySql),
            tokens_for("select ifnull (a, 0) from t where a in (1)", SqlGrammar::MySql)
        );
    }

    #[test]
    fn strings_joined_onto_one_line_change_the_statement() {
        assert_ne!(tokens("select 'a'\n'b'"), tokens("select 'a' 'b'"));
        assert_eq!(tokens("select 'a'\n'b'"), tokens("select\n    'a'\n    'b'"));
    }
}
