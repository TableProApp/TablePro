use serde_json::Value;

// RFC 7396, section 2, MergePatch(Target, Patch).
pub fn apply(target: &Value, patch: &Value) -> Value {
    let Value::Object(changes) = patch else {
        return patch.clone();
    };
    let mut result = match target {
        Value::Object(members) => members.clone(),
        _ => Default::default(),
    };
    for (key, change) in changes {
        if change.is_null() {
            result.remove(key);
        } else {
            let merged = apply(result.get(key).unwrap_or(&Value::Null), change);
            result.insert(key.clone(), merged);
        }
    }
    Value::Object(result)
}

// The smallest patch that `apply` turns `from` into `to`, or `None` when they are equal. Stored fields hold no null
// (0051, Limits), so a null member of `to` reads as an absent one.
pub fn diff(from: &Value, to: &Value) -> Option<Value> {
    let to = without_nulls(to);
    let patch = changes(from, &to);
    match &patch {
        Some(Value::Object(members)) if members.is_empty() => None,
        _ => patch,
    }
}

fn changes(from: &Value, to: &Value) -> Option<Value> {
    let (Value::Object(old), Value::Object(new)) = (from, to) else {
        return (from != to).then(|| to.clone());
    };
    let mut patch = serde_json::Map::new();
    for key in old.keys().filter(|key| !new.contains_key(*key)) {
        patch.insert(key.clone(), Value::Null);
    }
    for (key, value) in new {
        let change = match old.get(key) {
            Some(held @ Value::Object(_)) if value.is_object() => {
                changes(held, value).filter(|change| !matches!(change, Value::Object(members) if members.is_empty()))
            }
            Some(held) if held == value => None,
            _ => Some(value.clone()),
        };
        if let Some(change) = change {
            patch.insert(key.clone(), change);
        }
    }
    Some(Value::Object(patch))
}

pub fn without_nulls(value: &Value) -> Value {
    match value {
        Value::Object(members) => Value::Object(
            members
                .iter()
                .filter(|(_, member)| !member.is_null())
                .map(|(key, member)| (key.clone(), without_nulls(member)))
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(without_nulls).collect()),
        other => other.clone(),
    }
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;
    use serde_json::json;

    use super::*;

    // RFC 7396, Appendix A.
    #[test]
    fn the_rfc_examples_apply_as_written() {
        let cases = [
            (json!({"a":"b"}), json!({"a":"c"}), json!({"a":"c"})),
            (json!({"a":"b"}), json!({"b":"c"}), json!({"a":"b","b":"c"})),
            (json!({"a":"b"}), json!({"a":null}), json!({})),
            (json!({"a":"b","b":"c"}), json!({"a":null}), json!({"b":"c"})),
            (json!({"a":["b"]}), json!({"a":"c"}), json!({"a":"c"})),
            (json!({"a":"c"}), json!({"a":["b"]}), json!({"a":["b"]})),
            (
                json!({"a":{"b":"c"}}),
                json!({"a":{"b":"d","c":null}}),
                json!({"a":{"b":"d"}}),
            ),
            (json!({"a":[{"b":"c"}]}), json!({"a":[1]}), json!({"a":[1]})),
            (json!(["a", "b"]), json!(["c", "d"]), json!(["c", "d"])),
            (json!({"a":"b"}), json!(["c"]), json!(["c"])),
            (json!({"a":"foo"}), json!(null), json!(null)),
            (json!({"a":"foo"}), json!("bar"), json!("bar")),
            (json!({"e":null}), json!({"a":1}), json!({"e":null,"a":1})),
            (json!([1, 2]), json!({"a":"b","c":null}), json!({"a":"b"})),
            (json!({}), json!({"a":{"bb":{"ccc":null}}}), json!({"a":{"bb":{}}})),
        ];
        for (target, patch, result) in cases {
            assert_eq!(apply(&target, &patch), result, "{target} + {patch}");
        }
    }

    #[test]
    fn a_diff_names_only_what_changed() {
        let from = json!({"name": "prod", "port": 5432, "ssh_config": {"host": "a", "port": 22}, "tag_ids": ["A"]});
        let to = json!({"name": "prod", "port": 5433, "ssh_config": {"host": "a"}, "tag_ids": ["A", "B"]});

        assert_eq!(
            diff(&from, &to),
            Some(json!({"port": 5433, "ssh_config": {"port": null}, "tag_ids": ["A", "B"]}))
        );
        assert_eq!(diff(&from, &from), None);
    }

    #[test]
    fn an_emptied_object_removes_each_member() {
        let from = json!({"ssh_config": {"host": "a"}});
        let to = json!({"ssh_config": {}});

        assert_eq!(diff(&from, &to), Some(json!({"ssh_config": {"host": null}})));
        assert_eq!(apply(&from, &json!({"ssh_config": {"host": null}})), to);
    }

    #[test]
    fn a_null_in_the_new_copy_is_a_removal() {
        assert_eq!(
            diff(&json!({"a": 1, "b": 2}), &json!({"a": 1, "b": null})),
            Some(json!({"b": null}))
        );
    }

    fn json_value() -> impl Strategy<Value = Value> {
        let leaf = prop_oneof![
            any::<bool>().prop_map(Value::from),
            any::<i32>().prop_map(Value::from),
            "[a-c]{0,3}".prop_map(Value::from),
        ];
        leaf.prop_recursive(4, 32, 4, |inner| {
            prop_oneof![
                prop::collection::vec(inner.clone(), 0..3).prop_map(Value::Array),
                prop::collection::btree_map("[a-d]", inner, 0..4)
                    .prop_map(|members| Value::Object(members.into_iter().collect())),
            ]
        })
    }

    proptest! {
        #[test]
        fn applying_a_diff_gives_the_new_copy(from in json_value(), to in json_value()) {
            let from = Value::Object([("r".to_owned(), from)].into_iter().collect());
            let to = Value::Object([("r".to_owned(), to)].into_iter().collect());
            let patched = diff(&from, &to).map_or_else(|| from.clone(), |patch| apply(&from, &patch));

            prop_assert_eq!(patched, to);
        }
    }
}
