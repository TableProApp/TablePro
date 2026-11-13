// The detectors' shared fixtures: the macOS app mirrors these tables in its own tests, and
// `print_fixtures_markdown` writes them out for it (DETECTOR-FIXTURES.md).

use std::fmt::Write as _;

use super::SensitiveKind::{self, ApiKey, Card, Email, Iban, Ip, Jwt, Phone};
use super::{column_name_hit, column_value_kind, scan_sql_personal_data};
use crate::column::ColumnType;
use crate::masking::MaskingStyle::{self, Email as EmailStyle, Full, Hash, LastFour};
use crate::secret_scan::SecretHitKind::{
    self, AssignedSecret, AwsAccessKey, GitHubToken, GoogleApiKey, JsonWebToken, PrivateKey, SlackToken, StripeKey,
    UrlCredentials,
};
use crate::secret_scan::{scan_columns, scan_sql};
use crate::value::Value;

const JWT_TEXT: &str = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc-DEF_123";

// A column name and the term and style it hits.
const NAMES: &[(&str, Option<(&str, MaskingStyle)>)] = &[
    ("email", Some(("email", EmailStyle))),
    ("E-Mail", Some(("email", EmailStyle))),
    ("e_mail", Some(("email", EmailStyle))),
    ("mail", Some(("mail", EmailStyle))),
    ("work_mail", Some(("mail", EmailStyle))),
    ("ma_il", None),
    ("email_address", Some(("email", EmailStyle))),
    ("phone", Some(("phone", LastFour))),
    ("mobilePhone", Some(("phone", LastFour))),
    ("mobile", Some(("mobile", LastFour))),
    ("tel_no", Some(("tel", LastFour))),
    ("hotel", None),
    ("fax", Some(("fax", LastFour))),
    ("msisdn", Some(("msisdn", LastFour))),
    ("password_hash", Some(("password", Full))),
    ("passwords", None),
    ("stripe_api_key", Some(("apikey", Full))),
    ("apiKey", Some(("apikey", Full))),
    ("API-KEY", Some(("apikey", Full))),
    ("aws_access_key", Some(("accesskey", Full))),
    ("PrivateKey", Some(("privatekey", Full))),
    ("credential", Some(("credential", Full))),
    ("credentials", None),
    ("refresh_token", Some(("token", Full))),
    ("ssn", Some(("ssn", LastFour))),
    ("customerSSN", Some(("ssn", LastFour))),
    ("ssn4", Some(("ssn", LastFour))),
    ("classname", None),
    ("class_name", None),
    ("social_security_number", Some(("socialsecurity", LastFour))),
    ("national_id", Some(("nationalid", LastFour))),
    ("tax_id", Some(("taxid", LastFour))),
    ("tin", Some(("tin", LastFour))),
    ("credit_card_number", Some(("creditcard", LastFour))),
    ("CardNumber", Some(("cardnumber", LastFour))),
    ("pan", Some(("pan", LastFour))),
    ("company", None),
    ("iban", Some(("iban", LastFour))),
    ("routing_number", Some(("routingnumber", LastFour))),
    ("street_address", Some(("address", Full))),
    ("street", Some(("street", Full))),
    ("Address2Line", Some(("address", Full))),
    ("zip", Some(("zip", Full))),
    ("zipcode", Some(("zipcode", Full))),
    ("zip_code", Some(("zipcode", Full))),
    ("postal_code", Some(("postal", Full))),
    ("dob", Some(("dob", Full))),
    ("date_of_birth", Some(("dateofbirth", Full))),
    ("birthday", Some(("birthday", Full))),
    ("ip", Some(("ip", Hash))),
    ("ip_address", Some(("ipaddress", Hash))),
    ("IPAddress", Some(("ipaddress", Hash))),
    ("ipv4", Some(("ipv4", Hash))),
    ("client_ipv6", Some(("ipv6", Hash))),
    ("ipv", None),
    ("user_first_name", Some(("firstname", Full))),
    ("lastName", Some(("lastname", Full))),
    ("surname", Some(("surname", Full))),
    ("given_name", Some(("givenname", Full))),
    ("home_phone_address", Some(("phone", LastFour))),
    ("id", None),
    ("", None),
];

