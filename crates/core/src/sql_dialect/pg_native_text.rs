pub(crate) fn postgres_native_text_cast_type(data_type: &str) -> Option<String> {
    if data_type.len() > 64 {
        return None;
    }
    let lowered = data_type.trim().to_ascii_lowercase();
    let (base, modifier) = match lowered.split_once('(') {
        Some((base, rest)) => (base.trim(), Some(rest.strip_suffix(')')?.trim())),
        None => (lowered.as_str(), None),
    };
    let length = |modifier: Option<&str>| match modifier {
        None => Some(String::new()),
        Some(digits) if !digits.is_empty() && digits.len() <= 5 && digits.bytes().all(|byte| byte.is_ascii_digit()) => {
            Some(format!("({digits})"))
        }
        Some(_) => None,
    };
    Some(match base {
        "inet" | "cidr" | "macaddr" | "macaddr8" | "xml" | "tsvector" | "tsquery" => format!("pg_catalog.{base}"),
        "interval" => "pg_catalog.interval".to_string(),
        _ if base.starts_with("interval ") => "pg_catalog.interval".to_string(),
        "bit" => format!("pg_catalog.bit{}", length(modifier)?),
        "bit varying" | "varbit" => format!("pg_catalog.varbit{}", length(modifier)?),
        "bpchar" | "character" | "char" => "pg_catalog.bpchar".to_string(),
        _ => return None,
    })
}

pub(crate) fn text_cast_placeholder(column: &crate::ColumnInfo, value: &crate::Value, placeholder: String) -> String {
    super::postgres_text_cast_type(column, value)
        .map(|type_name| format!("{placeholder}::text::{type_name}"))
        .unwrap_or(placeholder)
}
