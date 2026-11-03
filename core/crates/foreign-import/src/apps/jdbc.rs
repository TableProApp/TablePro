use std::collections::HashMap;

use crate::{ForeignSsl, ForeignSslMode};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Endpoint {
    pub host: String,
    pub port: Option<u16>,
    pub database: String,
    // The user a URL names before `@`; its password never leaves the URL.
    pub username: Option<String>,
}

// The subprotocol is what follows `jdbc:` up to the next `:` or `/`.
pub(crate) fn subprotocol(url: &str) -> String {
    match strip_prefix_ignoring_case(url, "jdbc:") {
        Some(rest) => rest
            .chars()
            .take_while(|character| !matches!(character, ':' | '/'))
            .collect(),
        None => String::new(),
    }
}

pub(crate) fn parse(url: &str, subprotocol: &str) -> Option<Endpoint> {
    // The MongoDB driver takes its own URL, which the app stores with no `jdbc:` before it.
    if is_native_mongo(url) {
        return parse_authority(url.trim());
    }
    let body = strip_prefix_ignoring_case(url.trim(), "jdbc:")?;
    match subprotocol.to_lowercase().as_str() {
        "sqlserver" | "jtds" => parse_sql_server(body),
        "oracle" => parse_oracle(body),
        "sqlite" | "duckdb" | "h2" => Some(parse_file_path(body, subprotocol)),
        "bigquery" => parse_big_query(body),
        _ => parse_authority(body),
    }
}

pub(crate) fn is_native_mongo(url: &str) -> bool {
    let url = url.trim();
    strip_prefix_ignoring_case(url, "mongodb://").is_some() || is_mongo_seed_list(url)
}

// The macOS MongoDB driver's field for a DNS seed list.
pub(crate) const MONGO_USE_SRV: &str = "mongoUseSrv";

// The macOS MongoDB driver's field for the database it signs in against.
pub(crate) const MONGO_AUTH_SOURCE: &str = "mongoAuthSource";

// What a MongoDB URL says that the record keeps as an engine field: a seed list, and the
// database it signs in against.
pub(crate) fn url_fields(url: &str) -> std::collections::BTreeMap<String, String> {
    let mut fields = std::collections::BTreeMap::new();
    if is_mongo_seed_list(url) {
        fields.insert(MONGO_USE_SRV.to_owned(), "true".to_owned());
    }
    if is_native_mongo(url) || subprotocol(url).eq_ignore_ascii_case("mongodb") {
        let source = url_query(url)
            .split('&')
            .filter_map(|pair| pair.split_once('='))
            .filter(|(key, _)| key.trim().eq_ignore_ascii_case("authSource"))
            .map(|(_, value)| percent_decoded(value.trim()))
            .next_back()
            .filter(|source| !source.is_empty());
        if let Some(source) = source {
            fields.insert(MONGO_AUTH_SOURCE.to_owned(), source);
        }
    }
    fields
}

fn url_query(url: &str) -> &str {
    url.split_once('?').map_or("", |(_, query)| query)
}

pub(crate) fn is_mongo_seed_list(url: &str) -> bool {
    strip_prefix_ignoring_case(url.trim(), "mongodb+srv://").is_some()
}

// What a URL says about TLS. Only `sslmode` and a seed-list scheme say it plainly; the drivers read
// every other switch their own way and in combination (`ssl`, `useSSL` with `requireSSL`,
// `encrypt` with `trustServerCertificate`, certificate files), so a URL that uses one is reported
// as unread rather than guessed at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum UrlTls {
    None,
    Mode(&'static str),
    Unread,
}

pub(crate) fn url_tls(url: &str) -> UrlTls {
    let parameters = url_parameters(url);
    let other_switch = parameters.iter().any(|(key, _)| {
        key != "sslmode"
            && (key.starts_with("ssl")
                || key.starts_with("tls")
                || matches!(
                    key.as_str(),
                    "usessl" | "requiressl" | "encrypt" | "trustservercertificate" | "verifyservercertificate"
                ))
    });
    if other_switch {
        return UrlTls::Unread;
    }
    match parameters.iter().rev().find(|(key, _)| key == "sslmode") {
        Some((_, mode)) => named_mode(mode).map_or(UrlTls::Unread, UrlTls::Mode),
        None if is_mongo_seed_list(url) => UrlTls::Mode("verify-full"),
        None => UrlTls::None,
    }
}

