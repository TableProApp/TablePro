use std::num::NonZeroU32;
use std::ops::Range;

use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::compound_tracker::CompoundTracker;
use crate::sql_syntax::script::directive_scan::{delimiter_line, go_line};
use crate::sql_syntax::script::lexer::{LexedToken, Lexer};
use crate::sql_syntax::script::script_rules::{Boundary, ScriptRules, rules_for};
use crate::sql_syntax::script::server_reading::{self, ServerReading};
use crate::sql_syntax::script::{
    BatchErrorPolicy, LexicalSettings, OpenConstruct, ScriptBatch, ScriptDiagnostic, ScriptStatement, ScriptToken,
    ScriptTokenKind,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScriptPlan {
    tokens: Vec<ScriptToken>,
    statements: Vec<ScriptStatement>,
    batches: Vec<ScriptBatch>,
    diagnostics: Vec<ScriptDiagnostic>,
    batch_error: BatchErrorPolicy,
}

impl ScriptPlan {
    pub fn build(text: &str, grammar: SqlGrammar, settings: LexicalSettings) -> ScriptPlan {
        Self::read_as(text, grammar, settings, ServerReading::Client)
    }

    pub(crate) fn read_as(
        text: &str,
        grammar: SqlGrammar,
        settings: LexicalSettings,
        reading: ServerReading,
    ) -> ScriptPlan {
        match rules_for(grammar) {
            Some(rules) => Builder::new(text, rules, settings, reading, ";").run().0,
            None if grammar == SqlGrammar::Mongo => crate::sql_syntax::mongo::plan(text),
            None => crate::sql_syntax::redis::plan(text),
        }
    }

    /// `text` read on from a point where `delimiter` is in effect, as a
    /// client reads a file a piece at a time. Gives back where the last
    /// statement, batch or directive line that is known to be whole ends,
    /// and the delimiter in effect there. `None` for a grammar that is not
    /// SQL.
    pub(crate) fn build_continuing(
        text: &str,
        grammar: SqlGrammar,
        settings: LexicalSettings,
        delimiter: &str,
    ) -> Option<(ScriptPlan, Settled)> {
        let rules = rules_for(grammar)?;
        let (plan, settled) = Builder::new(text, rules, settings, ServerReading::Client, delimiter).run();
        Some((plan, settled))
    }

    pub(crate) fn from_parts(
        tokens: Vec<ScriptToken>,
        statements: Vec<ScriptStatement>,
        batches: Vec<ScriptBatch>,
        diagnostics: Vec<ScriptDiagnostic>,
        batch_error: BatchErrorPolicy,
    ) -> ScriptPlan {
        ScriptPlan {
            tokens,
            statements,
            batches,
            diagnostics,
            batch_error,
        }
    }

    /// Every plan the client or a server may make of `text`: as the client
    /// splits it and, on MySQL, as each server reads what it is sent, at
    /// each version its executable comments name. On SQL Server, with a
    /// `--` after a number's `e` a comment and not. Each with backslash
    /// escapes on and off, since a session setting decides. Built one at a
    /// time. `None` when the text names too many versions to try.
    pub fn server_readings(text: &str, grammar: SqlGrammar) -> Option<impl Iterator<Item = ScriptPlan> + '_> {
        let readings = server_reading::server_readings(text, grammar)?;
        Some(readings.into_iter().flat_map(move |reading| {
            [false, true]
                .map(|backslash_escapes| Self::read_as(text, grammar, LexicalSettings { backslash_escapes }, reading))
        }))
    }

    /// The pieces a client sends one at a time when a `DELIMITER` or `GO`
    /// line splits `text`, each of which a server reads anew. Empty when
    /// no such line does.
    pub(crate) fn client_pieces(text: &str, grammar: SqlGrammar) -> Vec<&str> {
        let plan = Self::build(text, grammar, LexicalSettings::default_for(grammar));
        if !plan.tokens.iter().any(|token| token.kind == ScriptTokenKind::Directive) {
            return Vec::new();
        }
        plan.statements
            .iter()
            .filter_map(|statement| text.get(statement.range.clone()))
            .collect()
    }

    pub fn batches(&self) -> &[ScriptBatch] {
        &self.batches
    }

    pub fn statements(&self) -> &[ScriptStatement] {
        &self.statements
    }

    pub fn statement_at(&self, byte: usize) -> Option<&ScriptStatement> {
        let following = self
            .statements
            .partition_point(|statement| statement.range.start <= byte);
        self.statements.get(following.saturating_sub(1))
    }

    pub fn diagnostics(&self) -> &[ScriptDiagnostic] {
        &self.diagnostics
    }

    pub fn tokens(&self, range: Range<usize>) -> impl Iterator<Item = ScriptToken> + '_ {
        let first = self.tokens.partition_point(|token| token.range.end <= range.start);
        self.tokens
            .get(first..)
            .unwrap_or_default()
            .iter()
            .take_while(move |token| token.range.start < range.end)
            .cloned()
    }

    pub fn batch_error_policy(&self) -> BatchErrorPolicy {
        self.batch_error
    }
}

/// Where a plan of a piece of a script stops being sure of itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Settled {
    pub offset: usize,
    pub delimiter: String,
}

struct Builder<'a> {
    text: &'a str,
    rules: &'static ScriptRules,
    lexer: Lexer<'a>,
    reads_directives: bool,
    tracker: CompoundTracker,
    delimiter: &'a str,
    open: Option<Range<usize>>,
    tokens: Vec<ScriptToken>,
    statements: Vec<ScriptStatement>,
    batches: Vec<ScriptBatch>,
    diagnostics: Vec<ScriptDiagnostic>,
    settled: usize,
    settled_delimiter: &'a str,
}

