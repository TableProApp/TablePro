use super::SqlGrammar;
use super::statement_tokens::StatementToken;

/// What marks a statement as one whose text can hold a password or a
/// connection secret, for one engine. Each driver declares its own next
/// to its dialect. Words compare without regard to case.
///
/// Prefixes are looked for at every word, not only where a statement
/// starts: a T-SQL batch needs no semicolon between its statements, and
/// a routine body holds whole statements of its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CredentialRules {
    /// Unquoted words that begin such a statement, such as `CREATE USER`.
    /// An `OR REPLACE` straight after the first word is skipped.
    pub statement_prefixes: &'static [&'static [&'static str]],
    /// A prefix that counts only when one of the words with it follows
    /// in the same statement, such as `GRANT` with `IDENTIFIED`.
    pub conditional_prefixes: &'static [(&'static [&'static str], &'static [&'static str])],
    /// Functions, procedures and table engines whose arguments can hold
    /// a login or a connection string.
    pub carriers: &'static [&'static str],
}

/// The word before a name being declared or written to, where a carrier
/// name followed by a parenthesis is a table and its column list, not a
/// call: `CREATE TABLE s3 (id int)`. A carrier the engine reserves, such
/// as T-SQL's OPENROWSET, cannot name a table, so there it is a call.
/// `EXISTS` and `ON` also start conditions, so `names_an_object` takes
/// them only in `TABLE IF NOT EXISTS name` and `CREATE INDEX ... ON name`.
const NAME_POSITIONS: [&str; 4] = ["TABLE", "INTO", "VIEW", "REFERENCES"];

/// The words a CREATE takes before INDEX or STATISTICS, in any engine.
const INDEX_MODIFIERS: [&str; 11] = [
    "UNIQUE",
    "CLUSTERED",
    "NONCLUSTERED",
    "COLUMNSTORE",
    "PRIMARY",
    "SELECTIVE",
    "XML",
    "SPATIAL",
    "FULLTEXT",
    "OR",
    "REPLACE",
];

impl CredentialRules {
    pub(crate) fn matches(&self, grammar: SqlGrammar, tokens: &[StatementToken<'_>]) -> bool {
        (0..tokens.len()).any(|at| {
            self.prefix_at(tokens, at) || self.conditional_at(tokens, at) || self.carrier_at(grammar, tokens, at)
        })
    }

    fn prefix_at(&self, tokens: &[StatementToken<'_>], at: usize) -> bool {
        self.statement_prefixes
            .iter()
            .any(|prefix| words_at(tokens, at, prefix).is_some())
    }

    fn conditional_at(&self, tokens: &[StatementToken<'_>], at: usize) -> bool {
        self.conditional_prefixes.iter().any(|(prefix, triggers)| {
            words_at(tokens, at, prefix).is_some_and(|end| {
                tokens.get(end..).unwrap_or_default().iter().any(|token| {
                    token
                        .name()
                        .is_some_and(|name| triggers.iter().any(|trigger| trigger.eq_ignore_ascii_case(name)))
                })
            })
        })
    }

    fn carrier_at(&self, grammar: SqlGrammar, tokens: &[StatementToken<'_>], at: usize) -> bool {
        let Some(token) = tokens.get(at) else {
            return false;
        };
        let Some(name) = token.name() else {
            return false;
        };
        if !self.carriers.iter().any(|carrier| carrier.eq_ignore_ascii_case(name)) {
            return false;
        }
        let next = tokens.get(at + 1);
        if next.is_some_and(|token| token.is_punct('.')) {
            return false;
        }
        let start = qualified_name_start(tokens, at);
        if next == Some(&StatementToken::OpenParen) {
            let reserved = matches!(token, StatementToken::Word(_)) && grammar.is_reserved(name);
            if reserved || !names_an_object(tokens, start) {
                return true;
            }
        }
        // T-SQL runs a procedure without EXEC only as the first statement
        // of a batch. At the start of a later statement, or anywhere with
        // its arguments, the batch fails, and history keeps failed runs.
        starts_statement(tokens, start) || follows_exec(tokens, start) || arguments_start(tokens, at + 1)
    }
}

fn starts_statement(tokens: &[StatementToken<'_>], start: usize) -> bool {
    start == 0 || tokens.get(start - 1).is_some_and(|token| token.is_punct(';'))
}

/// A string, T-SQL's `N'...'` or a `@parameter`, which only a call puts
/// straight after a name.
fn arguments_start(tokens: &[StatementToken<'_>], at: usize) -> bool {
    match tokens.get(at) {
        Some(StatementToken::StringLiteral(_)) => true,
        Some(StatementToken::Word(word)) if word.starts_with('@') => true,
        Some(token) if token.is_word("N") => {
            matches!(tokens.get(at + 1), Some(StatementToken::StringLiteral(_)))
        }
        _ => false,
    }
}

/// Where `words` match at `at`, the index just past them.
fn words_at(tokens: &[StatementToken<'_>], at: usize, words: &[&str]) -> Option<usize> {
    let (first, rest) = words.split_first()?;
    if !tokens.get(at)?.is_word(first) {
        return None;
    }
    let mut next = at + 1;
    let or_replace = tokens.get(next).is_some_and(|token| token.is_word("OR"))
        && tokens.get(next + 1).is_some_and(|token| token.is_word("REPLACE"));
    if or_replace {
        next += 2;
    }
    for word in rest {
        if !tokens.get(next)?.is_word(word) {
            return None;
        }
        next += 1;
    }
    Some(next)
}

/// The first part of the dotted name that ends at `at`, so `master..sp_addlogin`
/// and `public.dblink(` are read as one name.
fn qualified_name_start(tokens: &[StatementToken<'_>], at: usize) -> usize {
    let mut start = at;
    loop {
        let mut dots = start;
        while dots > 0 && tokens.get(dots - 1).is_some_and(|token| token.is_punct('.')) {
            dots -= 1;
        }
        let qualifier = dots.checked_sub(1).filter(|_| dots < start);
        match qualifier.and_then(|index| tokens.get(index)?.name().map(|_| index)) {
            Some(index) => start = index,
            None => return start,
        }
    }
}

/// Whether the name starting at `start` is where the grammar puts a
/// table. Anything else is read as a call, since a call there that was
/// taken for a name would put its arguments in the history.
fn names_an_object(tokens: &[StatementToken<'_>], start: usize) -> bool {
    let word_before = |back: usize| start.checked_sub(back).and_then(|index| tokens.get(index));
    let Some(before) = word_before(1) else {
        return false;
    };
    if before.is_word("ON") {
        return on_names_an_indexed_table(tokens, start - 1);
    }
    if before.is_word("EXISTS") {
        // `IF [NOT] EXISTS name (` declares a table or a view; a bare
        // EXISTS is a condition.
        let mut back = 2;
        if word_before(back).is_some_and(|token| token.is_word("NOT")) {
            back += 1;
        }
        return word_before(back).is_some_and(|token| token.is_word("IF"))
            && word_before(back + 1).is_some_and(|token| token.is_word("TABLE") || token.is_word("VIEW"));
    }
    if !NAME_POSITIONS.iter().any(|word| before.is_word(word)) {
        return false;
    }
    // ClickHouse describes a table function's result: DESCRIBE TABLE s3(...).
    let described = word_before(2).is_some_and(|token| token.is_word("DESCRIBE") || token.is_word("DESC"));
    !(before.is_word("TABLE") && described)
}

/// `CREATE [UNIQUE ...] INDEX|STATISTICS [name] ON table (columns)`, the
/// one place a table name and a parenthesis follow ON. A JOIN's ON, or
/// any other, starts a condition.
fn on_names_an_indexed_table(tokens: &[StatementToken<'_>], on: usize) -> bool {
    let mut at = on;
    while at > 0 {
        at -= 1;
        let Some(token) = tokens.get(at) else {
            return false;
        };
        if token.is_word("CREATE") {
            let mut next = at + 1;
            while tokens
                .get(next)
                .is_some_and(|token| INDEX_MODIFIERS.iter().any(|word| token.is_word(word)))
            {
                next += 1;
            }
            return next < on
                && tokens
                    .get(next)
                    .is_some_and(|token| token.is_word("INDEX") || token.is_word("STATISTICS"));
        }
        if token.name().is_none() && !token.is_punct('.') {
            return false;
        }
    }
    false
}

/// `EXEC name`, or `EXEC @status = name`.
fn follows_exec(tokens: &[StatementToken<'_>], start: usize) -> bool {
    let token_before = |back: usize| start.checked_sub(back).and_then(|index| tokens.get(index));
    let is_exec = |token: Option<&StatementToken<'_>>| {
        token.is_some_and(|token| token.is_word("EXEC") || token.is_word("EXECUTE"))
    };
    if is_exec(token_before(1)) {
        return true;
    }
    let status_variable = matches!(token_before(2), Some(StatementToken::Word(word)) if word.starts_with('@'));
    token_before(1).is_some_and(|token| token.is_punct('=')) && status_variable && is_exec(token_before(3))
}
