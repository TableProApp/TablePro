use super::catalog::{ConfigFormat, ConfigLocation, PlatformSpec};
use super::config_edit::{ConfigEditError, Upsert};
use super::json_value::{JsonValue, quote};
use super::toml_table;

// How a client reaches TablePro: the macOS bridge it starts, or the
// Linux server's address with the header that carries the token. The
// header is unknown while the server is off and the keyring unread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerTarget {
    Stdio { command: String },
    Http { url: String, authorization: Option<String> },
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TemplateError {
    #[error("the client has no entry to render")]
    NoEntry,
    #[error("unknown placeholder {0}")]
    UnknownPlaceholder(String),
    #[error("unknown filter {0}")]
    UnknownFilter(String),
    #[error("no value for {0}")]
    MissingValue(&'static str),
    #[error("a placeholder is not closed")]
    Unterminated,
    #[error("an entry placeholder needs the json filter")]
    EntryNeedsJson,
}

impl TemplateError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::NoEntry => "no_entry",
            Self::UnknownPlaceholder(_) => "unknown_placeholder",
            Self::UnknownFilter(_) => "unknown_filter",
            Self::MissingValue(_) => "missing_value",
            Self::Unterminated => "unterminated",
            Self::EntryNeedsJson => "entry_needs_json",
        }
    }
}

enum Piece {
    Text(String),
    Json(JsonValue),
}

pub struct TemplateRenderer<'a> {
    server_name: &'a str,
    target: &'a ServerTarget,
}

impl<'a> TemplateRenderer<'a> {
    pub fn new(server_name: &'a str, target: &'a ServerTarget) -> Self {
        Self { server_name, target }
    }

    pub fn entry(&self, spec: &PlatformSpec) -> Result<JsonValue, TemplateError> {
        let template = spec.entry.as_ref().ok_or(TemplateError::NoEntry)?;
        self.fill_value(template)
    }

    pub fn arguments(&self, template: &[String], entry: &JsonValue) -> Result<Vec<String>, TemplateError> {
        template
            .iter()
            .map(|argument| self.fill(argument, Some(entry)))
            .collect()
    }

    pub fn url(&self, template: &str, entry: &JsonValue) -> Result<String, TemplateError> {
        self.fill(template, Some(entry))
    }

    fn fill_value(&self, template: &JsonValue) -> Result<JsonValue, TemplateError> {
        Ok(match template {
            JsonValue::String(text) => JsonValue::String(self.fill(text, None)?),
            JsonValue::Array(items) => JsonValue::Array(
                items
                    .iter()
                    .map(|item| self.fill_value(item))
                    .collect::<Result<_, _>>()?,
            ),
            JsonValue::Object(members) => JsonValue::Object(
                members
                    .iter()
                    .map(|(name, member)| Ok((name.clone(), self.fill_value(member)?)))
                    .collect::<Result<_, TemplateError>>()?,
            ),
            scalar => scalar.clone(),
        })
    }

    fn fill(&self, template: &str, entry: Option<&JsonValue>) -> Result<String, TemplateError> {
        let mut out = String::with_capacity(template.len());
        let mut rest = template;
        while let Some(open) = rest.find('{') {
            out.push_str(&rest[..open]);
            let after = &rest[open + 1..];
            let close = after.find('}').ok_or(TemplateError::Unterminated)?;
            out.push_str(&self.expand(&after[..close], entry)?);
            rest = &after[close + 1..];
        }
        out.push_str(rest);
        Ok(out)
    }

    fn expand(&self, expression: &str, entry: Option<&JsonValue>) -> Result<String, TemplateError> {
        let mut parts = expression.split('|');
        let name = parts.next().unwrap_or_default();
        let mut piece = match name {
            "name" => Piece::Text(self.server_name.to_owned()),
            "url" | "authorization" | "command" => Piece::Text(self.value(name)?),
            "entry" => Piece::Json(entry.ok_or(TemplateError::NoEntry)?.clone()),
            "entryWithName" => Piece::Json(with_name(entry.ok_or(TemplateError::NoEntry)?, self.server_name)),
            other => return Err(TemplateError::UnknownPlaceholder(other.to_owned())),
        };
        for filter in parts {
            piece = match (filter, piece) {
                ("json", Piece::Json(value)) => Piece::Text(value.to_compact()),
                ("base64", Piece::Text(text)) => Piece::Text(base64(text.as_bytes())),
                ("uri", Piece::Text(text)) => Piece::Text(percent_encode(&text)),
                (other, _) => return Err(TemplateError::UnknownFilter(other.to_owned())),
            };
        }
        match piece {
            Piece::Text(text) => Ok(text),
            Piece::Json(_) => Err(TemplateError::EntryNeedsJson),
        }
    }

