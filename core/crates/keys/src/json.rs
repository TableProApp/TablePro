use std::collections::HashSet;

use zeroize::{Zeroize, Zeroizing};

use crate::KeysError;
use crate::encoding::Version;

// serde_json's own nesting limit.
const MAX_DEPTH: usize = 128;

// A JSON value (RFC 8259) that keeps member order and each number's text, and that refuses a
// duplicate member name at any depth (ADR 0056, Encoding; ADR 0051, Key object bodies). serde_json
// lets the last duplicate win and parses floats lossily without its float_roundtrip feature.
#[derive(Debug, Clone)]
pub enum JsonValue {
    Null,
    Bool(bool),
    Number(JsonNumber),
    String(String),
    Array(Vec<JsonValue>),
    Object(Vec<(String, JsonValue)>),
}

// A number as its text, which the grammar checked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonNumber(String);

impl JsonNumber {
    pub fn as_str(&self) -> &str {
        &self.0
    }

    // A JSON integer: no fraction or exponent, in i64.
    pub fn as_i64(&self) -> Option<i64> {
        if self.0.contains(['.', 'e', 'E']) {
            None
        } else {
            self.0.parse().ok()
        }
    }

    pub fn as_u64(&self) -> Option<u64> {
        if self.0.contains(['.', 'e', 'E', '-']) {
            None
        } else {
            self.0.parse().ok()
        }
    }

    // (negative, significant digits without leading or trailing zeros, exponent of the last digit).
    // Equal numbers, as Postgres jsonb compares them, have the same form.
    fn canonical(&self) -> Option<(bool, String, i64)> {
        let text = self.0.as_str();
        let (negative, rest) = text.strip_prefix('-').map_or((false, text), |rest| (true, rest));
        let (mantissa, exponent) = match rest.find(['e', 'E']) {
            Some(at) => (&rest[..at], rest[at + 1..].parse::<i64>().ok()?),
            None => (rest, 0),
        };
        let (whole, fraction) = mantissa.split_once('.').unwrap_or((mantissa, ""));
        let fraction_len = i64::try_from(fraction.len()).ok()?;
        let mut digits: String = whole.chars().chain(fraction.chars()).collect();
        let mut exponent = exponent.checked_sub(fraction_len)?;
        let trimmed = digits.trim_start_matches('0').len();
        digits.drain(..digits.len() - trimmed);
        while digits.ends_with('0') {
            digits.pop();
            exponent = exponent.checked_add(1)?;
        }
        if digits.is_empty() {
            return Some((false, String::new(), 0));
        }
        Some((negative, digits, exponent))
    }

    fn same_as(&self, other: &Self) -> bool {
        match (self.canonical(), other.canonical()) {
            (Some(a), Some(b)) => a == b,
            _ => self.0 == other.0,
        }
    }
}

impl From<u64> for JsonNumber {
    fn from(value: u64) -> Self {
        Self(value.to_string())
    }
}

// No record a client reads is longer than a 4 MiB push or page (ADR 0051, Limits), so nothing longer
// is read: a server cannot make the tree grow past what a page could hold.
pub const MAX_JSON_LEN: usize = 4 << 20;

pub fn parse(bytes: &[u8]) -> Result<JsonValue, KeysError> {
    if bytes.len() > MAX_JSON_LEN {
        return Err(KeysError::encoding("JSON longer than a 4 MiB page"));
    }
    let text = std::str::from_utf8(bytes).map_err(|_| KeysError::encoding("JSON is not UTF-8"))?;
    let mut reader = Reader { text, at: 0 };
    reader.whitespace();
    let mut value = Zeroizing::new(reader.value(0)?);
    reader.whitespace();
    if reader.at != text.len() {
        return Err(KeysError::encoding("text after the JSON value"));
    }
    Ok(std::mem::replace(&mut *value, JsonValue::Null))
}

struct Reader<'a> {
    text: &'a str,
    at: usize,
}

fn syntax() -> KeysError {
    KeysError::encoding("not JSON")
}

