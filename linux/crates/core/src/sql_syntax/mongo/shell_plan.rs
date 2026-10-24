use std::num::NonZeroU32;
use std::ops::Range;

use super::shell_lexer::{ShellToken, ShellTokenKind, lex_shell};
use crate::sql_syntax::script::{
    BatchErrorPolicy, OpenConstruct, ScriptBatch, ScriptDiagnostic, ScriptPlan, ScriptStatement, ScriptToken,
    ScriptTokenKind,
};

/// Tokens after which a line break cannot end a statement: the line
/// goes on.
const CONTINUING: [char; 9] = ['.', ',', '(', '[', '{', ':', '+', '-', '='];

/// The ranges of the statements in `text`, as mongosh reads them: a `;`
/// outside brackets ends one, and so does a line break outside brackets
/// unless the next line goes on with `.method()` or this one ends on a
/// token that cannot end a statement. `show` and `use` end at their line.
pub fn statement_ranges(text: &str) -> Vec<Range<usize>> {
    let tokens = lex_shell(text);
    let mut ranges = Vec::new();
    let mut start: Option<usize> = None;
    let mut last_end = 0;
    let mut last_punct: Option<char> = None;
    let mut line_command = false;
    let mut depth = 0usize;
    for (index, token) in tokens.iter().enumerate() {
        let c = token.punct(text);
        match token.kind {
            ShellTokenKind::Whitespace { newline: true } if depth == 0 && start.is_some() => {
                let continues = !line_command
                    && (last_punct.is_some_and(|last| CONTINUING.contains(&last))
                        || next_significant(&tokens[index + 1..], text) == Some('.'));
                if !continues && let Some(begun) = start.take() {
                    ranges.push(begun..last_end);
                }
                continue;
            }
            kind if kind.is_trivia() => continue,
            _ => {}
        }
        if c == Some(';') && depth == 0 {
            if let Some(begun) = start.take() {
                ranges.push(begun..last_end);
            }
            continue;
        }
        match c {
            Some('(' | '[' | '{') => depth += 1,
            Some(')' | ']' | '}') => depth = depth.saturating_sub(1),
            _ => {}
        }
        if start.is_none() {
            start = Some(token.range.start);
            line_command = matches!(token.text(text), "show" | "use");
        }
        last_end = token.range.end;
        last_punct = c;
    }
    if let Some(begun) = start {
        ranges.push(begun..last_end);
    }
    ranges
}

fn next_significant(tokens: &[ShellToken], text: &str) -> Option<char> {
    let token = tokens.iter().find(|token| !token.kind.is_trivia())?;
    Some(token.punct(text).unwrap_or(' '))
}

/// The editor's plan of shell text: a statement and a batch per
/// statement, the tokens covering the text, and a diagnostic for a
/// string, regular expression or comment that never closes. A failed
/// statement stops the script.
pub(crate) fn plan(text: &str) -> ScriptPlan {
    let tokens = lex_shell(text);
    let mut diagnostics = Vec::new();
    let script_tokens = tokens
        .iter()
        .map(|token| {
            if token.kind.is_open() {
                let construct = match token.kind {
                    ShellTokenKind::BlockComment { .. } => OpenConstruct::BlockComment,
                    _ => OpenConstruct::StringLiteral,
                };
                diagnostics.push(ScriptDiagnostic::Unterminated {
                    construct,
                    start: token.range.start,
                });
            }
            ScriptToken {
                kind: script_kind(token, text),
                range: token.range.clone(),
            }
        })
        .collect();
    let mut statements = Vec::new();
    let mut batches = Vec::new();
    for range in statement_ranges(text) {
        let index = statements.len();
        statements.push(ScriptStatement {
            extent: range.start..extent_end(text, range.end),
            range: range.clone(),
        });
        batches.push(ScriptBatch {
            range,
            repeat: NonZeroU32::MIN,
            statements: index..index + 1,
        });
    }
    ScriptPlan::from_parts(
        script_tokens,
        statements,
        batches,
        diagnostics,
        BatchErrorPolicy::StopScript,
    )
}