// A value and every kind it matches, in table order.
const VALUES: &[(&str, &[SensitiveKind])] = &[
    ("4111 1111 1111 1111", &[Card]),
    ("4111-1111-1111-1111", &[Card]),
    ("4111111111111111", &[Card]),
    ("4222222222222", &[Card]),
    ("4222 2222 22222", &[Card, Phone]),
    ("4111111111111112", &[]),
    ("411111111111", &[]),
    ("4111.1111.1111.1111", &[]),
    (" 4111111111111111", &[Card]),
    ("GB82 WEST 1234 5698 7654 32", &[Iban]),
    ("GB82WEST12345698765432", &[Iban]),
    ("DE89 3704 0044 0532 0130 00", &[Iban]),
    ("GB82 WEST 1234 5698 7654 33", &[]),
    ("gb82west12345698765432", &[]),
    ("GB82\tWEST12345698765432", &[]),
    (JWT_TEXT, &[Jwt]),
    (" eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc", &[]),
    ("AKIAIOSFODNN7EXAMPLE", &[ApiKey]),
    ("key=AKIAIOSFODNN7EXAMPLE;", &[ApiKey]),
    ("ghp_0123456789abcdefghijABCDEFGHIJ012345", &[ApiKey]),
    ("xoxb-123", &[ApiKey]),
    ("sk_live_abc", &[ApiKey]),
    ("AIzaSyA1234567890abcdefghijklmnopqrstuv", &[ApiKey]),
    ("sk_test_abc", &[]),
    ("ann@example.com", &[Email]),
    ("émile@exämple.fr", &[Email]),
    ("a@b@c.com", &[]),
    ("ann@localhost", &[]),
    ("ann @example.com", &[]),
    ("ann@example.com ", &[]),
    ("ann\u{a0}x@example.com", &[]),
    ("+1 555 0100", &[Phone]),
    ("(555) 010-0100", &[Phone]),
    ("555.010.0100", &[Phone]),
    ("+15550100", &[Phone]),
    ("1.234.567", &[Phone]),
    ("5550100", &[]),
    ("+123456", &[]),
    ("+1234567890123456", &[]),
    ("555-0100 ext 2", &[]),
    ("2024-01-02", &[]),
    ("2024-01-0212345", &[]),
    ("1234567.89", &[]),
    ("-1234567.89", &[]),
    ("12:30:45", &[]),
    ("192.168.100.200", &[Ip]),
    ("192.168.1.1", &[Ip]),
    ("0.0.0.0", &[Ip]),
    ("192.168.01.1", &[Phone]),
    ("256.1.1.1", &[]),
    ("256.10.10.10", &[Phone]),
    ("1.2.3", &[]),
    ("1.1.1.1 ", &[]),
    ("::1", &[Ip]),
    ("2001:db8::1", &[Ip]),
    ("1:2:3:4:5:6:7:8", &[Ip]),
    ("::ffff:192.168.1.1", &[Ip]),
    ("fe80::1%eth0", &[]),
    ("[::1]", &[]),
    ("2001:db8::1::2", &[]),
    ("12345::1", &[]),
    ("", &[]),
];

