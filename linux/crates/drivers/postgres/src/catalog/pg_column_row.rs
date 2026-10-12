use tablepro_core::DriverError;
use tokio_postgres::Row;

use super::type_facts::{TypeFacts, TypeShape};

/// One column of a table, as the catalogue query returns it. Every
/// projected type is built in, so the read never needs a type lookup.
///
/// The recursive CTE follows a domain to its base type, keeping the
/// first modifier along the way, because a domain column's own
/// `atttypmod` is -1 when the modifier was declared on the domain.
pub(crate) const COLUMNS_SQL: &str = "\
WITH RECURSIVE resolved AS (
    SELECT a.attnum, a.atttypid AS type_oid, a.atttypmod AS typmod, 0 AS depth
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = $1::text::regclass AND a.attnum > 0 AND NOT a.attisdropped
  UNION ALL
    SELECT r.attnum, t.typbasetype,
           CASE WHEN r.typmod = -1 THEN t.typtypmod ELSE r.typmod END,
           r.depth + 1
    FROM resolved r
    JOIN pg_catalog.pg_type t ON t.oid = r.type_oid
    WHERE t.typtype = 'd' AND r.depth < 32
),
base AS (
    SELECT DISTINCT ON (attnum) attnum, type_oid, typmod
    FROM resolved
    ORDER BY attnum, depth DESC
)
SELECT a.attname::text,
       pg_catalog.format_type(a.atttypid, a.atttypmod)::text,
       pg_catalog.format_type(a.atttypid, NULL)::text,
       b.type_oid::int8,
       b.typmod::int4,
       bt.typtype::text,
       bt.typname::text,
       et.oid::int8,
       et.typtype::text,
       et.typname::text,
       (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
          FROM pg_catalog.pg_enum e
         WHERE e.enumtypid = COALESCE(et.oid, bt.oid)),
       a.attnotnull,
       COALESCE(a.attnum = ANY (pk.conkey), false),
       pg_catalog.pg_get_expr(d.adbin, d.adrelid)::text,
       a.attidentity::text,
       a.attgenerated::text,
       pg_catalog.col_description(a.attrelid, a.attnum::int4)::text,
       CASE WHEN a.attcollation <> 0 AND a.attcollation <> at.typcollation THEN cn.nspname::text END,
       CASE WHEN a.attcollation <> 0 AND a.attcollation <> at.typcollation THEN co.collname::text END
FROM pg_catalog.pg_attribute a
JOIN base b ON b.attnum = a.attnum
JOIN pg_catalog.pg_type at ON at.oid = a.atttypid
JOIN pg_catalog.pg_type bt ON bt.oid = b.type_oid
LEFT JOIN pg_catalog.pg_type et ON et.oid = bt.typelem AND bt.typcategory = 'A'
LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
LEFT JOIN pg_catalog.pg_constraint pk ON pk.conrelid = a.attrelid AND pk.contype = 'p'
LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation
LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid = co.collnamespace
WHERE a.attrelid = $1::text::regclass AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY a.attnum";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PgColumnRow {
    pub(crate) name: String,
    pub(crate) declaration: String,
    pub(crate) cast_target: String,
    pub(crate) facts: TypeFacts,
    pub(crate) not_null: bool,
    pub(crate) primary_key: bool,
    pub(crate) default_expression: Option<String>,
    /// `pg_attribute.attidentity`: `a` always, `d` by default, empty
    /// for neither.
    pub(crate) identity: String,
    /// `pg_attribute.attgenerated`: `s` stored, `v` virtual (18 on).
    pub(crate) generated: String,
    pub(crate) comment: Option<String>,
    pub(crate) collation: Option<(Option<String>, String)>,
}

impl PgColumnRow {
    pub(crate) fn from_row(row: &Row) -> Result<Self, DriverError> {
        let field = |error: tokio_postgres::Error| DriverError::Decode {
            column: "pg_attribute".to_owned(),
            detail: error.to_string(),
        };
        let base_oid: i64 = row.try_get(3).map_err(field)?;
        let element_oid: Option<i64> = row.try_get(7).map_err(field)?;
        let element_shape: Option<String> = row.try_get(8).map_err(field)?;
        let element_name: Option<String> = row.try_get(9).map_err(field)?;
        let enum_labels: Option<Vec<String>> = row.try_get(10).map_err(field)?;
        let enum_labels = enum_labels.unwrap_or_default();
        let element = match element_oid {
            Some(element_oid) => Some(Box::new(TypeFacts {
                oid: oid_of(element_oid)?,
                typmod: -1,
                shape: TypeShape::from_typtype(element_shape.as_deref().unwrap_or("b")),
                name: element_name.unwrap_or_default(),
                element: None,
                enum_labels: enum_labels.clone(),
            })),
            None => None,
        };
        let typtype: String = row.try_get(5).map_err(field)?;
        let facts = TypeFacts {
            oid: oid_of(base_oid)?,
            typmod: row.try_get(4).map_err(field)?,
            shape: TypeShape::from_typtype(&typtype),
            name: row.try_get(6).map_err(field)?,
            enum_labels: if element.is_some() { Vec::new() } else { enum_labels },
            element,
        };
        let collation_schema: Option<String> = row.try_get(17).map_err(field)?;
        let collation_name: Option<String> = row.try_get(18).map_err(field)?;
        Ok(Self {
            name: row.try_get(0).map_err(field)?,
            declaration: row.try_get(1).map_err(field)?,
            cast_target: row.try_get(2).map_err(field)?,
            facts,
            not_null: row.try_get(11).map_err(field)?,
            primary_key: row.try_get(12).map_err(field)?,
            default_expression: row.try_get(13).map_err(field)?,
            identity: row.try_get(14).map_err(field)?,
            generated: row.try_get(15).map_err(field)?,
            comment: row.try_get(16).map_err(field)?,
            collation: collation_name.map(|name| (collation_schema, name)),
        })
    }
}

fn oid_of(value: i64) -> Result<u32, DriverError> {
    u32::try_from(value).map_err(|_| DriverError::Protocol(format!("{value} is not a type OID")))
}
