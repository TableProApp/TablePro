use thiserror::Error;

use super::shell_lexer::{ShellToken, ShellTokenKind, lex_shell};
use super::{CallRoot, ShellCall, ShellConstructor, ShellMethod, ShellNumber, ShellStatement, ShellValue, ShowTarget};

/// How deep objects and arrays may nest. A document the server takes
/// nests at most 100 levels, and recursion stays well inside the stack.
const MAX_DEPTH: usize = 120;

/// Why shell text is not a statement or a value the editor can run.
/// `at` is a byte offset into the text that was parsed.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ShellSyntaxError {
    #[error("there is nothing to run")]
    Empty,
    #[error("the text ends before the statement does")]
    Incomplete,
    #[error("unexpected `{found}`")]
    Unexpected { at: usize, found: String },
    #[error("a statement starts with db, rs, show or use, not `{found}`")]
    UnknownRoot { at: usize, found: String },
    #[error("show takes dbs, collections, users or roles")]
    UnknownShow { at: usize },
    #[error("use takes the name of a database")]
    MissingDatabase { at: usize },
    #[error("call a method, such as db.{collection}.find()")]
    NoMethod { at: usize, collection: String },
    #[error("{name}() is not a shell helper")]
    UnknownHelper { at: usize, name: String },
    #[error("{helper}() takes {expected}")]
    HelperArguments {
        at: usize,
        helper: &'static str,
        expected: &'static str,
    },
    #[error("`{name}` is not a value")]
    UnknownName { at: usize, name: String },
    #[error("the regular expression flag `{flag}` is not one MongoDB takes")]
    RegexFlag { at: usize, flag: char },
    #[error("the string has an escape that does not read")]
    BadEscape { at: usize },
    #[error("a template string cannot hold `${{`")]
    TemplateSubstitution { at: usize },
    #[error("values nest too deeply")]
    TooDeep { at: usize },
    #[error("a parameter is not a value that typed text can hold")]
    Parameter { at: usize },
}

impl ShellSyntaxError {
    /// Where in the text the problem is, when it is at one place.
    pub fn offset(&self) -> Option<usize> {
        match self {
            Self::Empty | Self::Incomplete => None,
            Self::Unexpected { at, .. }
            | Self::UnknownRoot { at, .. }
            | Self::UnknownShow { at }
            | Self::MissingDatabase { at }
            | Self::NoMethod { at, .. }
            | Self::UnknownHelper { at, .. }
            | Self::HelperArguments { at, .. }
            | Self::UnknownName { at, .. }
            | Self::RegexFlag { at, .. }
            | Self::BadEscape { at }
            | Self::TemplateSubstitution { at }
            | Self::TooDeep { at }
            | Self::Parameter { at } => Some(*at),
        }
    }
}

/// One statement as typed in the editor.
pub fn parse_statement(text: &str) -> Result<ShellStatement, ShellSyntaxError> {
    Parser::new(text, 0).statement()
}

/// A statement the app generated, whose values are `$1` to `$params`.
pub fn parse_bound_statement(text: &str, params: usize) -> Result<ShellStatement, ShellSyntaxError> {
    Parser::new(text, params).statement()
}

/// One value as typed: a filter, or a document in a cell.
pub fn parse_value(text: &str) -> Result<ShellValue, ShellSyntaxError> {
    let mut parser = Parser::new(text, 0);
    let value = parser.value(0)?;
    parser.end()?;
    Ok(value)
}

struct Parser<'a> {
    text: &'a str,
    tokens: Vec<ShellToken>,
    at: usize,
    params: usize,
}

enum Segment {
    Member(String, usize),
    Call(Vec<ShellValue>, usize),
}

impl<'a> Parser<'a> {
    fn new(text: &'a str, params: usize) -> Self {
        let tokens = lex_shell(text)
            .into_iter()
            .filter(|token| !token.kind.is_trivia())
            .collect();
        Self {
            text,
            tokens,
            at: 0,
            params,
        }
    }

    fn peek(&self) -> Option<&ShellToken> {
        self.tokens.get(self.at)
    }

    fn next(&mut self) -> Result<ShellToken, ShellSyntaxError> {
        let token = self.peek().cloned().ok_or(ShellSyntaxError::Incomplete)?;
        if token.kind.is_open() {
            return Err(ShellSyntaxError::Incomplete);
        }
        self.at += 1;
        Ok(token)
    }

