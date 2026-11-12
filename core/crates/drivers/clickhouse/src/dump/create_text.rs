use std::ops::Range;

use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptToken, ScriptTokenKind};

/// `create` with every `database.` qualifier gone, so the file loads into
/// a database of any name. The server qualifies the names a view's query
/// reads, as well as the created name and a materialized view's target.
/// Where the query also uses the database's name as an alias, `name.`
/// there can be a column of that alias, so only the header's go.
pub(crate) fn without_database(create: &str, database: &str) -> String {
    let tokens = tokens(create);
    let aliased = tokens
        .windows(2)
        .any(|pair| is_word(create, &pair[0], "AS") && name_text(create, &pair[1]).as_deref() == Some(database));
    let considered = match aliased {
        true => &tokens[..head(create, &tokens)],
        false => &tokens[..],
    };
    let mut cuts = Vec::new();
    for (at, window) in considered.windows(3).enumerate() {
        let [name, dot, next] = window else {
            continue;
        };
        let follows_dot = at.checked_sub(1).is_some_and(|before| is_dot(create, &tokens[before]));
        if !follows_dot && name_text(create, name).as_deref() == Some(database) && is_dot(create, dot) && is_name(next)
        {
            cuts.push(name.range.start..dot.range.end);
        }
    }
    cut(create, &cuts)
}

/// A view's text without its `DEFINER = user`, as mysqldump leaves the
/// definer out: the user may not exist where the file loads, and the
/// server makes whoever runs the CREATE the definer.
pub(crate) fn without_definer(create: &str) -> String {
    let tokens = tokens(create);
    let head = head(create, &tokens);
    let mut cuts = Vec::new();
    for (at, window) in tokens[..head].windows(3).enumerate() {
        let [definer, equals, user] = window else {
            continue;
        };
        if is_word(create, definer, "DEFINER") && token_text(create, equals) == "=" && is_name(user) {
            let end = tokens.get(at + 3).map_or(user.range.end, |next| next.range.start);
            cuts.push(definer.range.start..end);
        }
    }
    cut(create, &cuts)
}

/// Whether a materialized view keeps its rows in an inner table of its
/// own: one with no `TO` target and no refresh. That table's name changes
/// with every CREATE, so its rows cannot go in the file, and a POPULATE
/// would recompute them from the source rows still there, not the ones
/// the view kept.
pub(crate) fn keeps_own_rows(create: &str) -> bool {
    let tokens = tokens(create);
    let head = head(create, &tokens);
    let Some(after_name) = after_created_name(create, &tokens) else {
        return false;
    };
    let mut depth = 0usize;
    for token in &tokens[after_name.min(head)..] {
        match token.kind {
            ScriptTokenKind::OpenParen => depth += 1,
            ScriptTokenKind::CloseParen => depth = depth.saturating_sub(1),
            _ if depth > 0 => {}
            _ if ["TO", "REFRESH"].iter().any(|word| is_word(create, token, word)) => return false,
            _ if ["AS", "COMMENT", "DEFINER", "SQL"]
                .iter()
                .any(|word| is_word(create, token, word)) =>
            {
                return true;
            }
            _ => {}
        }
    }
    false
}

/// Whether the server wrote `'[HIDDEN]'` in place of a secret: in an
/// engine's, a table function's or a dictionary source's arguments, or a
/// setting. The same string as a column's default or a comment is text.
pub(crate) fn hides_secret(create: &str) -> bool {
    let tokens = tokens(create);
    let mut depth = 0usize;
    let mut seen_group = false;
    let mut in_columns = false;
    for (at, token) in tokens.iter().enumerate() {
        match token.kind {
            ScriptTokenKind::OpenParen => {
                if depth == 0 && !seen_group {
                    seen_group = true;
                    let called = at
                        .checked_sub(2)
                        .and_then(|before| tokens.get(before))
                        .is_some_and(|before| is_word(create, before, "AS") || token_text(create, before) == "=");
                    in_columns = !called;
                }
                depth += 1;
            }
            ScriptTokenKind::CloseParen => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    in_columns = false;
                }
            }
            ScriptTokenKind::StringLiteral if token_text(create, token) == "'[HIDDEN]'" => {
                let comment = at
                    .checked_sub(1)
                    .is_some_and(|before| is_word(create, &tokens[before], "COMMENT"));
                if !in_columns && !comment {
                    return true;
                }
            }
            _ => {}
        }
    }
    false
}

/// Whether `create` makes a dictionary, rather than a table over one.
pub(crate) fn is_dictionary(create: &str) -> bool {
    let tokens = tokens(create);
    matches!(tokens.as_slice(), [first, second, ..] if is_word(create, first, "CREATE") && is_word(create, second, "DICTIONARY"))
}

