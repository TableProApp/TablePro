use super::catalog::{ConfigFormat, ConfigLocation};
use super::config_edit;
use super::json_value::JsonValue;
use super::merge;
use super::template::ServerTarget;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClientConfigStatus {
    NotConfigured,
    Current,
    // Current, but turned off in the client.
    Disabled,
    Stale(StaleReason),
    // Set up only where TablePro does not install, such as one project.
    OtherScope,
    Unreadable,
    // The client keeps its setup where TablePro cannot read it.
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StaleReason {
    CommandMissing,
    OtherCommand,
    OtherUrl,
    OtherToken,
    // The entry TablePro writes is current, but an entry in another
    // scope, which the client prefers there, is not.
    Shadowed,
}

impl ClientConfigStatus {
    pub fn is_configured(self) -> bool {
        matches!(self, Self::Current | Self::Disabled | Self::Stale(_))
    }
}

enum Step {
    Key(String),
    Index(usize),
}

// `template` is the catalog's entry before rendering: where it puts a
// placeholder is where the file has to hold the value. `config_text` is
// None when the file does not exist. With no authorization known, as
// while the Linux server is off, only the address is compared.
pub fn evaluate_status(
    config_text: Option<&str>,
    location: Option<&ConfigLocation>,
    server_name: &str,
    template: &JsonValue,
    target: &ServerTarget,
    file_exists: impl Fn(&str) -> bool,
) -> ClientConfigStatus {
    let Some(location) = location.filter(|location| location.format != ConfigFormat::Yaml) else {
        return ClientConfigStatus::Unknown;
    };
    let Some(text) = config_text else {
        return ClientConfigStatus::NotConfigured;
    };
    let (Ok(actual), Ok(scoped)) = (
        own_member(text, location, server_name),
        scoped_members(text, location, server_name),
    ) else {
        return ClientConfigStatus::Unreadable;
    };
    let stale = |entry: &JsonValue| match target {
        ServerTarget::Stdio { command } => stdio_reason(template, entry, command, &file_exists),
        ServerTarget::Http { url, authorization } => http_reason(template, entry, url, authorization.as_deref()),
    };
    let Some(actual) = actual else {
        return match scoped.is_empty() {
            true => ClientConfigStatus::NotConfigured,
            false => ClientConfigStatus::OtherScope,
        };
    };
    // Before stale: the client does not use it, and an Update leaves it off.
    if turned_off(&actual) {
        return ClientConfigStatus::Disabled;
    }
    if let Some(reason) = stale(&actual) {
        return ClientConfigStatus::Stale(reason);
    }
    match scoped.iter().any(|entry| stale(entry).is_some()) {
        true => ClientConfigStatus::Stale(StaleReason::Shadowed),
        false => ClientConfigStatus::Current,
    }
}

// The entry where TablePro writes it, or where an older layout of the
// same file kept it.
fn own_member(
    text: &str,
    location: &ConfigLocation,
    server_name: &str,
) -> Result<Option<JsonValue>, config_edit::ConfigEditError> {
    for key_path in std::iter::once(&location.key_path).chain(&location.alternate_key_paths) {
        if let Some(found) = config_edit::read_member(location.format, text, key_path, server_name)? {
            return Ok(Some(found));
        }
    }
    Ok(None)
}

fn scoped_members(
    text: &str,
    location: &ConfigLocation,
    server_name: &str,
) -> Result<Vec<JsonValue>, config_edit::ConfigEditError> {
    let mut found = Vec::new();
    for scope in &location.other_scopes {
        found.extend(config_edit::members_in_scope(
            location.format,
            text,
            scope,
            server_name,
        )?);
    }
    Ok(found)
}

// Clients spell it either way; Codex's TOML as `enabled = false`.
fn turned_off(entry: &JsonValue) -> bool {
    entry.get("disabled") == Some(&JsonValue::Bool(true)) || entry.get("enabled") == Some(&JsonValue::Bool(false))
}

fn stdio_reason(
    template: &JsonValue,
    actual: &JsonValue,
    command: &str,
    file_exists: &impl Fn(&str) -> bool,
) -> Option<StaleReason> {
    let written = locate(template, "{command}").and_then(|path| follow(actual, &path));
    match written.and_then(JsonValue::as_str) {
        Some(written) if written == command => None,
        Some(written) if !file_exists(written) => Some(StaleReason::CommandMissing),
        _ => Some(StaleReason::OtherCommand),
    }
}

fn http_reason(
    template: &JsonValue,
    actual: &JsonValue,
    url: &str,
    authorization: Option<&str>,
) -> Option<StaleReason> {
    // A client may start the program and never read the url beside it.
    if merge::names_a_command(actual) {
        return Some(StaleReason::OtherCommand);
    }
    let written = locate(template, "{url}")
        .and_then(|path| follow(actual, &path))
        .and_then(JsonValue::as_str);
    if !written.is_some_and(|written| same_endpoint(written, url)) {
        return Some(StaleReason::OtherUrl);
    }
    let (Some(authorization), Some(path)) = (authorization, locate(template, "{authorization}")) else {
        return None;
    };
    let expected = follow(template, &path)
        .and_then(JsonValue::as_str)
        .map(|shape| shape.replace("{authorization}", authorization));
    let written = follow(actual, &path).and_then(JsonValue::as_str).map(str::trim);
    match (written, expected) {
        (Some(written), Some(expected)) if written == expected.trim() => None,
        _ => Some(StaleReason::OtherToken),
    }
}

// The port and path decide it: the server listens on the loopback only,
// and a client may spell it 127.0.0.1 or localhost.
fn same_endpoint(written: &str, expected: &str) -> bool {
    endpoint(written).is_some_and(|written| Some(written) == endpoint(expected))
}

fn endpoint(url: &str) -> Option<(u16, String)> {
    let rest = url.trim();
    let scheme_end = rest.find("://")?;
    if !rest[..scheme_end].eq_ignore_ascii_case("http") {
        return None;
    }
    let rest = &rest[scheme_end + 3..];
    let (authority, path) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
    let port = match authority.rsplit_once(':') {
        Some((host, port)) if !host.ends_with(']') || authority.starts_with('[') => port.parse().ok()?,
        _ => 80,
    };
    let path = path.split(['?', '#']).next().unwrap_or_default().trim_end_matches('/');
    Some((port, path.to_owned()))
}

fn locate(template: &JsonValue, placeholder: &str) -> Option<Vec<Step>> {
    match template {
        JsonValue::String(text) if text.contains(placeholder) => Some(Vec::new()),
        JsonValue::Array(items) => items.iter().enumerate().find_map(|(index, item)| {
            locate(item, placeholder).map(|mut path| {
                path.insert(0, Step::Index(index));
                path
            })
        }),
        JsonValue::Object(members) => members.iter().find_map(|(name, member)| {
            locate(member, placeholder).map(|mut path| {
                path.insert(0, Step::Key(name.clone()));
                path
            })
        }),
        _ => None,
    }
}

// Keys match exactly first, then ignoring case, since a header name is
// not case sensitive. A command written as a string where the template
// has a one-element list still counts.
fn follow<'v>(value: &'v JsonValue, path: &[Step]) -> Option<&'v JsonValue> {
    let Some((step, rest)) = path.split_first() else {
        return Some(value);
    };
    let next = match (step, value) {
        (Step::Key(key), JsonValue::Object(members)) => members
            .iter()
            .find(|(name, _)| name == key)
            .or_else(|| members.iter().find(|(name, _)| name.eq_ignore_ascii_case(key)))
            .map(|(_, member)| member)?,
        (Step::Index(index), JsonValue::Array(items)) => items.get(*index)?,
        (Step::Index(0), JsonValue::String(_)) if rest.is_empty() => value,
        _ => return None,
    };
    follow(next, rest)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clients::catalog::{ClientCatalog, ClientPlatform};

    const URL: &str = "http://127.0.0.1:23508/mcp";

    fn http(authorization: Option<&str>) -> ServerTarget {
        ServerTarget::Http {
            url: URL.to_owned(),
            authorization: authorization.map(str::to_owned),
        }
    }

    fn status(id: &str, text: Option<&str>, target: &ServerTarget, platform: ClientPlatform) -> ClientConfigStatus {
        let catalog = ClientCatalog::bundled().expect("the bundled catalog");
        let client = catalog.client(id).expect("a client");
        let template = client
            .spec(platform)
            .and_then(|spec| spec.entry.clone())
            .expect("an entry");
        evaluate_status(
            text,
            catalog.location(client, platform),
            "tablepro",
            &template,
            target,
            |path| path == "/old/tablepro-mcp",
        )
    }

    fn linux(id: &str, text: Option<&str>, authorization: Option<&str>) -> ClientConfigStatus {
        status(id, text, &http(authorization), ClientPlatform::Linux)
    }

    #[test]
    fn the_port_and_the_header_decide_a_linux_entry() {
        let current = r#"{"mcpServers": {"tablepro": {"url": "http://localhost:23508/mcp/",
            "headers": {"authorization": "Bearer tp_a"}}}}"#;
        let other_port = r#"{"mcpServers": {"tablepro": {"url": "http://127.0.0.1:9/mcp",
            "headers": {"Authorization": "Bearer tp_a"}}}}"#;

        assert_eq!(
            linux("cursor", Some(current), Some("Bearer tp_a")),
            ClientConfigStatus::Current
        );
        assert_eq!(
            linux("cursor", Some(current), Some("Bearer tp_b")),
            ClientConfigStatus::Stale(StaleReason::OtherToken)
        );
        assert_eq!(linux("cursor", Some(current), None), ClientConfigStatus::Current);
        assert_eq!(
            linux("cursor", Some(other_port), Some("Bearer tp_a")),
            ClientConfigStatus::Stale(StaleReason::OtherUrl)
        );
    }

    #[test]
    fn a_missing_or_empty_file_is_not_configured_and_a_broken_one_unreadable() {
        assert_eq!(linux("cursor", None, None), ClientConfigStatus::NotConfigured);
        assert_eq!(linux("cursor", Some(""), None), ClientConfigStatus::NotConfigured);
        assert_eq!(linux("cursor", Some("{"), None), ClientConfigStatus::Unreadable);
    }

    #[test]
    fn a_server_in_one_project_only_is_another_scope() {
        let text = r#"{"projects": {"/home/ana/app": {"mcpServers": {"tablepro": {"type": "http"}}}}}"#;

        assert_eq!(linux("claude-code", Some(text), None), ClientConfigStatus::OtherScope);
    }

    #[test]
    fn a_stale_entry_in_another_scope_shadows_a_current_one() {
        let user = r#""mcpServers": {"tablepro": {"type": "http", "url": "http://127.0.0.1:23508/mcp",
            "headers": {"Authorization": "Bearer tp_a"}}}"#;
        let project = |token: &str| {
            format!(
                r#""projects": {{"/home/ana/app": {{"mcpServers": {{"tablepro": {{"type": "http",
                "url": "http://127.0.0.1:23508/mcp", "headers": {{"Authorization": "Bearer {token}"}}}}}}}}}}"#
            )
        };
        let stale = format!("{{{user}, {}}}", project("tp_old"));
        let current = format!("{{{user}, {}}}", project("tp_a"));

        assert_eq!(
            linux("claude-code", Some(&stale), Some("Bearer tp_a")),
            ClientConfigStatus::Stale(StaleReason::Shadowed)
        );
        assert_eq!(
            linux("claude-code", Some(&current), Some("Bearer tp_a")),
            ClientConfigStatus::Current
        );
        assert_eq!(
            linux("claude-code", Some(&stale), Some("Bearer tp_z")),
            ClientConfigStatus::Stale(StaleReason::OtherToken),
            "the entry TablePro writes comes first"
        );
    }

    #[test]
    fn an_older_layout_of_the_file_is_read_like_the_current_one() {
        let older = r#"{"mcp": {"tablepro": {"type": "remote", "url": "http://127.0.0.1:23508/mcp",
            "headers": {"Authorization": "Bearer tp_a"}}}}"#;

        assert_eq!(
            linux("opencode", Some(older), Some("Bearer tp_a")),
            ClientConfigStatus::Current
        );
        assert_eq!(
            linux("opencode", Some(older), Some("Bearer tp_b")),
            ClientConfigStatus::Stale(StaleReason::OtherToken)
        );
        assert_eq!(
            linux("opencode", Some(r#"{"mcp": {"servers": {}}}"#), None),
            ClientConfigStatus::NotConfigured
        );
    }

    #[test]
    fn an_entry_turned_off_in_the_client_is_not_read_as_set_up() {
        let json = |extra: &str| {
            format!(
                r#"{{"mcpServers": {{"tablepro": {{"url": "{URL}",
                "headers": {{"Authorization": "Bearer tp_a"}}{extra}}}}}}}"#
            )
        };
        let toml = "[mcp_servers.tablepro]\nurl = \"http://127.0.0.1:23508/mcp\"\n\
http_headers = { Authorization = \"Bearer tp_a\" }\nenabled = false\n";

        for (id, extra) in [
            ("cursor", r#", "disabled": true"#),
            ("kiro", r#", "disabled": true"#),
            ("warp", r#", "enabled": false"#),
        ] {
            let status = linux(id, Some(&json(extra)), Some("Bearer tp_a"));
            assert_eq!(status, ClientConfigStatus::Disabled, "{id}");
            assert!(status != ClientConfigStatus::Current, "{id}");
        }
        assert_eq!(
            linux("codex", Some(toml), Some("Bearer tp_a")),
            ClientConfigStatus::Disabled
        );
        assert_eq!(
            linux("kiro", Some(&json(r#", "disabled": false"#)), Some("Bearer tp_a")),
            ClientConfigStatus::Current
        );
    }

    #[test]
    fn a_turned_off_entry_is_disabled_whatever_its_address_or_token() {
        let old = |off: &str| {
            format!(
                r#"{{"mcpServers": {{"tablepro": {{"url": "http://127.0.0.1:9/mcp",
                "headers": {{"Authorization": "Bearer tp_old"}}, {off}}}}}}}"#
            )
        };
        let toml = "[mcp_servers.tablepro]\nurl = \"http://127.0.0.1:9/mcp\"\nenabled = false\n";

        for id in ["cline", "kiro"] {
            assert_eq!(
                linux(id, Some(&old(r#""disabled": true"#)), Some("Bearer tp_a")),
                ClientConfigStatus::Disabled,
                "{id}"
            );
        }
        assert_eq!(
            linux("warp", Some(&old(r#""enabled": false"#)), Some("Bearer tp_a")),
            ClientConfigStatus::Disabled
        );
        assert_eq!(
            linux("codex", Some(toml), Some("Bearer tp_a")),
            ClientConfigStatus::Disabled
        );
    }

    #[test]
    fn an_http_entry_that_still_names_a_command_is_stale() {
        let current = r#""url": "http://127.0.0.1:23508/mcp", "headers": {"Authorization": "Bearer tp_a"}"#;
        let both = format!(r#"{{"mcpServers": {{"tablepro": {{"command": "/x/tablepro-mcp", {current}}}}}}}"#);
        let stdio = r#"{"mcpServers": {"tablepro": {"command": "/x/tablepro-mcp", "args": []}}}"#;
        let codex = "[mcp_servers.tablepro]\ncommand = \"/x/tablepro-mcp\"\nurl = \"http://127.0.0.1:23508/mcp\"\n";

        assert_eq!(
            linux("cursor", Some(&both), Some("Bearer tp_a")),
            ClientConfigStatus::Stale(StaleReason::OtherCommand)
        );
        assert_eq!(
            linux("cursor", Some(stdio), Some("Bearer tp_a")),
            ClientConfigStatus::Stale(StaleReason::OtherCommand)
        );
        assert_eq!(
            linux("codex", Some(codex), None),
            ClientConfigStatus::Stale(StaleReason::OtherCommand)
        );
    }

    #[test]
    fn codex_reads_its_toml_table() {
        let text = "[mcp_servers.tablepro]\nurl = \"http://127.0.0.1:23508/mcp\"\n\
http_headers = { Authorization = \"Bearer tp_a\" }\n";

        assert_eq!(
            linux("codex", Some(text), Some("Bearer tp_a")),
            ClientConfigStatus::Current
        );
        assert_eq!(
            linux("codex", Some(text), Some("Bearer tp_z")),
            ClientConfigStatus::Stale(StaleReason::OtherToken)
        );
    }

    #[test]
    fn a_client_whose_file_is_yaml_or_absent_is_unknown() {
        assert_eq!(
            linux("goose", Some("extensions: {}\n"), None),
            ClientConfigStatus::Unknown
        );
        assert_eq!(linux("jetbrains-ai", None, None), ClientConfigStatus::Unknown);
    }

    #[test]
    fn a_macos_entry_is_current_only_with_this_bridge() {
        let bridge = ServerTarget::Stdio {
            command: "/Applications/TablePro.app/Contents/MacOS/tablepro-mcp".to_owned(),
        };
        let entry = |command: &str| format!(r#"{{"mcpServers": {{"tablepro": {{"command": "{command}"}}}}}}"#);
        let opencode =
            |command: &str| format!(r#"{{"mcp": {{"servers": {{"tablepro": {{"command": ["{command}"]}}}}}}}}"#);
        let macos = |id: &str, text: &str| status(id, Some(text), &bridge, ClientPlatform::Macos);

        assert_eq!(
            macos(
                "cursor",
                &entry("/Applications/TablePro.app/Contents/MacOS/tablepro-mcp")
            ),
            ClientConfigStatus::Current
        );
        assert_eq!(
            macos("cursor", &entry("/gone/tablepro-mcp")),
            ClientConfigStatus::Stale(StaleReason::CommandMissing)
        );
        assert_eq!(
            macos("cursor", &entry("/old/tablepro-mcp")),
            ClientConfigStatus::Stale(StaleReason::OtherCommand)
        );
        assert_eq!(
            macos(
                "opencode",
                &opencode("/Applications/TablePro.app/Contents/MacOS/tablepro-mcp")
            ),
            ClientConfigStatus::Current
        );
    }

    #[test]
    fn an_endpoint_is_its_port_and_path() {
        assert_eq!(endpoint("http://127.0.0.1:23508/mcp"), Some((23508, "/mcp".to_owned())));
        assert_eq!(endpoint("HTTP://localhost/mcp/?x=1"), Some((80, "/mcp".to_owned())));
        assert_eq!(endpoint("https://127.0.0.1:23508/mcp"), None);
        assert_eq!(endpoint("127.0.0.1:23508/mcp"), None);
    }
}
