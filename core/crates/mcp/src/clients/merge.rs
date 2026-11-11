use super::json_value::JsonValue;

const PLACEHOLDERS: [&str; 4] = ["command", "url", "authorization", "name"];

// No placeholder, but they decide how the client starts the server.
const ALWAYS_WRITTEN: [&str; 2] = ["type", "args"];

// Every spelling the catalog uses; a test below keeps them in step.
const STDIO_MEMBERS: [&str; 2] = ["command", "cmd"];
const HTTP_MEMBERS: [&str; 4] = ["url", "serverUrl", "httpUrl", "uri"];

// Only what reaches TablePro is written over, so an Update never widens
// a restriction the user set, such as `tools` or `disabled`.
pub(crate) fn update_for(existing: &JsonValue, rendered: &JsonValue, template: &JsonValue) -> JsonValue {
    filter(existing, rendered, Some(template), false)
}

fn filter(existing: &JsonValue, rendered: &JsonValue, template: Option<&JsonValue>, nested: bool) -> JsonValue {
    let (JsonValue::Object(have), JsonValue::Object(want)) = (existing, rendered) else {
        return rendered.clone();
    };
    JsonValue::Object(
        want.iter()
            .filter_map(|(key, value)| {
                let shape = template.and_then(|template| template.get(key));
                match lookup(have, key, nested) {
                    None => Some((key.clone(), value.clone())),
                    Some(found) if overwrites(key, shape, nested) => {
                        Some((key.clone(), filter(found, value, shape, true)))
                    }
                    Some(_) => None,
                }
            })
            .collect(),
    )
}

// As the editors match: exactly on top of the entry, ignoring case below.
fn lookup<'v>(members: &'v [(String, JsonValue)], key: &str, nested: bool) -> Option<&'v JsonValue> {
    members
        .iter()
        .find(|(name, _)| name == key)
        .or_else(|| {
            members
                .iter()
                .find(|(name, _)| nested && name.eq_ignore_ascii_case(key))
        })
        .map(|(_, value)| value)
}

fn overwrites(key: &str, template: Option<&JsonValue>, nested: bool) -> bool {
    (!nested && ALWAYS_WRITTEN.contains(&key)) || template.is_some_and(|template| holds(template, &PLACEHOLDERS))
}

fn holds(template: &JsonValue, names: &[&str]) -> bool {
    match template {
        JsonValue::String(text) => placeholder_names(text).any(|name| names.contains(&name)),
        JsonValue::Array(items) => items.iter().any(|item| holds(item, names)),
        JsonValue::Object(members) => members.iter().any(|(_, member)| holds(member, names)),
        _ => false,
    }
}

fn placeholder_names(text: &str) -> impl Iterator<Item = &str> {
    text.split('{')
        .skip(1)
        .filter_map(|after| after.split_once('}'))
        .map(|(expression, _)| expression.split('|').next().unwrap_or_default())
}

// The old transport's members go, but a limit the user set, such as `tools`, stays.
pub(crate) fn replace_keeping_choices(existing: &JsonValue, rendered: &JsonValue, template: &JsonValue) -> JsonValue {
    let JsonValue::Object(want) = rendered else {
        return rendered.clone();
    };
    JsonValue::Object(
        want.iter()
            .map(|(key, value)| {
                let chosen = !ALWAYS_WRITTEN.contains(&key.as_str())
                    && !template.get(key).is_some_and(|shape| holds(shape, &PLACEHOLDERS));
                match existing.get(key) {
                    Some(mine) if chosen => (key.clone(), mine.clone()),
                    _ => (key.clone(), value.clone()),
                }
            })
            .collect(),
    )
}

// Its members mean nothing to the other transport, so it is replaced.
pub(crate) fn transport_differs(existing: &JsonValue, template: &JsonValue) -> bool {
    let names_any = |members: &[&str]| members.iter().any(|member| existing.get(member).is_some());
    match (holds(template, &["command"]), holds(template, &["url"])) {
        (false, true) => names_any(&STDIO_MEMBERS),
        (true, false) => names_any(&HTTP_MEMBERS),
        _ => false,
    }
}

