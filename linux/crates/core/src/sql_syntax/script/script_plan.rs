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
        Builder::new(text, rules_for(grammar), settings, reading).run()
    }

    /// Every plan the client or a server may make of `text`: as the client
    /// splits it and, on MySQL, as each server reads what it is sent, at
    /// each version its executable comments name. Each with backslash
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
}

impl<'a> Builder<'a> {
    fn new(text: &'a str, rules: &'static ScriptRules, settings: LexicalSettings, reading: ServerReading) -> Self {
        Self {
            text,
            rules,
            lexer: Lexer::new(text, &rules.syntax, settings, reading),
            reads_directives: reading.reads_directives(),
            tracker: CompoundTracker::new(rules.compound, rules.parens_hold_semicolons),
            delimiter: ";",
            open: None,
            tokens: Vec::new(),
            statements: Vec::new(),
            batches: Vec::new(),
            diagnostics: Vec::new(),
        }
    }

    fn run(mut self) -> ScriptPlan {
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
        self.finish_statement(None, NonZeroU32::MIN);
        self.extend_extents();
        ScriptPlan {
            tokens: self.tokens,
            statements: self.statements,
            batches: self.batches,
            diagnostics: self.diagnostics,
            batch_error: self.rules.batch_error,
        }
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