fn named_mode(mode: &str) -> Option<&'static str> {
    match mode {
        "disable" | "disabled" => Some("disabled"),
        "allow" | "prefer" | "preferred" => Some("preferred"),
        // MariaDB's `trust` encrypts without checking the certificate.
        "require" | "required" | "trust" => Some("required"),
        "verify-ca" | "verify_ca" => Some("verify-ca"),
        "verify-full" | "verify_full" | "verify_identity" => Some("verify-full"),
        _ => None,
    }
}

// Lowercased keys and values after `?` (and SQL Server's `;` properties), in order.
fn url_parameters(url: &str) -> Vec<(String, String)> {
    let Some((_, query)) = url.split_once('?').or_else(|| url.split_once(';')) else {
        return Vec::new();
    };
    query
        .split(['&', ';'])
        .filter_map(|pair| pair.split_once('='))
        .map(|(key, value)| (key.trim().to_lowercase(), value.trim().to_lowercase()))
        .collect()
}

// The SSL settings a source keeps in its URL, used when its own settings name none. TLS the URL
// sets in a way this cannot read marks the record, so the review asks instead of importing it off.
pub(crate) fn url_ssl_or_mark(
    url: &str,
    fields: &mut std::collections::BTreeMap<String, String>,
) -> Option<ForeignSsl> {
    if url_tls(url) == UrlTls::Unread {
        fields.insert(crate::TLS_SETTINGS_UNREAD.to_owned(), "true".to_owned());
    }
    url_ssl(url)
}

// The TLS a URL asks for as a record's SSL settings: none when it asks for none or turns it off.
pub(crate) fn url_ssl(url: &str) -> Option<ForeignSsl> {
    let UrlTls::Mode(mode) = url_tls(url) else {
        return None;
    };
    let mode = match mode {
        "disabled" => return None,
        "preferred" => ForeignSslMode::Preferred,
        "required" => ForeignSslMode::Required,
        "verify-ca" => ForeignSslMode::VerifyCa,
        _ => ForeignSslMode::VerifyIdentity,
    };
    Some(ForeignSsl {
        mode,
        ca_certificate_path: None,
        client_certificate_path: None,
        client_key_path: None,
    })
}

// jdbc:<sub>://[user[:pass]@]host[:port][/database][?params]
fn parse_authority(body: &str) -> Option<Endpoint> {
    let (_, remainder) = body.split_once("://")?;
    let (head, tail) = split_once(strip_query(remainder), '/');
    let authority = strip_user_info(head);
    let first_host = authority.split(',').next().unwrap_or(authority);
    let (host, port) = parse_host_port(first_host);
    let username = head
        .rsplit_once('@')
        .map(|(user_info, _)| user_info.split(':').next().unwrap_or_default())
        .map(percent_decoded)
        .filter(|user| !user.is_empty());
    // A database name escapes a space or a slash, and the drivers take the name as written.
    let database = percent_decoded(tail.unwrap_or_default());
    endpoint(host, port, &database).map(|endpoint| Endpoint { username, ..endpoint })
}

