use tablepro_core::DriverError;
use tablepro_core::meta::{ObjectInfo, ObjectKind, ObjectScope, SchemaInfo};
use tokio_postgres::Client;

use super::{decode_error, text_rows};

/// Schemas this session can use: no TOAST schemas, and no other
/// session's temporary schema.
const SCHEMAS_SQL: &str = "\
SELECT n.nspname::text,
       COALESCE(n.nspname = current_schema(), false),
       n.nspname = 'information_schema' OR starts_with(n.nspname, 'pg_')
FROM pg_catalog.pg_namespace n
WHERE NOT starts_with(n.nspname, 'pg_toast')
  AND NOT pg_catalog.pg_is_other_temp_schema(n.oid)
ORDER BY n.nspname";

const OBJECTS_SQL: &str = "\
SELECT DISTINCT n.nspname::text, o.name, o.kind
FROM (
    SELECT c.relnamespace AS namespace, c.relname::text AS name, c.relkind::text AS kind
    FROM pg_catalog.pg_class c
    WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
  UNION ALL
    SELECT p.pronamespace, p.proname::text, CASE p.prokind WHEN 'f' THEN 'fn' ELSE 'pr' END
    FROM pg_catalog.pg_proc p
    WHERE p.prokind IN ('f', 'p')
) o
JOIN pg_catalog.pg_namespace n ON n.oid = o.namespace
WHERE NOT pg_catalog.pg_is_other_temp_schema(n.oid)
  AND CASE $1
        WHEN 'default' THEN n.nspname = current_schema()
        WHEN 'schema' THEN n.nspname = $2
        ELSE n.nspname <> 'information_schema' AND NOT starts_with(n.nspname, 'pg_')
      END
ORDER BY 1, 2, 3";

pub(crate) async fn list_schemas(client: &Client) -> Result<Vec<SchemaInfo>, DriverError> {
    let field = decode_error("pg_namespace");
    text_rows(client, SCHEMAS_SQL, &[])
        .await?
        .iter()
        .map(|row| {
            Ok(SchemaInfo {
                name: row.try_get(0).map_err(&field)?,
                is_default: row.try_get(1).map_err(&field)?,
                is_system: row.try_get(2).map_err(&field)?,
            })
        })
        .collect()
}

pub(crate) async fn list_objects(client: &Client, scope: &ObjectScope) -> Result<Vec<ObjectInfo>, DriverError> {
    let (mode, schema) = match scope {
        ObjectScope::DefaultSchema => ("default", ""),
        ObjectScope::Schema(schema) => ("schema", schema.as_str()),
        ObjectScope::AllSchemas => ("all", ""),
    };
    let field = decode_error("pg_class");
    let rows = text_rows(client, OBJECTS_SQL, &[mode, schema]).await?;
    let mut objects = Vec::with_capacity(rows.len());
    for row in &rows {
        let code: String = row.try_get(2).map_err(&field)?;
        let Some(kind) = object_kind(&code) else {
            continue;
        };
        objects.push(ObjectInfo {
            schema: Some(row.try_get(0).map_err(&field)?),
            name: row.try_get(1).map_err(&field)?,
            kind,
        });
    }
    Ok(objects)
}

/// `pg_class.relkind`, or `fn` and `pr` for routines, whose own
/// `prokind` letters collide with the relation kinds.
fn object_kind(code: &str) -> Option<ObjectKind> {
    Some(match code {
        "r" => ObjectKind::Table,
        "p" => ObjectKind::PartitionedTable,
        "v" => ObjectKind::View,
        "m" => ObjectKind::MaterializedView,
        "f" => ObjectKind::ForeignTable,
        "S" => ObjectKind::Sequence,
        "fn" => ObjectKind::Function,
        "pr" => ObjectKind::Procedure,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relation_and_routine_codes_map_to_kinds() {
        assert_eq!(object_kind("r"), Some(ObjectKind::Table));
        assert_eq!(object_kind("p"), Some(ObjectKind::PartitionedTable));
        assert_eq!(object_kind("S"), Some(ObjectKind::Sequence));
        assert_eq!(object_kind("fn"), Some(ObjectKind::Function));
        assert_eq!(object_kind("pr"), Some(ObjectKind::Procedure));
        assert_eq!(object_kind("i"), None);
    }
}