    fn value(&self, name: &str) -> Result<String, TemplateError> {
        match (name, self.target) {
            ("command", ServerTarget::Stdio { command }) => Ok(command.clone()),
            ("url", ServerTarget::Http { url, .. }) => Ok(url.clone()),
            ("authorization", ServerTarget::Http { authorization, .. }) => authorization
                .clone()
                .ok_or(TemplateError::MissingValue("authorization")),
            ("command", _) => Err(TemplateError::MissingValue("command")),
            ("url", _) => Err(TemplateError::MissingValue("url")),
            _ => Err(TemplateError::MissingValue("authorization")),
        }
    }
}

fn with_name(entry: &JsonValue, server_name: &str) -> JsonValue {
    let mut members = vec![("name".to_owned(), JsonValue::String(server_name.to_owned()))];
    if let JsonValue::Object(existing) = entry {
        members.extend(existing.iter().filter(|(name, _)| name != "name").cloned());
    }
    JsonValue::Object(members)
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let triple = chunk
            .iter()
            .enumerate()
            .fold(0u32, |acc, (index, byte)| acc | (u32::from(*byte) << (16 - 8 * index)));
        for index in 0..4 {
            if index <= chunk.len() {
                let sextet = (triple >> (18 - 6 * index)) & 0x3f;
                out.push(char::from(ALPHABET[sextet as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

// Everything outside RFC 3986's unreserved set is escaped.
fn percent_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

// The text a user pastes: the entry under its key path, in the file's
// format. A client with no file takes the common `mcpServers` form.
pub fn snippet(
    location: Option<&ConfigLocation>,
    server_name: &str,
    entry: &JsonValue,
) -> Result<String, ConfigEditError> {
    let Some(location) = location else {
        let keyed = nest(&["mcpServers".to_owned()], server_name, entry);
        return Ok(format!("{}\n", keyed.to_pretty("  ", "")));
    };
    match location.format {
        ConfigFormat::Json | ConfigFormat::Jsonc => Ok(format!(
            "{}\n",
            nest(&location.key_path, server_name, entry).to_pretty("  ", "")
        )),
        ConfigFormat::Toml => toml_table::upserting("", &location.key_path, server_name, entry, Upsert::Merge),
        ConfigFormat::Yaml => {
            let mut out = String::new();
            write_yaml(&nest(&location.key_path, server_name, entry), "", &mut out);
            Ok(out)
        }
    }
}

fn nest(key_path: &[String], server_name: &str, entry: &JsonValue) -> JsonValue {
    let inner = JsonValue::Object(vec![(server_name.to_owned(), entry.clone())]);
    key_path
        .iter()
        .rev()
        .fold(inner, |value, key| JsonValue::Object(vec![(key.clone(), value)]))
}

// Block style for nested objects and lists, every string double-quoted,
// which YAML reads with JSON's escapes.
fn write_yaml(value: &JsonValue, indent: &str, out: &mut String) {
    match value {
        JsonValue::Object(members) => {
            for (name, member) in members {
                out.push_str(indent);
                out.push_str(&yaml_key(name));
                out.push(':');
                write_yaml_child(member, indent, out);
            }
        }
        JsonValue::Array(items) => {
            for item in items {
                out.push_str(indent);
                out.push('-');
                write_yaml_child(item, indent, out);
            }
        }
        scalar => {
            out.push_str(indent);
            out.push_str(&yaml_scalar(scalar));
            out.push('\n');
        }
    }
}

fn write_yaml_child(value: &JsonValue, indent: &str, out: &mut String) {
    match value {
        JsonValue::Object(members) if !members.is_empty() => {
            out.push('\n');
            write_yaml(value, &format!("{indent}  "), out);
        }
        JsonValue::Array(items) if !items.is_empty() => {
            out.push('\n');
            write_yaml(value, &format!("{indent}  "), out);
        }
        other => {
            out.push(' ');
            out.push_str(&yaml_scalar(other));
            out.push('\n');
        }
    }
}

fn yaml_key(name: &str) -> String {
    match name
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
        && !name.is_empty()
    {
        true => name.to_owned(),
        false => quote(name),
    }
}

fn yaml_scalar(value: &JsonValue) -> String {
    match value {
        JsonValue::Object(_) => "{}".to_owned(),
        JsonValue::Array(_) => "[]".to_owned(),
        JsonValue::String(text) => quote(text),
        other => other.to_compact(),
    }
}

// A command a user can paste into a POSIX shell. The app itself never
// runs it through one.
pub fn command_line(binary: &str, arguments: &[String]) -> String {
    std::iter::once(binary)
        .chain(arguments.iter().map(String::as_str))
        .map(shell_word)
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_word(word: &str) -> String {
    let plain = !word.is_empty()
        && word
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"@%+=:,./_-".contains(&byte));
    match plain {
        true => word.to_owned(),
        false => format!("'{}'", word.replace('\'', r"'\''")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clients::catalog::{ClientCatalog, ClientPlatform, InstallMethod};

    fn http(authorization: Option<&str>) -> ServerTarget {
        ServerTarget::Http {
            url: "http://127.0.0.1:23508/mcp".to_owned(),
            authorization: authorization.map(str::to_owned),
        }
    }

    fn catalog() -> ClientCatalog {
        ClientCatalog::bundled().expect("the bundled catalog")
    }

    #[test]
    fn every_linux_entry_renders_with_the_address_and_header() {
        let catalog = catalog();
        let target = http(Some("Bearer tp_abc"));
        let renderer = TemplateRenderer::new(&catalog.server_name, &target);

        for client in catalog.clients_on(ClientPlatform::Linux) {
            let spec = client.spec(ClientPlatform::Linux).expect("a spec");
            if spec.entry.is_none() {
                continue;
            }
            let entry = renderer
                .entry(spec)
                .unwrap_or_else(|error| panic!("{}: {error}", client.id));
            let text = entry.to_compact();
            assert!(text.contains("http://127.0.0.1:23508/mcp"), "{}", client.id);
            assert!(text.contains("\"Bearer tp_abc\""), "{}", client.id);
            assert!(
                !text.contains("{url}") && !text.contains("{authorization}"),
                "{}",
                client.id
            );
            let location = catalog.location(client, ClientPlatform::Linux);
            snippet(location, &catalog.server_name, &entry).unwrap_or_else(|error| panic!("{}: {error}", client.id));
        }
    }

    #[test]
    fn every_macos_entry_and_link_renders_with_the_bridge() {
        let catalog = catalog();
        let target = ServerTarget::Stdio {
            command: "/Applications/TablePro.app/Contents/MacOS/tablepro-mcp".to_owned(),
        };
        let renderer = TemplateRenderer::new(&catalog.server_name, &target);

        for client in catalog.clients_on(ClientPlatform::Macos) {
            let spec = client.spec(ClientPlatform::Macos).expect("a spec");
            let Ok(entry) = renderer.entry(spec) else {
                assert!(spec.unsupported.is_some(), "{}", client.id);
                continue;
            };
            for method in &spec.install {
                match method {
                    InstallMethod::Deeplink(link) => {
                        let url = renderer.url(&link.url, &entry).expect("a link");
                        assert!(url.starts_with(&link.scheme), "{url}");
                    }
                    InstallMethod::Cli(cli) => {
                        renderer.arguments(&cli.add, &entry).expect("arguments");
                    }
                    InstallMethod::File => {}
                }
            }
        }
    }

    #[test]
    fn the_claude_code_command_carries_the_whole_header_in_one_argument() {
        let catalog = catalog();
        let target = http(Some("Bearer tp_abc"));
        let renderer = TemplateRenderer::new(&catalog.server_name, &target);
        let spec = catalog
            .client("claude-code")
            .and_then(|client| client.spec(ClientPlatform::Linux))
            .expect("Claude Code on Linux");
        let entry = renderer.entry(spec).expect("an entry");
        let Some(InstallMethod::Cli(cli)) = spec.install.first() else {
            panic!("Claude Code installs through its CLI");
        };

        let arguments = renderer.arguments(&cli.add, &entry).expect("arguments");

        assert_eq!(
            arguments,
            [
                "mcp",
                "add",
                "--scope",
                "user",
                "--transport",
                "http",
                "tablepro",
                "http://127.0.0.1:23508/mcp",
                "--header",
                "Authorization: Bearer tp_abc"
            ]
        );
        assert_eq!(
            command_line("claude", &arguments),
            "claude mcp add --scope user --transport http tablepro http://127.0.0.1:23508/mcp --header \
'Authorization: Bearer tp_abc'"
        );
    }

    #[test]
    fn filters_encode_the_entry_for_a_link() {
        let target = ServerTarget::Stdio {
            command: "/A B/x".to_owned(),
        };
        let renderer = TemplateRenderer::new("tablepro", &target);
        let entry = JsonValue::Object(vec![("command".to_owned(), JsonValue::String("/A B/x".to_owned()))]);

        assert_eq!(
            renderer.url("{entry|json}", &entry),
            Ok(r#"{"command":"/A B/x"}"#.to_owned())
        );
        assert_eq!(
            renderer.url("{entry|json|base64}", &entry),
            Ok("eyJjb21tYW5kIjoiL0EgQi94In0=".to_owned())
        );
        assert_eq!(
            renderer.url("{entry|json|base64|uri}", &entry),
            Ok("eyJjb21tYW5kIjoiL0EgQi94In0%3D".to_owned())
        );
        assert_eq!(
            renderer.url("x?{entryWithName|json|uri}", &entry),
            Ok("x?%7B%22name%22%3A%22tablepro%22%2C%22command%22%3A%22%2FA%20B%2Fx%22%7D".to_owned())
        );
        assert_eq!(renderer.url("{command|uri}", &entry), Ok("%2FA%20B%2Fx".to_owned()));
        assert_eq!(renderer.url("{entry}", &entry), Err(TemplateError::EntryNeedsJson));
        assert_eq!(
            renderer.url("{nope}", &entry).map_err(|error| error.code()),
            Err("unknown_placeholder")
        );
        assert_eq!(renderer.url("{url}", &entry), Err(TemplateError::MissingValue("url")));
    }

    #[test]
    fn base64_pads_to_whole_quads() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foob"), "Zm9vYg==");
    }

    #[test]
    fn an_entry_without_the_token_cannot_be_rendered() {
        let catalog = catalog();
        let target = http(None);
        let spec = catalog
            .client("cursor")
            .and_then(|client| client.spec(ClientPlatform::Linux))
            .expect("Cursor on Linux");

        let refused = TemplateRenderer::new(&catalog.server_name, &target).entry(spec);

        assert_eq!(refused, Err(TemplateError::MissingValue("authorization")));
    }

    #[test]
    fn snippets_nest_the_entry_in_the_file_format() {
        let catalog = catalog();
        let target = http(Some("Bearer tp_abc"));
        let renderer = TemplateRenderer::new(&catalog.server_name, &target);
        let render = |id: &str| {
            let client = catalog.client(id).expect("a client");
            let spec = client.spec(ClientPlatform::Linux).expect("a spec");
            let entry = renderer.entry(spec).expect("an entry");
            snippet(catalog.location(client, ClientPlatform::Linux), "tablepro", &entry).expect("a snippet")
        };

        assert!(render("cursor").starts_with("{\n  \"mcpServers\": {\n    \"tablepro\": {\n      \"url\""));
        assert_eq!(
            render("codex"),
            "[mcp_servers.tablepro]\nurl = \"http://127.0.0.1:23508/mcp\"\nhttp_headers = { Authorization = \
\"Bearer tp_abc\" }\n"
        );
        assert!(render("goose").starts_with(
            "extensions:\n  tablepro:\n    type: \"streamable_http\"\n    name: \"tablepro\"\n    enabled: true\n"
        ));
        assert!(render("goose").contains("    headers:\n      Authorization: \"Bearer tp_abc\"\n    envs: {}\n"));
        assert!(render("jetbrains-ai").starts_with("{\n  \"mcpServers\": {\n    \"tablepro\""));
    }

    #[test]
    fn shell_words_are_quoted_only_when_needed() {
        assert_eq!(shell_word("plain-word_1.2"), "plain-word_1.2");
        assert_eq!(shell_word("two words"), "'two words'");
        assert_eq!(shell_word("it's"), r"'it'\''s'");
        assert_eq!(shell_word(""), "''");
    }
}
