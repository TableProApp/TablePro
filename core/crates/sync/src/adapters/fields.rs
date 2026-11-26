// Each member of a record by the class that rules it (0044, Fields a pull applies only with approval; 0061): a walk
// over a record's wire schema to the members a class decides, named by a JSON Pointer (RFC 6901). An object the schema
// describes is walked into, so its own members decide; an entries list is judged by entry, a settings record by
// option, and anything else as one value. A member the schema does not name waits for approval.

use std::collections::BTreeSet;

use serde_json::{Map, Value};
use tablepro_records::Kind;
use tablepro_records::schema::{Approval, Class, ENTRY, Field, Type, entry_class, schema};
use tablepro_records::settings::{Document, registry};

use crate::api::ids::ScopeName;

// What a pull may do with one member.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rule {
    Applies,
    Waits(Approval),
    // Device-only, or dropped on pull in a team: the device's value stays and never goes up.
    Stays,
}

impl Rule {
    fn of(class: Class, scope: ScopeName) -> Self {
        match class {
            Class::Inert => Self::Applies,
            Class::Approval(approval) => Self::Waits(approval),
            Class::DeviceOnly | Class::Dropped => Self::Stays,
            // Which entry a driver keeps on the device is the adapter's to leave out; on the wire each one waits.
            Class::ByEntry => Rule::of(entry_class(scope.records_scope(), None), scope),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Member {
    pub pointer: String,
    pub rule: Rule,
}

const ALWAYS: Rule = Rule::Waits(Approval::Always);

// The members of `kind` either copy holds, each once, in a stable order.
pub fn members(kind: Kind, scope: ScopeName, a: Option<&Value>, b: Option<&Value>) -> Vec<Member> {
    let mut out = Vec::new();
    // Envelopes, history entries and key objects carry ciphertext or signed bytes: nothing in them waits.
    if kind.is_create_once() || kind == Kind::SecretEnvelope {
        return out;
    }
    let fields = schema(kind).fields;
    walk_object(kind, scope, fields, a, b, "", &mut out);
    out
}

fn walk_object(
    kind: Kind,
    scope: ScopeName,
    fields: &'static [Field],
    a: Option<&Value>,
    b: Option<&Value>,
    prefix: &str,
    out: &mut Vec<Member>,
) {
    for name in names(a, b) {
        let pointer = format!("{prefix}/{}", escape(&name));
        let (left, right) = (a.and_then(|a| a.get(&name)), b.and_then(|b| b.get(&name)));
        let Some(field) = fields.iter().find(|field| field.key == name) else {
            out.push(Member { pointer, rule: ALWAYS });
            continue;
        };
        let rule = Rule::of(field.class, scope);
        if rule == Rule::Stays {
            out.push(Member { pointer, rule });
            continue;
        }
        match field.ty {
            Type::Object(nested) if is_object(left) && is_object(right) => {
                walk_object(kind, scope, nested, left, right, &pointer, out);
            }
            Type::Entries(_) if field.class == Class::ByEntry && is_entries(left) && is_entries(right) => {
                walk_entries(scope, left, right, &pointer, out);
            }
            Type::Map(_) if field.class == Class::ByEntry && is_object(left) && is_object(right) => {
                for key in names(left, right) {
                    out.push(Member {
                        pointer: format!("{pointer}/{}", escape(&key)),
                        rule: Rule::of(entry_class(scope.records_scope(), None), scope),
                    });
                }
            }
            Type::Options => walk_options(kind, scope, a, b, left, right, &pointer, out),
            _ => out.push(Member { pointer, rule }),
        }
    }
}

// Each entry of an `{"id", "value"}` list by its id, whole.
fn walk_entries(scope: ScopeName, a: Option<&Value>, b: Option<&Value>, prefix: &str, out: &mut Vec<Member>) {
    let ids: BTreeSet<String> = [a, b]
        .into_iter()
        .flatten()
        .filter_map(Value::as_array)
        .flatten()
        .filter_map(|item| item.get("id").and_then(Value::as_str).map(str::to_owned))
        .collect();
    for id in ids {
        out.push(Member {
            pointer: format!("{prefix}/{}", escape(&id)),
            rule: Rule::of(entry_class(scope.records_scope(), None), scope),
        });
    }
}

// A settings record's options by the class its platform's registry gives each one in the record's category; an
// option or a category nobody has classed waits (0061, 6).
#[expect(
    clippy::too_many_arguments,
    reason = "both copies of the record and of its options, with where they sit"
)]
fn walk_options(
    kind: Kind,
    scope: ScopeName,
    record_a: Option<&Value>,
    record_b: Option<&Value>,
    a: Option<&Value>,
    b: Option<&Value>,
    prefix: &str,
    out: &mut Vec<Member>,
) {
    let category = [record_a, record_b]
        .into_iter()
        .flatten()
        .find_map(|record| record.get("category").and_then(Value::as_str));
    let document = category.and_then(|category| registry(kind)?.category(category).map(|known| known.document));
    match document {
        Some(Document::Object(fields)) if is_object(a) && is_object(b) => {
            walk_object(kind, scope, fields, a, b, prefix, out);
        }
        Some(Document::List(fields)) if is_list(a) && is_list(b) => walk_list(kind, scope, fields, a, b, prefix, out),
        _ => out.push(Member {
            pointer: prefix.to_owned(),
            rule: ALWAYS,
        }),
    }
}

// A list of objects merged by `id`: each item's members by the item's id.
fn walk_list(
    kind: Kind,
    scope: ScopeName,
    fields: &'static [Field],
    a: Option<&Value>,
    b: Option<&Value>,
    prefix: &str,
    out: &mut Vec<Member>,
) {
    fn find<'v>(list: Option<&'v Value>, id: &str) -> Option<&'v Value> {
        list.and_then(Value::as_array)
            .and_then(|items| items.iter().find(|item| item_id(item) == Some(id)))
    }
    let ids: BTreeSet<String> = [a, b]
        .into_iter()
        .flatten()
        .filter_map(Value::as_array)
        .flatten()
        .filter_map(|item| item_id(item).map(str::to_owned))
        .collect();
    for id in ids {
        let pointer = format!("{prefix}/{}", escape(&id));
        let (left, right) = (find(a, &id), find(b, &id));
        if left.is_some_and(|item| !item.is_object()) || right.is_some_and(|item| !item.is_object()) {
            out.push(Member { pointer, rule: ALWAYS });
            continue;
        }
        walk_object(kind, scope, fields, left, right, &pointer, out);
    }
}

