use super::config_edit::{ConfigEditError, Upsert};
use super::json_value::{JsonValue, quote};

// Deeper than any config file nests; a file past it is refused rather
// than parsed on an ever deeper stack.
const MAX_DEPTH: usize = 256;

const DEFAULT_INDENT: &str = "  ";

const REPLACEMENT: u32 = 0xFFFD;

// Edits splice the text, so comments, key order, indentation and every
// byte outside the edited member stay as the user wrote them.
pub(crate) fn member(text: &str, key_path: &[String], name: &str) -> Result<Option<JsonValue>, ConfigEditError> {
    let document = Document::parse(text)?;
    match document.walk(key_path)? {
        Walk::Found(object) => Ok(find(object, name, key_path)?.map(|member| member.value.to_value())),
        Walk::Missing { .. } | Walk::NoRoot => Ok(None),
    }
}

pub(crate) fn upserting(
    text: &str,
    key_path: &[String],
    name: &str,
    value: &JsonValue,
    mode: Upsert,
) -> Result<String, ConfigEditError> {
    let document = Document::parse(text)?;
    let edits = match document.walk(key_path)? {
        Walk::NoRoot => return Ok(document.new_root(&nest(key_path, name, value))),
        Walk::Found(object) => match find(object, name, key_path)? {
            Some(member) if mode == Upsert::Replace => vec![document.replace_value(object, member, value)],
            Some(member) => {
                let mut path = key_path.to_vec();
                path.push(name.to_owned());
                let mut edits = Vec::new();
                document.update(object, member, value, &path, false, &mut edits)?;
                edits
            }
            None => document.insert_members(object, &[(name.to_owned(), value.clone())]),
        },
        Walk::Missing { deepest, depth } => {
            let wrapped = nest(&key_path[depth + 1..], name, value);
            document.insert_members(deepest, &[(key_path[depth].clone(), wrapped)])
        }
    };
    Ok(splice(text, edits))
}

pub(crate) fn removing(text: &str, key_path: &[String], name: &str) -> Result<String, ConfigEditError> {
    let document = Document::parse(text)?;
    let Walk::Found(object) = document.walk(key_path)? else {
        return Ok(text.to_owned());
    };
    if find(object, name, key_path)?.is_none() {
        return Ok(text.to_owned());
    }
    let index = object
        .members
        .iter()
        .position(|member| member.key == name)
        .unwrap_or_default();
    document.remove_member(object, index)
}

// `*` in the scope stands for any key at that level.
pub(crate) fn members_in_scope(text: &str, scope: &[String], name: &str) -> Result<Vec<JsonValue>, ConfigEditError> {
    let document = Document::parse(text)?;
    let mut found = Vec::new();
    if let Some(root) = document.root_object()? {
        collect_in_scope(root, scope, name, &mut found);
    }
    Ok(found)
}

fn collect_in_scope(object: &ObjectNode, scope: &[String], name: &str, found: &mut Vec<JsonValue>) {
    let Some((first, rest)) = scope.split_first() else {
        found.extend(
            object
                .members
                .iter()
                .filter(|member| member.key == name)
                .map(|member| member.value.to_value()),
        );
        return;
    };
    for member in object
        .members
        .iter()
        .filter(|member| first == "*" || member.key == *first)
    {
        if let Node::Object(inner) = &member.value {
            collect_in_scope(inner, rest, name, found);
        }
    }
}

fn nest(keys: &[String], name: &str, value: &JsonValue) -> JsonValue {
    let inner = JsonValue::Object(vec![(name.to_owned(), value.clone())]);
    keys.iter()
        .rev()
        .fold(inner, |value, key| JsonValue::Object(vec![(key.clone(), value)]))
}

fn find<'n>(object: &'n ObjectNode, key: &str, path: &[String]) -> Result<Option<&'n Member>, ConfigEditError> {
    let mut found = object.members.iter().filter(|member| member.key == key);
    let first = found.next();
    if first.is_some() && found.next().is_some() {
        let mut path = path.to_vec();
        path.push(key.to_owned());
        return Err(ConfigEditError::DuplicateKey { path });
    }
    Ok(first)
}

enum Node {
    Object(ObjectNode),
    Array(ArrayNode),
    Scalar(ScalarNode),
}

struct ObjectNode {
    open: usize,
    close: usize,
    members: Vec<Member>,
}

struct Member {
    key: String,
    key_start: usize,
    value: Node,
    comma: Option<usize>,
}