    fn peek_punct(&self) -> Option<char> {
        self.peek().and_then(|token| token.punct(self.text))
    }

    fn eat_punct(&mut self, c: char) -> bool {
        let found = self.peek_punct() == Some(c);
        if found {
            self.at += 1;
        }
        found
    }

    fn expect_punct(&mut self, c: char) -> Result<(), ShellSyntaxError> {
        let token = self.next()?;
        match token.punct(self.text) {
            Some(found) if found == c => Ok(()),
            _ => Err(self.unexpected(&token)),
        }
    }

    fn unexpected(&self, token: &ShellToken) -> ShellSyntaxError {
        ShellSyntaxError::Unexpected {
            at: token.range.start,
            found: token.text(self.text).chars().take(40).collect(),
        }
    }

    /// Nothing but an optional `;` may follow.
    fn end(&mut self) -> Result<(), ShellSyntaxError> {
        self.eat_punct(';');
        match self.peek() {
            None => Ok(()),
            Some(token) if token.kind.is_open() => Err(ShellSyntaxError::Incomplete),
            Some(token) => Err(self.unexpected(token)),
        }
    }

    fn statement(&mut self) -> Result<ShellStatement, ShellSyntaxError> {
        let first = self.next().map_err(|error| match error {
            ShellSyntaxError::Incomplete if self.tokens.is_empty() => ShellSyntaxError::Empty,
            other => other,
        })?;
        let word = match first.kind {
            ShellTokenKind::Identifier => first.text(self.text),
            _ => return Err(self.unexpected(&first)),
        };
        let statement = match word {
            "show" => {
                let target = self.next()?;
                let shown = (target.kind == ShellTokenKind::Identifier)
                    .then(|| ShowTarget::named(target.text(self.text)))
                    .flatten();
                ShellStatement::Show(shown.ok_or(ShellSyntaxError::UnknownShow { at: target.range.start })?)
            }
            "use" => return self.use_database(first.range.end),
            "db" => ShellStatement::Call(self.call(CallRoot::Db)?),
            "rs" => ShellStatement::Call(self.call(CallRoot::Rs)?),
            other => {
                return Err(ShellSyntaxError::UnknownRoot {
                    at: first.range.start,
                    found: other.to_owned(),
                });
            }
        };
        self.end()?;
        Ok(statement)
    }

    /// `use` takes the rest of its line as the name, as mongosh does, so
    /// a name with a dash needs no quotes.
    fn use_database(&mut self, after: usize) -> Result<ShellStatement, ShellSyntaxError> {
        let rest = self.text[after..].trim();
        let rest = rest.strip_suffix(';').unwrap_or(rest).trim_end();
        let name = ['"', '\'']
            .iter()
            .find_map(|quote| rest.strip_prefix(*quote).and_then(|inner| inner.strip_suffix(*quote)))
            .unwrap_or(rest);
        if name.is_empty() || name.contains(char::is_whitespace) {
            return Err(ShellSyntaxError::MissingDatabase { at: after });
        }
        Ok(ShellStatement::Use(name.to_owned()))
    }

    fn call(&mut self, root: CallRoot) -> Result<ShellCall, ShellSyntaxError> {
        let mut segments = Vec::new();
        loop {
            let at = self.peek().map_or(self.text.len(), |token| token.range.start);
            if self.eat_punct('.') {
                let name = self.next()?;
                if name.kind != ShellTokenKind::Identifier {
                    return Err(self.unexpected(&name));
                }
                segments.push(Segment::Member(name.text(self.text).to_owned(), name.range.start));
            } else if self.eat_punct('[') {
                let name = self.next()?;
                let ShellTokenKind::String { .. } = name.kind else {
                    return Err(self.unexpected(&name));
                };
                segments.push(Segment::Member(self.string(&name)?, name.range.start));
                self.expect_punct(']')?;
            } else if self.eat_punct('(') {
                segments.push(Segment::Call(self.arguments(')', 0)?, at));
            } else {
                break;
            }
        }
        chain(root, segments, self.text.len())
    }

    /// Values separated by commas up to `close`, a trailing comma allowed.
    fn arguments(&mut self, close: char, depth: usize) -> Result<Vec<ShellValue>, ShellSyntaxError> {
        let mut values = Vec::new();
        loop {
            if self.eat_punct(close) {
                return Ok(values);
            }
            values.push(self.value(depth)?);
            if !self.eat_punct(',') {
                self.expect_punct(close)?;
                return Ok(values);
            }
        }
    }