impl<'a> Builder<'a> {
    fn new(
        text: &'a str,
        rules: &'static ScriptRules,
        settings: LexicalSettings,
        reading: ServerReading,
        delimiter: &'a str,
    ) -> Self {
        Self {
            text,
            rules,
            lexer: Lexer::new(text, &rules.syntax, settings, reading),
            reads_directives: reading.reads_directives(),
            tracker: CompoundTracker::new(rules.compound, rules.parens_hold_semicolons),
            delimiter,
            open: None,
            tokens: Vec::new(),
            statements: Vec::new(),
            batches: Vec::new(),
            diagnostics: Vec::new(),
            settled: 0,
            settled_delimiter: delimiter,
        }
    }

    fn run(mut self) -> (ScriptPlan, Settled) {
        while self.lexer.position() < self.text.len() {
            if self.reads_directives && self.lexer.at_line_start() && self.accept_directive() {
                continue;
            }
            let delimiter = (self.rules.boundary == Boundary::DelimiterDirectives).then_some(self.delimiter);
            let Some(token) = self.lexer.next_token(delimiter) else {
                break;
            };
            self.accept(token);
        }
        if let Some(start) = self.lexer.open_executable_comment()
            && self.diagnostics.is_empty()
        {
            self.diagnostics.push(ScriptDiagnostic::Unterminated {
                construct: OpenConstruct::BlockComment,
                start,
            });
        }
        let settled = Settled {
            offset: self.settled,
            delimiter: self.settled_delimiter.to_owned(),
        };
        self.finish_statement(None, NonZeroU32::MIN);
        self.extend_extents();
        let plan = ScriptPlan {
            tokens: self.tokens,
            statements: self.statements,
            batches: self.batches,
            diagnostics: self.diagnostics,
            batch_error: self.rules.batch_error,
        };
        (plan, settled)
    }

    fn accept_directive(&mut self) -> bool {
        let line_start = self.lexer.position();
        match self.rules.boundary {
            Boundary::GoBatch => {
                let Some(line) = go_line(self.text, line_start) else {
                    return false;
                };
                self.push_directive(line_start, line.start, line.end);
                self.finish_statement(None, line.repeat);
                self.settle(line.end);
                true
            }
            Boundary::DelimiterDirectives if self.open.is_none() => {
                let Some(line) = delimiter_line(self.text, line_start) else {
                    return false;
                };
                self.push_directive(line_start, line.start, line.end);
                if let Some(delimiter) = line.delimiter {
                    self.delimiter = delimiter;
                }
                self.settle(line.end);
                true
            }
            Boundary::DelimiterDirectives | Boundary::Semicolon => false,
        }
    }

    fn push_directive(&mut self, line_start: usize, start: usize, end: usize) {
        if start > line_start {
            self.push_token(ScriptTokenKind::Whitespace, line_start..start);
        }
        self.push_token(ScriptTokenKind::Directive, start..end);
        self.lexer.skip_to(end);
    }

    fn accept(&mut self, token: LexedToken) {
        let LexedToken { kind, range, open } = token;
        if let Some(construct) = open {
            self.diagnostics.push(ScriptDiagnostic::Unterminated {
                construct,
                start: range.start,
            });
        }
        if !kind.is_trivia() {
            let terminates = kind == ScriptTokenKind::Semicolon
                && self.rules.boundary != Boundary::GoBatch
                && self.tracker.semicolon_ends_statement();
            if terminates {
                self.finish_statement(Some(range.end), NonZeroU32::MIN);
                self.settle(range.end);
            } else {
                if kind != ScriptTokenKind::Semicolon {
                    self.tracker.observe(kind, &self.text[range.clone()]);
                }
                self.open = Some(match self.open.take() {
                    Some(open) => open.start..range.end,
                    None => range.clone(),
                });
            }
        }
        self.push_token(kind, range);
    }

    /// Nothing open before `offset` can change with more text.
    fn settle(&mut self, offset: usize) {
        if self.open.is_none() {
            self.settled = offset;
            self.settled_delimiter = self.delimiter;
        }
    }

    fn push_token(&mut self, kind: ScriptTokenKind, range: Range<usize>) {
        self.tokens.push(ScriptToken { kind, range });
    }

    fn finish_statement(&mut self, terminator_end: Option<usize>, repeat: NonZeroU32) {
        self.tracker.reset();
        let Some(range) = self.open.take() else {
            return;
        };
        let index = self.statements.len();
        self.statements.push(ScriptStatement {
            range: range.clone(),
            extent: range.start..terminator_end.unwrap_or(range.end),
        });
        self.batches.push(ScriptBatch {
            range,
            repeat,
            statements: index..index + 1,
        });
    }

    fn extend_extents(&mut self) {
        for statement in &mut self.statements {
            let mut end = statement.extent.end;
            let first = self.tokens.partition_point(|token| token.range.start < end);
            for token in self.tokens.get(first..).unwrap_or_default() {
                if !token.kind.is_trivia() {
                    break;
                }
                match self.text[token.range.clone()].find('\n') {
                    Some(offset) => {
                        if token.kind == ScriptTokenKind::Whitespace {
                            end = token.range.start + offset;
                        }
                        break;
                    }
                    None => end = token.range.end,
                }
            }
            statement.extent.end = end;
        }
    }
}