struct ArrayNode {
    open: usize,
    close: usize,
    items: Vec<Node>,
}

struct ScalarNode {
    start: usize,
    end: usize,
    value: JsonValue,
}

impl Node {
    fn start(&self) -> usize {
        match self {
            Self::Object(object) => object.open,
            Self::Array(array) => array.open,
            Self::Scalar(scalar) => scalar.start,
        }
    }

    fn end(&self) -> usize {
        match self {
            Self::Object(object) => object.close + 1,
            Self::Array(array) => array.close + 1,
            Self::Scalar(scalar) => scalar.end,
        }
    }

    fn to_value(&self) -> JsonValue {
        match self {
            Self::Object(object) => JsonValue::Object(
                object
                    .members
                    .iter()
                    .map(|member| (member.key.clone(), member.value.to_value()))
                    .collect(),
            ),
            Self::Array(array) => JsonValue::Array(array.items.iter().map(Node::to_value).collect()),
            Self::Scalar(scalar) => scalar.value.clone(),
        }
    }
}

enum Walk<'n> {
    NoRoot,
    Found(&'n ObjectNode),
    // The keys from `depth` on are missing below `deepest`.
    Missing { deepest: &'n ObjectNode, depth: usize },
}

struct Document<'a> {
    text: &'a str,
    root: Option<Node>,
}

impl<'a> Document<'a> {
    fn parse(text: &'a str) -> Result<Self, ConfigEditError> {
        let mut parser = Parser {
            text,
            bytes: text.as_bytes(),
            pos: if text.starts_with('\u{feff}') { 3 } else { 0 },
        };
        parser.skip_trivia()?;
        if parser.pos == text.len() {
            return Ok(Self { text, root: None });
        }
        let root = parser.value(0)?;
        parser.skip_trivia()?;
        if parser.pos != text.len() {
            return Err(parser.error());
        }
        Ok(Self { text, root: Some(root) })
    }

    fn root_object(&self) -> Result<Option<&ObjectNode>, ConfigEditError> {
        match &self.root {
            None => Ok(None),
            Some(Node::Object(object)) => Ok(Some(object)),
            Some(_) => Err(ConfigEditError::NotAnObject { path: Vec::new() }),
        }
    }

