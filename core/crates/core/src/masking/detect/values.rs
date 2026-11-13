use std::net::{IpAddr, Ipv4Addr};
use std::sync::LazyLock;

use regex::Regex;

use crate::column::ColumnType;
use crate::export::value_text;
use crate::masking::MaskingStyle;
use crate::secret_scan::SecretHitKind;
use crate::value::Value;

// What the values of a column look like, in table order: a column several kinds flag takes the first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SensitiveKind {
    Card,
    Iban,
    Jwt,
    ApiKey,
    Email,
    Phone,
    Ip,
}

impl SensitiveKind {
    pub const ALL: [Self; 7] = [
        Self::Card,
        Self::Iban,
        Self::Jwt,
        Self::ApiKey,
        Self::Email,
        Self::Phone,
        Self::Ip,
    ];

    pub fn code(self) -> &'static str {
        match self {
            Self::Card => "card",
            Self::Iban => "iban",
            Self::Jwt => "jwt",
            Self::ApiKey => "api_key",
            Self::Email => "email",
            Self::Phone => "phone",
            Self::Ip => "ip",
        }
    }

    pub fn style(self) -> MaskingStyle {
        match self {
            Self::Card | Self::Iban | Self::Phone => MaskingStyle::LastFour,
            Self::Jwt | Self::ApiKey => MaskingStyle::Full,
            Self::Email => MaskingStyle::Email,
            Self::Ip => MaskingStyle::Hash,
        }
    }

    // One such value flags its column; the rest need at least half the non-null values.
    fn flags_on_any(self) -> bool {
        matches!(self, Self::Card | Self::Iban | Self::Jwt | Self::ApiKey)
    }

    pub fn matches(self, text: &str) -> bool {
        match self {
            Self::Card => is_card(text),
            Self::Iban => is_iban(text),
            Self::Jwt => JWT.is_match(text),
            Self::ApiKey => API_KEYS.iter().any(|key| key.is_match(text)),
            Self::Email => EMAIL.is_match(text),
            Self::Phone => is_phone(text),
            Self::Ip => text.parse::<IpAddr>().is_ok(),
        }
    }
}

// A fixed pattern, which `every_pattern_compiles` proves; one that did not would match nothing.
struct Pattern(Option<Regex>);

impl Pattern {
    fn new(source: &str) -> Self {
        Self(Regex::new(source).ok())
    }

    fn is_match(&self, text: &str) -> bool {
        self.0.as_ref().is_some_and(|regex| regex.is_match(text))
    }
}

static NOT_TEXT: LazyLock<Pattern> = LazyLock::new(|| {
    Pattern::new(
        r"\A(u?int[0-9]*|tinyint|smallint|mediumint|bigint|integer|serial|smallserial|bigserial|numeric|decimal[0-9]*|number|real|float[0-9]*|double|money|smallmoney|bool|boolean|bit|date[0-9]*|datetime[0-9]*|smalldatetime|datetimeoffset|time|timetz|timestamp|timestamptz|interval|year|uuid|uniqueidentifier)( .*)?\z",
    )
});
static IBAN: LazyLock<Pattern> = LazyLock::new(|| Pattern::new(r"\A[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\z"));
static JWT: LazyLock<Pattern> =
    LazyLock::new(|| Pattern::new(r"\AeyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z"));
static EMAIL: LazyLock<Pattern> = LazyLock::new(|| Pattern::new(r"\A[^\s@]+@[^\s@]+\.[^\s@]+\z"));
static PHONE: LazyLock<Pattern> = LazyLock::new(|| Pattern::new(r"\A\+?[0-9() .-]+\z"));
static ISO_DATE: LazyLock<Pattern> = LazyLock::new(|| Pattern::new(r"\A[0-9]{4}-[0-9]{2}-[0-9]{2}"));
static DECIMAL: LazyLock<Pattern> = LazyLock::new(|| Pattern::new(r"\A[+-]?[0-9]+\.[0-9]+\z"));
// The secret scan's key patterns, found anywhere in the value.
static API_KEYS: LazyLock<Vec<Pattern>> = LazyLock::new(|| {
    [
        SecretHitKind::AwsAccessKey,
        SecretHitKind::GitHubToken,
        SecretHitKind::SlackToken,
        SecretHitKind::StripeKey,
        SecretHitKind::GoogleApiKey,
    ]
    .into_iter()
    .map(|kind| Pattern::new(kind.pattern()))
    .collect()
});

