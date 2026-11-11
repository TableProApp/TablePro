use toml_edit::{Array, DocumentMut, InlineTable, Item, Table, TableLike, Value};

use super::config_edit::{ConfigEditError, Upsert};
use super::json_value::JsonValue;

// The server is a `[<key path>.<name>]` table. A server written any other
// way, inline or with dotted keys, is read but never rewritten.
pub(crate) fn member(text: &str, key_path: &[String], name: &str) -> Result<Option<JsonValue>, ConfigEditError> {
    let document = parse(text)?;
    let mut table: &dyn TableLike = document.as_table();
    for (depth, key) in key_path.iter().enumerate() {
        let Some(item) = table.get(key) else {
            return Ok(None);
        };
        table = item.as_table_like().ok_or_else(|| ConfigEditError::NotAnObject {
            path: key_path[..=depth].to_vec(),
        })?;
    }
    Ok(table.get(name).map(item_to_json))
}

pub(crate) fn upserting(
    text: &str,
    key_path: &[String],
    name: &str,
    value: &JsonValue,
    mode: Upsert,
) -> Result<String, ConfigEditError> {
    let JsonValue::Object(members) = value else {
        return Err(ConfigEditError::UnsupportedValue);
    };
    let mut document = parse(text)?;
    let mut table = document.as_table_mut();
    for (depth, key) in key_path.iter().enumerate() {
        let current = table;
        let item = current.entry(key).or_insert_with(|| {
            let mut implicit = Table::new();
            implicit.set_implicit(true);
            Item::Table(implicit)
        });
        table = match item {
            Item::Table(inner) if !inner.is_dotted() => inner,
            _ => {
                return Err(ConfigEditError::UnsupportedShape {
                    path: key_path[..=depth].to_vec(),
                });
            }
        };
    }
    match table.get_mut(name) {
        None => {
            let mut server = Table::new();
            fill(&mut server, members)?;
            table.insert(name, Item::Table(server));
        }
        // Clearing the table keeps its header and the comments above it.
        Some(Item::Table(server)) if !server.is_dotted() && mode == Upsert::Replace => {
            server.clear();
            fill(server, members)?;
        }
        Some(Item::Table(server)) if !server.is_dotted() => merge(server, members, false)?,
        Some(_) => return Err(unsupported(key_path, name)),
    }
    Ok(document.to_string())
}

pub(crate) fn removing(text: &str, key_path: &[String], name: &str) -> Result<String, ConfigEditError> {
    let mut document = parse(text)?;
    let mut table = document.as_table_mut();
    for (depth, key) in key_path.iter().enumerate() {
        let current = table;
        table = match current.get_mut(key) {
            None => return Ok(text.to_owned()),
            Some(Item::Table(inner)) if !inner.is_dotted() => inner,
            Some(_) => {
                return Err(ConfigEditError::UnsupportedShape {
                    path: key_path[..=depth].to_vec(),
                });
            }
        };
    }
    match table.get(name) {
        None => return Ok(text.to_owned()),
        Some(Item::Table(server)) if !server.is_dotted() => {}
        Some(_) => return Err(unsupported(key_path, name)),
    }
    table.remove(name);
    Ok(document.to_string())
}

pub(crate) fn members_in_scope(text: &str, scope: &[String], name: &str) -> Result<Vec<JsonValue>, ConfigEditError> {
    let document = parse(text)?;
    let mut found = Vec::new();
    collect_in_scope(document.as_table(), scope, name, &mut found);
    Ok(found)
}

fn collect_in_scope(table: &dyn TableLike, scope: &[String], name: &str, found: &mut Vec<JsonValue>) {
    let Some((first, rest)) = scope.split_first() else {
        found.extend(table.get(name).map(item_to_json));
        return;
    };
    for (key, item) in table.iter() {
        if (first == "*" || first.as_str() == key)
            && let Some(inner) = item.as_table_like()
        {
            collect_in_scope(inner, rest, name, found);
        }
    }
}

fn unsupported(key_path: &[String], name: &str) -> ConfigEditError {
    let mut path = key_path.to_vec();
    path.push(name.to_owned());
    ConfigEditError::UnsupportedShape { path }
}

fn parse(text: &str) -> Result<DocumentMut, ConfigEditError> {
    text.parse::<DocumentMut>()
        .map_err(|error| ConfigEditError::InvalidSyntax {
            offset: error.span().map(|span| span.start),
        })
}

fn fill(table: &mut Table, members: &[(String, JsonValue)]) -> Result<(), ConfigEditError> {
    for (key, member) in members {
        table.insert(key, Item::Value(to_toml(member)?));
    }
    Ok(())
}

