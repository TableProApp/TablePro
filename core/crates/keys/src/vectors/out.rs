use crate::json::{JsonValue, parse, push_string};

pub(super) fn obj(members: Vec<(&str, JsonValue)>) -> JsonValue {
    JsonValue::Object(
        members
            .into_iter()
            .map(|(name, value)| (name.to_owned(), value))
            .collect(),
    )
}

pub(super) fn s(text: &str) -> JsonValue {
    JsonValue::String(text.to_owned())
}

pub(super) fn h(bytes: &[u8]) -> JsonValue {
    JsonValue::String(hex::encode(bytes))
}

pub(super) fn n(value: u64) -> JsonValue {
    JsonValue::Number(value.into())
}

pub(super) fn b(value: bool) -> JsonValue {
    JsonValue::Bool(value)
}

pub(super) fn arr(items: Vec<JsonValue>) -> JsonValue {
    JsonValue::Array(items)
}

pub(super) fn null() -> JsonValue {
    JsonValue::Null
}

pub(super) fn raw(json: &str) -> JsonValue {
    parse(json.as_bytes()).expect("generator JSON parses")
}

// The JSON of a key object's or a sealed record's fields, kept as the exact text a writer sends.
pub(super) fn fields(json: &str) -> JsonValue {
    raw(json)
}

// A case: what to compute, its inputs, and either its outputs or the client's error code with the
// server's code from ADR 0051 where the server checks it.
pub(super) fn case(name: &str, op: &str, input: Vec<(&str, JsonValue)>, output: Vec<(&str, JsonValue)>) -> JsonValue {
    obj(vec![
        ("name", s(name)),
        ("op", s(op)),
        ("input", obj(input)),
        ("output", obj(output)),
    ])
}

// A case for a row of ADR 0056's negative table whose client outcome is not an error.
pub(super) fn case_row(
    name: &str,
    op: &str,
    row: &str,
    input: Vec<(&str, JsonValue)>,
    output: Vec<(&str, JsonValue)>,
    server: Option<&str>,
) -> JsonValue {
    obj(vec![
        ("name", s(name)),
        ("op", s(op)),
        ("row", s(row)),
        ("input", obj(input)),
        ("output", obj(output)),
        ("server", server.map_or_else(null, s)),
    ])
}

pub(super) fn negative(
    name: &str,
    op: &str,
    row: &str,
    input: Vec<(&str, JsonValue)>,
    client: &str,
    server: Option<&str>,
) -> JsonValue {
    obj(vec![
        ("name", s(name)),
        ("op", s(op)),
        ("row", s(row)),
        ("input", obj(input)),
        ("error", s(client)),
        ("server", server.map_or_else(null, s)),
    ])
}

pub(super) fn file(area: &str, about: &str, groups: Vec<(&str, JsonValue)>) -> JsonValue {
    let mut members = vec![
        ("area", s(area)),
        ("suite", s("tp1")),
        ("format", n(1)),
        ("about", s(about)),
    ];
    members.extend(groups);
    obj(members)
}

pub(super) fn pretty(value: &JsonValue) -> String {
    let mut out = String::new();
    write(value, 0, &mut out);
    out.push('\n');
    out
}

fn write(value: &JsonValue, depth: usize, out: &mut String) {
    let indent = |out: &mut String, depth: usize| out.push_str(&"  ".repeat(depth));
    match value {
        JsonValue::Array(items) if !items.is_empty() => {
            if items
                .iter()
                .all(|item| !matches!(item, JsonValue::Array(_) | JsonValue::Object(_)))
                && items.len() <= 8
            {
                out.push_str(&value.to_json());
                return;
            }
            out.push_str("[\n");
            for (index, item) in items.iter().enumerate() {
                indent(out, depth + 1);
                write(item, depth + 1, out);
                if index + 1 < items.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            indent(out, depth);
            out.push(']');
        }
        JsonValue::Object(members) if !members.is_empty() => {
            out.push_str("{\n");
            for (index, (name, member)) in members.iter().enumerate() {
                indent(out, depth + 1);
                push_string(out, name);
                out.push_str(": ");
                write(member, depth + 1, out);
                if index + 1 < members.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            indent(out, depth);
            out.push('}');
        }
        _ => out.push_str(&value.to_json()),
    }
}