// A user name in a URL escapes `@`, `:` and the like as `%40`; a malformed escape stays as written.
fn percent_decoded(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let escaped = (bytes[index] == b'%')
            .then(|| text.get(index + 1..index + 3))
            .flatten()
            .and_then(|hex| u8::from_str_radix(hex, 16).ok());
        match escaped {
            Some(byte) => {
                decoded.push(byte);
                index += 3;
            }
            None => {
                decoded.push(bytes[index]);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

// jdbc:sqlserver://host[\instance][:port][;prop=value...] and jdbc:jtds:sqlserver://host:port/database
fn parse_sql_server(body: &str) -> Option<Endpoint> {
    let mut remainder = body;
    if let Some(rest) = strip_prefix_ignoring_case(remainder, "jtds:") {
        remainder = rest;
    }
    if let Some(rest) = strip_prefix_ignoring_case(remainder, "sqlserver:") {
        remainder = rest;
    }
    let remainder = remainder.strip_prefix("//")?;
    let (before_properties, properties) = split_once(remainder, ';');
    let properties = semicolon_properties(properties.unwrap_or_default());
    let (authority, database) = split_once(before_properties, '/');
    // `host\instance:port` names its port after the instance, which the macOS port dropped with it.
    let (host, port) = match authority.split_once('\\') {
        Some((host, instance)) => (host, instance.rsplit_once(':').and_then(|(_, port)| port.parse().ok())),
        None => parse_host_port(authority),
    };
    let mut database = database.unwrap_or_default().to_owned();
    if database.is_empty() {
        database = properties
            .get("databasename")
            .or_else(|| properties.get("database"))
            .cloned()
            .unwrap_or_default();
    }
    endpoint(host, port, &database)
}

// jdbc:oracle:thin:@host:port:SID, @//host:port/SERVICE and @host:port/SERVICE
fn parse_oracle(body: &str) -> Option<Endpoint> {
    let (_, descriptor) = body.split_once('@')?;
    let descriptor = strip_query(descriptor);

    if let Some(rest) = descriptor.strip_prefix("//") {
        let (head, tail) = split_once(rest, '/');
        let (host, port) = parse_host_port(head);
        return endpoint(host, port, tail.unwrap_or_default());
    }

    let parts: Vec<&str> = descriptor.split(':').collect();
    let (Some(&host), Some(&port_and_rest)) = (parts.first(), parts.get(1)) else {
        return host_port_path(descriptor);
    };
    if host.is_empty() {
        return host_port_path(descriptor);
    }
    let (port, service_name) = split_once(port_and_rest, '/');
    let port = port.parse().ok();
    let database = service_name.unwrap_or_else(|| parts.get(2).copied().unwrap_or_default());
    Some(Endpoint {
        host: host.to_owned(),
        port,
        database: database.to_owned(),
        username: None,
    })
}

fn host_port_path(descriptor: &str) -> Option<Endpoint> {
    let (head, tail) = split_once(descriptor, '/');
    let (host, port) = parse_host_port(head);
    endpoint(host, port, tail.unwrap_or_default())
}

// jdbc:sqlite:/path/to/file.db, jdbc:duckdb:/path/to/file.duckdb
fn parse_file_path(body: &str, subprotocol: &str) -> Endpoint {
    let prefix = format!("{subprotocol}:");
    let path = strip_prefix_ignoring_case(body, &prefix).unwrap_or(body);
    Endpoint {
        host: String::new(),
        port: None,
        database: strip_query(path).to_owned(),
        username: None,
    }
}

// jdbc:bigquery://https://www.googleapis.com/bigquery/v2;ProjectId=my-project;...
fn parse_big_query(body: &str) -> Option<Endpoint> {
    // The macOS port looked for `//` before stripping `bigquery:`, so it never found an endpoint.
    let remainder = strip_prefix_ignoring_case(body, "bigquery:")
        .unwrap_or(body)
        .strip_prefix("//")?;
    let (head, properties) = split_once(remainder, ';');
    let properties = semicolon_properties(properties.unwrap_or_default());
    let project = properties
        .get("projectid")
        .or_else(|| properties.get("project"))
        .cloned()
        .unwrap_or_default();
    Some(Endpoint {
        host: head.to_owned(),
        port: None,
        database: project,
        username: None,
    })
}

fn endpoint(host: &str, port: Option<u16>, database: &str) -> Option<Endpoint> {
    if host.is_empty() {
        return None;
    }
    Some(Endpoint {
        host: host.to_owned(),
        port,
        database: database.to_owned(),
        username: None,
    })
}

fn parse_host_port(authority: &str) -> (&str, Option<u16>) {
    if let Some(bracketed) = authority.strip_prefix('[') {
        let Some((host, after)) = bracketed.split_once(']') else {
            return (authority, None);
        };
        return (host, after.strip_prefix(':').and_then(|port| port.parse().ok()));
    }
    match authority.rsplit_once(':') {
        Some((host, port)) => (host, port.parse().ok()),
        None => (authority, None),
    }
}

fn strip_user_info(authority: &str) -> &str {
    authority.rsplit_once('@').map_or(authority, |(_, rest)| rest)
}

fn strip_query(value: &str) -> &str {
    value.split_once('?').map_or(value, |(head, _)| head)
}

fn split_once(value: &str, separator: char) -> (&str, Option<&str>) {
    match value.split_once(separator) {
        Some((head, tail)) => (head, Some(tail)),
        None => (value, None),
    }
}

fn semicolon_properties(value: &str) -> HashMap<String, String> {
    value
        .split(';')
        .filter(|pair| !pair.is_empty())
        .filter_map(|pair| pair.split_once('='))
        .map(|(key, value)| (key.to_lowercase().trim().to_owned(), value.to_owned()))
        .collect()
}

fn strip_prefix_ignoring_case<'a>(value: &'a str, prefix: &str) -> Option<&'a str> {
    let head = value.get(..prefix.len())?;
    head.eq_ignore_ascii_case(prefix).then(|| &value[prefix.len()..])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(url: &str, subprotocol: &str) -> Endpoint {
        parse(url, subprotocol).expect("an endpoint")
    }

    #[test]
    fn mysql_reads_host_port_and_database() {
        let endpoint = parsed("jdbc:mysql://db.example.com:3307/shop", "mysql");
        assert_eq!(endpoint.host, "db.example.com");
        assert_eq!(endpoint.port, Some(3307));
        assert_eq!(endpoint.database, "shop");
    }

    #[test]
    fn postgresql_drops_query_parameters() {
        let endpoint = parsed(
            "jdbc:postgresql://localhost:5432/app?sslmode=require&user=x",
            "postgresql",
        );
        assert_eq!(endpoint.host, "localhost");
        assert_eq!(endpoint.port, Some(5432));
        assert_eq!(endpoint.database, "app");
    }

    #[test]
    fn mysql_without_a_port_has_no_port() {
        let endpoint = parsed("jdbc:mysql://localhost/app", "mysql");
        assert_eq!(endpoint.host, "localhost");
        assert_eq!(endpoint.port, None);
        assert_eq!(endpoint.database, "app");
    }

    #[test]
    fn the_authority_drops_user_info() {
        let endpoint = parsed("jdbc:mysql://root:pw@host:3306/db", "mysql");
        assert_eq!(endpoint.host, "host");
        assert_eq!(endpoint.port, Some(3306));
    }

    #[test]
    fn an_ipv6_host_comes_out_of_its_brackets() {
        let endpoint = parsed("jdbc:postgresql://[::1]:5432/db", "postgresql");
        assert_eq!(endpoint.host, "::1");
        assert_eq!(endpoint.port, Some(5432));
        assert_eq!(endpoint.database, "db");
    }

    #[test]
    fn sql_server_reads_the_database_from_semicolon_properties() {
        let endpoint = parsed(
            "jdbc:sqlserver://sql.example.com:1433;databaseName=Sales;encrypt=true",
            "sqlserver",
        );
        assert_eq!(endpoint.host, "sql.example.com");
        assert_eq!(endpoint.port, Some(1433));
        assert_eq!(endpoint.database, "Sales");
    }

    #[test]
    fn sql_server_drops_the_named_instance() {
        let endpoint = parsed("jdbc:sqlserver://host\\SQLEXPRESS;databaseName=db", "sqlserver");
        assert_eq!(endpoint.host, "host");
        assert_eq!(endpoint.database, "db");
    }

    #[test]
    fn jtds_reads_the_path_form() {
        let endpoint = parsed("jdbc:jtds:sqlserver://host:1433/mydb", "jtds");
        assert_eq!(endpoint.host, "host");
        assert_eq!(endpoint.port, Some(1433));
        assert_eq!(endpoint.database, "mydb");
    }

    #[test]
    fn oracle_reads_the_sid_form() {
        let endpoint = parsed("jdbc:oracle:thin:@orahost:1521:ORCL", "oracle");
        assert_eq!(endpoint.host, "orahost");
        assert_eq!(endpoint.port, Some(1521));
        assert_eq!(endpoint.database, "ORCL");
    }

    #[test]
    fn oracle_reads_the_service_name_form_with_slashes() {
        let endpoint = parsed("jdbc:oracle:thin:@//orahost:1521/PRODSVC", "oracle");
        assert_eq!(endpoint.host, "orahost");
        assert_eq!(endpoint.port, Some(1521));
        assert_eq!(endpoint.database, "PRODSVC");
    }

    #[test]
    fn oracle_reads_the_service_name_form_without_slashes() {
        let endpoint = parsed("jdbc:oracle:thin:@orahost:1521/PRODSVC", "oracle");
        assert_eq!(endpoint.host, "orahost");
        assert_eq!(endpoint.port, Some(1521));
        assert_eq!(endpoint.database, "PRODSVC");
    }

    #[test]
    fn sqlite_keeps_the_file_path_as_the_database() {
        let endpoint = parsed("jdbc:sqlite:/Users/me/data/app.db", "sqlite");
        assert_eq!(endpoint.host, "");
        assert_eq!(endpoint.port, None);
        assert_eq!(endpoint.database, "/Users/me/data/app.db");
    }

    #[test]
    fn duckdb_keeps_the_file_path_as_the_database() {
        assert_eq!(
            parsed("jdbc:duckdb:/tmp/analytics.duckdb", "duckdb").database,
            "/tmp/analytics.duckdb"
        );
    }

    #[test]
    fn clickhouse_reads_the_authority_form() {
        let endpoint = parsed("jdbc:clickhouse://ch.example.com:8123/metrics", "clickhouse");
        assert_eq!(endpoint.host, "ch.example.com");
        assert_eq!(endpoint.port, Some(8123));
        assert_eq!(endpoint.database, "metrics");
    }

    #[test]
    fn mongodb_drops_the_auth_source_query() {
        let endpoint = parsed("jdbc:mongodb://mongo:27017/app?authSource=admin", "mongodb");
        assert_eq!(endpoint.host, "mongo");
        assert_eq!(endpoint.port, Some(27017));
        assert_eq!(endpoint.database, "app");
    }

    #[test]
    fn a_url_without_jdbc_has_no_endpoint() {
        assert_eq!(parse("mysql://x/y", "mysql"), None);
    }

    #[test]
    fn a_native_mongo_url_names_its_first_host_and_database() {
        let endpoint = parse(
            "mongodb://app:secret@mongo1.example:27018,mongo2.example/shop?replicaSet=rs0",
            "",
        )
        .expect("an endpoint");
        assert_eq!(endpoint.host, "mongo1.example");
        assert_eq!(endpoint.port, Some(27018));
        assert_eq!(endpoint.database, "shop");
        let seeded = parse("mongodb+srv://cluster0.example.net/app", "").expect("an endpoint");
        assert_eq!((seeded.host.as_str(), seeded.port), ("cluster0.example.net", None));
        assert!(is_mongo_seed_list("mongodb+srv://cluster0.example.net/app"));
    }

    #[test]
    fn only_sslmode_and_a_seed_list_are_read_and_every_other_tls_switch_is_reported_unread() {
        assert_eq!(
            url_tls("jdbc:postgresql://db/app?sslmode=verify-full"),
            UrlTls::Mode("verify-full")
        );
        assert_eq!(
            url_tls("jdbc:postgresql://db/app?sslmode=require"),
            UrlTls::Mode("required")
        );
        assert_eq!(url_tls("jdbc:mariadb://db/app?sslMode=trust"), UrlTls::Mode("required"));
        assert_eq!(
            url_tls("jdbc:mysql://db/app?sslMode=VERIFY_IDENTITY"),
            UrlTls::Mode("verify-full")
        );
        assert_eq!(
            url_tls("mongodb+srv://cluster.example/app"),
            UrlTls::Mode("verify-full")
        );
        assert_eq!(url_tls("jdbc:postgresql://db/app"), UrlTls::None);
        assert_eq!(url_tls("mongodb://db/app"), UrlTls::None);
        for unread in [
            "jdbc:postgresql://db/app?ssl=true",
            "jdbc:postgresql://db/app?sslmode=verify-full&sslrootcert=/ca.pem",
            "jdbc:mysql://db/app?useSSL=true&requireSSL=false",
            "jdbc:sqlserver://db:1433;databaseName=app;encrypt=true",
            "mongodb+srv://cluster.example/app?tls=false",
            "jdbc:postgresql://db/app?sslmode=sometimes",
        ] {
            assert_eq!(url_tls(unread), UrlTls::Unread, "{unread}");
        }
        assert_eq!(url_ssl("jdbc:postgresql://db/app?sslmode=disable"), None);
    }

    #[test]
    fn a_url_names_its_user_but_never_its_password() {
        let endpoint = parse("mongodb://alice%40corp:s3cret@db.example/shop", "").expect("an endpoint");
        assert_eq!(endpoint.username.as_deref(), Some("alice@corp"));
        assert_eq!(endpoint.host, "db.example");
        assert!(!format!("{endpoint:?}").contains("s3cret"));
        assert_eq!(
            parse("jdbc:postgresql://db/app", "postgresql")
                .expect("an endpoint")
                .username,
            None
        );
    }

    #[test]
    fn an_escaped_database_name_is_decoded() {
        let endpoint = parse("jdbc:postgresql://db/team%20db?ssl=true", "postgresql").expect("an endpoint");
        assert_eq!(endpoint.database, "team db");
    }

    #[test]
    fn a_sql_server_instance_keeps_the_port_named_after_it() {
        let endpoint = parse("jdbc:sqlserver://db\\SALES:1444;databaseName=app", "sqlserver").expect("an endpoint");
        assert_eq!(
            (endpoint.host.as_str(), endpoint.port, endpoint.database.as_str()),
            ("db", Some(1444), "app")
        );
        let bare = parse("jdbc:sqlserver://db\\SALES;databaseName=app", "sqlserver").expect("an endpoint");
        assert_eq!((bare.host.as_str(), bare.port), ("db", None));
    }

    #[test]
    fn a_mongo_url_keeps_its_seed_list_and_its_auth_database_as_fields() {
        let fields = url_fields("mongodb+srv://cluster0.example.net/app?authSource=admin&retryWrites=true");
        assert_eq!(fields.get(MONGO_USE_SRV).map(String::as_str), Some("true"));
        assert_eq!(fields.get(MONGO_AUTH_SOURCE).map(String::as_str), Some("admin"));
        assert!(url_fields("jdbc:postgresql://db/app?authSource=admin").is_empty());
    }

    #[test]
    fn a_big_query_url_names_the_api_host_and_the_project() {
        let url = "jdbc:bigquery://https://www.googleapis.com/bigquery/v2;ProjectId=my-project;OAuthType=3";
        let endpoint = parse(url, "bigquery").expect("an endpoint");
        assert_eq!(endpoint.host, "https://www.googleapis.com/bigquery/v2");
        assert_eq!(endpoint.port, None);
        assert_eq!(endpoint.database, "my-project");
    }

    #[test]
    fn the_subprotocol_stops_at_the_next_colon_or_slash() {
        assert_eq!(subprotocol("jdbc:mysql://h/db"), "mysql");
        assert_eq!(subprotocol("JDBC:oracle:thin:@h:1521:X"), "oracle");
        assert_eq!(subprotocol("mongodb://h/db"), "");
    }
}
