use sqlx::postgres::PgRow;
use sqlx::{Pool, Postgres, Row};
use tablepro_core::{CATALOG_OBJECT_LIMIT, CatalogObject, CatalogObjectKind, DriverError};

use crate::map_sqlx_error;

pub(crate) const SUPPORTED_KINDS: &[CatalogObjectKind] = &CatalogObjectKind::ALL;

const USER_SCHEMA: &str = "n.nspname NOT IN ('pg_catalog', 'information_schema') \
     AND n.nspname NOT LIKE 'pg\\_toast%' AND n.nspname NOT LIKE 'pg\\_temp\\_%' \
     AND ($1::text IS NULL OR n.nspname = $1)";

fn not_generated(catalog: &str, oid: &str) -> String {
    format!(
        "NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d WHERE d.classid = '{catalog}'::regclass \
         AND d.objid = {oid} AND d.deptype IN ('i', 'e'))"
    )
}

fn routines_sql() -> String {
    let generated = not_generated("pg_catalog.pg_proc", "p.oid");
    format!(
        "SELECT n.nspname, p.proname,
             CASE p.prokind WHEN 'p' THEN 'procedure' WHEN 'a' THEN 'aggregate' WHEN 'w' THEN 'window'
                 ELSE 'function' END || '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')'
         FROM pg_catalog.pg_proc p
         JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
         WHERE {USER_SCHEMA} AND {generated}
         ORDER BY 1, 2, 3 LIMIT $2"
    )
}

fn triggers_sql() -> String {
    format!(
        "SELECT n.nspname, t.tgname, 'on ' || c.relname
         FROM pg_catalog.pg_trigger t
         JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
         JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE NOT t.tgisinternal AND {USER_SCHEMA}
         ORDER BY 1, 2, 3 LIMIT $2"
    )
}

fn sequences_sql() -> String {
    format!(
        "SELECT n.nspname, c.relname, pg_catalog.format_type(s.seqtypid, NULL)
         FROM pg_catalog.pg_sequence s
         JOIN pg_catalog.pg_class c ON c.oid = s.seqrelid
         JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE {USER_SCHEMA}
         ORDER BY 1, 2 LIMIT $2"
    )
}

fn types_sql() -> String {
    let generated = not_generated("pg_catalog.pg_type", "t.oid");
    format!(
        "SELECT n.nspname, t.typname,
             CASE t.typtype WHEN 'e' THEN 'enum' WHEN 'c' THEN 'composite' WHEN 'r' THEN 'range'
                 ELSE 'domain over ' || pg_catalog.format_type(t.typbasetype, t.typtypmod) END
         FROM pg_catalog.pg_type t
         JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
         LEFT JOIN pg_catalog.pg_class c ON c.oid = t.typrelid
         WHERE t.typtype IN ('e', 'c', 'd', 'r') AND (t.typtype <> 'c' OR c.relkind = 'c')
             AND {USER_SCHEMA} AND {generated}
         ORDER BY 1, 2 LIMIT $2"
    )
}

fn grants_sql() -> String {
    format!(
        "SELECT n.nspname, c.relname,
             CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(a.grantee) END
                 || ': ' || string_agg(a.privilege_type, ', ' ORDER BY a.privilege_type)
         FROM pg_catalog.pg_class c
         JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(c.relacl, pg_catalog.acldefault('r', c.relowner))) a
         WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND {USER_SCHEMA}
         GROUP BY n.nspname, c.relname, a.grantee
         ORDER BY 1, 2, 3 LIMIT $2"
    )
}

const EXTENSIONS_SQL: &str = "SELECT n.nspname, e.extname, e.extversion
     FROM pg_catalog.pg_extension e
     JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
     ORDER BY 2 LIMIT $1";

const ROLES_SQL: &str = "SELECT NULL::text, r.rolname,
         NULLIF(concat_ws(', ',
             CASE WHEN r.rolsuper THEN 'superuser' END,
             CASE WHEN r.rolcanlogin THEN 'login' END,
             CASE WHEN r.rolcreatedb THEN 'create database' END,
             CASE WHEN r.rolcreaterole THEN 'create role' END), '')
     FROM pg_catalog.pg_roles r
     WHERE r.rolname NOT LIKE 'pg\\_%'
     ORDER BY 2 LIMIT $1";

fn sql_for(kind: CatalogObjectKind) -> String {
    match kind {
        CatalogObjectKind::Routine => routines_sql(),
        CatalogObjectKind::Trigger => triggers_sql(),
        CatalogObjectKind::Sequence => sequences_sql(),
        CatalogObjectKind::Type => types_sql(),
        CatalogObjectKind::Grant => grants_sql(),
        CatalogObjectKind::Extension => EXTENSIONS_SQL.to_string(),
        CatalogObjectKind::Role => ROLES_SQL.to_string(),
    }
}

pub(crate) async fn list_objects(
    pool: &Pool<Postgres>,
    kind: CatalogObjectKind,
    schema: Option<&str>,
) -> Result<Vec<CatalogObject>, DriverError> {
    let limit = i64::try_from(CATALOG_OBJECT_LIMIT).unwrap_or(i64::MAX);
    let query = sqlx::query(sqlx::AssertSqlSafe(sql_for(kind)));
    let query = match kind.is_schema_scoped() {
        true => query.bind(schema).bind(limit),
        false => query.bind(limit),
    };
    let rows = query.fetch_all(pool).await.map_err(map_sqlx_error)?;
    rows.iter().map(|row| object_from_row(kind, row)).collect()
}

fn object_from_row(kind: CatalogObjectKind, row: &PgRow) -> Result<CatalogObject, DriverError> {
    Ok(CatalogObject {
        kind,
        schema: row.try_get(0).map_err(map_sqlx_error)?,
        name: row.try_get(1).map_err(map_sqlx_error)?,
        detail: row.try_get(2).map_err(map_sqlx_error)?,
    })
}