    fn value(&mut self, depth: usize) -> Result<ShellValue, ShellSyntaxError> {
        let token = self.next()?;
        if depth > MAX_DEPTH {
            return Err(ShellSyntaxError::TooDeep { at: token.range.start });
        }
        match token.kind {
            ShellTokenKind::String { .. } => Ok(ShellValue::String(self.string(&token)?)),
            ShellTokenKind::Number => Ok(ShellValue::Number(ShellNumber::new(token.text(self.text)))),
            ShellTokenKind::Regex { .. } => self.regex(&token),
            ShellTokenKind::Identifier => self.named_value(&token, depth),
            ShellTokenKind::Punct => match token.punct(self.text) {
                Some('{') => self.object(depth),
                Some('[') => Ok(ShellValue::Array(self.arguments(']', depth + 1)?)),
                Some(sign @ ('-' | '+')) => self.signed(sign, &token),
                _ => Err(self.unexpected(&token)),
            },
            ShellTokenKind::Whitespace { .. } | ShellTokenKind::LineComment | ShellTokenKind::BlockComment { .. } => {
                Err(self.unexpected(&token))
            }
        }
    }

    fn signed(&mut self, sign: char, sign_token: &ShellToken) -> Result<ShellValue, ShellSyntaxError> {
        let token = self.next()?;
        let text = token.text(self.text);
        let number = match token.kind {
            ShellTokenKind::Number => text,
            ShellTokenKind::Identifier if matches!(text, "Infinity" | "NaN") => text,
            _ => return Err(self.unexpected(sign_token)),
        };
        let signed = match sign {
            '-' => format!("-{number}"),
            _ => number.to_owned(),
        };
        Ok(ShellValue::Number(ShellNumber::new(signed)))
    }

    fn object(&mut self, depth: usize) -> Result<ShellValue, ShellSyntaxError> {
        let mut fields = Vec::new();
        loop {
            if self.eat_punct('}') {
                return Ok(ShellValue::Object(fields));
            }
            let key = self.next()?;
            let name = match key.kind {
                ShellTokenKind::Identifier | ShellTokenKind::Number => key.text(self.text).to_owned(),
                ShellTokenKind::String { .. } => self.string(&key)?,
                _ => return Err(self.unexpected(&key)),
            };
            self.expect_punct(':')?;
            fields.push((name, self.value(depth + 1)?));
            if !self.eat_punct(',') {
                self.expect_punct('}')?;
                return Ok(ShellValue::Object(fields));
            }
        }
    }

    fn named_value(&mut self, token: &ShellToken, depth: usize) -> Result<ShellValue, ShellSyntaxError> {
        let at = token.range.start;
        let name = token.text(self.text);
        match name {
            "true" => return Ok(ShellValue::Bool(true)),
            "false" => return Ok(ShellValue::Bool(false)),
            "null" => return Ok(ShellValue::Null),
            "Infinity" | "NaN" => return Ok(ShellValue::Number(ShellNumber::new(name))),
            _ => {}
        }
        if let Some(digits) = name.strip_prefix('$')
            && !digits.is_empty()
            && digits.bytes().all(|byte| byte.is_ascii_digit())
        {
            return match digits.parse::<usize>() {
                Ok(index) if (1..=self.params).contains(&index) => Ok(ShellValue::Param(index)),
                _ => Err(ShellSyntaxError::Parameter { at }),
            };
        }
        let (name, at) = if name == "new" {
            let helper = self.next()?;
            if helper.kind != ShellTokenKind::Identifier {
                return Err(self.unexpected(&helper));
            }
            (helper.text(self.text), helper.range.start)
        } else {
            (name, at)
        };
        let Some(kind) = ShellConstructor::named(name) else {
            return Err(match self.peek_punct() {
                Some('(') => ShellSyntaxError::UnknownHelper {
                    at,
                    name: name.to_owned(),
                },
                _ => ShellSyntaxError::UnknownName {
                    at,
                    name: name.to_owned(),
                },
            });
        };
        let args = match self.eat_punct('(') {
            true => self.arguments(')', depth + 1)?,
            // MinKey and MaxKey are values in the shell even uncalled.
            false if matches!(kind, ShellConstructor::MinKey | ShellConstructor::MaxKey) => Vec::new(),
            false => {
                return Err(ShellSyntaxError::UnknownName {
                    at,
                    name: name.to_owned(),
                });
            }
        };
        super::shell_helpers::check_helper(kind, &args, at)?;
        Ok(ShellValue::Constructor { kind, args })
    }