impl Reader<'_> {
    fn peek(&self) -> Option<u8> {
        self.text.as_bytes().get(self.at).copied()
    }

    fn whitespace(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn expect(&mut self, byte: u8) -> Result<(), KeysError> {
        if self.peek() == Some(byte) {
            self.at += 1;
            Ok(())
        } else {
            Err(syntax())
        }
    }

    fn literal(&mut self, word: &str, value: JsonValue) -> Result<JsonValue, KeysError> {
        if self.text[self.at..].starts_with(word) {
            self.at += word.len();
            Ok(value)
        } else {
            Err(syntax())
        }
    }

    fn value(&mut self, depth: usize) -> Result<JsonValue, KeysError> {
        match self.peek().ok_or_else(syntax)? {
            b'{' => self.object(depth + 1),
            b'[' => self.array(depth + 1),
            b'"' => self.string().map(JsonValue::String),
            b't' => self.literal("true", JsonValue::Bool(true)),
            b'f' => self.literal("false", JsonValue::Bool(false)),
            b'n' => self.literal("null", JsonValue::Null),
            b'-' | b'0'..=b'9' => self.number().map(JsonValue::Number),
            _ => Err(syntax()),
        }
    }

    fn object(&mut self, depth: usize) -> Result<JsonValue, KeysError> {
        if depth > MAX_DEPTH {
            return Err(KeysError::encoding("JSON nested too deep"));
        }
        self.expect(b'{')?;
        // Wiped if a later member fails, since a plaintext's values can be secrets.
        let mut object = Zeroizing::new(JsonValue::Object(Vec::new()));
        // Hashes, not copies: a member name stays only in the tree, which is wiped.
        let hasher = std::hash::RandomState::new();
        let mut names: HashSet<u64> = HashSet::new();
        self.whitespace();
        if self.peek() == Some(b'}') {
            self.at += 1;
            return Ok(std::mem::replace(&mut *object, JsonValue::Null));
        }
        loop {
            self.whitespace();
            let mut name = Zeroizing::new(self.string()?);
            let seen = !names.insert(std::hash::BuildHasher::hash_one(&hasher, name.as_str()))
                && matches!(&*object, JsonValue::Object(members) if members.iter().any(|(member, _)| *member == *name));
            if seen {
                return Err(KeysError::encoding("a duplicate member name"));
            }
            self.whitespace();
            self.expect(b':')?;
            self.whitespace();
            let value = self.value(depth)?;
            let name = std::mem::take(&mut *name);
            if let JsonValue::Object(members) = &mut *object {
                members.push((name, value));
            }
            self.whitespace();
            match self.peek() {
                Some(b',') => self.at += 1,
                Some(b'}') => {
                    self.at += 1;
                    return Ok(std::mem::replace(&mut *object, JsonValue::Null));
                }
                _ => return Err(syntax()),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<JsonValue, KeysError> {
        if depth > MAX_DEPTH {
            return Err(KeysError::encoding("JSON nested too deep"));
        }
        self.expect(b'[')?;
        let mut array = Zeroizing::new(JsonValue::Array(Vec::new()));
        self.whitespace();
        if self.peek() == Some(b']') {
            self.at += 1;
            return Ok(std::mem::replace(&mut *array, JsonValue::Null));
        }
        loop {
            self.whitespace();
            let item = self.value(depth)?;
            if let JsonValue::Array(items) = &mut *array {
                items.push(item);
            }
            self.whitespace();
            match self.peek() {
                Some(b',') => self.at += 1,
                Some(b']') => {
                    self.at += 1;
                    return Ok(std::mem::replace(&mut *array, JsonValue::Null));
                }
                _ => return Err(syntax()),
            }
        }
    }

    fn hex4(&mut self) -> Result<u32, KeysError> {
        let digits = self.text.get(self.at..self.at + 4).ok_or_else(syntax)?;
        if !digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(syntax());
        }
        self.at += 4;
        u32::from_str_radix(digits, 16).map_err(|_| syntax())
    }

    // The raw length up to the closing quote, which the decoded text never passes.
    fn raw_string_len(&self) -> usize {
        let bytes = self.text.as_bytes();
        let mut end = self.at + 1;
        while let Some(byte) = bytes.get(end) {
            match byte {
                b'\\' => end += 2,
                b'"' => break,
                _ => end += 1,
            }
        }
        end.min(bytes.len()).saturating_sub(self.at + 1)
    }

    // Built in place at its final size and wiped on failure, so a secret leaves no copy behind.
    fn string(&mut self) -> Result<String, KeysError> {
        let mut out = Zeroizing::new(String::with_capacity(self.raw_string_len()));
        self.expect(b'"')?;
        loop {
            let rest = &self.text[self.at..];
            let run = rest
                .find(|character: char| character == '"' || character == '\\' || character < '\u{20}')
                .ok_or_else(syntax)?;
            out.push_str(&rest[..run]);
            self.at += run;
            match self.peek().ok_or_else(syntax)? {
                b'"' => {
                    self.at += 1;
                    return Ok(std::mem::take(&mut *out));
                }
                b'\\' => {
                    self.at += 1;
                    let escape = self.peek().ok_or_else(syntax)?;
                    self.at += 1;
                    let character = match escape {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => self.unicode_escape()?,
                        _ => return Err(syntax()),
                    };
                    out.push(character);
                }
                // A control character must be escaped.
                _ => return Err(syntax()),
            }
        }
    }

    // A \u escape, with a UTF-16 surrogate pair as one character; a lone surrogate is refused.
    fn unicode_escape(&mut self) -> Result<char, KeysError> {
        let first = self.hex4()?;
        let code = match first {
            0xd800..=0xdbff => {
                if !self.text[self.at..].starts_with("\\u") {
                    return Err(syntax());
                }
                self.at += 2;
                let second = self.hex4()?;
                if !(0xdc00..=0xdfff).contains(&second) {
                    return Err(syntax());
                }
                0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
            }
            0xdc00..=0xdfff => return Err(syntax()),
            _ => first,
        };
        char::from_u32(code).ok_or_else(syntax)
    }

    // -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?
    fn number(&mut self) -> Result<JsonNumber, KeysError> {
        let start = self.at;
        let digits = |reader: &mut Self| {
            let begin = reader.at;
            while matches!(reader.peek(), Some(b'0'..=b'9')) {
                reader.at += 1;
            }
            reader.at > begin
        };
        if self.peek() == Some(b'-') {
            self.at += 1;
        }
        if self.peek() == Some(b'0') {
            self.at += 1;
        } else if !digits(self) {
            return Err(syntax());
        }
        if self.peek() == Some(b'.') {
            self.at += 1;
            if !digits(self) {
                return Err(syntax());
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.at += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.at += 1;
            }
            if !digits(self) {
                return Err(syntax());
            }
        }
        Ok(JsonNumber(self.text[start..self.at].to_owned()))
    }
}

impl JsonValue {
    // Equal as JSON values: the same members in any order, equal strings, and numbers equal in value.
    pub fn same_as(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Null, Self::Null) => true,
            (Self::Bool(a), Self::Bool(b)) => a == b,
            (Self::Number(a), Self::Number(b)) => a.same_as(b),
            (Self::String(a), Self::String(b)) => a == b,
            (Self::Array(a), Self::Array(b)) => a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x.same_as(y)),
            (Self::Object(a), Self::Object(b)) => {
                a.len() == b.len()
                    && a.iter().all(|(name, value)| {
                        b.iter()
                            .find(|(other, _)| other == name)
                            .is_some_and(|(_, other)| value.same_as(other))
                    })
            }
            _ => false,
        }
    }

    pub fn to_json(&self) -> String {
        let mut out = String::with_capacity(self.encoded_len());
        self.write(&mut out);
        out
    }

    // The length `to_json` writes, so a buffer for a secret can be made at its final size.
    pub fn encoded_len(&self) -> usize {
        let mut count = Count::default();
        self.write(&mut count);
        count.0
    }

    pub(crate) fn write(&self, out: &mut impl Sink) {
        match self {
            Self::Null => out.push_str("null"),
            Self::Bool(value) => out.push_str(if *value { "true" } else { "false" }),
            Self::Number(value) => out.push_str(value.as_str()),
            Self::String(value) => push_string(out, value),
            Self::Array(items) => {
                out.push('[');
                for (index, item) in items.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    item.write(out);
                }
                out.push(']');
            }
            Self::Object(members) => {
                out.push('{');
                for (index, (name, value)) in members.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    push_string(out, name);
                    out.push(':');
                    value.write(out);
                }
                out.push('}');
            }
        }
    }

    pub fn is_object(&self) -> bool {
        matches!(self, Self::Object(_))
    }

    // Moves a member out of an object, leaving null in its place.
    pub(crate) fn take_member(&mut self, name: &str) -> Option<Self> {
        let Self::Object(members) = self else {
            return None;
        };
        members
            .iter_mut()
            .find(|(member, _)| member == name)
            .map(|(_, value)| std::mem::replace(value, Self::Null))
    }

    // Moves a string member out of an object, leaving an empty string in its place.
    pub(crate) fn take_string(&mut self, name: &str) -> Option<String> {
        let Self::Object(members) = self else {
            return None;
        };
        match members.iter_mut().find(|(member, _)| member == name) {
            Some((_, Self::String(text))) => Some(std::mem::take(text)),
            _ => None,
        }
    }
}

