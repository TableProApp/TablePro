use tablepro_core::meta::{ObjectInfo, ObjectKind};
use tablepro_core::{DriverError, UnsupportedFeature};
use tokio_postgres::Client;

use super::{decode_error, text_rows};

/// Every overload of the name, in a stable order. `prokind` keeps a
/// function and a procedure of the same name apart, and leaves out
/// aggregates, which `pg_get_functiondef` refuses.
pub(super) const FUNCTIONS_SQL: &str = "\
SELECT pg_catalog.pg_get_functiondef(p.oid)::text
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname::text = $1 AND p.proname::text = $2 AND p.prokind::text = $3
ORDER BY pg_catalog.pg_get_function_identity_arguments(p.oid), p.oid";

pub(super) const SEQUENCE_SQL: &str = "\
SELECT pg_catalog.quote_ident(s.schemaname) || '.' || pg_catalog.quote_ident(s.sequencename),
       s.data_type::text, s.start_value, s.increment_by, s.min_value, s.max_value, s.cache_size, s.cycle
FROM pg_catalog.pg_sequences s
WHERE s.schemaname::text = $1 AND s.sequencename::text = $2";

pub(super) const TRIGGER_SQL: &str = "\
SELECT pg_catalog.pg_get_triggerdef(t.oid, true)::text
FROM pg_catalog.pg_trigger t
JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname::text = $1 AND t.tgname::text = $2 AND c.relname::text = $3 AND NOT t.tgisinternal";

struct SequenceFacts {
    qualified_name: String,
    data_type: String,
    start: i64,
    increment: i64,
    min: i64,
    max: i64,
    cache: i64,
    cycle: bool,
}

pub(crate) async fn fetch_object_definition(client: &Client, object: &ObjectInfo) -> Result<String, DriverError> {
    let unsupported = || DriverError::Unsupported {
        feature: UnsupportedFeature::ObjectDefinitions,
    };
    if !object.kind.has_definition() {
        return Err(unsupported());
    }
    let Some(schema) = object.schema.as_deref() else {
        return Ok(String::new());
    };
    let name = object.name.as_str();
    match object.kind {
        ObjectKind::Function => function_definitions(client, schema, name, "f").await,
        ObjectKind::Procedure => function_definitions(client, schema, name, "p").await,
        ObjectKind::Sequence => sequence_definition(client, schema, name).await,
        ObjectKind::Trigger => match object.table.as_deref() {
            Some(table) => trigger_definition(client, schema, name, table).await,
            None => Ok(String::new()),
        },
        _ => Err(unsupported()),
    }
}

async fn function_definitions(client: &Client, schema: &str, name: &str, prokind: &str) -> Result<String, DriverError> {
    let field = decode_error("pg_proc");
    let mut definitions = Vec::new();
    for row in text_rows(client, FUNCTIONS_SQL, &[schema, name, prokind]).await? {
        let text: Option<String> = row.try_get(0).map_err(&field)?;
        definitions.extend(text.map(|text| terminated(&text)));
    }
    Ok(definitions.join("\n\n"))
}

async fn sequence_definition(client: &Client, schema: &str, name: &str) -> Result<String, DriverError> {
    let field = decode_error("pg_sequences");
    let rows = text_rows(client, SEQUENCE_SQL, &[schema, name]).await?;
    let Some(row) = rows.first() else {
        return Ok(String::new());
    };
    let facts = SequenceFacts {
        qualified_name: row.try_get(0).map_err(&field)?,
        data_type: row.try_get(1).map_err(&field)?,
        start: row.try_get(2).map_err(&field)?,
        increment: row.try_get(3).map_err(&field)?,
        min: row.try_get(4).map_err(&field)?,
        max: row.try_get(5).map_err(&field)?,
        cache: row.try_get(6).map_err(&field)?,
        cycle: row.try_get(7).map_err(&field)?,
    };
    Ok(create_sequence(&facts))
}

async fn trigger_definition(client: &Client, schema: &str, name: &str, table: &str) -> Result<String, DriverError> {
    let field = decode_error("pg_trigger");
    let rows = text_rows(client, TRIGGER_SQL, &[schema, name, table]).await?;
    let text: Option<String> = match rows.first() {
        Some(row) => row.try_get(0).map_err(&field)?,
        None => None,
    };
    Ok(text.map(|text| terminated(&text)).unwrap_or_default())
}

/// The server's text ends in a newline or not, depending on the function.
fn terminated(text: &str) -> String {
    format!("{};", text.trim_end().trim_end_matches(';'))
}

fn create_sequence(facts: &SequenceFacts) -> String {
    format!(
        "CREATE SEQUENCE {}\n    AS {}\n    INCREMENT BY {}\n    MINVALUE {}\n    MAXVALUE {}\n    START WITH {}\n    CACHE {}\n    {};",
        facts.qualified_name,
        facts.data_type,
        facts.increment,
        facts.min,
        facts.max,
        facts.start,
        facts.cache,
        if facts.cycle { "CYCLE" } else { "NO CYCLE" },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sequence_statement_carries_every_catalog_setting() {
        let facts = SequenceFacts {
            qualified_name: "public.\"Orders Seq\"".to_owned(),
            data_type: "integer".to_owned(),
            start: 5,
            increment: -2,
            min: -100,
            max: 50,
            cache: 3,
            cycle: true,
        };
        assert_eq!(
            create_sequence(&facts),
            "CREATE SEQUENCE public.\"Orders Seq\"\n    AS integer\n    INCREMENT BY -2\n    MINVALUE -100\n    MAXVALUE 50\n    START WITH 5\n    CACHE 3\n    CYCLE;"
        );
    }

    #[test]
    fn a_definition_ends_in_one_semicolon() {
        assert_eq!(
            terminated("CREATE FUNCTION f()\n$function$\n"),
            "CREATE FUNCTION f()\n$function$;"
        );
        assert_eq!(terminated("CREATE TRIGGER t ON x;"), "CREATE TRIGGER t ON x;");
    }
}