    fn walk(&self, key_path: &[String]) -> Result<Walk<'_>, ConfigEditError> {
        let Some(mut object) = self.root_object()? else {
            return Ok(Walk::NoRoot);
        };
        for (depth, key) in key_path.iter().enumerate() {
            match find(object, key, &key_path[..depth])? {
                None => return Ok(Walk::Missing { deepest: object, depth }),
                Some(member) => match &member.value {
                    Node::Object(inner) => object = inner,
                    _ => {
                        return Err(ConfigEditError::NotAnObject {
                            path: key_path[..=depth].to_vec(),
                        });
                    }
                },
            }
        }
        Ok(Walk::Found(object))
    }

    fn new_root(&self, whole: &JsonValue) -> String {
        let kept = self.text.trim_end();
        let separator = if kept.trim_start_matches('\u{feff}').is_empty() {
            ""
        } else {
            "\n"
        };
        format!("{kept}{separator}{}\n", whole.to_pretty(DEFAULT_INDENT, ""))
    }

    // Rewrites only the members given, so the user's other members and
    // their comments stay. Below the top of the entry, as in a header
    // map, a key matches ignoring case.
    fn update(
        &self,
        parent: &ObjectNode,
        member: &Member,
        value: &JsonValue,
        path: &[String],
        nested: bool,
        edits: &mut Vec<Edit>,
    ) -> Result<(), ConfigEditError> {
        let (Node::Object(existing), JsonValue::Object(wanted)) = (&member.value, value) else {
            edits.push(self.replace_value(parent, member, value));
            return Ok(());
        };
        let mut missing = Vec::new();
        for (key, wanted) in wanted {
            let found = match find(existing, key, path)? {
                Some(found) => Some(found),
                None if nested => existing
                    .members
                    .iter()
                    .find(|candidate| candidate.key.eq_ignore_ascii_case(key)),
                None => None,
            };
            match found {
                Some(found) => {
                    let mut inner = path.to_vec();
                    inner.push(found.key.clone());
                    self.update(existing, found, wanted, &inner, true, edits)?;
                }
                None => missing.push((key.clone(), wanted.clone())),
            }
        }
        if !missing.is_empty() {
            edits.extend(self.insert_members(existing, &missing));
        }
        Ok(())
    }

    fn replace_value(&self, parent: &ObjectNode, member: &Member, value: &JsonValue) -> Edit {
        let rendered = match is_single_line(self.text, parent) {
            true => value.to_compact(),
            false => value.to_pretty(&self.indent_unit(), line_indent(self.text, member.key_start)),
        };
        (member.value.start(), member.value.end(), rendered)
    }

    fn insert_members(&self, object: &ObjectNode, members: &[(String, JsonValue)]) -> Vec<Edit> {
        let text = self.text;
        let unit = self.indent_unit();
        let open_indent = line_indent(text, object.open);
        let pretty = |indent: &str| {
            members
                .iter()
                .map(|(name, value)| format!("{}: {}", quote(name), value.to_pretty(&unit, indent)))
                .collect::<Vec<_>>()
                .join(&format!(",\n{indent}"))
        };
        let Some(last) = object.members.last() else {
            let indent = format!("{open_indent}{unit}");
            let rendered = pretty(&indent);
            if text[object.open + 1..object.close].trim().is_empty() {
                let filled = format!("\n{indent}{rendered}\n{open_indent}");
                return vec![(object.open + 1, object.close, filled)];
            }
            if starts_line(text, object.close) {
                let at = line_start(text, object.close);
                return vec![(at, at, format!("{indent}{rendered}\n"))];
            }
            let filled = format!("\n{indent}{rendered}\n{open_indent}");
            return vec![(object.close, object.close, filled)];
        };
        if is_single_line(text, object) {
            let rendered = members
                .iter()
                .map(|(name, value)| format!("{}: {}", quote(name), value.to_compact()))
                .collect::<Vec<_>>()
                .join(", ");
            return match last.comma {
                Some(comma) => vec![(comma + 1, comma + 1, format!(" {rendered},"))],
                None => vec![(last.value.end(), last.value.end(), format!(", {rendered}"))],
            };
        }
        let indent = match starts_line(text, last.key_start) {
            true => line_indent(text, last.key_start).to_owned(),
            false => format!("{open_indent}{unit}"),
        };
        let rendered = pretty(&indent);
        let mut edits = Vec::new();
        let anchor = match last.comma {
            Some(comma) => comma + 1,
            None => {
                edits.push((last.value.end(), last.value.end(), ",".to_owned()));
                last.value.end()
            }
        };
        // A comment after the last member stays with it.
        let end_of_line = line_end(text, anchor);
        let at = match object.close >= end_of_line && only_trivia(&text[anchor..end_of_line]) {
            true => end_of_line,
            false => anchor,
        };
        let trailing = if last.comma.is_some() { "," } else { "" };
        edits.push((at, at, format!("\n{indent}{rendered}{trailing}")));
        edits
    }

    fn remove_member(&self, object: &ObjectNode, index: usize) -> Result<String, ConfigEditError> {
        let text = self.text;
        let member = &object.members[index];
        if object.members.len() == 1 && !text[object.open..object.close].contains('\n') {
            return Ok(splice(text, vec![(object.open + 1, object.close, String::new())]));
        }
        let last_without_comma = index + 1 == object.members.len() && member.comma.is_none();
        if last_without_comma && index > 0 {
            let comma = object.members[index - 1].comma.ok_or(ConfigEditError::InvalidSyntax {
                offset: Some(member.key_start),
            })?;
            if text[comma + 1..member.key_start].trim().is_empty() {
                return Ok(splice(text, vec![(comma, member.value.end(), String::new())]));
            }
            let (start, end) = self.member_span(object, member);
            return Ok(splice(
                text,
                vec![(comma, comma + 1, String::new()), (start, end, String::new())],
            ));
        }
        let (start, end) = self.member_span(object, member);
        Ok(splice(text, vec![(start, end, String::new())]))
    }

    fn member_span(&self, object: &ObjectNode, member: &Member) -> (usize, usize) {
        let text = self.text;
        let after = member.comma.map_or(member.value.end(), |comma| comma + 1);
        if starts_line(text, member.key_start) {
            let end_of_line = line_end(text, after);
            if text[after..end_of_line].trim().is_empty() && object.close > end_of_line {
                return (line_start(text, member.key_start), end_of_line + 1);
            }
            return (line_start(text, member.key_start), after);
        }
        let mut end = after;
        if member.comma.is_some() {
            while matches!(text.as_bytes().get(end), Some(b' ' | b'\t')) {
                end += 1;
            }
        }
        (member.key_start, end)
    }

    // The step one level of nesting adds, read from the first object that
    // puts a member on a line below its brace.
    fn indent_unit(&self) -> String {
        self.root
            .as_ref()
            .and_then(|root| indent_in(self.text, root))
            .unwrap_or_else(|| DEFAULT_INDENT.to_owned())
    }
}