impl Zeroize for JsonValue {
    fn zeroize(&mut self) {
        match self {
            Self::String(text) => text.zeroize(),
            Self::Number(number) => number.0.zeroize(),
            Self::Array(items) => items.iter_mut().for_each(Zeroize::zeroize),
            Self::Object(members) => members.iter_mut().for_each(|(name, value)| {
                name.zeroize();
                value.zeroize();
            }),
            Self::Null | Self::Bool(_) => {}
        }
    }
}

pub(crate) fn string_len(value: &str) -> usize {
    let mut count = Count::default();
    push_string(&mut count, value);
    count.0
}

pub(crate) trait Sink {
    fn push(&mut self, character: char);
    fn push_str(&mut self, text: &str);
}

impl Sink for String {
    fn push(&mut self, character: char) {
        String::push(self, character);
    }

    fn push_str(&mut self, text: &str) {
        String::push_str(self, text);
    }
}

// Counts what a writer would write, so the real buffer is sized once and never moves.
#[derive(Default)]
pub(crate) struct Count(pub(crate) usize);

impl Sink for Count {
    fn push(&mut self, character: char) {
        self.0 += character.len_utf8();
    }

    fn push_str(&mut self, text: &str) {
        self.0 += text.len();
    }
}

// A JSON string with the escapes RFC 8259 requires: the quote, the backslash and control characters.
pub(crate) fn push_string(out: &mut impl Sink, value: &str) {
    out.push('"');
    for character in value.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            control if control < '\u{20}' => {
                const HEX: &[u8; 16] = b"0123456789abcdef";
                let code = u32::from(control);
                out.push_str("\\u00");
                out.push(char::from(HEX[(code >> 4) as usize & 0xf]));
                out.push(char::from(HEX[code as usize & 0xf]));
            }
            other => out.push(other),
        }
    }
    out.push('"');
}

