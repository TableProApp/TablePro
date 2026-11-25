// A settings document merged option by option, as the Mac's `SyncJSONMerge` does: the document and the objects
// directly in it merge member by member, deeper values are one option each, lists of objects merge by `id`, and a
// value both sides changed takes this device's.

use std::collections::HashSet;

use serde_json::Value;

const OPTION_DEPTH: usize = 2;

pub fn merge_document(base: Option<&Value>, local: Option<&Value>, server: Option<&Value>) -> Value {
    let base = base.unwrap_or(&Value::Null);
    let local = local.unwrap_or(&Value::Null);
    let server = server.unwrap_or(&Value::Null);
    merged(base, local, server, 0)
}

fn merged(base: &Value, local: &Value, server: &Value, depth: usize) -> Value {
    if local == base {
        return server.clone();
    }
    if server == base || depth >= OPTION_DEPTH {
        return local.clone();
    }
    match (local, server) {
        (Value::Object(mine), Value::Object(theirs)) => {
            let mut result = theirs.clone();
            let held = |key: &str| base.get(key).unwrap_or(&Value::Null);
            let changed: HashSet<&String> = mine
                .keys()
                .chain(object_keys(base))
                .filter(|key| mine.get(*key).unwrap_or(&Value::Null) != held(key))
                .collect();
            for key in changed {
                match (mine.get(key), theirs.get(key)) {
                    (None, _) => {
                        result.remove(key);
                    }
                    (Some(value), None) => {
                        result.insert(key.clone(), value.clone());
                    }
                    (Some(value), Some(other)) => {
                        result.insert(key.clone(), merged(held(key), value, other, depth + 1));
                    }
                }
            }
            Value::Object(result)
        }
        (Value::Array(mine), Value::Array(theirs)) if [base, local, server].into_iter().all(keyed_by_id) => {
            by_id(base.as_array().map_or(&[], Vec::as_slice), mine, theirs)
        }
        _ => local.clone(),
    }
}

// Walk the server's items in order: one deleted here goes, one changed here takes this device's copy. Then add this
// device's items the server lacks that differ from the base: added here, or changed here while removed elsewhere.
fn by_id(base: &[Value], local: &[Value], server: &[Value]) -> Value {
    let find = |items: &'_ [Value], id: &str| items.iter().find(|item| item_id(item).as_deref() == Some(id)).cloned();
    let mut result = Vec::with_capacity(server.len());
    let mut seen = HashSet::new();
    for item in server {
        let Some(id) = item_id(item) else {
            continue;
        };
        seen.insert(id.clone());
        let (held, mine) = (find(base, &id), find(local, &id));
        match (held, mine) {
            (Some(_), None) => {}
            // Changed here, or added here as well as there.
            (held, Some(mine)) if held.as_ref() != Some(&mine) => result.push(mine),
            _ => result.push(item.clone()),
        }
    }
    for item in local {
        let Some(id) = item_id(item) else {
            continue;
        };
        if !seen.contains(&id) && find(base, &id).as_ref() != Some(item) {
            result.push(item.clone());
        }
    }
    Value::Array(result)
}

// Every item an object with an `id` no other item shares.
fn keyed_by_id(list: &Value) -> bool {
    match list {
        Value::Null => true,
        Value::Array(items) => {
            let mut seen = HashSet::with_capacity(items.len());
            items
                .iter()
                .all(|item| item.is_object() && item_id(item).is_some_and(|id| seen.insert(id)))
        }
        _ => false,
    }
}

// `"\(id)"`: a string as itself, any other value as its JSON text.
fn item_id(item: &Value) -> Option<String> {
    match item.get("id")? {
        Value::String(text) => Some(text.clone()),
        other => Some(other.to_string()),
    }
}