    fn regex(&self, token: &ShellToken) -> Result<ShellValue, ShellSyntaxError> {
        let text = token.text(self.text);
        let close = text.rfind('/').unwrap_or(0);
        let pattern = text.get(1..close).unwrap_or_default().to_owned();
        let flags = text.get(close + 1..).unwrap_or_default();
        if let Some(flag) = flags.chars().find(|flag| !"imsux".contains(*flag)) {
            return Err(ShellSyntaxError::RegexFlag {
                at: token.range.start,
                flag,
            });
        }
        Ok(ShellValue::Regex {
            pattern,
            flags: flags.to_owned(),
        })
    }

    fn string(&self, token: &ShellToken) -> Result<String, ShellSyntaxError> {
        decode_string(token.text(self.text), token.range.start)
    }
}

/// The value of a quoted string, its escapes read as JavaScript reads
/// them.
pub(crate) fn decode_string(quoted: &str, at: usize) -> Result<String, ShellSyntaxError> {
    let mut chars = quoted.chars();
    let quote = chars.next().unwrap_or('"');
    let inner = chars.as_str().strip_suffix(quote).unwrap_or(chars.as_str());
    if quote == '`' && inner.contains("${") {
        return Err(ShellSyntaxError::TemplateSubstitution { at });
    }
    let mut decoded = String::with_capacity(inner.len());
    let mut chars = inner.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\\' {
            decoded.push(c);
            continue;
        }
        let bad = ShellSyntaxError::BadEscape { at };
        match chars.next().ok_or(bad.clone())? {
            'n' => decoded.push('\n'),
            't' => decoded.push('\t'),
            'r' => decoded.push('\r'),
            'b' => decoded.push('\u{8}'),
            'f' => decoded.push('\u{c}'),
            'v' => decoded.push('\u{b}'),
            '0' => decoded.push('\0'),
            '\n' => {}
            '\r' => {
                chars.next_if_eq(&'\n');
            }
            'x' => {
                let hex: String = (0..2).filter_map(|_| chars.next()).collect();
                decoded.push(code_point(&hex).ok_or(bad)?);
            }
            'u' => {
                let hex: String = if chars.next_if_eq(&'{').is_some() {
                    chars.by_ref().take_while(|c| *c != '}').collect()
                } else {
                    (0..4).filter_map(|_| chars.next()).collect()
                };
                decoded.push(utf16_unit(&hex, &mut chars).ok_or(bad)?);
            }
            other => decoded.push(other),
        }
    }
    Ok(decoded)
}

fn code_point(hex: &str) -> Option<char> {
    u32::from_str_radix(hex, 16).ok().and_then(char::from_u32)
}

