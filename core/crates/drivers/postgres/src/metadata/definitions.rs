use tablepro_core::meta::{EditorRefusal, ObjectDefinition, ObjectInfo, ObjectKind};
use tablepro_core::sql_syntax::terminated;
use tablepro_core::{DriverError, UnsupportedFeature};
use tokio_postgres::Client;

use super::{decode_error, text_rows};

/// `prokind` keeps a function and a procedure of one name apart, and
/// leaves out aggregates, which `pg_get_functiondef` refuses.
pub(super) const FUNCTIONS_SQL: &str = "\
SELECT pg_catalog.pg_get_functiondef(p.oid)::text
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname::text = $1 AND p.proname::text = $2 AND p.prokind::text = $3
ORDER BY pg_catalog.pg_get_function_identity_arguments(p.oid), p.oid";

/// Every clause CREATE SEQUENCE takes: the settings, whether it is
/// unlogged or temporary, the column that owns it (`a`), and whether an
/// identity column makes it (`i`).
pub(super) const SEQUENCE_SQL: &str = "\
SELECT pg_catalog.quote_ident(s.schemaname) || '.' || pg_catalog.quote_ident(s.sequencename),
       pg_catalog.quote_ident(s.sequencename),
       s.data_type::text, s.start_value, s.increment_by, s.min_value, s.max_value, s.cache_size, s.cycle,
       c.relpersistence::text,
       (SELECT pg_catalog.quote_ident(tn.nspname) || '.' || pg_catalog.quote_ident(t.relname) || '.'
               || pg_catalog.quote_ident(a.attname)
        FROM pg_catalog.pg_depend d
        JOIN pg_catalog.pg_class t ON t.oid = d.refobjid
        JOIN pg_catalog.pg_namespace tn ON tn.oid = t.relnamespace
        JOIN pg_catalog.pg_attribute a ON a.attrelid = d.refobjid AND a.attnum::pg_catalog.int4 = d.refobjsubid
        WHERE d.classid = 'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid AND d.objid = c.oid
          AND d.deptype = 'a'
        LIMIT 1),
       EXISTS (SELECT 1 FROM pg_catalog.pg_depend d
               WHERE d.classid = 'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid
                 AND d.objid = c.oid AND d.deptype = 'i')
FROM pg_catalog.pg_sequences s
JOIN pg_catalog.pg_namespace n ON n.nspname = s.schemaname
JOIN pg_catalog.pg_class c ON c.relnamespace = n.oid AND c.relname = s.sequencename
WHERE s.schemaname::text = $1 AND s.sequencename::text = $2";

/// Not pretty-printed, so the table is always named with its schema.
pub(super) const TRIGGER_SQL: &str = "\
SELECT pg_catalog.pg_get_triggerdef(t.oid, false)::text
FROM pg_catalog.pg_trigger t
JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname::text = $1 AND t.tgname::text = $2 AND c.relname::text = $3 AND NOT t.tgisinternal";

struct SequenceFacts {
    qualified_name: String,
    bare_name: String,
    persistence: String,
    owned_by: Option<String>,
    data_type: String,
    start: i64,
    increment: i64,
    min: i64,
    max: i64,
    cache: i64,
    cycle: bool,
}

/// Every text names the object with its schema, so it runs in any tab.
pub(crate) async fn fetch_object_definition(
    client: &Client,
    object: &ObjectInfo,
) -> Result<Option<ObjectDefinition>, DriverError> {
    let schema = object.schema.as_deref().unwrap_or_default();
    let name = object.name.as_str();
    let sql = match (object.kind, object.parent_table.as_deref()) {
        (ObjectKind::Function, _) => function_definitions(client, schema, name, "f").await?,
        (ObjectKind::Procedure, _) => function_definitions(client, schema, name, "p").await?,
        (ObjectKind::Sequence, _) => return sequence_definition(client, schema, name).await,
        (ObjectKind::Trigger, Some(table)) => trigger_definition(client, schema, name, table).await?,
        _ => {
            return Err(DriverError::Unsupported {
                feature: UnsupportedFeature::ObjectDefinitions,
            });
        }
    };
    Ok(sql.map(|sql| ObjectDefinition {
        sql,
        database: None,
        refusal: None,
    }))
}

async fn function_definitions(
    client: &Client,
    schema: &str,
    name: &str,
    prokind: &str,
) -> Result<Option<String>, DriverError> {
    let field = decode_error("pg_proc");
    let mut definitions = Vec::new();
    for row in text_rows(client, FUNCTIONS_SQL, &[schema, name, prokind]).await? {
        let text: Option<String> = row.try_get(0).map_err(&field)?;
        definitions.extend(text.map(|text| terminated(&text)));
    }
    Ok((!definitions.is_empty()).then(|| definitions.join("\n\n")))
}