fn object_keys(value: &Value) -> impl Iterator<Item = &String> {
    match value {
        Value::Object(members) => Some(members.keys()),
        _ => None,
    }
    .into_iter()
    .flatten()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn options_changed_on_different_sides_both_land() {
        let base = json!({"tabWidth": 4, "wordWrap": false, "keyBindings": "standard"});
        let local = json!({"tabWidth": 2, "wordWrap": false, "keyBindings": "standard"});
        let server = json!({"tabWidth": 4, "wordWrap": true, "keyBindings": "standard"});

        assert_eq!(
            merge_document(Some(&base), Some(&local), Some(&server)),
            json!({"tabWidth": 2, "wordWrap": true, "keyBindings": "standard"})
        );
    }

    #[test]
    fn an_option_both_sides_changed_takes_this_devices_value() {
        let base = json!({"tabWidth": 4});

        assert_eq!(
            merge_document(
                Some(&base),
                Some(&json!({"tabWidth": 2})),
                Some(&json!({"tabWidth": 8}))
            ),
            json!({"tabWidth": 2})
        );
    }

    #[test]
    fn an_option_removed_here_goes_even_when_the_server_changed_it() {
        let base = json!({"a": 1, "b": 1});

        assert_eq!(
            merge_document(
                Some(&base),
                Some(&json!({"b": 1})),
                Some(&json!({"a": 2, "b": 1, "c": 3}))
            ),
            json!({"b": 1, "c": 3})
        );
    }

    #[test]
    fn a_nested_object_merges_one_level_down_and_no_further() {
        let base = json!({"o": {"x": 1, "y": {"p": 1, "q": 1}}});
        let local = json!({"o": {"x": 2, "y": {"p": 2, "q": 1}}});
        let server = json!({"o": {"x": 1, "y": {"p": 1, "q": 2}}});

        assert_eq!(
            merge_document(Some(&base), Some(&local), Some(&server)),
            json!({"o": {"x": 2, "y": {"p": 2, "q": 1}}})
        );
    }

    #[test]
    fn lists_of_objects_merge_by_id() {
        let base = json!([{"id": "a", "name": "one"}, {"id": "b", "name": "two"}, {"id": "c", "name": "three"}]);
        let local = json!([{"id": "a", "name": "uno"}, {"id": "c", "name": "three"}, {"id": "d", "name": "four"}]);
        let server = json!([{"id": "c", "name": "three"}, {"id": "a", "name": "one"}, {"id": "b", "name": "two"}, {"id": "e", "name": "five"}]);

        assert_eq!(
            merge_document(Some(&base), Some(&local), Some(&server)),
            json!([
                {"id": "c", "name": "three"},
                {"id": "a", "name": "uno"},
                {"id": "e", "name": "five"},
                {"id": "d", "name": "four"}
            ])
        );
    }

    #[test]
    fn an_item_both_sides_added_takes_this_devices_copy() {
        let base = json!({"columnWidths": []});
        let local = json!({"columnWidths": [{"id": "email", "value": 240}]});
        let server = json!({"columnWidths": [{"id": "email", "value": 180}, {"id": "id", "value": 60}]});

        assert_eq!(
            merge_document(Some(&base), Some(&local), Some(&server)),
            json!({"columnWidths": [{"id": "email", "value": 240}, {"id": "id", "value": 60}]})
        );
    }

    #[test]
    fn a_list_without_unique_ids_goes_whole() {
        let base = json!({"columnOrder": ["a", "b"]});
        let local = json!({"columnOrder": ["b", "a"]});
        let server = json!({"columnOrder": ["a", "b", "c"]});

        assert_eq!(
            merge_document(Some(&base), Some(&local), Some(&server)),
            json!({"columnOrder": ["b", "a"]})
        );
    }

    #[test]
    fn an_item_changed_here_and_removed_elsewhere_comes_back() {
        let base = json!([{"id": "a", "v": 1}]);
        let local = json!([{"id": "a", "v": 2}]);
        let server = json!([]);

        assert_eq!(
            merge_document(Some(&base), Some(&local), Some(&server)),
            json!([{"id": "a", "v": 2}])
        );
    }
}