fn item_id(item: &Value) -> Option<&str> {
    item.get("id").and_then(Value::as_str)
}

fn names(a: Option<&Value>, b: Option<&Value>) -> BTreeSet<String> {
    [a, b]
        .into_iter()
        .flatten()
        .filter_map(Value::as_object)
        .flat_map(|members| members.keys().cloned())
        .collect()
}

// Absent counts as either shape, so a member one side lacks is still walked into.
fn is_object(value: Option<&Value>) -> bool {
    value.is_none_or(Value::is_object)
}

fn is_list(value: Option<&Value>) -> bool {
    value.is_none_or(Value::is_array)
}

fn is_entries(value: Option<&Value>) -> bool {
    value.is_none_or(|value| {
        value.as_array().is_some_and(|items| {
            items.iter().all(|item| {
                item.as_object()
                    .is_some_and(|item| item.keys().all(|key| entry_member(key)))
            })
        })
    })
}

fn entry_member(key: &str) -> bool {
    ENTRY.iter().any(|field| field.key == key)
}

fn escape(segment: &str) -> String {
    segment.replace('~', "~0").replace('/', "~1")
}

fn unescape(segment: &str) -> String {
    segment.replace("~1", "/").replace("~0", "~")
}

fn segments(pointer: &str) -> Vec<String> {
    pointer.split('/').skip(1).map(unescape).collect()
}

// A segment names an object's member, or the item of a list whose `id` it is.
fn child<'a>(value: &'a Value, segment: &str) -> Option<&'a Value> {
    match value {
        Value::Object(members) => members.get(segment),
        Value::Array(items) => items.iter().find(|item| item_id(item) == Some(segment)),
        _ => None,
    }
}

pub fn get<'a>(value: Option<&'a Value>, pointer: &str) -> Option<&'a Value> {
    segments(pointer)
        .iter()
        .try_fold(value?, |value, segment| child(value, segment))
}

// Sets or removes the member at `pointer`, making the objects on the way. A list item is put by its id, so a pulled
// entry takes its place or goes at the end.
pub fn set(value: &mut Value, pointer: &str, to: Option<Value>) {
    let parts = segments(pointer);
    put(value, &parts, to);
}

fn put(value: &mut Value, parts: &[String], to: Option<Value>) {
    let Some((first, rest)) = parts.split_first() else {
        if let Some(to) = to {
            *value = to;
        }
        return;
    };
    if value.is_null() {
        if to.is_none() {
            return;
        }
        *value = Value::Object(Map::new());
    }
    match value {
        Value::Object(members) => {
            if rest.is_empty() {
                match to {
                    Some(to) => {
                        members.insert(first.clone(), to);
                    }
                    None => {
                        members.remove(first);
                    }
                }
                return;
            }
            if to.is_none() && !members.contains_key(first) {
                return;
            }
            let next = members.entry(first.clone()).or_insert(Value::Null);
            put(next, rest, to);
            if next.as_object().is_some_and(Map::is_empty) && rest.len() == 1 {
                members.remove(first);
            }
        }
        Value::Array(items) => {
            let at = items.iter().position(|item| item_id(item) == Some(first.as_str()));
            if rest.is_empty() {
                match (at, to) {
                    (Some(at), Some(to)) => items[at] = to,
                    (None, Some(to)) => items.push(to),
                    (Some(at), None) => {
                        items.remove(at);
                    }
                    (None, None) => {}
                }
                return;
            }
            if let Some(at) = at {
                put(&mut items[at], rest, to);
            }
        }
        _ => {}
    }
}