enum Cell {
    Text(&'static str),
    Null,
    Bytes,
}

// A column's type, its values and the kind it is flagged as.
const COLUMNS: &[(&str, &[Cell], Option<SensitiveKind>)] = &[
    (
        "text",
        &[
            Cell::Text("ann@example.com"),
            Cell::Text("bob@example.com"),
            Cell::Text("n/a"),
            Cell::Text("x"),
        ],
        Some(Email),
    ),
    (
        "text",
        &[Cell::Text("ann@example.com"), Cell::Text("x"), Cell::Text("y")],
        None,
    ),
    (
        "text",
        &[Cell::Text("ann@example.com"), Cell::Null, Cell::Null],
        Some(Email),
    ),
    (
        "text",
        &[Cell::Text("ann@example.com"), Cell::Text(""), Cell::Text("")],
        None,
    ),
    ("text", &[Cell::Text("ann@example.com"), Cell::Bytes, Cell::Bytes], None),
    (
        "text",
        &[Cell::Text("x"), Cell::Text("y"), Cell::Text("4111 1111 1111 1111")],
        Some(Card),
    ),
    (
        "text",
        &[Cell::Text("ann@example.com"), Cell::Text(JWT_TEXT)],
        Some(Jwt),
    ),
    ("text", &[Cell::Text("192.168.1.1"), Cell::Text("10.0.0.1")], Some(Ip)),
    (
        "varchar(64)",
        &[Cell::Text("+1 555 0100"), Cell::Text("x")],
        Some(Phone),
    ),
    ("", &[Cell::Text("ann@example.com")], Some(Email)),
    ("Nullable(String)", &[Cell::Text("ann@example.com")], Some(Email)),
    ("bigint", &[Cell::Text("4111111111111111")], None),
    ("uuid", &[Cell::Text("ann@example.com")], None),
    ("Nullable(UInt64)", &[Cell::Text("4111111111111111")], None),
    (
        "timestamp with time zone",
        &[Cell::Text("2024-01-02 10:00:00+00")],
        None,
    ),
    ("text", &[Cell::Null, Cell::Null], None),
    ("text", &[], None),
];

// A query and the personal data its single-quoted literals hold, each kind once per line.
const SQL: &[(&str, &[(SensitiveKind, u32)])] = &[
    ("SELECT * FROM users WHERE email = 'ann@example.com'", &[(Email, 1)]),
    (r#"SELECT "ann@example.com" FROM t"#, &[]),
    ("WHERE note = 'call +1 555 0100'", &[]),
    ("WHERE card = '4111-1111-1111-1111'", &[(Card, 1)]),
    ("WHERE iban = 'GB82 WEST 1234 5698 7654 32'", &[(Iban, 1)]),
    (
        "SET token = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc-DEF_123'",
        &[(Jwt, 1)],
    ),
    ("WHERE k = 'id AKIAIOSFODNN7EXAMPLE'", &[(ApiKey, 1)]),
    ("SELECT 'o''brien@example.com'", &[(Email, 1)]),
    ("WHERE ip = '192.168.1.1'", &[]),
    ("WHERE e = 'ann@example.com", &[]),
    ("-- don't\nWHERE e = 'ann@example.com'", &[(Email, 2)]),
    ("SELECT /* it's */ 'ann@example.com'", &[(Email, 1)]),
    ("SELECT 1 -- 'ann@example.com'", &[]),
    ("SELECT 1 /* 'ann@example.com' */", &[]),
    ("/* 'ann@example.com'", &[]),
    ("-- it's\r'ann@example.com'", &[(Email, 2)]),
    ("SELECT 'a--b@example.com'", &[(Email, 1)]),
    (r#"SELECT "x--y", 'ann@example.com'"#, &[(Email, 1)]),
    ("SELECT 1 - -1, 'ann@example.com'", &[(Email, 1)]),
    (
        "WHERE e = 'a@b.co' AND f = 'c@d.co'\nOR p = '(555) 010-0100'",
        &[(Email, 1), (Phone, 2)],
    ),
    ("SELECT 1;\r\n\r\nSELECT '+1 555 0100'", &[(Phone, 3)]),
    ("SELECT 1", &[]),
];

// A query and what the secret scan finds, each kind once per line.
const SECRET_SQL: &[(&str, &[(SecretHitKind, u32)])] = &[
    ("-- AKIAIOSFODNN7EXAMPLE", &[(AwsAccessKey, 1)]),
    ("-----BEGIN RSA PRIVATE KEY-----", &[(PrivateKey, 1)]),
    ("-----BEGIN PRIVATE KEY-----", &[(PrivateKey, 1)]),
    ("-----BEGIN OPENSSH PRIVATE KEY-----", &[(PrivateKey, 1)]),
    ("-----BEGIN EC2 PRIVATE KEY-----", &[(PrivateKey, 1)]),
    ("-----BEGIN ENCRYPTED  PRIVATE KEY-----", &[]),
    ("-----BEGIN rsa PRIVATE KEY-----", &[]),
    ("-----BEGIN PUBLIC KEY-----", &[]),
    (
        "-- eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc-DEF_123",
        &[(JsonWebToken, 1)],
    ),
    ("-- ghp_0123456789abcdefghijABCDEFGHIJ012345", &[(GitHubToken, 1)]),
    ("-- xoxb-123", &[(SlackToken, 1)]),
    ("-- sk_live_abc", &[(StripeKey, 1)]),
    ("-- AIzaSyA1234567890abcdefghijklmnopqrstuv", &[(GoogleApiKey, 1)]),
    ("-- postgres://app:hunter2@db.internal/shop", &[(UrlCredentials, 1)]),
    ("-- https://a@b:c@d", &[]),
    ("https://tablepro.app/docs", &[]),
    ("WHERE u.password = 'hunter2'", &[(AssignedSecret, 1)]),
    (r#"SELECT '{"token": "abc"}'::jsonb"#, &[(AssignedSecret, 1)]),
    (r#"WHERE "password" = 'x'"#, &[(AssignedSecret, 1)]),
    (r#"WHERE 'password' = "x""#, &[(AssignedSecret, 1)]),
    ("SET `password` := 'x'", &[(AssignedSecret, 1)]),
    ("VALUES ([db_passwd] => 'x')", &[(AssignedSecret, 1)]),
    ("WHERE Api_Key: 'x'", &[(AssignedSecret, 1)]),
    ("WHERE password = ''", &[]),
    (r#"WHERE password = """#, &[]),
    (r#"WHERE password = 'abc" AND 1 = 1"#, &[]),
    ("WHERE password = 'a\nb'", &[(AssignedSecret, 1)]),
    ("SELECT password FROM users", &[]),
    ("WHERE token = :token", &[]),
    ("SELECT 'password' AS label", &[]),
    (
        "SELECT 'AKIAIOSFODNN7EXAMPLE', 'AKIAIOSFODNN7EXAMPLF';\nSELECT 'sk_live_a'",
        &[(AwsAccessKey, 1), (StripeKey, 2)],
    ),
    ("\r\rsk_live_x", &[(StripeKey, 3)]),
    ("\r\n\r\nsk_live_x", &[(StripeKey, 3)]),
    ("\n\rsk_live_x", &[(StripeKey, 3)]),
];

// Column names and the ones the secret scan names, in order, each once.
const SECRET_COLUMNS: &[(&[&str], &[&str])] = &[
    (
        &[
            "id",
            "user_password",
            "PasswordHash",
            "access_token",
            "apiKey",
            "API-KEY",
            "client_secret",
            "ssn",
            "customerSSN",
            "ssn_last4",
            "credit_card",
            "CardNumber",
            "class_name",
            "lesson",
            "id",
            "user_password",
        ],
        &[
            "user_password",
            "PasswordHash",
            "access_token",
            "apiKey",
            "API-KEY",
            "client_secret",
            "ssn",
            "customerSSN",
            "ssn_last4",
            "credit_card",
            "CardNumber",
        ],
    ),
    (
        &["passwords", "tokens", "passwd", "secrets", "api_key_id"],
        &["passwd", "api_key_id"],
    ),
];

fn cell(cell: &Cell) -> Value {
    match cell {
        Cell::Text(text) => Value::Text((*text).to_owned()),
        Cell::Null => Value::Null,
        Cell::Bytes => Value::Bytes(vec![0x40, 0x41]),
    }
}

#[test]
fn column_names() {
    for (name, expected) in NAMES {
        let found = column_name_hit(name).map(|hit| (hit.term, hit.style));
        assert_eq!(found, *expected, "{name:?}");
    }
}

#[test]
fn values() {
    for (text, expected) in VALUES {
        let found: Vec<SensitiveKind> = SensitiveKind::ALL
            .into_iter()
            .filter(|kind| kind.matches(text))
            .collect();
        assert_eq!(found, *expected, "{text:?}");
    }
}

#[test]
fn columns() {
    for (type_name, cells, expected) in COLUMNS {
        let values: Vec<Value> = cells.iter().map(cell).collect();
        assert_eq!(
            column_value_kind(&ColumnType::untyped_text(*type_name), &values),
            *expected,
            "{type_name}"
        );
    }
}

#[test]
fn sql_personal_data() {
    for (sql, expected) in SQL {
        let found: Vec<(SensitiveKind, u32)> = scan_sql_personal_data(sql)
            .into_iter()
            .map(|hit| (hit.kind, hit.line))
            .collect();
        assert_eq!(found, *expected, "{sql:?}");
    }
}

#[test]
fn secret_sql() {
    for (sql, expected) in SECRET_SQL {
        let found: Vec<(SecretHitKind, u32)> = scan_sql(sql).into_iter().map(|hit| (hit.kind, hit.line)).collect();
        assert_eq!(found, *expected, "{sql:?}");
    }
}

#[test]
fn secret_columns() {
    for (names, expected) in SECRET_COLUMNS {
        assert_eq!(scan_columns(names), *expected);
    }
}

#[test]
#[ignore = "prints the fixtures as Markdown for the macOS app's tests: cargo test -p tablepro-core --lib print_fixtures_markdown -- --ignored --nocapture"]
fn print_fixtures_markdown() {
    println!("{}", fixtures_markdown());
}

fn shown(text: &str) -> String {
    format!("`{}`", text.escape_debug()).replace('|', "\\|")
}

fn fixtures_markdown() -> String {
    let mut out = String::from("## Column names\n\n| Name | Term | Style |\n|---|---|---|\n");
    for (name, hit) in NAMES {
        let (term, style) = hit.map_or(("none", "none"), |(term, style)| (term, style.code()));
        let _ = writeln!(out, "| {} | {term} | {style} |", shown(name));
    }
    out.push_str("\n## Values (each kind tested alone, table order)\n\n| Value | Kinds |\n|---|---|\n");
    for (text, kinds) in VALUES {
        let _ = writeln!(
            out,
            "| {} | {} |",
            shown(text),
            codes(kinds.iter().map(|kind| kind.code()))
        );
    }
    out.push_str("\n## Columns (thresholds, text-like types)\n\n| Type | Values | Flagged |\n|---|---|---|\n");
    for (type_name, cells, kind) in COLUMNS {
        let values: Vec<String> = cells
            .iter()
            .map(|cell| match cell {
                Cell::Text(text) => shown(text),
                Cell::Null => "NULL".to_owned(),
                Cell::Bytes => "bytes".to_owned(),
            })
            .collect();
        let flagged = kind.map_or("none", SensitiveKind::code);
        let _ = writeln!(out, "| {} | {} | {flagged} |", shown(type_name), values.join(", "));
    }
    out.push_str("\n## SQL personal data\n\n| SQL | Hits (kind:line) |\n|---|---|\n");
    for (sql, hits) in SQL {
        let hits = hits.iter().map(|(kind, line)| format!("{}:{line}", kind.code()));
        let _ = writeln!(out, "| {} | {} |", shown(sql), codes(hits));
    }
    out.push_str("\n## Secret scan, SQL\n\n| SQL | Hits (kind:line) |\n|---|---|\n");
    for (sql, hits) in SECRET_SQL {
        let hits = hits.iter().map(|(kind, line)| format!("{}:{line}", kind.code()));
        let _ = writeln!(out, "| {} | {} |", shown(sql), codes(hits));
    }
    out.push_str("\n## Secret scan, columns\n\n| Names | Found |\n|---|---|\n");
    for (names, found) in SECRET_COLUMNS {
        let names: Vec<String> = names.iter().map(|name| shown(name)).collect();
        let found: Vec<String> = found.iter().map(|name| shown(name)).collect();
        let _ = writeln!(out, "| {} | {} |", names.join(", "), found.join(", "));
    }
    out
}

fn codes<S: AsRef<str>>(codes: impl Iterator<Item = S>) -> String {
    let joined: Vec<String> = codes.map(|code| code.as_ref().to_owned()).collect();
    match joined.is_empty() {
        true => "none".to_owned(),
        false => joined.join(", "),
    }
}