// Rewrites only the members given: the user's other keys and subtables
// stay, and a replaced value keeps its comment. Below the top of the
// entry, as in a header table, a key matches ignoring case.
fn merge(table: &mut dyn TableLike, members: &[(String, JsonValue)], nested: bool) -> Result<(), ConfigEditError> {
    for (key, member) in members {
        let Some(existing) = matching_key(table, key, nested) else {
            table.insert(key, Item::Value(to_toml(member)?));
            continue;
        };
        let Some(item) = table.get_mut(&existing) else {
            continue;
        };
        if let JsonValue::Object(inner) = member
            && let Some(sub) = item.as_table_like_mut()
        {
            merge(sub, inner, true)?;
            continue;
        }
        let mut value = to_toml(member)?;
        if let Item::Value(old) = &*item {
            *value.decor_mut() = old.decor().clone();
        }
        *item = Item::Value(value);
    }
    Ok(())
}

fn matching_key(table: &dyn TableLike, key: &str, nested: bool) -> Option<String> {
    if table.contains_key(key) {
        return Some(key.to_owned());
    }
    nested
        .then(|| {
            table
                .iter()
                .map(|(name, _)| name)
                .find(|name| name.eq_ignore_ascii_case(key))
                .map(str::to_owned)
        })
        .flatten()
}

fn to_toml(value: &JsonValue) -> Result<Value, ConfigEditError> {
    Ok(match value {
        JsonValue::String(text) => Value::from(text.as_str()),
        JsonValue::Bool(flag) => Value::from(*flag),
        JsonValue::Number(number) => match (number.as_i64(), number.as_f64()) {
            (Some(integer), _) => Value::from(integer),
            (None, Some(float)) => Value::from(float),
            (None, None) => return Err(ConfigEditError::UnsupportedValue),
        },
        JsonValue::Array(items) => Value::Array(items.iter().map(to_toml).collect::<Result<Array, _>>()?),
        JsonValue::Object(members) => {
            let mut inline = InlineTable::new();
            for (key, member) in members {
                inline.insert(key, to_toml(member)?);
            }
            Value::InlineTable(inline)
        }
        JsonValue::Null => return Err(ConfigEditError::UnsupportedValue),
    })
}

fn item_to_json(item: &Item) -> JsonValue {
    match item {
        Item::Value(value) => value_to_json(value),
        Item::Table(table) => table_to_json(table),
        Item::ArrayOfTables(tables) => JsonValue::Array(tables.iter().map(table_to_json).collect()),
        Item::None => JsonValue::Null,
    }
}

fn table_to_json(table: &Table) -> JsonValue {
    JsonValue::Object(
        table
            .iter()
            .map(|(key, item)| (key.to_owned(), item_to_json(item)))
            .collect(),
    )
}