// Reads an object's members by name, refusing a wrongly typed one, and at the end refuses or
// ignores the members nobody read.
pub(crate) struct Members<'a> {
    members: &'a [(String, JsonValue)],
    read: Vec<bool>,
}

impl<'a> Members<'a> {
    pub(crate) fn of(value: &'a JsonValue) -> Result<Self, KeysError> {
        match value {
            JsonValue::Object(members) => Ok(Self {
                members,
                read: vec![false; members.len()],
            }),
            _ => Err(KeysError::encoding("not a JSON object")),
        }
    }

    pub(crate) fn optional(&mut self, name: &str) -> Option<&'a JsonValue> {
        let index = self.members.iter().position(|(member, _)| member == name)?;
        self.read[index] = true;
        self.members.get(index).map(|(_, value)| value)
    }

    pub(crate) fn required(&mut self, name: &str) -> Result<&'a JsonValue, KeysError> {
        self.optional(name).ok_or(KeysError::encoding("a member is missing"))
    }

    pub(crate) fn string(&mut self, name: &str) -> Result<&'a str, KeysError> {
        as_str(self.required(name)?)
    }

    pub(crate) fn integer(&mut self, name: &str) -> Result<i64, KeysError> {
        as_integer(self.required(name)?)
    }

    pub(crate) fn version(&mut self, name: &str) -> Result<Version, KeysError> {
        Version::from_i64(self.integer(name)?)
    }

    pub(crate) fn boolean(&mut self, name: &str) -> Result<bool, KeysError> {
        match self.required(name)? {
            JsonValue::Bool(value) => Ok(*value),
            _ => Err(KeysError::encoding("a member is not a boolean")),
        }
    }

    pub(crate) fn array(&mut self, name: &str) -> Result<&'a [JsonValue], KeysError> {
        match self.required(name)? {
            JsonValue::Array(items) => Ok(items),
            _ => Err(KeysError::encoding("a member is not an array")),
        }
    }

    pub(crate) fn object(&mut self, name: &str) -> Result<&'a JsonValue, KeysError> {
        let value = self.required(name)?;
        if value.is_object() {
            Ok(value)
        } else {
            Err(KeysError::encoding("a member is not an object"))
        }
    }

    // Key object bodies refuse an unknown member.
    pub(crate) fn finish_strict(self) -> Result<(), KeysError> {
        if self.read.iter().all(|read| *read) {
            Ok(())
        } else {
            Err(KeysError::encoding("an unknown member"))
        }
    }
}

pub(crate) fn as_str(value: &JsonValue) -> Result<&str, KeysError> {
    match value {
        JsonValue::String(text) => Ok(text),
        _ => Err(KeysError::encoding("a member is not a string")),
    }
}

