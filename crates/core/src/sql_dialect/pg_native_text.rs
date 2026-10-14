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
        "inet" | "cidr" | "macaddr" | "macaddr8" | "xml" | "tsvector" | "tsquery" | "point" | "line" | "lseg"
        | "box" | "path" | "polygon" | "circle" => format!("pg_catalog.{base}"),
        "interval" => "pg_catalog.interval".to_string(),
        "int4range" | "int8range" | "numrange" | "tsrange" | "tstzrange" | "daterange" | "int4multirange"
        | "int8multirange" | "nummultirange" | "tsmultirange" | "tstzmultirange" | "datemultirange" => {
            format!("pg_catalog.{base}")
        }
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

pub(crate) fn postgres_array_cast_type(data_type: &str) -> Option<&'static str> {
    let lowered = data_type.trim().to_ascii_lowercase();
    let element = lowered.strip_suffix("[]")?;
    let element = if let Some((base, modifier)) = element.split_once('(') {
        let modifier = modifier.strip_suffix(')')?;
        if modifier.is_empty()
            || !modifier
                .bytes()
                .all(|byte| byte.is_ascii_digit() || matches!(byte, b',' | b' '))
        {
            return None;
        }
        base.trim()
    } else {
        element
    };
    Some(match element {
        "bool" | "boolean" => "pg_catalog.bool[]",
        "bytea" => "pg_catalog.bytea[]",
        "name" => "pg_catalog.name[]",
        "int2" | "smallint" => "pg_catalog.int2[]",
        "int4" | "integer" | "int" => "pg_catalog.int4[]",
        "int8" | "bigint" => "pg_catalog.int8[]",
        "oid" => "pg_catalog.oid[]",
        "text" => "pg_catalog.text[]",
        "xml" => "pg_catalog.xml[]",
        "bit" => "pg_catalog.bit[]",
        "bit varying" | "varbit" => "pg_catalog.varbit[]",
        "float4" | "real" => "pg_catalog.float4[]",
        "float8" | "double precision" => "pg_catalog.float8[]",
        "varchar" | "character varying" => "pg_catalog.varchar[]",
        "char" | "bpchar" | "character" => "pg_catalog.bpchar[]",
        "numeric" | "decimal" => "pg_catalog.numeric[]",
        "uuid" => "pg_catalog.uuid[]",
        "json" => "pg_catalog.json[]",
        "jsonb" => "pg_catalog.jsonb[]",
        "pg_lsn" => "pg_catalog.pg_lsn[]",
        "date" => "pg_catalog.date[]",
        "time" | "time without time zone" => "pg_catalog.time[]",
        "timetz" | "time with time zone" => "pg_catalog.timetz[]",
        "timestamp" | "timestamp without time zone" => "pg_catalog.timestamp[]",
        "timestamptz" | "timestamp with time zone" => "pg_catalog.timestamptz[]",
        "interval" => "pg_catalog.interval[]",
        _ => return None,
    })
}

fn without_typmod(lowered: &str) -> String {
    let mut out = String::with_capacity(lowered.len());
    let mut depth = 0;
    for c in lowered.chars() {
        match c {
            '(' => depth += 1,
            ')' if depth > 0 => depth -= 1,
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub(crate) fn postgres_temporal_cast_type(data_type: &str) -> Option<&'static str> {
    let lowered = without_typmod(&data_type.trim().to_ascii_lowercase());
    Some(match lowered.as_str() {
        "date" => "pg_catalog.date",
        "time" | "time without time zone" => "pg_catalog.time",
        "timetz" | "time with time zone" => "pg_catalog.timetz",
        "timestamp" | "timestamp without time zone" => "pg_catalog.timestamp",
        "timestamptz" | "timestamp with time zone" => "pg_catalog.timestamptz",
        _ => return None,
    })
}