fn indent_in(text: &str, node: &Node) -> Option<String> {
    match node {
        Node::Object(object) => {
            let brace = line_indent(text, object.open);
            for member in &object.members {
                if starts_line(text, member.key_start) && line_start(text, member.key_start) > object.open {
                    let indent = line_indent(text, member.key_start);
                    if let Some(step) = indent.strip_prefix(brace)
                        && !step.is_empty()
                    {
                        return Some(step.to_owned());
                    }
                }
            }
            object.members.iter().find_map(|member| indent_in(text, &member.value))
        }
        Node::Array(array) => array.items.iter().find_map(|item| indent_in(text, item)),
        Node::Scalar(_) => None,
    }
}

fn is_single_line(text: &str, object: &ObjectNode) -> bool {
    !text[object.open..object.close].contains('\n')
}

fn line_start(text: &str, pos: usize) -> usize {
    text[..pos].rfind('\n').map_or(0, |newline| newline + 1)
}

fn line_end(text: &str, pos: usize) -> usize {
    text[pos..].find('\n').map_or(text.len(), |newline| pos + newline)
}

fn line_indent(text: &str, pos: usize) -> &str {
    let line = &text[line_start(text, pos)..];
    let content = line.trim_start_matches([' ', '\t']);
    &line[..line.len() - content.len()]
}

fn starts_line(text: &str, pos: usize) -> bool {
    text[line_start(text, pos)..pos].trim_matches([' ', '\t']).is_empty()
}

fn only_trivia(mut segment: &str) -> bool {
    loop {
        segment = segment.trim_start();
        if segment.is_empty() || segment.starts_with("//") {
            return true;
        }
        let Some(comment) = segment.strip_prefix("/*") else {
            return false;
        };
        let Some(close) = comment.find("*/") else {
            return false;
        };
        segment = &comment[close + 2..];
    }
}

// A byte range and the text that takes its place.
type Edit = (usize, usize, String);

// Edits do not overlap; two at one point go in the order given.
fn splice(text: &str, mut edits: Vec<Edit>) -> String {
    edits.sort_by_key(|(start, _, _)| *start);
    let mut out = String::with_capacity(text.len() + edits.iter().map(|edit| edit.2.len()).sum::<usize>());
    let mut cursor = 0;
    for (start, end, replacement) in edits {
        out.push_str(text.get(cursor..start).unwrap_or_default());
        out.push_str(&replacement);
        cursor = cursor.max(end);
    }
    out.push_str(text.get(cursor..).unwrap_or_default());
    out
}

struct Parser<'a> {
    text: &'a str,
    bytes: &'a [u8],
    pos: usize,
}

