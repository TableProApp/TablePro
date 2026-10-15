use sqlparser::dialect::MsSqlDialect;
use sqlparser::keywords::Keyword;
use sqlparser::tokenizer::{Token, Tokenizer, Word};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TsqlPhrase {
    Begin,
    Commit,
    Rollback,
    NamedRollback,
    Save,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct TsqlScan {
    pub phrases: Vec<TsqlPhrase>,
    pub other_tokens: bool,
}

impl TsqlScan {
    pub(crate) fn only_phrase(&self) -> Option<TsqlPhrase> {
        match self.phrases.as_slice() {
            [phrase] if !self.other_tokens => Some(*phrase),
            _ => None,
        }
    }

    pub(crate) fn hides_control(&self) -> bool {
        !self.phrases.is_empty()
            && (self.other_tokens
                || self.phrases.len() > 1
                || self
                    .phrases
                    .iter()
                    .any(|phrase| matches!(phrase, TsqlPhrase::NamedRollback | TsqlPhrase::Save)))
    }

    pub(crate) fn leaves_shared_transaction_unclosed(&self) -> bool {
        let mut open = false;
        for phrase in &self.phrases {
            match phrase {
                TsqlPhrase::Begin if open => return true,
                TsqlPhrase::Begin => open = true,
                TsqlPhrase::Commit | TsqlPhrase::Rollback if !open => return true,
                TsqlPhrase::Commit | TsqlPhrase::Rollback => open = false,
                TsqlPhrase::NamedRollback | TsqlPhrase::Save => return true,
            }
        }
        open
    }
}

pub(crate) fn scan(sql: &str) -> TsqlScan {
    let Ok(tokens) = Tokenizer::new(&MsSqlDialect {}, sql).tokenize() else {
        return TsqlScan::default();
    };
    let tokens: Vec<Token> = tokens
        .into_iter()
        .filter(|token| !matches!(token, Token::Whitespace(_)))
        .collect();
    let mut scan = TsqlScan::default();
    let mut at = 0;
    while at < tokens.len() {
        let after_period = at > 0 && matches!(tokens.get(at - 1), Some(Token::Period));
        match phrase_at(&tokens, at).filter(|_| !after_period) {
            Some((phrase, next)) => {
                scan.phrases.push(phrase);
                at = next;
            }
            None => {
                if !matches!(tokens.get(at), Some(Token::SemiColon)) {
                    scan.other_tokens = true;
                }
                at += 1;
            }
        }
    }
    scan
}

fn phrase_at(tokens: &[Token], at: usize) -> Option<(TsqlPhrase, usize)> {
    let word = keyword_at(tokens, at)?;
    match word {
        Keyword::BEGIN => begin_at(tokens, at + 1),
        Keyword::COMMIT => {
            let next = skip_tran_word(tokens, at + 1, true);
            let next = skip_name(tokens, next).unwrap_or(next);
            Some((TsqlPhrase::Commit, skip_with_options(tokens, next)))
        }
        Keyword::ROLLBACK => {
            let next = skip_tran_word(tokens, at + 1, true);
            match skip_name(tokens, next) {
                Some(after_name) => Some((TsqlPhrase::NamedRollback, after_name)),
                None => Some((TsqlPhrase::Rollback, next)),
            }
        }
        _ if is_word(tokens.get(at), "SAVE") && is_tran_word(tokens.get(at + 1)) => {
            let next = at + 2;
            Some((TsqlPhrase::Save, skip_name(tokens, next).unwrap_or(next)))
        }
        _ => None,
    }
}

fn begin_at(tokens: &[Token], at: usize) -> Option<(TsqlPhrase, usize)> {
    let at = if is_word(tokens.get(at), "DISTRIBUTED") {
        at + 1
    } else {
        at
    };
    if !is_tran_word(tokens.get(at)) {
        return None;
    }
    let next = at + 1;
    let next = skip_name(tokens, next).unwrap_or(next);
    if keyword_at(tokens, next) == Some(Keyword::WITH) && is_word(tokens.get(next + 1), "MARK") {
        let after_mark = next + 2;
        let after_text = if matches!(tokens.get(after_mark), Some(Token::SingleQuotedString(_))) {
            after_mark + 1
        } else {
            after_mark
        };
        return Some((TsqlPhrase::Begin, after_text));
    }
    Some((TsqlPhrase::Begin, next))
}

fn skip_tran_word(tokens: &[Token], at: usize, allow_work: bool) -> usize {
    let token = tokens.get(at);
    if is_tran_word(token) || (allow_work && is_word(token, "WORK")) {
        at + 1
    } else {
        at
    }
}

fn skip_name(tokens: &[Token], at: usize) -> Option<usize> {
    let Some(Token::Word(word)) = tokens.get(at) else {
        return None;
    };
    let unquoted_reserved = ["SAVE", "TRAN"]
        .iter()
        .any(|reserved| word.value.eq_ignore_ascii_case(reserved));
    let is_name = word.quote_style.is_some()
        || word.value.starts_with('@')
        || (word.keyword == Keyword::NoKeyword && !unquoted_reserved);
    is_name.then_some(at + 1)
}

fn skip_with_options(tokens: &[Token], at: usize) -> usize {
    if keyword_at(tokens, at) != Some(Keyword::WITH) || !matches!(tokens.get(at + 1), Some(Token::LParen)) {
        return at;
    }
    tokens
        .iter()
        .enumerate()
        .skip(at + 2)
        .find(|(_, token)| matches!(token, Token::RParen))
        .map_or(tokens.len(), |(index, _)| index + 1)
}

fn is_tran_word(token: Option<&Token>) -> bool {
    is_word(token, "TRAN") || keyword_of(token) == Some(Keyword::TRANSACTION)
}

fn keyword_at(tokens: &[Token], at: usize) -> Option<Keyword> {
    keyword_of(tokens.get(at))
}

fn keyword_of(token: Option<&Token>) -> Option<Keyword> {
    match token {
        Some(Token::Word(Word {
            keyword,
            quote_style: None,
            ..
        })) => Some(*keyword),
        _ => None,
    }
}

fn is_word(token: Option<&Token>, expected: &str) -> bool {
    matches!(token, Some(Token::Word(word)) if word.quote_style.is_none() && word.value.eq_ignore_ascii_case(expected))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_batch_without_semicolons_lists_each_phrase() {
        let scan = scan("BEGIN TRAN t1 WITH MARK 'm' UPDATE t SET a = 1 COMMIT TRAN t1 WITH (DELAYED_DURABILITY = ON)");
        assert_eq!(scan.phrases, vec![TsqlPhrase::Begin, TsqlPhrase::Commit]);
        assert!(scan.other_tokens);
        assert!(!scan.leaves_shared_transaction_unclosed());
    }

    #[test]
    fn quoted_or_qualified_words_are_not_phrases() {
        for sql in [
            "SELECT [commit] FROM t",
            "SELECT t.rollback FROM t",
            "SELECT 'BEGIN TRAN'",
            "BEGIN SELECT 1 END",
        ] {
            assert!(scan(sql).phrases.is_empty(), "{sql}");
        }
    }

    #[test]
    fn an_unbalanced_or_named_sequence_leaves_a_shared_transaction_unclosed() {
        for sql in [
            "BEGIN TRAN",
            "COMMIT TRAN",
            "BEGIN TRAN BEGIN TRAN COMMIT",
            "BEGIN TRAN SAVE TRAN s COMMIT",
        ] {
            assert!(scan(sql).leaves_shared_transaction_unclosed(), "{sql}");
        }
        assert!(!scan("SELECT 1").leaves_shared_transaction_unclosed());
    }
}
