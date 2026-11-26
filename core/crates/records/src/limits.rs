use serde_json::Value;

use crate::secret_key::first_secret_key;

// 0051, Limits.
pub const MAX_RECORD_BYTES: usize = 1 << 20;
pub const MAX_DEPTH: usize = 32;

// The server's per-change refusals a device can see coming, so it keeps the record and lists it instead of pushing it.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Refusal {
    #[error("the fields nest deeper than 32 levels")]
    TooDeep,
    #[error("the fields hold a NUL character at {path}")]
    Nul { path: String },
    #[error("the fields hold a null at {path}")]
    Null { path: String },
    #[error("the member {path} names a secret")]
    SecretKey { path: String },
    #[error("the fields take {bytes} bytes, over 1 MiB")]
    TooLarge { bytes: usize },
}

impl Refusal {
    // The server's rejected codes (0051, Push).
    pub const fn code(&self) -> &'static str {
        match self {
            Self::TooDeep | Self::Nul { .. } | Self::Null { .. } => "bad_value",
            Self::SecretKey { .. } => "secret_key",
            Self::TooLarge { .. } => "too_large",
        }
    }
}

// The record's fields object is level 1.
pub fn check(fields: &Value) -> Result<(), Refusal> {
    if depth(fields) > MAX_DEPTH {
        return Err(Refusal::TooDeep);
    }
    if let Some(found) = find(
        fields,
        "",
        &|value| matches!(value, Value::String(text) if text.contains('\0')),
    ) {
        return Err(Refusal::Nul { path: found });
    }
    if let Some(found) = nul_key(fields, "") {
        return Err(Refusal::Nul { path: found });
    }
    if let Some(found) = find(fields, "", &Value::is_null) {
        return Err(Refusal::Null { path: found });
    }
    if let Some(path) = first_secret_key(fields) {
        return Err(Refusal::SecretKey { path });
    }
    let bytes = encoded_len(fields);
    if bytes > MAX_RECORD_BYTES {
        return Err(Refusal::TooLarge { bytes });
    }
    Ok(())
}

// As Go's encoder writes the fields with HTML escaping off, which is how the server measures a record: it also escapes
// U+2028 and U+2029, six bytes where UTF-8 takes three.
pub fn encoded_len(fields: &Value) -> usize {
    let compact = serde_json::to_vec(fields).map_or(0, |bytes| bytes.len());
    compact + 3 * separators(fields)
}

fn separators(value: &Value) -> usize {
    let count = |text: &str| text.chars().filter(|c| matches!(c, '\u{2028}' | '\u{2029}')).count();
    match value {
        Value::String(text) => count(text),
        Value::Array(items) => items.iter().map(separators).sum(),
        Value::Object(members) => members
            .iter()
            .map(|(key, member)| count(key) + separators(member))
            .sum(),
        _ => 0,
    }
}

fn depth(value: &Value) -> usize {
    match value {
        Value::Array(items) => 1 + items.iter().map(depth).max().unwrap_or(0),
        Value::Object(members) => 1 + members.values().map(depth).max().unwrap_or(0),
        _ => 0,
    }
}

fn find(value: &Value, path: &str, matches: &dyn Fn(&Value) -> bool) -> Option<String> {
    if matches(value) {
        return Some(path.to_owned());
    }
    match value {
        Value::Array(items) => items
            .iter()
            .enumerate()
            .find_map(|(index, item)| find(item, &format!("{path}[{index}]"), matches)),
        Value::Object(members) => members
            .iter()
            .find_map(|(key, member)| find(member, &joined(path, key), matches)),
        _ => None,
    }
}

fn nul_key(value: &Value, path: &str) -> Option<String> {
    match value {
        Value::Array(items) => items
            .iter()
            .enumerate()
            .find_map(|(index, item)| nul_key(item, &format!("{path}[{index}]"))),
        Value::Object(members) => members.iter().find_map(|(key, member)| {
            let at = joined(path, key);
            if key.contains('\0') {
                Some(at)
            } else {
                nul_key(member, &at)
            }
        }),
        _ => None,
    }
}

fn joined(path: &str, key: &str) -> String {
    if path.is_empty() {
        key.to_owned()
    } else {
        format!("{path}.{key}")
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn nested(levels: usize) -> Value {
        (1..levels).fold(json!({}), |inner, _| json!({ "a": inner }))
    }

    #[test]
    fn thirty_two_levels_pass_and_thirty_three_are_refused() {
        assert_eq!(check(&nested(32)), Ok(()));
        assert_eq!(check(&nested(33)).map_err(|refusal| refusal.code()), Err("bad_value"));
    }

    #[test]
    fn a_nul_in_a_value_or_a_key_and_a_stored_null_are_bad_values() {
        assert_eq!(
            check(&json!({"name": "a\u{0}b"})),
            Err(Refusal::Nul {
                path: "name".to_owned()
            })
        );
        assert_eq!(
            check(&json!({"x": {"a\u{0}": 1}})),
            Err(Refusal::Nul {
                path: "x.a\u{0}".to_owned()
            })
        );
        assert_eq!(
            check(&json!({"x": [1, null]})),
            Err(Refusal::Null {
                path: "x[1]".to_owned()
            })
        );
    }

    #[test]
    fn a_secret_named_member_is_refused_by_its_code() {
        let refused = check(&json!({"ssh_config": {"password": "x"}}));

        assert_eq!(refused.map_err(|refusal| refusal.code()), Err("secret_key"));
    }

    #[test]
    fn a_record_is_measured_as_the_server_measures_it() {
        let at_limit = json!({ "q": "a".repeat(MAX_RECORD_BYTES - 8) });

        assert_eq!(encoded_len(&at_limit), MAX_RECORD_BYTES);
        assert_eq!(check(&at_limit), Ok(()));
        let over = json!({ "q": format!("{}\u{2028}", "a".repeat(MAX_RECORD_BYTES - 13)) });

        assert_eq!(encoded_len(&over), MAX_RECORD_BYTES + 1);
        assert_eq!(check(&over).map_err(|refusal| refusal.code()), Err("too_large"));
        assert_eq!(encoded_len(&json!({"a": "<&>"})), 11);
    }
}
