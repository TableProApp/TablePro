use crate::sql_syntax::script::ScriptTokenKind;
use crate::sql_syntax::script::script_rules::CompoundRule;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TriggerState {
    Start,
    Normal,
    Explain,
    Create,
    Trigger,
    Semi,
    End,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TriggerToken {
    Other,
    Explain,
    Create,
    Temp,
    Trigger,
    End,
}

const ROUTINE_WORDS: [&str; 5] = ["create", "function", "procedure", "or", "replace"];

#[derive(Debug, Clone)]
pub(crate) struct CompoundTracker {
    rule: CompoundRule,
    parens_hold_semicolons: bool,
    paren_depth: u32,
    identifier_count: usize,
    identifiers: [u8; 4],
    begin_depth: u32,
    trigger: TriggerState,
    batch: BatchState,
}

/// Where a CQL statement stands with a batch, read as cqlsh's
/// `cql_split_statements` reads it: a piece between two `;` that opens
/// with BEGIN starts a batch, and the batch takes every piece up to one
/// whose last word but one is APPLY.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct BatchState {
    open: bool,
    piece_tokens: usize,
    piece_opens: bool,
    last_apply: bool,
    second_last_apply: bool,
}

impl BatchState {
    fn observe(&mut self, kind: ScriptTokenKind, text: &str) {
        let word = |expected: &str| kind == ScriptTokenKind::Word && text.eq_ignore_ascii_case(expected);
        if self.piece_tokens == 0 {
            self.piece_opens = word("begin");
        }
        self.second_last_apply = self.last_apply;
        self.last_apply = word("apply");
        self.piece_tokens += 1;
    }

    /// The piece ends at a `;`. Whether the statement ends with it.
    fn piece_ends(&mut self) -> bool {
        if self.piece_tokens >= 2 {
            if self.second_last_apply {
                self.open = false;
            } else if self.piece_opens {
                self.open = true;
            }
        }
        *self = Self {
            open: self.open,
            ..Self::default()
        };
        !self.open
    }
}

impl CompoundTracker {
    pub fn new(rule: CompoundRule, parens_hold_semicolons: bool) -> Self {
        Self {
            rule,
            parens_hold_semicolons,
            paren_depth: 0,
            identifier_count: 0,
            identifiers: [0; 4],
            begin_depth: 0,
            trigger: TriggerState::Start,
            batch: BatchState::default(),
        }
    }

    pub fn observe(&mut self, kind: ScriptTokenKind, text: &str) {
        match kind {
            ScriptTokenKind::OpenParen => self.paren_depth += 1,
            ScriptTokenKind::CloseParen => self.paren_depth = self.paren_depth.saturating_sub(1),
            _ => {}
        }
        match self.rule {
            CompoundRule::None => {}
            CompoundRule::RoutineBody => {
                if kind == ScriptTokenKind::Word {
                    self.observe_routine_word(text);
                }
            }
            CompoundRule::TriggerBody => self.trigger = advance_trigger(self.trigger, classify_trigger(kind, text)),
            CompoundRule::Batch => self.batch.observe(kind, text),
        }
    }

    pub fn semicolon_ends_statement(&mut self) -> bool {
        let ends = match self.rule {
            CompoundRule::None => !(self.parens_hold_semicolons && self.paren_depth > 0),
            CompoundRule::RoutineBody => {
                !(self.parens_hold_semicolons && self.paren_depth > 0) && self.begin_depth == 0
            }
            CompoundRule::TriggerBody => !matches!(self.trigger, TriggerState::Trigger | TriggerState::Semi),
            CompoundRule::Batch => self.batch.piece_ends(),
        };
        if ends {
            self.reset();
        } else if self.rule == CompoundRule::TriggerBody {
            self.trigger = TriggerState::Semi;
        }
        ends
    }

    pub fn reset(&mut self) {
        *self = Self::new(self.rule, self.parens_hold_semicolons);
    }

    fn observe_routine_word(&mut self, word: &str) {
        let is_routine_word = ROUTINE_WORDS.iter().any(|known| word.eq_ignore_ascii_case(known));
        if is_routine_word && let Some(slot) = self.identifiers.get_mut(self.identifier_count) {
            *slot = word.as_bytes().first().map_or(0, u8::to_ascii_lowercase);
        }
        self.identifier_count += 1;

        let [first, second, third, fourth] = self.identifiers;
        let creates_routine = first == b'c'
            && (second == b'f'
                || second == b'p'
                || (second == b'o' && third == b'r' && (fourth == b'f' || fourth == b'p')));
        if !creates_routine || self.paren_depth != 0 {
            return;
        }
        if word.eq_ignore_ascii_case("begin") {
            self.begin_depth += 1;
        } else if word.eq_ignore_ascii_case("case") {
            if self.begin_depth >= 1 {
                self.begin_depth += 1;
            }
        } else if word.eq_ignore_ascii_case("end") {
            self.begin_depth = self.begin_depth.saturating_sub(1);
        }
    }
}