// A result names `TINYINT(1)` or `Nullable(String)` where the list says `tinyint` or `string`: ClickHouse wrappers are
// unwrapped and the width dropped, as the macOS app reads a type.
fn base_type_name(type_name: &str) -> String {
    const WRAPPERS: [&str; 2] = ["NULLABLE(", "LOWCARDINALITY("];
    let mut name = trim_blanks(type_name);
    while name.ends_with(')') {
        let Some(wrapper) = WRAPPERS.iter().find(|wrapper| {
            name.get(..wrapper.len())
                .is_some_and(|head| head.eq_ignore_ascii_case(wrapper))
        }) else {
            break;
        };
        name = trim_blanks(&name[wrapper.len()..name.len() - 1]);
    }
    trim_blanks(name.split('(').next().unwrap_or_default()).to_owned()
}

// Foundation's `.whitespaces`: tab and the space separators, never a line break.
fn trim_blanks(text: &str) -> &str {
    text.trim_matches(|character: char| {
        matches!(
            character,
            '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
        )
    })
}

// A number, date, time, boolean or UUID column holds no text a person typed; an unknown or empty type might.
pub fn is_text_like(column: &ColumnType) -> bool {
    !NOT_TEXT.is_match(&base_type_name(&column.name).to_lowercase())
}

// The first kind in table order the column's non-null values show. Bytes and empty strings count and never match.
pub fn column_value_kind<'v>(
    column: &ColumnType,
    values: impl IntoIterator<Item = &'v Value>,
) -> Option<SensitiveKind> {
    if !is_text_like(column) {
        return None;
    }
    let mut tally = ValueTally::default();
    for value in values {
        tally.record(Seen::of(column, value));
    }
    tally.kind()
}

// What one value of a text-like column adds to a tally, worked out once for every window it falls in.
#[derive(Debug, Clone, Copy, Default)]
pub struct Seen {
    counted: bool,
    matched: [bool; SensitiveKind::ALL.len()],
}

impl Seen {
    pub fn of(column: &ColumnType, value: &Value) -> Self {
        let mut seen = Self::default();
        match value {
            Value::Null => {}
            Value::Bytes(_) => seen.counted = true,
            value => {
                seen.counted = true;
                if let Some(text) = value_text(value, column).filter(|text| !text.is_empty()) {
                    for (matched, kind) in seen.matched.iter_mut().zip(SensitiveKind::ALL) {
                        *matched = kind.matches(&text);
                    }
                }
            }
        }
        seen
    }
}

// A column's values counted a value at a time, so no window of rows is held to judge them.
#[derive(Debug, Clone, Default)]
pub struct ValueTally {
    counted: usize,
    matched: [usize; SensitiveKind::ALL.len()],
}

impl ValueTally {
    pub fn record(&mut self, seen: Seen) {
        self.counted += usize::from(seen.counted);
        for (count, matched) in self.matched.iter_mut().zip(seen.matched) {
            *count += usize::from(matched);
        }
    }

    pub fn kind(&self) -> Option<SensitiveKind> {
        SensitiveKind::ALL
            .into_iter()
            .zip(self.matched)
            .find(|(kind, count)| *count > 0 && (kind.flags_on_any() || count * 2 >= self.counted))
            .map(|(kind, _)| kind)
    }
}