/// PostgreSQL has no function that prints a sequence, so the statement is
/// built from the catalog.
async fn sequence_definition(
    client: &Client,
    schema: &str,
    name: &str,
) -> Result<Option<ObjectDefinition>, DriverError> {
    let field = decode_error("pg_sequences");
    let rows = text_rows(client, SEQUENCE_SQL, &[schema, name]).await?;
    let Some(row) = rows.first() else {
        return Ok(None);
    };
    let facts = SequenceFacts {
        qualified_name: row.try_get(0).map_err(&field)?,
        bare_name: row.try_get(1).map_err(&field)?,
        data_type: row.try_get(2).map_err(&field)?,
        start: row.try_get(3).map_err(&field)?,
        increment: row.try_get(4).map_err(&field)?,
        min: row.try_get(5).map_err(&field)?,
        max: row.try_get(6).map_err(&field)?,
        cache: row.try_get(7).map_err(&field)?,
        cycle: row.try_get(8).map_err(&field)?,
        persistence: row.try_get(9).map_err(&field)?,
        owned_by: row.try_get(10).map_err(&field)?,
    };
    let identity: bool = row.try_get(11).map_err(&field)?;
    Ok(Some(ObjectDefinition {
        sql: create_sequence(&facts),
        database: None,
        refusal: identity.then_some(EditorRefusal::MadeWithOther),
    }))
}

async fn trigger_definition(
    client: &Client,
    schema: &str,
    name: &str,
    table: &str,
) -> Result<Option<String>, DriverError> {
    let field = decode_error("pg_trigger");
    let rows = text_rows(client, TRIGGER_SQL, &[schema, name, table]).await?;
    let text: Option<String> = match rows.first() {
        Some(row) => row.try_get(0).map_err(&field)?,
        None => None,
    };
    Ok(text.map(|text| terminated(&text)))
}

fn create_sequence(facts: &SequenceFacts) -> String {
    // A temporary sequence lives in the session's own temporary schema,
    // which a name with the other session's schema would miss.
    let (kind, name) = match facts.persistence.as_str() {
        "u" => ("UNLOGGED SEQUENCE", &facts.qualified_name),
        "t" => ("TEMPORARY SEQUENCE", &facts.bare_name),
        _ => ("SEQUENCE", &facts.qualified_name),
    };
    let owned_by = facts
        .owned_by
        .as_ref()
        .map(|column| format!("\n    OWNED BY {column}"))
        .unwrap_or_default();
    format!(
        "CREATE {kind} {name}\n    AS {}\n    INCREMENT BY {}\n    MINVALUE {}\n    MAXVALUE {}\n    START WITH {}\n    CACHE {}\n    {}{owned_by};",
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

    fn facts(persistence: &str, owned_by: Option<&str>) -> SequenceFacts {
        SequenceFacts {
            qualified_name: "public.\"Orders Seq\"".to_owned(),
            bare_name: "\"Orders Seq\"".to_owned(),
            persistence: persistence.to_owned(),
            owned_by: owned_by.map(str::to_owned),
            data_type: "integer".to_owned(),
            start: 5,
            increment: -2,
            min: -100,
            max: 50,
            cache: 3,
            cycle: true,
        }
    }

    #[test]
    fn sequence_statement_carries_every_catalog_setting() {
        assert_eq!(
            create_sequence(&facts("p", None)),
            "CREATE SEQUENCE public.\"Orders Seq\"\n    AS integer\n    INCREMENT BY -2\n    MINVALUE -100\n    MAXVALUE 50\n    START WITH 5\n    CACHE 3\n    CYCLE;"
        );
    }

    #[test]
    fn persistence_and_the_owning_column_are_kept() {
        let unlogged = create_sequence(&facts("u", Some("public.orders.id")));
        assert!(
            unlogged.starts_with("CREATE UNLOGGED SEQUENCE public.\"Orders Seq\"\n"),
            "{unlogged}"
        );
        assert!(
            unlogged.ends_with("CYCLE\n    OWNED BY public.orders.id;"),
            "{unlogged}"
        );
        let temporary = create_sequence(&facts("t", None));
        assert!(
            temporary.starts_with("CREATE TEMPORARY SEQUENCE \"Orders Seq\"\n"),
            "{temporary}"
        );
    }
}