/// Where a statement's line ends, past a `;` that closes it.
fn extent_end(text: &str, end: usize) -> usize {
    let rest = &text[end..];
    let line = rest.find(['\n', '\r']).unwrap_or(rest.len());
    end + line
}

fn script_kind(token: &ShellToken, text: &str) -> ScriptTokenKind {
    if token.kind.is_open() {
        return ScriptTokenKind::Unterminated;
    }
    match token.kind {
        ShellTokenKind::Whitespace { .. } => ScriptTokenKind::Whitespace,
        ShellTokenKind::LineComment => ScriptTokenKind::LineComment,
        ShellTokenKind::BlockComment { .. } => ScriptTokenKind::BlockComment,
        ShellTokenKind::String { .. } | ShellTokenKind::Regex { .. } => ScriptTokenKind::StringLiteral,
        ShellTokenKind::Number => ScriptTokenKind::Number,
        ShellTokenKind::Identifier => ScriptTokenKind::Word,
        ShellTokenKind::Punct => match token.punct(text) {
            Some(';') => ScriptTokenKind::Semicolon,
            Some('(') => ScriptTokenKind::OpenParen,
            Some(')') => ScriptTokenKind::CloseParen,
            _ => ScriptTokenKind::Punct,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn statements(text: &str) -> Vec<&str> {
        statement_ranges(text).into_iter().map(|range| &text[range]).collect()
    }

    #[test]
    fn a_semicolon_or_a_line_break_ends_a_statement() {
        assert_eq!(
            statements("use shop\ndb.a.find(); db.b.find()\n\nshow collections"),
            ["use shop", "db.a.find()", "db.b.find()", "show collections"]
        );
    }

    #[test]
    fn a_statement_goes_on_inside_brackets_and_before_a_method() {
        let text = "db.orders.find({\n  qty: 1;\n})\n  .sort({at: -1})\n  // newest\n  .limit(5)\ndb.x.drop()";
        assert_eq!(
            statements(text),
            [
                "db.orders.find({\n  qty: 1;\n})\n  .sort({at: -1})\n  // newest\n  .limit(5)",
                "db.x.drop()"
            ]
        );
        assert_eq!(statements("db.a.find({a:\n1})"), ["db.a.find({a:\n1})"]);
        assert_eq!(statements("db.a\n.find()"), ["db.a\n.find()"]);
    }

    #[test]
    fn a_semicolon_inside_a_string_or_comment_ends_nothing() {
        assert_eq!(
            statements("db.a.find({n: 'x;y'}) /* ; */ // ;\ndb.b.find()"),
            ["db.a.find({n: 'x;y'})", "db.b.find()"]
        );
    }

    #[test]
    fn the_plan_covers_the_text_and_names_what_never_closes() {
        let text = "db.a.find({n: 'open\ndb.b.find()";
        let plan = plan(text);

        assert_eq!(
            plan.diagnostics(),
            [ScriptDiagnostic::Unterminated {
                construct: OpenConstruct::StringLiteral,
                start: 14,
            }]
        );
        let covered: usize = plan.tokens(0..text.len()).map(|token| token.range.len()).sum();
        assert_eq!(covered, text.len());
        assert_eq!(plan.batch_error_policy(), BatchErrorPolicy::StopScript);
        let statements: Vec<&str> = plan.statements().iter().map(|statement| statement.text(text)).collect();
        assert_eq!(statements, ["db.a.find({n: 'open\ndb.b.find()"]);
    }

    #[test]
    fn a_statement_extends_to_its_line_end() {
        let text = "db.a.find();  // all\ndb.b.find()";
        let plan = plan(text);

        assert_eq!(plan.statements()[0].range, 0..11);
        assert_eq!(plan.statements()[0].extent, 0..20);
        assert_eq!(plan.batches().len(), 2);
    }
}