fn value_to_json(value: &Value) -> JsonValue {
    match value {
        Value::String(text) => JsonValue::String(text.value().clone()),
        Value::Integer(integer) => JsonValue::Number((*integer.value()).into()),
        Value::Float(float) => serde_json::Number::from_f64(*float.value()).map_or(JsonValue::Null, JsonValue::Number),
        Value::Boolean(flag) => JsonValue::Bool(*flag.value()),
        Value::Datetime(datetime) => JsonValue::String(datetime.value().to_string()),
        Value::Array(items) => JsonValue::Array(items.iter().map(value_to_json).collect()),
        Value::InlineTable(table) => JsonValue::Object(
            table
                .iter()
                .map(|(key, member)| (key.to_owned(), value_to_json(member)))
                .collect(),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn path() -> Vec<String> {
        vec!["mcp_servers".to_owned()]
    }

    fn entry(url: &str) -> JsonValue {
        JsonValue::Object(vec![
            ("url".to_owned(), JsonValue::String(url.to_owned())),
            (
                "http_headers".to_owned(),
                JsonValue::Object(vec![(
                    "Authorization".to_owned(),
                    JsonValue::String("Bearer tp_x".to_owned()),
                )]),
            ),
        ])
    }

    #[test]
    fn a_new_server_table_is_added_and_the_rest_is_kept() {
        let text = "# Codex\nmodel = \"o4\"\n\n[mcp_servers.other]\ncommand = \"/bin/other\" # keep\n";

        let edited = upserting(
            text,
            &path(),
            "tablepro",
            &entry("http://127.0.0.1:1/mcp"),
            Upsert::Merge,
        )
        .expect("an edit");

        assert_eq!(
            edited,
            "# Codex\nmodel = \"o4\"\n\n[mcp_servers.other]\ncommand = \"/bin/other\" # keep\n\n\
[mcp_servers.tablepro]\nurl = \"http://127.0.0.1:1/mcp\"\nhttp_headers = { Authorization = \"Bearer tp_x\" }\n"
        );
        assert_eq!(
            member(&edited, &path(), "tablepro").expect("readable"),
            Some(entry("http://127.0.0.1:1/mcp"))
        );
    }

    #[test]
    fn an_update_rewrites_only_what_the_entry_renders() {
        let text = "[mcp_servers.tablepro]\nurl = \"old\" # mine\nstartup_timeout_sec = 20\n\n\
[mcp_servers.tablepro.env]\nA = \"1\"\n\n[profile]\nx = 1\n";

        let edited = upserting(text, &path(), "tablepro", &entry("new"), Upsert::Merge).expect("an edit");

        assert!(
            edited.starts_with("[mcp_servers.tablepro]\nurl = \"new\" # mine\nstartup_timeout_sec = 20\n"),
            "{edited}"
        );
        assert!(
            edited.contains("http_headers = { Authorization = \"Bearer tp_x\" }"),
            "{edited}"
        );
        assert!(edited.contains("[mcp_servers.tablepro.env]\nA = \"1\"\n"), "{edited}");
        assert!(edited.ends_with("[profile]\nx = 1\n"), "{edited}");
        let server = member(&edited, &path(), "tablepro")
            .expect("readable")
            .expect("the server");
        assert_eq!(server.get("url"), Some(&JsonValue::String("new".to_owned())));
        assert!(server.get("env").is_some() && server.get("startup_timeout_sec").is_some());
    }

    #[test]
    fn an_update_keeps_other_headers_and_the_spelling_of_the_one_it_replaces() {
        let text = "[mcp_servers.tablepro]\nurl = \"old\"\n\n[mcp_servers.tablepro.http_headers]\n\
authorization = \"Bearer tp_old\"\nX-Team = \"data\"\n";

        let edited = upserting(text, &path(), "tablepro", &entry("new"), Upsert::Merge).expect("an edit");

        assert!(
            edited
                .contains("[mcp_servers.tablepro.http_headers]\nauthorization = \"Bearer tp_x\"\nX-Team = \"data\"\n"),
            "{edited}"
        );
        assert!(
            !edited.contains("Authorization") && !edited.contains("tp_old"),
            "{edited}"
        );
    }

    #[test]
    fn a_server_written_inline_or_dotted_is_read_but_not_rewritten() {
        let inline = "[mcp_servers]\ntablepro = { url = \"x\" }\n";
        let dotted = "mcp_servers.tablepro.url = \"x\"\n";

        assert!(member(inline, &path(), "tablepro").expect("readable").is_some());
        assert_eq!(
            upserting(inline, &path(), "tablepro", &entry("y"), Upsert::Merge).map_err(|error| error.code()),
            Err("unsupported_shape")
        );
        assert_eq!(
            upserting(dotted, &path(), "tablepro", &entry("y"), Upsert::Merge).map_err(|error| error.code()),
            Err("unsupported_shape")
        );
        assert_eq!(
            removing(inline, &path(), "tablepro").map_err(|error| error.code()),
            Err("unsupported_shape")
        );
    }

    #[test]
    fn removing_takes_only_the_server_table() {
        let text = "a = 1\n\n[mcp_servers.tablepro]\nurl = \"x\"\n\n[mcp_servers.other]\ncommand = \"y\"\n";

        let removed = removing(text, &path(), "tablepro").expect("an edit");

        assert_eq!(removed, "a = 1\n\n[mcp_servers.other]\ncommand = \"y\"\n");
        assert_eq!(removing(&removed, &path(), "tablepro").expect("no edit"), removed);
    }

    #[test]
    fn every_server_in_a_scope_is_found() {
        let text = "[projects.a.mcp_servers.tablepro]\nurl = \"x\"\n\n[projects.b.mcp_servers.other]\nurl = \"y\"\n";
        let scope: Vec<String> = ["projects", "*", "mcp_servers"].map(str::to_owned).to_vec();

        let found = members_in_scope(text, &scope, "tablepro").expect("readable");

        assert_eq!(found.len(), 1);
        assert_eq!(found[0].get("url"), Some(&JsonValue::String("x".to_owned())));
    }

    #[test]
    fn a_broken_file_is_refused() {
        assert_eq!(
            upserting("[mcp_servers\n", &path(), "tablepro", &entry("y"), Upsert::Merge).map_err(|error| error.code()),
            Err("invalid_syntax")
        );
    }
}
