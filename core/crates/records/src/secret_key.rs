use serde_json::Value;

// The server's `SecretKey` (tablepro-cloud `internal/library/domain/data.go`): a key whose name, lower-cased without
// spaces, `_`, `-` and `.`, ends in one of these names a secret and is refused at any depth.
const SECRET_SUFFIXES: [&str; 7] = [
    "password",
    "passphrase",
    "token",
    "privatekey",
    "secret",
    "securefields",
    "passwordsource",
];

pub fn is_secret_key(key: &str) -> bool {
    let normalized: String = key
        .chars()
        .filter(|c| !matches!(c, ' ' | '_' | '-' | '.'))
        .map(simple_lowercase)
        .collect();
    SECRET_SUFFIXES.iter().any(|suffix| normalized.ends_with(suffix))
}

// Go's `unicode.ToLower` maps one rune to one rune. Rust's lower-casing differs only for U+0130, which it writes as
// two characters and Go as `i`.
fn simple_lowercase(c: char) -> char {
    if c == '\u{130}' {
        return 'i';
    }
    let mut lower = c.to_lowercase();
    match (lower.next(), lower.next()) {
        (Some(single), None) => single,
        _ => c,
    }
}

// The first member name the server would refuse, as a dotted path, walking members in key order as the server does.
pub fn first_secret_key(value: &Value) -> Option<String> {
    first_in(value, "")
}

fn first_in(value: &Value, path: &str) -> Option<String> {
    match value {
        Value::Object(members) => {
            let mut keys: Vec<&String> = members.keys().collect();
            keys.sort();
            keys.into_iter().find_map(|key| {
                let at = if path.is_empty() {
                    key.clone()
                } else {
                    format!("{path}.{key}")
                };
                if is_secret_key(key) {
                    return Some(at);
                }
                members.get(key).and_then(|member| first_in(member, &at))
            })
        }
        Value::Array(items) => items
            .iter()
            .enumerate()
            .find_map(|(index, item)| first_in(item, &format!("{path}[{index}]"))),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn names_the_server_refuses_are_secret() {
        for key in [
            "password",
            "sshPassword",
            "key_passphrase",
            "totpSecret",
            "AWS_SESSION_TOKEN",
            "private-key",
            "Private Key",
            "secureFields",
            "password.source",
            "has_passphrase",
            "PASSWORD",
            "\u{130}private key",
        ] {
            assert!(is_secret_key(key), "{key}");
        }
    }

    #[test]
    fn paths_and_flags_that_only_mention_a_secret_pass() {
        for key in [
            "privateKeyPath",
            "private_key_path",
            "passphrase_stored",
            "password_mode",
            "tokens",
            "secure_field_ids",
            "secretary",
            "ssh_auth_method",
            "",
        ] {
            assert!(!is_secret_key(key), "{key}");
        }
    }

    #[test]
    fn the_first_refused_key_is_found_at_any_depth_in_key_order() {
        let fields = json!({
            "name": "prod",
            "ssh_config": {"jump_hosts": [{"host": "a"}, {"host": "b", "password": "x"}]},
            "a_token": "y"
        });

        assert_eq!(first_secret_key(&fields).as_deref(), Some("a_token"));
        assert_eq!(
            first_secret_key(&json!({"ssh_config": {"jump_hosts": [{}, {"password": 1}]}})).as_deref(),
            Some("ssh_config.jump_hosts[1].password")
        );
        assert_eq!(first_secret_key(&json!({"name": "prod", "tags": ["token"]})), None);
    }
}