// A JSON integer with no fraction or exponent.
pub(crate) fn as_integer(value: &JsonValue) -> Result<i64, KeysError> {
    match value {
        JsonValue::Number(number) => number
            .as_i64()
            .ok_or(KeysError::encoding("a member is not an integer in range")),
        _ => Err(KeysError::encoding("a member is not an integer")),
    }
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::{JsonValue, as_integer, parse};

    #[test]
    fn duplicate_names_are_refused_at_any_depth() {
        assert!(parse(br#"{"a":1,"a":1}"#).is_err());
        assert!(parse(br#"{"a":{"b":1,"b":2}}"#).is_err());
        assert!(parse(br#"[{"x":1,"x":1}]"#).is_err());
        assert!(parse(br#"{"a":1,"b":{"a":1}}"#).is_ok());
        assert!(
            parse(br#"{"\u0061":1,"a":2}"#).is_err(),
            "a name compared after its escapes"
        );
    }

    #[test]
    fn integers_have_no_fraction_or_exponent() {
        assert_eq!(as_integer(&parse(b"7").unwrap()).unwrap(), 7);
        assert_eq!(as_integer(&parse(b"-7").unwrap()).unwrap(), -7);
        assert!(as_integer(&parse(b"7.0").unwrap()).is_err());
        assert!(as_integer(&parse(b"7e0").unwrap()).is_err());
        assert!(as_integer(&parse(b"18446744073709551615").unwrap()).is_err());
        assert!(as_integer(&parse(br#""7""#).unwrap()).is_err());
    }

    #[test]
    fn equality_ignores_member_order_and_number_form() {
        let a = parse(br#"{"host":"db","port":5432,"hops":[{"h":"a"}]}"#).unwrap();
        let b = parse(br#"{"hops":[{"h":"a"}],"port":5432.0,"host":"db"}"#).unwrap();
        let c = parse(br#"{"host":"db","port":5433,"hops":[{"h":"a"}]}"#).unwrap();
        assert!(a.same_as(&b));
        assert!(!a.same_as(&c));
        assert!(!a.same_as(&JsonValue::Null));
        for (x, y) in [
            ("1", "1.0"),
            ("1e2", "100"),
            ("-0", "0"),
            ("0.10", "1e-1"),
            ("26626666666626666662", "2.6626666666626666662e19"),
        ] {
            assert!(
                parse(x.as_bytes()).unwrap().same_as(&parse(y.as_bytes()).unwrap()),
                "{x} {y}"
            );
        }
        assert!(!parse(b"1").unwrap().same_as(&parse(b"-1").unwrap()));
        assert!(!parse(b"0.1").unwrap().same_as(&parse(b"0.10000000000000001").unwrap()));
    }

    #[test]
    fn writing_keeps_member_order_and_number_text() {
        let text = r#"{"z":1,"a":[true,null,"\"q\"\u0001\u001f\n"],"m":{},"n":2.6626666666626666662e19}"#;
        let value = parse(text.as_bytes()).unwrap();
        assert_eq!(value.to_json(), text);
        assert_eq!(value.encoded_len(), text.len());
    }

    #[test]
    fn invalid_text_is_refused() {
        for bad in [
            &br#""\ud800""#[..],
            br#""\udc00\ud800""#,
            b"\xff",
            b"{} x",
            b"01",
            b"1.",
            b".1",
            b"1e",
            b"+1",
            b"[1,]",
            b"{\"a\":1,}",
            b"\"a\x01\"",
            b"tru",
            b"",
            b"\"\\x\"",
        ] {
            assert!(parse(bad).is_err(), "{}", String::from_utf8_lossy(bad));
        }
        let deep = "[".repeat(200) + &"]".repeat(200);
        assert!(parse(deep.as_bytes()).is_err());
        let fine = "[".repeat(128) + &"]".repeat(128);
        assert!(parse(fine.as_bytes()).is_ok());
        let long = format!("\"{}\"", "a".repeat(super::MAX_JSON_LEN));
        assert!(parse(long.as_bytes()).is_err(), "past a page");
    }

    proptest! {
        // The same text serde_json accepts, apart from duplicate names, which only this reader refuses.
        #[test]
        fn accepts_what_serde_json_accepts(text in r#"[ \[\]{}",:0-9eE.+\-tfnrulsaxb\\]{0,24}"#) {
            let ours = parse(text.as_bytes()).is_ok();
            let theirs = serde_json::from_str::<serde::de::IgnoredAny>(&text).is_ok();
            if ours {
                prop_assert!(theirs, "{}", text);
            } else if theirs {
                prop_assert!(text.contains(':'), "{}", text);
            }
        }

        #[test]
        fn written_values_read_back(text in r#"[ \[\]{}",:0-9eE.\-tfnul]{0,32}"#) {
            if let Ok(value) = parse(text.as_bytes()) {
                let written = value.to_json();
                let again = parse(written.as_bytes()).unwrap();
                prop_assert!(again.same_as(&value));
                prop_assert_eq!(again.to_json(), written);
            }
        }
    }
}