pub(crate) fn names_a_command(entry: &JsonValue) -> bool {
    STDIO_MEMBERS.iter().any(|member| entry.get(member).is_some())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clients::catalog::{ClientCatalog, ClientPlatform};

    fn parse(text: &str) -> JsonValue {
        serde_json::from_str(text).expect("JSON")
    }

    #[test]
    fn only_members_that_reach_tablepro_are_written_over() {
        let template = parse(
            r#"{"type": "http", "url": "{url}", "headers": {"Authorization": "{authorization}"},
            "tools": ["*"], "disabled": false, "args": []}"#,
        );
        let rendered = parse(
            r#"{"type": "http", "url": "http://new", "headers": {"Authorization": "Bearer tp_new"},
            "tools": ["*"], "disabled": false, "args": []}"#,
        );
        let existing = parse(
            r#"{"type": "sse", "url": "http://old", "headers": {"authorization": "Bearer tp_old"},
            "tools": ["list_connections"], "disabled": true, "args": ["-v"]}"#,
        );

        assert_eq!(
            update_for(&existing, &rendered, &template),
            parse(
                r#"{"type": "http", "url": "http://new", "headers": {"Authorization": "Bearer tp_new"}, "args": []}"#
            )
        );
    }

    #[test]
    fn a_member_the_entry_lacks_comes_from_the_template_and_one_it_has_stays_whole() {
        let template = parse(r#"{"url": "{url}", "tools": ["*"], "headers": {"X-Client": "tablepro"}}"#);
        let rendered = parse(r#"{"url": "http://new", "tools": ["*"], "headers": {"X-Client": "tablepro"}}"#);

        assert_eq!(
            update_for(&parse(r#"{"url": "http://old"}"#), &rendered, &template),
            rendered
        );
        assert_eq!(
            update_for(
                &parse(r#"{"url": "http://old", "headers": {"X-Team": "data"}}"#),
                &rendered,
                &template
            ),
            parse(r#"{"url": "http://new", "tools": ["*"]}"#)
        );
    }

    #[test]
    fn a_placeholder_with_a_filter_or_inside_text_still_counts() {
        assert!(holds(&parse(r#"{"a": ["x {command|uri} y"]}"#), &PLACEHOLDERS));
        assert!(holds(&parse(r#""Bearer {authorization}""#), &PLACEHOLDERS));
        assert!(!holds(&parse(r#"{"a": "{other}", "b": "{url"}"#), &PLACEHOLDERS));
    }

    #[test]
    fn an_entry_for_the_other_transport_is_told_apart() {
        let http = parse(r#"{"url": "{url}", "headers": {"Authorization": "{authorization}"}}"#);
        let stdio = parse(r#"{"command": "{command}", "args": []}"#);

        assert!(transport_differs(&parse(r#"{"command": "/x", "url": "u"}"#), &http));
        assert!(!transport_differs(&parse(r#"{"url": "u", "tools": []}"#), &http));
        assert!(transport_differs(&parse(r#"{"httpUrl": "u"}"#), &stdio));
        assert!(!transport_differs(&parse(r#"{"command": "/x"}"#), &stdio));
    }

    #[test]
    fn every_catalog_entry_names_its_target_where_the_transport_check_looks() {
        let catalog = ClientCatalog::bundled().expect("the bundled catalog");
        for platform in [ClientPlatform::Macos, ClientPlatform::Linux] {
            for client in catalog.clients_on(platform) {
                let Some(JsonValue::Object(members)) = client.spec(platform).and_then(|spec| spec.entry.as_ref())
                else {
                    continue;
                };
                for (key, member) in members {
                    if holds(member, &["command"]) {
                        assert!(STDIO_MEMBERS.contains(&key.as_str()), "{} {key}", client.id);
                    }
                    if holds(member, &["url"]) {
                        assert!(HTTP_MEMBERS.contains(&key.as_str()), "{} {key}", client.id);
                    }
                }
            }
        }
    }
}