// Each member of `copy` that a rule keeps on the device, or that `held` names, takes `from`'s value instead: what
// goes up from this device, and what a merge reads as its side.
pub fn with_members_of(
    kind: Kind,
    scope: ScopeName,
    copy: &Value,
    from: Option<&Value>,
    held: &BTreeSet<String>,
) -> Value {
    let mut out = copy.clone();
    for member in members(kind, scope, Some(copy), from) {
        if member.rule == Rule::Stays || held.contains(&member.pointer) {
            set(&mut out, &member.pointer, get(from, &member.pointer).cloned());
        }
    }
    for pointer in held {
        if get(Some(&out), pointer) != get(from, pointer) {
            set(&mut out, pointer, get(from, pointer).cloned());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn rule_of(kind: Kind, scope: ScopeName, record: &Value, pointer: &str) -> Option<Rule> {
        members(kind, scope, Some(record), None)
            .into_iter()
            .find(|member| member.pointer == pointer)
            .map(|member| member.rule)
    }

    #[test]
    fn nested_members_take_their_own_class() {
        let record = json!({
            "name": "Prod",
            "host": "db",
            "ssh_config": {"host": "bastion", "totp_digits": 6, "future": 1},
            "local_only": true,
        });

        assert_eq!(
            rule_of(Kind::Connection, ScopeName::Personal, &record, "/name"),
            Some(Rule::Applies)
        );
        assert_eq!(
            rule_of(Kind::Connection, ScopeName::Personal, &record, "/host"),
            Some(ALWAYS)
        );
        assert_eq!(
            rule_of(
                Kind::Connection,
                ScopeName::Personal,
                &record,
                "/ssh_config/totp_digits"
            ),
            Some(Rule::Applies)
        );
        assert_eq!(
            rule_of(Kind::Connection, ScopeName::Personal, &record, "/ssh_config/host"),
            Some(ALWAYS)
        );
        assert_eq!(
            rule_of(Kind::Connection, ScopeName::Personal, &record, "/ssh_config/future"),
            Some(ALWAYS)
        );
        assert_eq!(
            rule_of(Kind::Connection, ScopeName::Personal, &record, "/local_only"),
            Some(Rule::Stays)
        );
    }

    #[test]
    fn the_ai_options_0061_names_wait_and_an_unclassed_option_waits() {
        let record = json!({"category": "ai", "options": {
            "chatMode": "agent",
            "maxSchemaTables": 500,
            "inlineSuggestionDebounceMs": 300,
            "somethingNew": true,
        }});

        for option in ["chatMode", "maxSchemaTables", "somethingNew"] {
            assert!(
                matches!(
                    rule_of(
                        Kind::MacosSettings,
                        ScopeName::Personal,
                        &record,
                        &format!("/options/{option}")
                    ),
                    Some(Rule::Waits(_))
                ),
                "{option}"
            );
        }
        assert_eq!(
            rule_of(
                Kind::MacosSettings,
                ScopeName::Personal,
                &record,
                "/options/inlineSuggestionDebounceMs"
            ),
            Some(Rule::Applies)
        );
    }

    #[test]
    fn a_team_drops_startup_sql_and_entries_go_one_by_one() {
        let library = json!({"startupCommands": "DROP TABLE x", "additionalFields": {"a": "1"}});
        let personal = json!({"additional_fields": [{"id": "useSSL", "value": "true"}]});

        assert_eq!(
            rule_of(
                Kind::LibraryConnection,
                ScopeName::Team(team()),
                &library,
                "/startupCommands"
            ),
            Some(Rule::Stays)
        );
        assert_eq!(
            rule_of(
                Kind::LibraryConnection,
                ScopeName::Team(team()),
                &library,
                "/additionalFields/a"
            ),
            Some(ALWAYS)
        );
        assert_eq!(
            rule_of(
                Kind::Connection,
                ScopeName::Personal,
                &personal,
                "/additional_fields/useSSL"
            ),
            Some(ALWAYS)
        );
    }

    #[test]
    fn a_pointer_reaches_members_and_list_items_by_id() {
        let mut value = json!({"a": {"b": 1}, "list": [{"id": "x/y", "value": "1"}]});

        assert_eq!(get(Some(&value), "/a/b"), Some(&json!(1)));
        assert_eq!(
            get(Some(&value), "/list/x~1y"),
            Some(&json!({"id": "x/y", "value": "1"}))
        );
        set(&mut value, "/a/c", Some(json!(2)));
        set(&mut value, "/list/x~1y", None);
        set(&mut value, "/list/z", Some(json!({"id": "z", "value": "2"})));
        set(&mut value, "/new/deep", Some(json!(true)));
        set(&mut value, "/missing/deep", None);

        assert_eq!(
            value,
            json!({"a": {"b": 1, "c": 2}, "list": [{"id": "z", "value": "2"}], "new": {"deep": true}})
        );
    }

    fn team() -> tablepro_keys::encoding::TeamId {
        tablepro_keys::encoding::TeamId(uuid::Uuid::from_u128(7))
    }
}