impl Parser<'_> {
    fn error(&self) -> ConfigEditError {
        ConfigEditError::InvalidSyntax { offset: Some(self.pos) }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn skip_trivia(&mut self) -> Result<(), ConfigEditError> {
        loop {
            match self.peek() {
                Some(b' ' | b'\t' | b'\n' | b'\r') => self.pos += 1,
                Some(b'/') => match self.bytes.get(self.pos + 1) {
                    Some(b'/') => self.pos = line_end(self.text, self.pos),
                    Some(b'*') => {
                        let close = self.text[self.pos + 2..].find("*/").ok_or_else(|| self.error())?;
                        self.pos += close + 4;
                    }
                    _ => return Err(self.error()),
                },
                _ => return Ok(()),
            }
        }
    }

    fn value(&mut self, depth: usize) -> Result<Node, ConfigEditError> {
        if depth > MAX_DEPTH {
            return Err(self.error());
        }
        let start = self.pos;
        let scalar = |value: JsonValue, end: usize| Node::Scalar(ScalarNode { start, end, value });
        match self.peek() {
            Some(b'{') => self.object(depth),
            Some(b'[') => self.array(depth),
            Some(b'"') => {
                let text = self.string()?;
                Ok(scalar(JsonValue::String(text), self.pos))
            }
            Some(b't') => self.literal("true").map(|end| scalar(JsonValue::Bool(true), end)),
            Some(b'f') => self.literal("false").map(|end| scalar(JsonValue::Bool(false), end)),
            Some(b'n') => self.literal("null").map(|end| scalar(JsonValue::Null, end)),
            Some(b'-' | b'0'..=b'9') => {
                while matches!(self.peek(), Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')) {
                    self.pos += 1;
                }
                let number = self.text[start..self.pos]
                    .parse::<serde_json::Number>()
                    .map_err(|_| ConfigEditError::InvalidSyntax { offset: Some(start) })?;
                Ok(scalar(JsonValue::Number(number), self.pos))
            }
            _ => Err(self.error()),
        }
    }

    fn literal(&mut self, word: &str) -> Result<usize, ConfigEditError> {
        if !self.text[self.pos..].starts_with(word) {
            return Err(self.error());
        }
        self.pos += word.len();
        Ok(self.pos)
    }

    fn object(&mut self, depth: usize) -> Result<Node, ConfigEditError> {
        let open = self.pos;
        self.pos += 1;
        let mut members = Vec::new();
        loop {
            self.skip_trivia()?;
            match self.peek() {
                Some(b'}') => {
                    let close = self.pos;
                    self.pos += 1;
                    return Ok(Node::Object(ObjectNode { open, close, members }));
                }
                Some(b'"') => {}
                _ => return Err(self.error()),
            }
            let key_start = self.pos;
            let key = self.string()?;
            self.skip_trivia()?;
            if self.peek() != Some(b':') {
                return Err(self.error());
            }
            self.pos += 1;
            self.skip_trivia()?;
            let value = self.value(depth + 1)?;
            let comma = self.separator(b'}')?;
            members.push(Member {
                key,
                key_start,
                value,
                comma,
            });
        }
    }

    fn array(&mut self, depth: usize) -> Result<Node, ConfigEditError> {
        let open = self.pos;
        self.pos += 1;
        let mut items = Vec::new();
        loop {
            self.skip_trivia()?;
            if self.peek() == Some(b']') {
                let close = self.pos;
                self.pos += 1;
                return Ok(Node::Array(ArrayNode { open, close, items }));
            }
            items.push(self.value(depth + 1)?);
            self.separator(b']')?;
        }
    }

    // After a value: a comma, kept where it is, or the closing bracket,
    // left for the caller. JSONC allows a comma before the bracket.
    fn separator(&mut self, close: u8) -> Result<Option<usize>, ConfigEditError> {
        self.skip_trivia()?;
        match self.peek() {
            Some(b',') => {
                self.pos += 1;
                Ok(Some(self.pos - 1))
            }
            Some(found) if found == close => Ok(None),
            _ => Err(self.error()),
        }
    }

    fn string(&mut self) -> Result<String, ConfigEditError> {
        self.pos += 1;
        let mut out = String::new();
        loop {
            let rest = &self.text[self.pos..];
            let stop = rest
                .find(|character: char| character == '"' || character == '\\' || character < ' ')
                .ok_or_else(|| self.error())?;
            out.push_str(&rest[..stop]);
            self.pos += stop;
            match self.peek() {
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.pos += 1;
                    self.escape(&mut out)?;
                }
                _ => return Err(self.error()),
            }
        }
    }

    fn escape(&mut self, out: &mut String) -> Result<(), ConfigEditError> {
        let code = self.peek().ok_or_else(|| self.error())?;
        self.pos += 1;
        match code {
            b'"' => out.push('"'),
            b'\\' => out.push('\\'),
            b'/' => out.push('/'),
            b'b' => out.push('\u{8}'),
            b'f' => out.push('\u{c}'),
            b'n' => out.push('\n'),
            b'r' => out.push('\r'),
            b't' => out.push('\t'),
            b'u' => {
                let first = self.hex4()?;
                let scalar = match first {
                    0xD800..=0xDBFF => self.low_surrogate().map_or(REPLACEMENT, |second| {
                        0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    }),
                    0xDC00..=0xDFFF => REPLACEMENT,
                    other => other,
                };
                out.push(char::from_u32(scalar).unwrap_or(char::REPLACEMENT_CHARACTER));
            }
            _ => return Err(self.error()),
        }
        Ok(())
    }

    // The second half of a surrogate pair, taken only when it is one. A
    // lone half reads as U+FFFD, so one odd string in a file the user owns
    // does not make the rest of it unreadable; edits never write it back.
    fn low_surrogate(&mut self) -> Option<u32> {
        if self.bytes.get(self.pos..self.pos + 2) != Some(b"\\u") {
            return None;
        }
        let digits = self.text.get(self.pos + 2..self.pos + 6)?;
        if !digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return None;
        }
        let value = u32::from_str_radix(digits, 16).ok()?;
        if !(0xDC00..=0xDFFF).contains(&value) {
            return None;
        }
        self.pos += 6;
        Some(value)
    }

    fn hex4(&mut self) -> Result<u32, ConfigEditError> {
        let digits = self.text.get(self.pos..self.pos + 4).ok_or_else(|| self.error())?;
        if !digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(self.error());
        }
        let value = u32::from_str_radix(digits, 16).map_err(|_| self.error())?;
        self.pos += 4;
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn path(keys: &[&str]) -> Vec<String> {
        keys.iter().map(|key| (*key).to_owned()).collect()
    }

    fn entry() -> JsonValue {
        JsonValue::Object(vec![
            (
                "url".to_owned(),
                JsonValue::String("http://127.0.0.1:23508/mcp".to_owned()),
            ),
            (
                "headers".to_owned(),
                JsonValue::Object(vec![(
                    "Authorization".to_owned(),
                    JsonValue::String("Bearer tp_x".to_owned()),
                )]),
            ),
        ])
    }

    fn upsert(text: &str, keys: &[&str]) -> String {
        upserting(text, &path(keys), "tablepro", &entry(), Upsert::Merge).expect("an edit")
    }

    #[test]
    fn an_empty_file_becomes_the_whole_document() {
        let edited = upsert("", &["mcpServers"]);

        assert_eq!(
            edited,
            "{\n  \"mcpServers\": {\n    \"tablepro\": {\n      \"url\": \"http://127.0.0.1:23508/mcp\",\n      \
\"headers\": {\n        \"Authorization\": \"Bearer tp_x\"\n      }\n    }\n  }\n}\n"
        );
        assert_eq!(upsert("  \n", &["mcpServers"]), edited);
    }

    #[test]
    fn a_new_server_goes_after_the_others_and_keeps_comments_and_order() {
        let text = "// Zed settings\n{\n\t\"theme\": \"One Dark\", // the theme\n\t\"context_servers\": {\n\t\t\
\"other\": { \"url\": \"x\" } // keep me\n\t},\n\t/* tail */\n\t\"vim_mode\": true\n}\n";

        let edited = upsert(text, &["context_servers"]);

        assert_eq!(
            edited,
            "// Zed settings\n{\n\t\"theme\": \"One Dark\", // the theme\n\t\"context_servers\": {\n\t\t\
\"other\": { \"url\": \"x\" }, // keep me\n\t\t\"tablepro\": {\n\t\t\t\"url\": \"http://127.0.0.1:23508/mcp\",\n\t\t\t\
\"headers\": {\n\t\t\t\t\"Authorization\": \"Bearer tp_x\"\n\t\t\t}\n\t\t}\n\t},\n\t/* tail */\n\t\"vim_mode\": true\n}\n"
        );
        assert_eq!(
            member(&edited, &path(&["context_servers"]), "tablepro").expect("readable"),
            Some(entry())
        );
        assert!(
            member(&edited, &path(&["context_servers"]), "other")
                .expect("readable")
                .is_some()
        );
    }

    #[test]
    fn a_trailing_comma_style_is_kept() {
        let text = "{\n  \"servers\": {\n    \"a\": {},\n  },\n}\n";

        let edited = upsert(text, &["servers"]);

        assert!(edited.contains("    \"a\": {},\n    \"tablepro\": {\n"), "{edited}");
        assert!(edited.ends_with("      }\n    },\n  },\n}\n"), "{edited}");
        assert!(
            member(&edited, &path(&["servers"]), "tablepro")
                .expect("readable")
                .is_some()
        );
    }

    #[test]
    fn missing_objects_on_the_key_path_are_created() {
        let text = "{\n    \"$schema\": \"https://opencode.ai/config.json\"\n}\n";

        let edited = upsert(text, &["mcp", "servers"]);

        assert!(
            edited.starts_with(
                "{\n    \"$schema\": \"https://opencode.ai/config.json\",\n    \"mcp\": {\n        \"servers\": {\n"
            ),
            "{edited}"
        );
        assert_eq!(
            member(&edited, &path(&["mcp", "servers"]), "tablepro").expect("readable"),
            Some(entry())
        );
    }

    #[test]
    fn an_existing_entry_keeps_its_place_and_gets_what_it_lacks() {
        let text = "{\n  \"mcpServers\": {\n    \"tablepro\": { \"url\": \"old\" },\n    \"next\": {}\n  }\n}";

        let edited = upsert(text, &["mcpServers"]);

        assert_eq!(
            edited,
            "{\n  \"mcpServers\": {\n    \"tablepro\": { \"url\": \"http://127.0.0.1:23508/mcp\", \
\"headers\": {\"Authorization\":\"Bearer tp_x\"} },\n    \"next\": {}\n  }\n}"
        );
        assert_eq!(
            member(&edited, &path(&["mcpServers"]), "tablepro").expect("readable"),
            Some(entry())
        );
    }

    #[test]
    fn an_update_rewrites_only_what_the_entry_renders() {
        let text = "{\n  \"mcpServers\": {\n    \"tablepro\": {\n      // my note\n      \"url\": \"http://old\",\n      \
\"timeout\": 30,\n      \"headers\": {\n        \"authorization\": \"Bearer tp_old\",\n        \"X-Team\": \"data\"\n      \
}\n    }\n  }\n}\n";

        let edited = upsert(text, &["mcpServers"]);

        assert_eq!(
            edited,
            "{\n  \"mcpServers\": {\n    \"tablepro\": {\n      // my note\n      \"url\": \"http://127.0.0.1:23508/mcp\",\n      \
\"timeout\": 30,\n      \"headers\": {\n        \"authorization\": \"Bearer tp_x\",\n        \"X-Team\": \"data\"\n      \
}\n    }\n  }\n}\n"
        );
    }

    #[test]
    fn a_key_on_top_of_the_entry_matches_only_as_spelled() {
        let edited = upsert(
            r#"{"mcpServers": {"tablepro": {"URL": "x", "headers": {"AUTHORIZATION": "y"}}}}"#,
            &["mcpServers"],
        );

        assert_eq!(
            edited,
            r#"{"mcpServers": {"tablepro": {"URL": "x", "headers": {"AUTHORIZATION": "Bearer tp_x"}, "url": "http://127.0.0.1:23508/mcp"}}}"#
        );
    }

    #[test]
    fn an_entry_that_is_not_an_object_is_replaced_whole() {
        let edited = upsert("{\"mcpServers\": {\"tablepro\": \"x\"}}", &["mcpServers"]);

        assert_eq!(
            edited,
            r#"{"mcpServers": {"tablepro": {"url":"http://127.0.0.1:23508/mcp","headers":{"Authorization":"Bearer tp_x"}}}}"#
        );
    }

    #[test]
    fn an_empty_object_gets_its_first_member() {
        assert!(upsert("{}", &["mcpServers"]).starts_with("{\n  \"mcpServers\": {\n    \"tablepro\""));
        let with_comment = upsert("{\n  \"mcpServers\": {\n    // none yet\n  }\n}", &["mcpServers"]);
        assert!(
            with_comment.contains("    // none yet\n    \"tablepro\": {\n"),
            "{with_comment}"
        );
    }

    #[test]
    fn a_one_line_object_stays_on_one_line() {
        let edited = upsert(r#"{"mcpServers": {"a": {"url": "y"}}}"#, &["mcpServers"]);

        assert_eq!(
            edited,
            r#"{"mcpServers": {"a": {"url": "y"}, "tablepro": {"url":"http://127.0.0.1:23508/mcp","headers":{"Authorization":"Bearer tp_x"}}}}"#
        );
    }

    #[test]
    fn a_duplicate_key_on_the_path_or_the_server_is_refused() {
        let twice = "{\"mcpServers\": {}, \"mcpServers\": {}}";
        let server_twice = "{\"mcpServers\": {\"tablepro\": {}, \"tablepro\": {}}}";

        assert_eq!(
            upserting(twice, &path(&["mcpServers"]), "tablepro", &entry(), Upsert::Merge),
            Err(ConfigEditError::DuplicateKey {
                path: path(&["mcpServers"])
            })
        );
        assert_eq!(
            member(server_twice, &path(&["mcpServers"]), "tablepro"),
            Err(ConfigEditError::DuplicateKey {
                path: path(&["mcpServers", "tablepro"])
            })
        );
    }

    #[test]
    fn broken_or_misshapen_files_are_refused() {
        for text in [
            "{",
            "{\"a\": 1 \"b\": 2}",
            "[1, 2]",
            "{\"a\": tru}",
            "{} {}",
            "{\"a\": \"\u{1}\"}",
            "/* open",
        ] {
            assert!(
                upserting(text, &path(&["mcpServers"]), "tablepro", &entry(), Upsert::Merge).is_err(),
                "{text:?}"
            );
        }
        assert_eq!(
            upserting(
                "{\"mcpServers\": []}",
                &path(&["mcpServers"]),
                "tablepro",
                &entry(),
                Upsert::Merge
            ),
            Err(ConfigEditError::NotAnObject {
                path: path(&["mcpServers"])
            })
        );
    }

    #[test]
    fn escapes_and_a_byte_order_mark_are_read() {
        let text = "\u{feff}{\"mcpServers\": {\"tablepro\": {\"url\": \"a\\u00e9\\ud83d\\ude00\\n\"}}}";

        let found = member(text, &path(&["mcpServers"]), "tablepro").expect("readable");

        assert_eq!(
            found.and_then(|value| value.get("url").cloned()),
            Some(JsonValue::String("aé😀\n".to_owned()))
        );
    }

    #[test]
    fn a_lone_surrogate_reads_as_a_replacement_and_stays_in_the_file() {
        let text = "{\"other\": {\"name\": \"a\\ud83d b\\ude00 c\\ud83d\\u0041\"}, \"mcpServers\": {}}";

        let other = member(text, &[], "other").expect("readable");
        let edited = upsert(text, &["mcpServers"]);

        assert_eq!(
            other.and_then(|value| value.get("name").cloned()),
            Some(JsonValue::String("a\u{fffd} b\u{fffd} c\u{fffd}A".to_owned()))
        );
        assert!(
            edited.starts_with("{\"other\": {\"name\": \"a\\ud83d b\\ude00 c\\ud83d\\u0041\"}"),
            "{edited}"
        );
        assert!(
            member(&edited, &path(&["mcpServers"]), "tablepro")
                .expect("readable")
                .is_some()
        );
    }

    #[test]
    fn removing_the_last_member_takes_the_comma_before_it() {
        let text =
            "{\n  \"mcpServers\": {\n    \"other\": {},\n    \"tablepro\": {\n      \"url\": \"x\"\n    }\n  }\n}\n";

        let removed = removing(text, &path(&["mcpServers"]), "tablepro").expect("an edit");

        assert_eq!(removed, "{\n  \"mcpServers\": {\n    \"other\": {}\n  }\n}\n");
    }

    #[test]
    fn removing_a_middle_member_takes_its_own_line() {
        let text = "{\n  \"mcpServers\": {\n    \"tablepro\": {\"url\": \"x\"},\n    \"other\": {}\n  }\n}\n";

        let removed = removing(text, &path(&["mcpServers"]), "tablepro").expect("an edit");

        assert_eq!(removed, "{\n  \"mcpServers\": {\n    \"other\": {}\n  }\n}\n");
    }

    #[test]
    fn removing_the_only_member_leaves_an_empty_object() {
        let text = "{\n  \"mcpServers\": {\n    \"tablepro\": {\"url\": \"x\"}\n  }\n}\n";

        assert_eq!(
            removing(text, &path(&["mcpServers"]), "tablepro").expect("an edit"),
            "{\n  \"mcpServers\": {\n  }\n}\n"
        );
        assert_eq!(
            removing(
                r#"{"mcpServers": {"tablepro": {}}}"#,
                &path(&["mcpServers"]),
                "tablepro"
            )
            .expect("an edit"),
            r#"{"mcpServers": {}}"#
        );
    }

    #[test]
    fn removing_what_is_not_there_changes_nothing() {
        let text = "{ \"a\": 1 } // done\n";

        assert_eq!(
            removing(text, &path(&["mcpServers"]), "tablepro").expect("no edit"),
            text
        );
    }

    #[test]
    fn a_comment_between_the_last_two_members_is_kept_on_removal() {
        let text = "{\n  \"a\": 1, // about a\n  \"tablepro\": {}\n}\n";

        let removed = removing(text, &[], "tablepro").expect("an edit");

        assert_eq!(removed, "{\n  \"a\": 1 // about a\n}\n");
    }

    #[test]
    fn a_wildcard_scope_finds_a_server_in_any_project() {
        let text = r#"{"projects": {"/home/ana/app": {"mcpServers": {"tablepro": {}}}}}"#;

        let scope = path(&["projects", "*", "mcpServers"]);

        assert_eq!(
            members_in_scope(text, &scope, "tablepro").expect("readable"),
            [JsonValue::Object(Vec::new())]
        );
        assert!(members_in_scope(text, &scope, "other").expect("readable").is_empty());
    }
}