fn tokens(sql: &str) -> Vec<ScriptToken> {
    let grammar = SqlGrammar::ClickHouse;
    ScriptPlan::build(sql, grammar, LexicalSettings::default_for(grammar))
        .tokens(0..sql.len())
        .filter(|token| !token.kind.is_trivia())
        .collect()
}

/// How many tokens come before the `AS` that starts a view's query.
fn head(sql: &str, tokens: &[ScriptToken]) -> usize {
    let mut depth = 0usize;
    for (at, token) in tokens.iter().enumerate() {
        match token.kind {
            ScriptTokenKind::OpenParen => depth += 1,
            ScriptTokenKind::CloseParen => depth = depth.saturating_sub(1),
            _ if depth == 0 && is_word(sql, token, "AS") => return at,
            _ => {}
        }
    }
    tokens.len()
}

/// The position after `CREATE MATERIALIZED VIEW [IF NOT EXISTS] name`.
fn after_created_name(sql: &str, tokens: &[ScriptToken]) -> Option<usize> {
    let mut at = 0;
    for word in ["CREATE", "MATERIALIZED", "VIEW"] {
        if !is_word(sql, tokens.get(at)?, word) {
            return None;
        }
        at += 1;
    }
    if is_word(sql, tokens.get(at)?, "IF") {
        at += 3;
    }
    if !is_name(tokens.get(at)?) {
        return None;
    }
    at += 1;
    while tokens.get(at).is_some_and(|token| is_dot(sql, token)) && tokens.get(at + 1).is_some_and(is_name) {
        at += 2;
    }
    Some(at)
}

fn cut(text: &str, ranges: &[Range<usize>]) -> String {
    let mut kept = text.to_owned();
    for range in ranges.iter().rev() {
        kept.replace_range(range.clone(), "");
    }
    kept
}

fn token_text<'a>(sql: &'a str, token: &ScriptToken) -> &'a str {
    sql.get(token.range.clone()).unwrap_or_default()
}

fn is_word(sql: &str, token: &ScriptToken, word: &str) -> bool {
    token.kind == ScriptTokenKind::Word && token_text(sql, token).eq_ignore_ascii_case(word)
}

fn is_dot(sql: &str, token: &ScriptToken) -> bool {
    token.kind == ScriptTokenKind::Punct && token_text(sql, token) == "."
}

fn is_name(token: &ScriptToken) -> bool {
    matches!(token.kind, ScriptTokenKind::Word | ScriptTokenKind::QuotedIdentifier)
}

/// The name a token spells, with a quoted one's escapes read as the
/// server reads them.
fn name_text(sql: &str, token: &ScriptToken) -> Option<String> {
    let text = token_text(sql, token);
    match token.kind {
        ScriptTokenKind::Word => Some(text.to_owned()),
        ScriptTokenKind::QuotedIdentifier => unquoted(text),
        _ => None,
    }
}

