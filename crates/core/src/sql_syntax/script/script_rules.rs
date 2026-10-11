use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::BatchErrorPolicy;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Boundary {
    Semicolon,
    DelimiterDirectives,
    GoBatch,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CompoundRule {
    None,
    RoutineBody,
    TriggerBody,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BackslashPolicy {
    Never,
    Always,
    WhenEnabled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum QuoteKind {
    StringLiteral,
    QuotedIdentifier,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct QuoteRule {
    pub kind: QuoteKind,
    pub backslash: BackslashPolicy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BracketIdentifier {
    None,
    NoDoubling,
    Doubling,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HashComment {
    None,
    Always,
    SpaceOrBang,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DollarQuote {
    None,
    Tagged,
    Heredoc,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ScriptSyntax {
    pub single_quote: QuoteRule,
    pub double_quote: QuoteRule,
    pub backtick: Option<QuoteRule>,
    pub bracket_identifier: BracketIdentifier,
    pub escape_string_prefix: bool,
    pub dash_comment_needs_space: bool,
    pub hash_comment: HashComment,
    pub slash_slash_comment: bool,
    pub nested_block_comments: bool,
    pub dollar_quote: DollarQuote,
    pub word_start_extra: &'static [u8],
    pub word_part_extra: &'static [u8],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ScriptRules {
    pub boundary: Boundary,
    pub compound: CompoundRule,
    pub parens_hold_semicolons: bool,
    pub batch_error: BatchErrorPolicy,
    pub syntax: ScriptSyntax,
}

const fn quote(kind: QuoteKind, backslash: BackslashPolicy) -> QuoteRule {
    QuoteRule { kind, backslash }
}

const POSTGRESQL: ScriptRules = ScriptRules {
    boundary: Boundary::Semicolon,
    compound: CompoundRule::RoutineBody,
    parens_hold_semicolons: true,
    batch_error: BatchErrorPolicy::StopScript,
    syntax: ScriptSyntax {
        single_quote: quote(QuoteKind::StringLiteral, BackslashPolicy::WhenEnabled),
        double_quote: quote(QuoteKind::QuotedIdentifier, BackslashPolicy::Never),
        backtick: None,
        bracket_identifier: BracketIdentifier::None,
        escape_string_prefix: true,
        dash_comment_needs_space: false,
        hash_comment: HashComment::None,
        slash_slash_comment: false,
        nested_block_comments: true,
        dollar_quote: DollarQuote::Tagged,
        word_start_extra: b"",
        word_part_extra: b"$",
    },
};

const MYSQL: ScriptRules = ScriptRules {
    boundary: Boundary::DelimiterDirectives,
    compound: CompoundRule::None,
    parens_hold_semicolons: false,
    batch_error: BatchErrorPolicy::StopScript,
    syntax: ScriptSyntax {
        single_quote: quote(QuoteKind::StringLiteral, BackslashPolicy::WhenEnabled),
        double_quote: quote(QuoteKind::StringLiteral, BackslashPolicy::WhenEnabled),
        backtick: Some(quote(QuoteKind::QuotedIdentifier, BackslashPolicy::Never)),
        bracket_identifier: BracketIdentifier::None,
        escape_string_prefix: false,
        dash_comment_needs_space: true,
        hash_comment: HashComment::Always,
        slash_slash_comment: false,
        nested_block_comments: false,
        dollar_quote: DollarQuote::None,
        word_start_extra: b"$",
        word_part_extra: b"$",
    },
};

const SQLITE: ScriptRules = ScriptRules {
    boundary: Boundary::Semicolon,
    compound: CompoundRule::TriggerBody,
    parens_hold_semicolons: false,
    batch_error: BatchErrorPolicy::StopScript,
    syntax: ScriptSyntax {
        single_quote: quote(QuoteKind::StringLiteral, BackslashPolicy::Never),
        double_quote: quote(QuoteKind::QuotedIdentifier, BackslashPolicy::Never),
        backtick: Some(quote(QuoteKind::QuotedIdentifier, BackslashPolicy::Never)),
        bracket_identifier: BracketIdentifier::NoDoubling,
        escape_string_prefix: false,
        dash_comment_needs_space: false,
        hash_comment: HashComment::None,
        slash_slash_comment: false,
        nested_block_comments: false,
        dollar_quote: DollarQuote::None,
        word_start_extra: b"$",
        word_part_extra: b"$",
    },
};

const MSSQL: ScriptRules = ScriptRules {
    boundary: Boundary::GoBatch,
    compound: CompoundRule::None,
    parens_hold_semicolons: false,
    batch_error: BatchErrorPolicy::ContinueNextBatch,
    syntax: ScriptSyntax {
        single_quote: quote(QuoteKind::StringLiteral, BackslashPolicy::Never),
        double_quote: quote(QuoteKind::QuotedIdentifier, BackslashPolicy::Never),
        backtick: None,
        bracket_identifier: BracketIdentifier::Doubling,
        escape_string_prefix: false,
        dash_comment_needs_space: false,
        hash_comment: HashComment::None,
        slash_slash_comment: false,
        nested_block_comments: true,
        dollar_quote: DollarQuote::None,
        word_start_extra: b"@#",
        word_part_extra: b"@#$",
    },
};

const CLICKHOUSE: ScriptRules = ScriptRules {
    boundary: Boundary::Semicolon,
    compound: CompoundRule::None,
    parens_hold_semicolons: false,
    batch_error: BatchErrorPolicy::StopScript,
    syntax: ScriptSyntax {
        single_quote: quote(QuoteKind::StringLiteral, BackslashPolicy::Always),
        double_quote: quote(QuoteKind::QuotedIdentifier, BackslashPolicy::Always),
        backtick: Some(quote(QuoteKind::QuotedIdentifier, BackslashPolicy::Always)),
        bracket_identifier: BracketIdentifier::None,
        escape_string_prefix: false,
        dash_comment_needs_space: false,
        hash_comment: HashComment::SpaceOrBang,
        slash_slash_comment: true,
        nested_block_comments: true,
        dollar_quote: DollarQuote::Heredoc,
        word_start_extra: b"",
        word_part_extra: b"",
    },
};

pub(crate) fn rules_for(grammar: SqlGrammar) -> &'static ScriptRules {
    match grammar {
        SqlGrammar::PostgreSql => &POSTGRESQL,
        SqlGrammar::MySql => &MYSQL,
        SqlGrammar::Sqlite => &SQLITE,
        SqlGrammar::MsSql => &MSSQL,
        SqlGrammar::ClickHouse => &CLICKHOUSE,
    }
}