/// A `\u` escape, which may be the first half of a surrogate pair whose
/// second half is the next escape.
fn utf16_unit(hex: &str, rest: &mut std::iter::Peekable<std::str::Chars<'_>>) -> Option<char> {
    let unit = u32::from_str_radix(hex, 16).ok()?;
    if !(0xD800..0xDC00).contains(&unit) {
        return char::from_u32(unit);
    }
    let mut ahead = rest.clone();
    if ahead.next()? != '\\' || ahead.next()? != 'u' {
        return None;
    }
    let low: String = (0..4).filter_map(|_| ahead.next()).collect();
    let low = u32::from_str_radix(&low, 16).ok()?;
    if !(0xDC00..0xE000).contains(&low) {
        return None;
    }
    *rest = ahead;
    char::from_u32(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
}

/// Read a chain of members and calls: the last member before a call is
/// the method, and members before the first method name the collection,
/// joined with dots as mongosh joins `db.system.users`.
fn chain(root: CallRoot, segments: Vec<Segment>, end: usize) -> Result<ShellCall, ShellSyntaxError> {
    let mut call = ShellCall {
        root,
        database: None,
        collection: None,
        methods: Vec::new(),
    };
    let mut pending: Vec<(String, usize)> = Vec::new();
    for segment in segments {
        let (args, at) = match segment {
            Segment::Member(name, at) => {
                pending.push((name, at));
                continue;
            }
            Segment::Call(args, at) => (args, at),
        };
        let Some((method, method_at)) = pending.pop() else {
            return Err(ShellSyntaxError::Unexpected {
                at,
                found: "(".to_owned(),
            });
        };
        if let Some((first, first_at)) = pending.first() {
            if call.collection.is_some() || !call.methods.is_empty() || root != CallRoot::Db {
                return Err(ShellSyntaxError::Unexpected {
                    at: *first_at,
                    found: first.clone(),
                });
            }
            call.collection = Some(joined(&pending));
            pending.clear();
        }
        let selects = root == CallRoot::Db && call.collection.is_none() && call.methods.is_empty();
        match method.as_str() {
            "getCollection" if selects => call.collection = Some(name_argument(&args, method_at, "getCollection")?),
            "getSiblingDB" | "getSisterDB" if selects && call.database.is_none() => {
                call.database = Some(name_argument(&args, method_at, "getSiblingDB")?);
            }
            _ => call.methods.push(ShellMethod::new(method, args)),
        }
    }
    if let Some((_, at)) = pending.first() {
        let collection = match &call.collection {
            Some(collection) => format!("{collection}.{}", joined(&pending)),
            None => joined(&pending),
        };
        return Err(ShellSyntaxError::NoMethod { at: *at, collection });
    }
    if call.methods.is_empty() {
        return Err(ShellSyntaxError::NoMethod {
            at: end,
            collection: call.collection.unwrap_or_else(|| "collection".to_owned()),
        });
    }
    Ok(call)
}

fn joined(names: &[(String, usize)]) -> String {
    names
        .iter()
        .map(|(name, _)| name.as_str())
        .collect::<Vec<_>>()
        .join(".")
}

fn name_argument(args: &[ShellValue], at: usize, helper: &'static str) -> Result<String, ShellSyntaxError> {
    match args {
        [ShellValue::String(name)] if !name.is_empty() => Ok(name.clone()),
        _ => Err(ShellSyntaxError::HelperArguments {
            at,
            helper,
            expected: "a name in quotes",
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(text: &str) -> ShellCall {
        match parse_statement(text) {
            Ok(ShellStatement::Call(call)) => call,
            other => panic!("{text}: {other:?}"),
        }
    }

    fn method(call: &ShellCall, index: usize) -> (&str, &[ShellValue]) {
        let method = &call.methods[index];
        (method.name.as_str(), method.args.as_slice())
    }

    #[test]
    fn a_collection_is_named_by_member_by_index_or_by_get_collection() {
        for text in [
            "db.orders.find()",
            "db['orders'].find()",
            r#"db.getCollection("orders").find()"#,
            "db\n  .orders\n  .find();",
        ] {
            let found = call(text);
            assert_eq!(found.collection.as_deref(), Some("orders"), "{text}");
            assert_eq!(found.database, None, "{text}");
            assert_eq!(method(&found, 0).0, "find", "{text}");
        }
        assert_eq!(
            call("db.system.users.find()").collection.as_deref(),
            Some("system.users")
        );
        let sibling = call(r#"db.getSiblingDB("admin").getCollection("x").countDocuments({})"#);
        assert_eq!(sibling.database.as_deref(), Some("admin"));
        assert_eq!(sibling.collection.as_deref(), Some("x"));
    }

    #[test]
    fn methods_chain_after_the_operation() {
        let found = call("db.users.find({age: {$gt: 30}}, {name: 1}).sort({name: -1}).limit(5)");

        assert_eq!(found.methods.len(), 3);
        let (name, args) = method(&found, 0);
        assert_eq!(name, "find");
        assert_eq!(args[0].to_string(), r#"{"age": {"$gt": 30}}"#);
        assert_eq!(args[1].to_string(), r#"{"name": 1}"#);
        assert_eq!(method(&found, 1).1[0].to_string(), r#"{"name": -1}"#);
        assert_eq!(found.modifiers().len(), 2);
        let database = call("db.runCommand({ping: 1})");
        assert_eq!(database.collection, None);
        assert_eq!(method(&database, 0).0, "runCommand");
        assert_eq!(call("rs.status()").root, CallRoot::Rs);
    }

    #[test]
    fn show_and_use_are_statements_of_their_own() {
        assert_eq!(
            parse_statement("show dbs"),
            Ok(ShellStatement::Show(ShowTarget::Databases))
        );
        assert_eq!(
            parse_statement("show tables;"),
            Ok(ShellStatement::Show(ShowTarget::Collections))
        );
        assert_eq!(
            parse_statement("use my-shop"),
            Ok(ShellStatement::Use("my-shop".to_owned()))
        );
        assert_eq!(
            parse_statement("use 'quoted';"),
            Ok(ShellStatement::Use("quoted".to_owned()))
        );
        assert!(matches!(
            parse_statement("show tablez"),
            Err(ShellSyntaxError::UnknownShow { .. })
        ));
        assert!(matches!(
            parse_statement("use"),
            Err(ShellSyntaxError::MissingDatabase { .. })
        ));
        assert!(matches!(
            parse_statement("use a b"),
            Err(ShellSyntaxError::MissingDatabase { .. })
        ));
    }

    #[test]
    fn values_read_as_javascript_literals() {
        let value = parse_value(
            "{ a: 'x', \"b c\": -2, d: [1, 2.5, ], e: new Date('2024-01-01'), f: /x/i, g: null, h: true, 7: NaN, }",
        )
        .expect("a value");
        assert_eq!(
            value.to_string(),
            r#"{"a": "x", "b c": -2, "d": [1, 2.5], "e": ISODate("2024-01-01"), "f": /x/i, "g": null, "h": true, "7": NaN}"#
        );
        assert_eq!(
            parse_value(r#""\u00e9\x41\u{1F600}\ud83d\ude00""#),
            Ok(ShellValue::string("éA😀😀"))
        );
        assert_eq!(
            parse_value("MinKey").map(|value| value.to_string()),
            Ok("MinKey()".to_owned())
        );
    }

    #[test]
    fn an_object_keeps_its_keys_in_order() {
        let value = parse_value("{z: 1, a: 2, m: 3}").expect("a value");
        let keys: Vec<&str> = value
            .as_object()
            .unwrap_or_default()
            .iter()
            .map(|(key, _)| key.as_str())
            .collect();
        assert_eq!(keys, ["z", "a", "m"]);
    }

    type Expected = fn(&ShellSyntaxError) -> bool;

    #[test]
    fn what_is_not_a_statement_says_where() {
        let cases: [(&str, Expected); 11] = [
            ("", |error| *error == ShellSyntaxError::Empty),
            ("db.users.find({a: 1}", |error| *error == ShellSyntaxError::Incomplete),
            ("db.users.find('open", |error| *error == ShellSyntaxError::Incomplete),
            (
                "db.users",
                |error| matches!(error, ShellSyntaxError::NoMethod { collection, .. } if collection == "users"),
            ),
            ("print(1)", |error| {
                matches!(error, ShellSyntaxError::UnknownRoot { at: 0, .. })
            }),
            ("db.x.find(eval('1'))", |error| {
                matches!(error, ShellSyntaxError::UnknownHelper { at: 10, .. })
            }),
            ("db.x.find({a: b})", |error| {
                matches!(error, ShellSyntaxError::UnknownName { at: 14, .. })
            }),
            ("db.x.find({a: /x/g})", |error| {
                matches!(error, ShellSyntaxError::RegexFlag { flag: 'g', .. })
            }),
            ("db.x.find({_id: ObjectId('xyz')})", |error| {
                matches!(error, ShellSyntaxError::HelperArguments { helper: "ObjectId", .. })
            }),
            ("db.x.find({a: $1})", |error| {
                matches!(error, ShellSyntaxError::Parameter { at: 14 })
            }),
            ("db.x.find() db.y.find()", |error| {
                matches!(error, ShellSyntaxError::Unexpected { at: 12, .. })
            }),
        ];
        for (text, expected) in cases {
            let error = parse_statement(text).expect_err(text);
            assert!(expected(&error), "{text}: {error:?}");
        }
        let deep = format!("db.x.find({}{})", "[".repeat(200), "]".repeat(200));
        assert!(matches!(parse_statement(&deep), Err(ShellSyntaxError::TooDeep { .. })));
    }

    #[test]
    fn a_bound_statement_takes_only_the_parameters_it_has() {
        assert!(parse_bound_statement("db.x.deleteOne({_id: $1})", 1).is_ok());
        assert!(matches!(
            parse_bound_statement("db.x.deleteOne({_id: $2})", 1),
            Err(ShellSyntaxError::Parameter { .. })
        ));
    }
}