fn unquoted(text: &str) -> Option<String> {
    let quote = text.chars().next().filter(|first| matches!(first, '`' | '"'))?;
    let inner = text.strip_prefix(quote)?.strip_suffix(quote)?;
    let mut bytes = Vec::with_capacity(inner.len());
    let mut chars = inner.chars().peekable();
    let mut buffer = [0u8; 4];
    while let Some(character) = chars.next() {
        let decoded = match character {
            '\\' => match chars.next()? {
                'x' => {
                    let high = chars.next()?.to_digit(16)?;
                    let low = chars.next()?.to_digit(16)?;
                    bytes.push(u8::try_from(high * 16 + low).ok()?);
                    continue;
                }
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b' => '\u{8}',
                'f' => '\u{c}',
                'a' => '\u{7}',
                'v' => '\u{b}',
                '0' => '\0',
                other => other,
            },
            doubled if doubled == quote && chars.peek() == Some(&quote) => {
                chars.next();
                quote
            }
            other => other,
        };
        bytes.extend_from_slice(decoded.encode_utf8(&mut buffer).as_bytes());
    }
    String::from_utf8(bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_secret_is_hidden_in_arguments_and_settings_only() {
        assert!(hides_secret(
            "CREATE TABLE app.r\n(\n    `id` UInt64\n)\nENGINE = MySQL('h:3306', 'db', 't', 'u', '[HIDDEN]')"
        ));
        assert!(hides_secret(
            "CREATE DICTIONARY app.d (`id` UInt64) PRIMARY KEY id SOURCE(CLICKHOUSE(HOST 'h' PASSWORD '[HIDDEN]'))"
        ));
        assert!(hides_secret(
            "CREATE TABLE app.s AS s3('https://h/b/f.csv', 'key', '[HIDDEN]')"
        ));
        assert!(!hides_secret(
            "CREATE TABLE app.t\n(\n    `note` String DEFAULT '[HIDDEN]' COMMENT '[HIDDEN]'\n)\n\
             ENGINE = MergeTree\nORDER BY tuple()\nCOMMENT '[HIDDEN]'"
        ));
    }

    #[test]
    fn the_database_qualifier_goes_from_every_name() {
        let create = "CREATE VIEW app.v\n(\n    `id` UInt64\n)\nAS SELECT app.parent.id\nFROM app.parent\nINNER JOIN `app`.`child` ON 1";
        assert_eq!(
            without_database(create, "app"),
            "CREATE VIEW v\n(\n    `id` UInt64\n)\nAS SELECT parent.id\nFROM parent\nINNER JOIN `child` ON 1"
        );
    }

    #[test]
    fn only_the_dumped_database_is_stripped() {
        let create = "CREATE MATERIALIZED VIEW app.mv TO app.counts AS SELECT * FROM other.t JOIN application.t2 ON 1";
        assert_eq!(
            without_database(create, "app"),
            "CREATE MATERIALIZED VIEW mv TO counts AS SELECT * FROM other.t JOIN application.t2 ON 1"
        );
    }

    #[test]
    fn strings_comments_and_inner_name_parts_are_left_alone() {
        let create = "CREATE VIEW app.v AS SELECT 'app.x', x.app.y /* app.z */ FROM app.t";
        assert_eq!(
            without_database(create, "app"),
            "CREATE VIEW v AS SELECT 'app.x', x.app.y /* app.z */ FROM t"
        );
    }

    #[test]
    fn a_quoted_database_name_is_read_with_its_escapes() {
        let create = "CREATE TABLE `my\\`db`.t (`a` UInt8) ENGINE = Memory";
        assert_eq!(
            without_database(create, "my`db"),
            "CREATE TABLE t (`a` UInt8) ENGINE = Memory"
        );
        assert_eq!(unquoted("`a``b`").as_deref(), Some("a`b"));
        assert_eq!(unquoted("\"\\x41\\n\"").as_deref(), Some("A\n"));
        assert_eq!(unquoted("plain"), None);
    }

    #[test]
    fn the_definer_goes_and_the_security_stays() {
        let create = "CREATE VIEW v\n(\n    `id` UInt64\n)\nDEFINER = tablepro SQL SECURITY DEFINER\nAS SELECT definer = x FROM t";
        assert_eq!(
            without_definer(create),
            "CREATE VIEW v\n(\n    `id` UInt64\n)\nSQL SECURITY DEFINER\nAS SELECT definer = x FROM t"
        );
        assert_eq!(
            without_definer("CREATE VIEW v DEFINER = `odd user` SQL SECURITY DEFINER AS SELECT 1"),
            "CREATE VIEW v SQL SECURITY DEFINER AS SELECT 1"
        );
        assert_eq!(
            without_definer("CREATE VIEW v AS SELECT 1"),
            "CREATE VIEW v AS SELECT 1"
        );
    }

    #[test]
    fn an_alias_named_like_the_database_keeps_its_columns() {
        let create = "CREATE VIEW app.v AS SELECT app.id FROM app.events AS app";

        assert_eq!(
            without_database(create, "app"),
            "CREATE VIEW v AS SELECT app.id FROM app.events AS app"
        );
    }

    #[test]
    fn an_inner_materialized_view_keeps_its_own_rows() {
        assert!(keeps_own_rows(
            "CREATE MATERIALIZED VIEW mv\n(\n    `k` UInt64\n)\nENGINE = SummingMergeTree\nORDER BY k\nAS SELECT k FROM src"
        ));
        assert!(keeps_own_rows(
            "CREATE MATERIALIZED VIEW mv (`k` UInt64) ENGINE = Memory SQL SECURITY DEFINER AS SELECT k FROM src"
        ));
    }

    #[test]
    fn a_view_with_a_target_or_a_refresh_keeps_none() {
        for create in [
            "CREATE MATERIALIZED VIEW mv TO counts (`k` UInt64) AS SELECT k FROM src",
            "CREATE MATERIALIZED VIEW mv REFRESH EVERY 1 HOUR (`k` UInt64) ENGINE = Memory AS SELECT k FROM src",
            "CREATE VIEW v",
        ] {
            assert!(!keeps_own_rows(create), "{create}");
        }
    }

    #[test]
    fn a_dictionary_is_told_from_a_table_over_one() {
        assert!(is_dictionary(
            "CREATE DICTIONARY d (`id` UInt64) PRIMARY KEY id SOURCE(NULL()) LIFETIME(0) LAYOUT(FLAT())"
        ));
        assert!(!is_dictionary("CREATE TABLE t (`id` UInt64) ENGINE = Dictionary(d)"));
    }
}
