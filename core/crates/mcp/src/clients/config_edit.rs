use super::catalog::ConfigFormat;
use super::json_value::JsonValue;
use super::{jsonc, merge, toml_table};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ConfigEditError {
    #[error("the file is not valid at byte {offset:?}")]
    InvalidSyntax { offset: Option<usize> },
    #[error("{path:?} appears more than once")]
    DuplicateKey { path: Vec<String> },
    #[error("{path:?} is not an object")]
    NotAnObject { path: Vec<String> },
    #[error("{path:?} is written in a form TablePro does not edit")]
    UnsupportedShape { path: Vec<String> },
    #[error("the entry holds a value the file format cannot hold")]
    UnsupportedValue,
    #[error("files in {0:?} are not edited")]
    UnsupportedFormat(ConfigFormat),
}

impl ConfigEditError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::InvalidSyntax { .. } => "invalid_syntax",
            Self::DuplicateKey { .. } => "duplicate_key",
            Self::NotAnObject { .. } => "not_an_object",
            Self::UnsupportedShape { .. } => "unsupported_shape",
            Self::UnsupportedValue => "unsupported_value",
            Self::UnsupportedFormat(_) => "unsupported_format",
        }
    }
}

// The server `name` in the object at `key_path`. Empty text reads as an
// empty object.
pub fn read_member(
    format: ConfigFormat,
    text: &str,
    key_path: &[String],
    name: &str,
) -> Result<Option<JsonValue>, ConfigEditError> {
    match format {
        ConfigFormat::Json | ConfigFormat::Jsonc => jsonc::member(text, key_path, name),
        ConfigFormat::Toml => toml_table::member(text, key_path, name),
        ConfigFormat::Yaml => Err(ConfigEditError::UnsupportedFormat(format)),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Upsert {
    // Writes each member given and keeps the entry's others.
    Merge,
    Replace,
}

// Creates what is missing on `key_path` and keeps the rest of the file.
// `template`, the catalog entry `value` was rendered from, decides which
// members of an entry already there are written over.
pub fn upsert_member(
    format: ConfigFormat,
    text: &str,
    key_path: &[String],
    name: &str,
    value: &JsonValue,
    template: &JsonValue,
) -> Result<String, ConfigEditError> {
    let (value, mode) = match read_member(format, text, key_path, name)? {
        Some(existing) if merge::transport_differs(&existing, template) => (
            merge::replace_keeping_choices(&existing, value, template),
            Upsert::Replace,
        ),
        Some(existing) => (merge::update_for(&existing, value, template), Upsert::Merge),
        None => (value.clone(), Upsert::Merge),
    };
    match format {
        ConfigFormat::Json | ConfigFormat::Jsonc => jsonc::upserting(text, key_path, name, &value, mode),
        ConfigFormat::Toml => toml_table::upserting(text, key_path, name, &value, mode),
        ConfigFormat::Yaml => Err(ConfigEditError::UnsupportedFormat(format)),
    }
}

// The text unchanged when the server is not there.
pub fn remove_member(
    format: ConfigFormat,
    text: &str,
    key_path: &[String],
    name: &str,
) -> Result<String, ConfigEditError> {
    match format {
        ConfigFormat::Json | ConfigFormat::Jsonc => jsonc::removing(text, key_path, name),
        ConfigFormat::Toml => toml_table::removing(text, key_path, name),
        ConfigFormat::Yaml => Err(ConfigEditError::UnsupportedFormat(format)),
    }
}

// Every server `name` in the objects `scope` reaches; `*` in the scope
// stands for any key at that level.
pub fn members_in_scope(
    format: ConfigFormat,
    text: &str,
    scope: &[String],
    name: &str,
) -> Result<Vec<JsonValue>, ConfigEditError> {
    match format {
        ConfigFormat::Json | ConfigFormat::Jsonc => jsonc::members_in_scope(text, scope, name),
        ConfigFormat::Toml => toml_table::members_in_scope(text, scope, name),
        ConfigFormat::Yaml => Err(ConfigEditError::UnsupportedFormat(format)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> JsonValue {
        serde_json::from_str(text).expect("JSON")
    }

    fn servers() -> Vec<String> {
        vec!["mcpServers".to_owned()]
    }

    fn copilot() -> (JsonValue, JsonValue) {
        (
            parse(
                r#"{"type": "http", "url": "{url}", "headers": {"Authorization": "{authorization}"}, "tools": ["*"]}"#,
            ),
            parse(
                r#"{"type": "http", "url": "http://127.0.0.1:23508/mcp", "headers": {"Authorization": "Bearer tp_new"},
                "tools": ["*"]}"#,
            ),
        )
    }

    #[test]
    fn an_update_never_widens_the_tools_or_turns_an_entry_back_on() {
        let (template, rendered) = copilot();
        let text = "{\n  \"mcpServers\": {\n    \"tablepro\": {\n      \"type\": \"http\",\n      \
\"url\": \"http://127.0.0.1:1/mcp\",\n      \"headers\": {\"Authorization\": \"Bearer tp_old\"},\n      \
// only this one\n      \"tools\": [\"list_connections\"],\n      \"disabled\": true\n    }\n  }\n}\n";

        let edited =
            upsert_member(ConfigFormat::Jsonc, text, &servers(), "tablepro", &rendered, &template).expect("an edit");

        assert_eq!(
            edited,
            "{\n  \"mcpServers\": {\n    \"tablepro\": {\n      \"type\": \"http\",\n      \
\"url\": \"http://127.0.0.1:23508/mcp\",\n      \"headers\": {\"Authorization\": \"Bearer tp_new\"},\n      \
// only this one\n      \"tools\": [\"list_connections\"],\n      \"disabled\": true\n    }\n  }\n}\n"
        );
    }

    #[test]
    fn a_new_entry_gets_every_member_the_template_has() {
        let (template, rendered) = copilot();

        let edited =
            upsert_member(ConfigFormat::Json, "{}", &servers(), "tablepro", &rendered, &template).expect("an edit");

        assert_eq!(
            read_member(ConfigFormat::Json, &edited, &servers(), "tablepro").expect("readable"),
            Some(rendered)
        );
    }

    #[test]
    fn a_stdio_entry_is_replaced_where_it_stands_keeping_the_users_tools() {
        let (template, rendered) = copilot();
        let text = r#"{"mcpServers": {"a": {}, "tablepro": {"command": "/x/tablepro-mcp", "args": ["-v"], "tools": ["q"]}, "b": {}}}"#;

        let edited =
            upsert_member(ConfigFormat::Json, text, &servers(), "tablepro", &rendered, &template).expect("an edit");

        assert_eq!(
            edited,
            r#"{"mcpServers": {"a": {}, "tablepro": {"type":"http","url":"http://127.0.0.1:23508/mcp","headers":{"Authorization":"Bearer tp_new"},"tools":["q"]}, "b": {}}}"#
        );
    }

    #[test]
    fn a_codex_table_keeps_its_restrictions_and_a_stdio_one_is_replaced_whole() {
        let template =
            parse(r#"{"url": "{url}", "http_headers": {"Authorization": "{authorization}"}, "enabled": true}"#);
        let rendered =
            parse(r#"{"url": "http://new", "http_headers": {"Authorization": "Bearer tp_new"}, "enabled": true}"#);
        let path = vec!["mcp_servers".to_owned()];
        let off = "[mcp_servers.tablepro]\nurl = \"http://old\"\nenabled = false\n\n\
[mcp_servers.tablepro.http_headers]\nAuthorization = \"Bearer tp_old\"\n";
        let stdio = "# mine\n[mcp_servers.tablepro]\ncommand = \"/x/tablepro-mcp\"\nargs = [\"-v\"]\n\n\
[mcp_servers.tablepro.env]\nA = \"1\"\n\n[profile]\nx = 1\n";

        let kept = upsert_member(ConfigFormat::Toml, off, &path, "tablepro", &rendered, &template).expect("an edit");
        let replaced =
            upsert_member(ConfigFormat::Toml, stdio, &path, "tablepro", &rendered, &template).expect("an edit");

        assert_eq!(
            kept,
            "[mcp_servers.tablepro]\nurl = \"http://new\"\nenabled = false\n\n\
[mcp_servers.tablepro.http_headers]\nAuthorization = \"Bearer tp_new\"\n"
        );
        assert_eq!(
            replaced,
            "# mine\n[mcp_servers.tablepro]\nurl = \"http://new\"\nhttp_headers = { Authorization = \"Bearer tp_new\" }\n\
enabled = true\n\n[profile]\nx = 1\n"
        );
    }
}
