use std::num::NonZeroU32;
use std::ops::Range;

use super::command_lexer::{ArgumentForm, split_commands};
use crate::sql_syntax::script::{
    BatchErrorPolicy, OpenConstruct, ScriptBatch, ScriptDiagnostic, ScriptPlan, ScriptStatement, ScriptToken,
    ScriptTokenKind,
};

/// The editor's plan of Redis text: a statement and a batch per command,
/// a token per argument and per run of blanks between them. A failed
/// command stops the script, as it does on the SQL engines.
pub(crate) fn plan(text: &str) -> ScriptPlan {
    let mut tokens = Vec::new();
    let mut statements = Vec::new();
    let mut batches = Vec::new();
    let mut diagnostics = Vec::new();
    let mut covered = 0;
    for command in split_commands(text) {
        for argument in &command.arguments {
            push_gap(&mut tokens, covered..argument.range.start);
            let kind = match argument.form {
                ArgumentForm::Bare => ScriptTokenKind::Word,
                ArgumentForm::Quoted => ScriptTokenKind::StringLiteral,
                ArgumentForm::Unterminated => ScriptTokenKind::Unterminated,
            };
            if let (ArgumentForm::Unterminated, Some(start)) = (argument.form, argument.quote_start) {
                diagnostics.push(ScriptDiagnostic::Unterminated {
                    construct: OpenConstruct::StringLiteral,
                    start,
                });
            }
            tokens.push(ScriptToken {
                kind,
                range: argument.range.clone(),
            });
            covered = argument.range.end;
        }
        let index = statements.len();
        let line_end = text
            .get(command.range.end..)
            .and_then(|rest| rest.find(['\n', '\r']))
            .map_or(text.len(), |offset| command.range.end + offset);
        statements.push(ScriptStatement {
            range: command.range.clone(),
            extent: command.range.start..line_end,
        });
        batches.push(ScriptBatch {
            range: command.range,
            repeat: NonZeroU32::MIN,
            statements: index..index + 1,
        });
    }
    push_gap(&mut tokens, covered..text.len());
    ScriptPlan::from_parts(tokens, statements, batches, diagnostics, BatchErrorPolicy::StopScript)
}

fn push_gap(tokens: &mut Vec<ScriptToken>, range: Range<usize>) {
    if !range.is_empty() {
        tokens.push(ScriptToken {
            kind: ScriptTokenKind::Whitespace,
            range,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_command_is_a_statement_and_a_batch() {
        let text = "GET a\n  SET b \"x y\"  \n";
        let plan = plan(text);

        let statements: Vec<&str> = plan.statements().iter().map(|statement| statement.text(text)).collect();
        assert_eq!(statements, ["GET a", "SET b \"x y\""]);
        assert_eq!(plan.batches().len(), 2);
        assert_eq!(plan.statements()[1].extent, 8..21);
        assert!(plan.diagnostics().is_empty());
        assert_eq!(plan.batch_error_policy(), BatchErrorPolicy::StopScript);
    }

    #[test]
    fn the_tokens_cover_the_text() {
        let text = " GET  'k' \n";
        let plan = plan(text);

        let kinds: Vec<ScriptTokenKind> = plan.tokens(0..text.len()).map(|token| token.kind).collect();
        assert_eq!(
            kinds,
            [
                ScriptTokenKind::Whitespace,
                ScriptTokenKind::Word,
                ScriptTokenKind::Whitespace,
                ScriptTokenKind::StringLiteral,
                ScriptTokenKind::Whitespace,
            ]
        );
    }

    #[test]
    fn an_open_quote_is_a_diagnostic() {
        let plan = plan("SET k \"open\nGET k");

        assert_eq!(
            plan.diagnostics(),
            [ScriptDiagnostic::Unterminated {
                construct: OpenConstruct::StringLiteral,
                start: 6,
            }]
        );
        assert_eq!(plan.statements().len(), 1);
    }
}
