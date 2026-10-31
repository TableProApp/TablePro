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
    /// CQL's `BEGIN [UNLOGGED | COUNTER] BATCH ... APPLY BATCH`, whose
    /// statements cqlsh sends as one.
    Batch,
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
    /// `$$ ... $$` with no tag, as CQL takes a function body.
    Untagged,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ScriptSyntax {
    pub single_quote: QuoteRule,
    pub double_quote: QuoteRule,
    pub backtick: Option<QuoteRule>,
    pub bracket_identifier: BracketIdentifier,
    pub escape_string_prefix: bool,
    pub dash_comment_needs_space: bool,
    /// A line comment ends at a carriage return as well as a line feed,
    /// as PostgreSQL's scanner and SQL Server read it. Elsewhere only a
    /// line feed ends it.
    pub line_comment_ends_at_cr: bool,
    pub hash_comment: HashComment,
    pub slash_slash_comment: bool,
    pub nested_block_comments: bool,
    /// MySQL and MariaDB run what `/*!` and `/*M!` comments hold.
    pub executable_comments: bool,
    pub dollar_quote: DollarQuote,
    /// An underscore between two digits is part of a number, as in
    /// `1_000.5e1_0`: PostgreSQL 16, SQLite 3.46 and ClickHouse read it
    /// so. MySQL reads `1_0e` as a name.
    pub digit_separators: bool,
    /// A parameter is named as a Tcl variable is, so after `$`, `@`, `:`
    /// or `#` the name can hold `::` and end in `(…)`, which runs to the
    /// next `)` whatever it holds: SQLite's `$space::name(index)`.
    pub tcl_parameters: bool,
    /// A UTF-8 byte-order mark where a token starts is a space, as
    /// SQLite's `sqlite3GetToken` reads it. Inside a name it stays a name
    /// character, there as elsewhere.
    pub byte_order_mark_is_space: bool,
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
        line_comment_ends_at_cr: true,
        hash_comment: HashComment::None,
        slash_slash_comment: false,
        nested_block_comments: true,
        executable_comments: false,
        dollar_quote: DollarQuote::Tagged,
        digit_separators: true,
        tcl_parameters: false,
        byte_order_mark_is_space: false,
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
        line_comment_ends_at_cr: false,
        hash_comment: HashComment::Always,
        slash_slash_comment: false,
        nested_block_comments: false,
        executable_comments: true,
        dollar_quote: DollarQuote::None,
        digit_separators: false,
        tcl_parameters: false,
        byte_order_mark_is_space: false,
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
        line_comment_ends_at_cr: false,
        hash_comment: HashComment::None,
        slash_slash_comment: false,
        nested_block_comments: false,
        executable_comments: false,
        dollar_quote: DollarQuote::None,
        digit_separators: true,
        tcl_parameters: true,
        byte_order_mark_is_space: true,
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
        line_comment_ends_at_cr: true,
        hash_comment: HashComment::None,
        slash_slash_comment: false,
        nested_block_comments: true,
        executable_comments: false,
        dollar_quote: DollarQuote::None,
        digit_separators: false,
        tcl_parameters: false,
        byte_order_mark_is_space: false,
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
        line_comment_ends_at_cr: false,
        hash_comment: HashComment::SpaceOrBang,
        slash_slash_comment: true,
        nested_block_comments: true,
        executable_comments: false,
        dollar_quote: DollarQuote::Heredoc,
        digit_separators: true,
        tcl_parameters: false,
        byte_order_mark_is_space: false,
        word_start_extra: b"",
        word_part_extra: b"",
    },
};

const CQL: ScriptRules = ScriptRules {
    boundary: Boundary::Semicolon,
    compound: CompoundRule::Batch,
    parens_hold_semicolons: false,
    batch_error: BatchErrorPolicy::StopScript,
    syntax: ScriptSyntax {
        single_quote: quote(QuoteKind::StringLiteral, BackslashPolicy::Never),
        double_quote: quote(QuoteKind::QuotedIdentifier, BackslashPolicy::Never),
        backtick: None,
        bracket_identifier: BracketIdentifier::None,
        escape_string_prefix: false,
        dash_comment_needs_space: false,
        line_comment_ends_at_cr: true,
        hash_comment: HashComment::None,
        slash_slash_comment: true,
        nested_block_comments: false,
        executable_comments: false,
        dollar_quote: DollarQuote::Untagged,
        digit_separators: false,
        tcl_parameters: false,
        byte_order_mark_is_space: false,
        word_start_extra: b"",
        word_part_extra: b"",
    },
};

/// DuckDB's parser is PostgreSQL's scanner without its procedural
/// bodies: a string escapes only with an `E` prefix, block comments
/// nest, `$tag$` quotes, and a backtick quotes nothing.
const DUCKDB: ScriptRules = ScriptRules {
    boundary: Boundary::Semicolon,
    compound: CompoundRule::None,
    parens_hold_semicolons: false,
    batch_error: BatchErrorPolicy::StopScript,
    syntax: ScriptSyntax {
        single_quote: quote(QuoteKind::StringLiteral, BackslashPolicy::Never),
        double_quote: quote(QuoteKind::QuotedIdentifier, BackslashPolicy::Never),
        backtick: None,
        bracket_identifier: BracketIdentifier::None,
        escape_string_prefix: true,
        dash_comment_needs_space: false,
        line_comment_ends_at_cr: true,
        hash_comment: HashComment::None,
        slash_slash_comment: false,
        nested_block_comments: true,
        executable_comments: false,
        dollar_quote: DollarQuote::Tagged,
        digit_separators: true,
        tcl_parameters: false,
        byte_order_mark_is_space: false,
        word_start_extra: b"",
        word_part_extra: b"$",
    },
};

/// `None` for Redis and MongoDB, whose languages have no SQL rules.
pub(crate) fn rules_for(grammar: SqlGrammar) -> Option<&'static ScriptRules> {
    match grammar {
        SqlGrammar::PostgreSql => Some(&POSTGRESQL),
        SqlGrammar::MySql => Some(&MYSQL),
        SqlGrammar::Sqlite => Some(&SQLITE),
        SqlGrammar::MsSql => Some(&MSSQL),
        SqlGrammar::ClickHouse => Some(&CLICKHOUSE),
        SqlGrammar::DuckDb => Some(&DUCKDB),
        SqlGrammar::Cql => Some(&CQL),
        SqlGrammar::Redis | SqlGrammar::Mongo => None,
    }
}
