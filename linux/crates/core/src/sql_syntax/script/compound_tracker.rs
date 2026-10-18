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
        }
    }

    pub fn semicolon_ends_statement(&mut self) -> bool {
        let ends = match self.rule {
            CompoundRule::None => !(self.parens_hold_semicolons && self.paren_depth > 0),
            CompoundRule::RoutineBody => {
                !(self.parens_hold_semicolons && self.paren_depth > 0) && self.begin_depth == 0
            }
            CompoundRule::TriggerBody => !matches!(self.trigger, TriggerState::Trigger | TriggerState::Semi),
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
    fn trigger_body_ends_at_semicolon_end_semicolon() {
        let mut tracker = CompoundTracker::new(CompoundRule::TriggerBody, false);
        feed(&mut tracker, &["CREATE", "TEMP", "TRIGGER", "t", "BEGIN", "SELECT"]);
        assert!(!tracker.semicolon_ends_statement());
        feed(&mut tracker, &["END"]);
        assert!(tracker.semicolon_ends_statement());
    }
}