fn classify_trigger(kind: ScriptTokenKind, text: &str) -> TriggerToken {
    if kind != ScriptTokenKind::Word {
        return TriggerToken::Other;
    }
    if text.eq_ignore_ascii_case("create") {
        TriggerToken::Create
    } else if text.eq_ignore_ascii_case("trigger") {
        TriggerToken::Trigger
    } else if text.eq_ignore_ascii_case("temp") || text.eq_ignore_ascii_case("temporary") {
        TriggerToken::Temp
    } else if text.eq_ignore_ascii_case("end") {
        TriggerToken::End
    } else if text.eq_ignore_ascii_case("explain") {
        TriggerToken::Explain
    } else {
        TriggerToken::Other
    }
}

fn advance_trigger(state: TriggerState, token: TriggerToken) -> TriggerState {
    match (state, token) {
        (TriggerState::Start, TriggerToken::Explain) => TriggerState::Explain,
        (TriggerState::Start | TriggerState::Explain, TriggerToken::Create) => TriggerState::Create,
        (TriggerState::Explain, TriggerToken::Other) => TriggerState::Explain,
        (TriggerState::Create, TriggerToken::Temp) => TriggerState::Create,
        (TriggerState::Create, TriggerToken::Trigger) => TriggerState::Trigger,
        (TriggerState::Semi, TriggerToken::End) => TriggerState::End,
        (TriggerState::Trigger | TriggerState::Semi | TriggerState::End, _) => TriggerState::Trigger,
        _ => TriggerState::Normal,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(tracker: &mut CompoundTracker, words: &[&str]) {
        for word in words {
            let kind = match *word {
                "(" => ScriptTokenKind::OpenParen,
                ")" => ScriptTokenKind::CloseParen,
                _ => ScriptTokenKind::Word,
            };
            tracker.observe(kind, word);
        }
    }

    #[test]
    fn routine_begin_holds_semicolons_until_end() {
        let mut tracker = CompoundTracker::new(CompoundRule::RoutineBody, true);
        feed(
            &mut tracker,
            &[
                "CREATE", "OR", "REPLACE", "FUNCTION", "f", "(", ")", "BEGIN", "ATOMIC", "SELECT",
            ],
        );
        assert!(!tracker.semicolon_ends_statement());
        feed(&mut tracker, &["END"]);
        assert!(tracker.semicolon_ends_statement());
    }

    #[test]
    fn transaction_begin_is_not_counted() {
        let mut tracker = CompoundTracker::new(CompoundRule::RoutineBody, true);
        feed(&mut tracker, &["BEGIN"]);
        assert!(tracker.semicolon_ends_statement());
    }

    #[test]
    fn a_batch_holds_semicolons_until_apply_batch() {
        let mut tracker = CompoundTracker::new(CompoundRule::Batch, false);
        feed(&mut tracker, &["BEGIN", "UNLOGGED", "BATCH", "INSERT", "INTO", "t"]);
        assert!(!tracker.semicolon_ends_statement());
        feed(&mut tracker, &["UPDATE", "t", "SET"]);
        assert!(!tracker.semicolon_ends_statement());
        feed(&mut tracker, &["APPLY", "BATCH"]);
        assert!(tracker.semicolon_ends_statement());
        feed(&mut tracker, &["SELECT", "x"]);
        assert!(tracker.semicolon_ends_statement());
    }

    #[test]
    fn a_lone_begin_is_not_a_batch() {
        let mut tracker = CompoundTracker::new(CompoundRule::Batch, false);
        feed(&mut tracker, &["BEGIN"]);
        assert!(tracker.semicolon_ends_statement(), "cqlsh needs two words before the ;");
        feed(&mut tracker, &["BEGIN", "BATCH", "APPLY", "BATCH"]);
        assert!(tracker.semicolon_ends_statement(), "an empty batch is one statement");
    }

    #[test]
    fn trigger_body_ends_at_semicolon_end_semicolon() {
        let mut tracker = CompoundTracker::new(CompoundRule::TriggerBody, false);
        feed(&mut tracker, &["CREATE", "TEMP", "TRIGGER", "t", "BEGIN", "SELECT"]);
        assert!(!tracker.semicolon_ends_statement());
        feed(&mut tracker, &["END"]);
        assert!(tracker.semicolon_ends_statement());
    }
}