// Only digits, spaces and dashes; 13 to 19 digits; Luhn.
fn is_card(text: &str) -> bool {
    if !text.chars().all(|character| matches!(character, '0'..='9' | ' ' | '-')) {
        return false;
    }
    let digits: Vec<u32> = text.chars().filter_map(|character| character.to_digit(10)).collect();
    if !(13..=19).contains(&digits.len()) {
        return false;
    }
    let sum: u32 = digits
        .iter()
        .rev()
        .enumerate()
        .map(|(place, digit)| match place % 2 {
            1 if digit * 2 > 9 => digit * 2 - 9,
            1 => digit * 2,
            _ => *digit,
        })
        .sum();
    sum.is_multiple_of(10)
}

// Spaces (U+0020 only) removed, the upper-case form, and mod-97 of the rearranged digits is 1.
fn is_iban(text: &str) -> bool {
    let compact: String = text.chars().filter(|character| *character != ' ').collect();
    if !IBAN.is_match(&compact) {
        return false;
    }
    let (head, tail) = compact.split_at(4);
    let mut remainder = 0_u32;
    for character in tail.chars().chain(head.chars()) {
        let Some(value) = character.to_digit(36) else {
            return false;
        };
        remainder = match value {
            0..=9 => (remainder * 10 + value) % 97,
            _ => (remainder * 100 + value) % 97,
        };
    }
    remainder == 1
}

// 7 to 15 digits with at least one of `+ ( ) - .` or a space, and neither an IPv4 address, an ISO date nor a decimal.
fn is_phone(text: &str) -> bool {
    if !PHONE.is_match(text) {
        return false;
    }
    let digits = text.chars().filter(char::is_ascii_digit).count();
    (7..=15).contains(&digits)
        && text.contains(['+', '(', ')', '-', '.', ' '])
        && text.parse::<Ipv4Addr>().is_err()
        && !ISO_DATE.is_match(text)
        && !DECIMAL.is_match(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::column::ColumnType;

    fn texts(values: &[&str]) -> Vec<Value> {
        values.iter().map(|value| Value::Text((*value).to_owned())).collect()
    }

    fn kind_of(type_name: &str, values: &[Value]) -> Option<SensitiveKind> {
        column_value_kind(&ColumnType::untyped_text(type_name), values)
    }

    #[test]
    fn every_pattern_compiles() {
        for pattern in [&*NOT_TEXT, &*IBAN, &*JWT, &*EMAIL, &*PHONE, &*ISO_DATE, &*DECIMAL] {
            assert!(pattern.0.is_some());
        }
        assert!(API_KEYS.iter().all(|key| key.0.is_some()));
        assert_eq!(API_KEYS.len(), 5);
    }

    #[test]
    fn a_column_of_numbers_dates_or_uuids_is_not_read_for_values() {
        for type_name in [
            "int",
            "bigint unsigned",
            "UInt64",
            "Nullable(Int32)",
            "double precision",
            "timestamp with time zone",
            "Date32",
            "DateTime64(3)",
            "numeric(10,2)",
            "uniqueidentifier",
            "BOOLEAN",
        ] {
            assert!(!is_text_like(&ColumnType::untyped_text(type_name)), "{type_name}");
        }
        for type_name in [
            "",
            "text",
            "varchar(255)",
            "jsonb",
            "String",
            "interval_text",
            "geometry",
        ] {
            assert!(is_text_like(&ColumnType::untyped_text(type_name)), "{type_name}");
        }
        assert_eq!(kind_of("bigint", &texts(&["4111111111111111"])), None);
    }

    #[test]
    fn base_type_names_unwrap_clickhouse_wrappers_and_drop_the_width() {
        assert_eq!(base_type_name("TINYINT(1)"), "TINYINT");
        assert_eq!(base_type_name("  Nullable( String ) "), "String");
        assert_eq!(base_type_name("lowcardinality(nullable(String))"), "String");
        assert_eq!(base_type_name("numeric (10, 2)"), "numeric");
        assert_eq!(base_type_name(""), "");
    }
}
