use std::collections::VecDeque;

use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptToken, ScriptTokenKind};

use super::copy_rows::CopyRows;
use super::directive_scan::delimiter_line;
use super::lexical_change::LexicalTracker;

/// Text a reader holds before it plans again with nothing settled, so a
/// statement of many megabytes is lexed a few times, not once per piece.
const PLAN_STEP: usize = 64 * 1024;

/// The longest statement or batch a reader holds. A dump's INSERTs are a
/// megabyte; a statement past this is not one a server takes either.
pub const MAX_UNIT_BYTES: usize = 128 * 1024 * 1024;

/// One thing a file asks the server, as its engine's client would send
/// it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScriptUnit {
    pub text: String,
    /// The line it starts on, from 1.
    pub line: u64,
    /// How many times it runs: a SQL Server `GO n` batch runs `n` times.
    pub repeat: u32,
    pub kind: ScriptUnitKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScriptUnitKind {
    /// Sent to the server.
    Run,
    /// A line only psql reads, such as pg_dump's `\restrict`, which keeps
    /// psql from running meta-commands a server could plant in the data.
    /// Nothing here runs meta-commands, so it is passed over.
    ClientOnly,
    /// A line nothing here can run.
    Refused(RefusedUnit),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefusedUnit {
    /// A psql meta-command other than `\restrict` and `\unrestrict`.
    ClientCommand { command: String },
    /// `COPY ... FROM stdin` in a form other than the text format pg_dump
    /// writes, or with options.
    CopyFormat,
    /// `COPY` data that is not UTF-8 once its escapes are read.
    CopyNotText,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum ScriptReadError {
    #[error("the statement starting on line {line} is longer than the reader holds")]
    TooLong { line: u64 },
}

/// Splits a script into the units its engine's client sends, read a
/// piece at a time so a file of any size is never held whole.
///
/// It splits as `ScriptPlan` does: at `;`, at the delimiter a MySQL
/// `DELIMITER` line sets, at SQL Server `GO` lines. Only text up to the
/// last line break is planned until the end, since a directive is a whole
/// line. On PostgreSQL it also reads what psql reads in a pg_dump file:
/// `COPY ... FROM stdin` rows up to `\.`, which become INSERTs, and
/// backslash lines. A `SET` of `standard_conforming_strings` or of a
/// `sql_mode` with `NO_BACKSLASH_ESCAPES` changes how the rest reads, as
/// it does on the server.
#[derive(Debug)]
pub struct ScriptReader {
    grammar: SqlGrammar,
    settings: LexicalSettings,
    pending: String,
    /// The line `pending` starts on.
    line: u64,
    delimiter: String,
    plan_at: usize,
    copy: Option<CopyRows>,
    /// What lets an INSERT made from COPY rows set an identity column, as
    /// COPY itself may.
    copy_overriding: Option<String>,
    tracker: LexicalTracker,
    units: VecDeque<ScriptUnit>,
}

impl ScriptReader {
    pub fn new(grammar: SqlGrammar) -> Self {
        Self {
            grammar,
            settings: LexicalSettings::default_for(grammar),
            pending: String::new(),
            line: 1,
            delimiter: ";".to_owned(),
            plan_at: 0,
            copy: None,
            copy_overriding: None,
            tracker: LexicalTracker::default(),
            units: VecDeque::new(),
        }
    }

    /// How the session reads a string before the script sets anything,
    /// where the server's configuration can differ from the default.
    pub fn with_settings(mut self, settings: LexicalSettings) -> Self {
        self.settings = settings;
        self
    }

    /// The clause `SqlDialect::insert_overriding_clause` gives, for the
    /// INSERTs COPY rows become.
    pub fn with_copy_overriding(mut self, clause: Option<&str>) -> Self {
        self.copy_overriding = clause.map(str::to_owned);
        self
    }

    /// Take the next piece of the script, and give back the units it
    /// completed.
    pub fn push(&mut self, text: &str) -> Result<Vec<ScriptUnit>, ScriptReadError> {
        self.pending.push_str(text);
        self.process(false)?;
        Ok(self.units.drain(..).collect())
    }

    /// The end of the script: what is left, whole or not, as the client
    /// sends a last statement with no terminator.
    pub fn finish(mut self) -> Result<Vec<ScriptUnit>, ScriptReadError> {
        self.process(true)?;
        Ok(self.units.drain(..).collect())
    }

    fn process(&mut self, end: bool) -> Result<(), ScriptReadError> {
        loop {
            if self.copy.is_some() {
                if self.copy_lines(end) {
                    continue;
                }
                break;
            }
            if self.grammar == SqlGrammar::PostgreSql && self.backslash_line(end) {
                continue;
            }
            if !end && self.pending.len() < self.plan_at {
                break;
            }
            // A line this long is no directive, and a file written on one
            // line still has to be cut where its statements end.
            let line_start = self.pending.rfind('\n').map_or(0, |at| at + 1);
            let limit = match end || self.pending.len() - line_start >= PLAN_STEP {
                true => self.pending.len(),
                false if line_start > 0 => line_start,
                false => break,
            };
            match self.plan(limit, end) {
                Planned::Interrupted => continue,
                Planned::Settled => {
                    self.plan_at = self.pending.len() + PLAN_STEP;
                    break;
                }
                Planned::Nothing => {
                    if self.pending.len() > MAX_UNIT_BYTES {
                        return Err(ScriptReadError::TooLong { line: self.line });
                    }
                    self.plan_at = (self.pending.len() * 2).max(self.pending.len() + PLAN_STEP);
                    break;
                }
            }
        }
        Ok(())
    }

    fn plan(&mut self, limit: usize, end: bool) -> Planned {
        let Some(text) = self.pending.get(..limit) else {
            return Planned::Nothing;
        };
        let Some((plan, settled)) = ScriptPlan::build_continuing(text, self.grammar, self.settings, &self.delimiter)
        else {
            return Planned::Nothing;
        };
        let whole_to = match end {
            true => limit,
            false => settled.offset,
        };
        let mut found = Vec::new();
        let mut interrupted_at = None;
        let mut delimiter_at_cut = None;
        for batch in plan.batches() {
            if batch.range.end > whole_to {
                break;
            }
            let unit_text = text.get(batch.range.clone()).unwrap_or_default();
            if self.grammar == SqlGrammar::PostgreSql && unit_text.starts_with('\\') {
                interrupted_at = Some((batch.range.start, None));
                break;
            }
            if self.grammar == SqlGrammar::PostgreSql {
                let tokens: Vec<ScriptToken> = plan.tokens(batch.range.clone()).collect();
                if let Some(copy) = CopyRows::starting(text, &tokens, self.copy_overriding.as_deref()) {
                    let after_line = text
                        .get(batch.range.end..)
                        .and_then(|rest| rest.find('\n'))
                        .map_or(limit, |at| batch.range.end + at + 1);
                    // A COPY the reader turns into INSERTs is never sent;
                    // one it cannot read is reported and its rows passed over.
                    if let Some(refused) = copy.refusal() {
                        found.push((batch.range.clone(), 1, Some(refused)));
                    }
                    interrupted_at = Some((after_line, Some(copy)));
                    break;
                }
            }
            found.push((batch.range.clone(), batch.repeat.get(), None));
            // A statement that changes how a backslash reads changes how
            // the rest of the text splits, so it is planned again from here.
            if let Some(settings) = self.tracker.after(unit_text, self.grammar, self.settings) {
                self.settings = settings;
                let cut = plan
                    .statements()
                    .get(batch.statements.start)
                    .map_or(batch.range.end, |statement| statement.extent.end.max(batch.range.end));
                delimiter_at_cut = Some(self.delimiter_at(&plan, text, cut));
                interrupted_at = Some((cut, None));
                break;
            }
        }
        let lines_before = |offset: usize| text.get(..offset).unwrap_or_default().matches('\n').count() as u64;
        for (range, repeat, refused) in &found {
            let unit_text = text.get(range.clone()).unwrap_or_default().trim().to_owned();
            if unit_text.is_empty() {
                continue;
            }
            self.units.push_back(ScriptUnit {
                text: unit_text,
                line: self.line + lines_before(range.start),
                repeat: *repeat,
                kind: match refused {
                    Some(refused) => ScriptUnitKind::Refused(refused.clone()),
                    None => ScriptUnitKind::Run,
                },
            });
        }
        match interrupted_at {
            Some((cut, copy)) => {
                self.cut(cut);
                self.copy = copy.map(|copy| copy.at_line(self.line));
                self.delimiter = delimiter_at_cut.unwrap_or_else(|| self.delimiter.clone());
                Planned::Interrupted
            }
            None if end => {
                self.cut(limit);
                Planned::Settled
            }
            None if whole_to > 0 => {
                self.cut(whole_to);
                self.delimiter = settled.delimiter;
                Planned::Settled
            }
            None => Planned::Nothing,
        }
    }

    /// The delimiter in effect at `offset` of `text`, from the `DELIMITER`
    /// lines before it.
    fn delimiter_at(&self, plan: &ScriptPlan, text: &str, offset: usize) -> String {
        let mut delimiter = self.delimiter.clone();
        for token in plan.tokens(0..offset) {
            if token.kind != ScriptTokenKind::Directive || token.range.end > offset {
                continue;
            }
            if let Some(chosen) = delimiter_line(text, token.range.start).and_then(|line| line.delimiter) {
                delimiter = chosen.to_owned();
            }
        }
        delimiter
    }

    /// psql reads a line that starts with a backslash where no statement
    /// is open as a meta-command, and only psql. pg_dump writes
    /// `\restrict` and `\unrestrict` around a dump.
    fn backslash_line(&mut self, end: bool) -> bool {
        let mut offset = 0;
        loop {
            let rest = self.pending.get(offset..).unwrap_or_default();
            let trimmed = rest.trim_start();
            offset += rest.len() - trimmed.len();
            if trimmed.starts_with("--") {
                match trimmed.find('\n') {
                    Some(at) => offset += at + 1,
                    None => return false,
                }
                continue;
            }
            if !trimmed.starts_with('\\') {
                return false;
            }
            let line_end = match trimmed.find('\n') {
                Some(at) => offset + at,
                None if end => self.pending.len(),
                None => return false,
            };
            let line = self
                .pending
                .get(offset..line_end)
                .unwrap_or_default()
                .trim_end()
                .to_owned();
            let starts_on = self.line + self.pending.get(..offset).unwrap_or_default().matches('\n').count() as u64;
            let command = line.split_whitespace().next().unwrap_or_default().to_owned();
            let kind = match command.as_str() {
                "\\restrict" | "\\unrestrict" => ScriptUnitKind::ClientOnly,
                _ => ScriptUnitKind::Refused(RefusedUnit::ClientCommand { command }),
            };
            self.units.push_back(ScriptUnit {
                text: line,
                line: starts_on,
                repeat: 1,
                kind,
            });
            self.cut((line_end + 1).min(self.pending.len()));
            return true;
        }
    }

    /// Read COPY rows a line at a time. True when the data ended and the
    /// script goes on.
    fn copy_lines(&mut self, end: bool) -> bool {
        let Some(mut copy) = self.copy.take() else {
            return false;
        };
        let mut consumed = 0;
        let mut finished = false;
        while let Some(at) = self.pending.get(consumed..).and_then(|rest| rest.find('\n')) {
            let line = self.pending.get(consumed..consumed + at).unwrap_or_default();
            let line = line.strip_suffix('\r').unwrap_or(line);
            consumed += at + 1;
            if line == "\\." {
                finished = true;
                break;
            }
            copy.row(line, &mut self.units);
        }
        if !finished && end {
            let line = self.pending.get(consumed..).unwrap_or_default();
            let line = line.strip_suffix('\r').unwrap_or(line);
            if !line.is_empty() && line != "\\." {
                copy.row(line, &mut self.units);
            }
            consumed = self.pending.len();
            finished = true;
        }
        self.cut(consumed);
        if finished {
            copy.finish(&mut self.units);
            self.plan_at = 0;
            return true;
        }
        self.copy = Some(copy);
        false
    }

    fn cut(&mut self, offset: usize) {
        let offset = offset.min(self.pending.len());
        self.line += self.pending.get(..offset).unwrap_or_default().matches('\n').count() as u64;
        self.pending.drain(..offset);
    }
}

enum Planned {
    /// A COPY or a backslash line stopped the plan; read on from there.
    Interrupted,
    Settled,
    /// No unit is whole yet.
    Nothing,
}

/// Whether a statement starts or ends a transaction, for an import that
/// runs a file as one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransactionControl {
    Begin,
    Commit,
    Rollback,
}

/// The transaction statement `text` is, where it is one: BEGIN, START
/// TRANSACTION, COMMIT, END and ROLLBACK, not a ROLLBACK TO a savepoint or
/// a prepared transaction's COMMIT.
pub fn transaction_control(text: &str, grammar: SqlGrammar) -> Option<TransactionControl> {
    let plan = ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar));
    let words: Vec<String> = plan
        .tokens(0..text.len())
        .filter(|token| !token.kind.is_trivia() && token.kind != ScriptTokenKind::Semicolon)
        .take(3)
        .map(|token| text.get(token.range).unwrap_or_default().to_ascii_uppercase())
        .collect();
    let first = words.first()?.as_str();
    let second = words.get(1).map(String::as_str);
    match (first, second) {
        (
            "BEGIN",
            None | Some("TRANSACTION" | "WORK" | "DEFERRED" | "IMMEDIATE" | "EXCLUSIVE" | "ISOLATION" | "READ"),
        ) => Some(TransactionControl::Begin),
        ("START", Some("TRANSACTION")) => Some(TransactionControl::Begin),
        ("COMMIT" | "END", None | Some("TRANSACTION" | "WORK" | "AND")) => Some(TransactionControl::Commit),
        ("ROLLBACK" | "ABORT", None | Some("TRANSACTION" | "WORK" | "AND")) => match words.get(2).map(String::as_str) {
            Some("TO") => None,
            _ => Some(TransactionControl::Rollback),
        },
        _ => None,
    }
}

#[cfg(test)]
mod tests;
