//! The catalog reads behind a dump. Each takes the scope as `$1` (`all`
//! or `schema`) and `$2` (the schema's name), and orders its rows by
//! schema and name so two dumps of the same database read alike.

/// The schemas a dump covers, the server's own left out.
macro_rules! in_scope {
    () => {
        "n.nspname <> 'information_schema' AND NOT pg_catalog.starts_with(n.nspname, 'pg_')
  AND ($1 = 'all' OR n.nspname = $2)"
    };
}

/// An extension makes its own objects again when it is created.
macro_rules! not_extension_member {
    ($catalog:literal, $oid:literal) => {
        concat!(
            "NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend x
      WHERE x.classid = 'pg_catalog.",
            $catalog,
            "'::pg_catalog.regclass::pg_catalog.oid AND x.objid = ",
            $oid,
            " AND x.deptype = 'e')"
        )
    };
}

/// `public` is in every new database already.
pub(crate) const SCHEMAS_SQL: &str = concat!(
    "SELECT n.nspname::text
FROM pg_catalog.pg_namespace n
WHERE ",
    in_scope!(),
    "
  AND n.nspname <> 'public'
  AND ",
    not_extension_member!("pg_namespace", "n.oid"),
    "
ORDER BY n.nspname"
);

/// plpgsql is in every new database already.
pub(crate) const EXTENSIONS_SQL: &str = concat!(
    "SELECT e.extname::text, n.nspname::text
FROM pg_catalog.pg_extension e
JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
WHERE ",
    in_scope!(),
    "
  AND e.extname <> 'plpgsql'
ORDER BY e.extname"
);

/// Collations users made. The column that names an ICU or builtin
/// locale moved between releases (`colliculocale` in 15 and 16,
/// `colllocale` from 17), so the row is read as JSON.
pub(crate) const COLLATIONS_SQL: &str = concat!(
    "SELECT n.nspname::text, c.collname::text, c.collprovider::text,
       COALESCE((pg_catalog.to_jsonb(c) ->> 'collisdeterministic')::boolean, true),
       pg_catalog.to_jsonb(c) ->> 'collcollate', pg_catalog.to_jsonb(c) ->> 'collctype',
       COALESCE(pg_catalog.to_jsonb(c) ->> 'colllocale', pg_catalog.to_jsonb(c) ->> 'colliculocale'),
       pg_catalog.to_jsonb(c) ->> 'collicurules'
FROM pg_catalog.pg_collation c
JOIN pg_catalog.pg_namespace n ON n.oid = c.collnamespace
WHERE ",
    in_scope!(),
    "
  AND ",
    not_extension_member!("pg_collation", "c.oid"),
    "
ORDER BY n.nspname, c.collname"
);

/// Enums, domains and composite types, then range and base types, which
/// the dump lists as left out. An array type comes with its element type
/// and a table's row type with its table.
pub(crate) const TYPES_SQL: &str = concat!(
    "SELECT n.nspname::text, t.typname::text, t.typtype::text,
       ARRAY(SELECT e.enumlabel::text FROM pg_catalog.pg_enum e
             WHERE e.enumtypid = t.oid ORDER BY e.enumsortorder),
       pg_catalog.format_type(t.typbasetype, t.typtypmod)::text,
       t.typnotnull,
       pg_catalog.pg_get_expr(t.typdefaultbin, 0::pg_catalog.oid)::text,
       cn.nspname::text,
       co.collname::text
FROM pg_catalog.pg_type t
JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
LEFT JOIN pg_catalog.pg_type b ON b.oid = t.typbasetype
LEFT JOIN pg_catalog.pg_collation co ON co.oid = t.typcollation AND t.typcollation <> b.typcollation
LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid = co.collnamespace
WHERE ",
    in_scope!(),
    "
  AND t.typtype IN ('b', 'c', 'd', 'e', 'r')
  AND NOT (t.typtype = 'b' AND t.typelem <> 0::pg_catalog.oid AND t.typlen = -1)
  AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class r WHERE r.oid = t.typrelid AND r.relkind <> 'c')
  AND ",
    not_extension_member!("pg_type", "t.oid"),
    "
ORDER BY CASE t.typtype WHEN 'e' THEN 0 WHEN 'd' THEN 1 ELSE 2 END, n.nspname, t.typname"
);

pub(crate) const DOMAIN_CHECKS_SQL: &str = concat!(
    "SELECT n.nspname::text, t.typname::text, k.conname::text,
       pg_catalog.pg_get_constraintdef(k.oid)::text, k.convalidated
FROM pg_catalog.pg_constraint k
JOIN pg_catalog.pg_type t ON t.oid = k.contypid
JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
WHERE k.contype = 'c' AND ",
    in_scope!(),
    "
ORDER BY n.nspname, t.typname, k.conname"
);

/// `pg_get_functiondef` refuses an aggregate, so one has no text.
macro_rules! functions_sql {
    ($sql_body:expr) => {
        concat!(
            "SELECT n.nspname::text, p.proname::text, p.prokind::text,
       CASE WHEN p.prokind <> 'a' THEN pg_catalog.pg_get_functiondef(p.oid)::text END,
       ",
            $sql_body,
            "
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE ",
            in_scope!(),
            "
  AND ",
            not_extension_member!("pg_proc", "p.oid"),
            "
ORDER BY n.nspname, p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid)"
        )
    };
}

/// Whether a routine waits for the tables: a body in standard SQL that
/// names a table or view, which the server resolves when it is made
/// (PostgreSQL 14 and later), or a signature that names a table's or
/// view's row type, which exists only once the relation does. Any other
/// routine goes first, where a table's DEFAULT or CHECK can call it.
macro_rules! after_tables {
    ($sql_body:literal) => {
        concat!(
            "(",
            $sql_body,
            " OR EXISTS (SELECT 1 FROM pg_catalog.pg_type rt
               JOIN pg_catalog.pg_class rc ON rc.oid = rt.typrelid
              WHERE rc.relkind IN ('r', 'p', 'v', 'm', 'f')
                AND (rt.oid = p.prorettype OR rt.typarray = p.prorettype
                     OR rt.oid = ANY (COALESCE(p.proallargtypes, p.proargtypes::pg_catalog.oid[]))
                     OR rt.typarray = ANY (COALESCE(p.proallargtypes, p.proargtypes::pg_catalog.oid[])))))"
        )
    };
}

pub(crate) const FUNCTIONS_SQL: &str = functions_sql!(after_tables!(
    "(p.prosqlbody IS NOT NULL AND EXISTS (SELECT 1 FROM pg_catalog.pg_depend dep
       WHERE dep.classid = 'pg_catalog.pg_proc'::pg_catalog.regclass AND dep.objid = p.oid
         AND dep.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass))"
));
pub(crate) const FUNCTIONS_SQL_BEFORE_14: &str = functions_sql!(after_tables!("false"));

/// Every sequence, with the column that owns it (`a`) or whose identity
/// it is (`i`), and its position read from the sequence itself:
/// `pg_sequences.last_value` is NULL until the next `nextval`, after a
/// RESTART as well as before the first use. NULL where the login may not
/// read the sequence.
pub(crate) const SEQUENCES_SQL: &str = concat!(
    "SELECT n.nspname::text, c.relname::text, s.data_type::text,
       s.start_value, s.increment_by, s.min_value, s.max_value, s.cache_size, s.cycle,
       c.relpersistence::text, seq_state.last_value,
       d.deptype::text, tn.nspname::text, t.relname::text, a.attname::text, seq_state.is_called
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
JOIN pg_catalog.pg_sequences s ON s.schemaname = n.nspname AND s.sequencename = c.relname
LEFT JOIN LATERAL (
    SELECT (pg_catalog.xpath('/row/last_value/text()', probe.state))[1]::text::bigint AS last_value,
           (pg_catalog.xpath('/row/is_called/text()', probe.state))[1]::text::boolean AS is_called
    FROM (SELECT CASE WHEN pg_catalog.has_sequence_privilege(c.oid, 'SELECT')
                      THEN pg_catalog.query_to_xml(
                               pg_catalog.format('SELECT last_value, is_called FROM %I.%I', n.nspname, c.relname),
                               false, true, '')
                 END AS state) probe
) seq_state ON true
LEFT JOIN pg_catalog.pg_depend d
       ON d.classid = 'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid AND d.objid = c.oid
      AND d.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid
      AND d.refobjsubid > 0 AND d.deptype IN ('a', 'i')
LEFT JOIN pg_catalog.pg_class t ON t.oid = d.refobjid
LEFT JOIN pg_catalog.pg_namespace tn ON tn.oid = t.relnamespace
LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = d.refobjid AND a.attnum::pg_catalog.int4 = d.refobjsubid
WHERE c.relkind = 'S' AND ",
    in_scope!(),
    "
  AND ",
    not_extension_member!("pg_class", "c.oid"),
    "
ORDER BY n.nspname, c.relname"
);

/// Tables, partitioned tables and foreign tables. A partition names its
/// parent; a child or parent by INHERITS is marked, since a read of the
/// parent returns its children's rows too. The last column says whether
/// row-level security shows this login only some of the table's rows.
pub(crate) const TABLES_SQL: &str = concat!(
    "SELECT n.nspname::text, c.relname::text, c.relkind::text, c.relpersistence::text,
       CASE WHEN c.relkind = 'p' THEN pg_catalog.pg_get_partkeydef(c.oid)::text END,
       CASE WHEN c.relispartition THEN pg_catalog.pg_get_expr(c.relpartbound, c.oid)::text END,
       pn.nspname::text, pc.relname::text,
       NOT c.relispartition AND (EXISTS (SELECT 1 FROM pg_catalog.pg_inherits h WHERE h.inhrelid = c.oid)
         OR EXISTS (SELECT 1 FROM pg_catalog.pg_inherits h
                    JOIN pg_catalog.pg_class ch ON ch.oid = h.inhrelid
                    WHERE h.inhparent = c.oid AND NOT ch.relispartition)),
       c.reloptions::text[], am.amname::text, ts.spcname::text,
       pg_catalog.obj_description(c.oid, 'pg_class')::text,
       c.relrowsecurity
         AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles r
                          WHERE r.rolname = CURRENT_USER AND (r.rolsuper OR r.rolbypassrls))
         AND (c.relforcerowsecurity OR NOT pg_catalog.pg_has_role(c.relowner, 'USAGE'))
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_inherits i ON i.inhrelid = c.oid AND c.relispartition
LEFT JOIN pg_catalog.pg_class pc ON pc.oid = i.inhparent
LEFT JOIN pg_catalog.pg_namespace pn ON pn.oid = pc.relnamespace
LEFT JOIN pg_catalog.pg_am am ON am.oid = c.relam AND am.amname <> 'heap'
LEFT JOIN pg_catalog.pg_tablespace ts ON ts.oid = c.reltablespace
WHERE c.relkind IN ('r', 'p', 'f') AND ",
    in_scope!(),
    "
  AND ",
    not_extension_member!("pg_class", "c.oid"),
    "
ORDER BY n.nspname, c.relname"
);

/// The columns of tables, views and composite types. The collation is
/// named only where it is not the type's own.
pub(crate) const COLUMNS_SQL: &str = concat!(
    "SELECT n.nspname::text, c.relname::text, a.attname::text,
       pg_catalog.format_type(a.atttypid, a.atttypmod)::text,
       cn.nspname::text, co.collname::text,
       pg_catalog.pg_get_expr(d.adbin, d.adrelid)::text,
       a.attidentity::text, a.attgenerated::text, a.attnotnull,
       pg_catalog.col_description(a.attrelid, a.attnum::pg_catalog.int4)::text
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation AND a.attcollation <> t.typcollation
LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid = co.collnamespace
WHERE c.relkind IN ('r', 'p', 'v', 'm', 'c') AND a.attnum > 0 AND NOT a.attisdropped AND ",
    in_scope!(),
    "
ORDER BY n.nspname, c.relname, a.attnum"
);

/// A table's own CHECK constraints, and the keys it declared: those a
/// partition took from its parent, or a key copied for each partition of
/// the table it references, come back with the declared one.
pub(crate) const CONSTRAINTS_SQL: &str = concat!(
    "SELECT n.nspname::text, c.relname::text, c.relkind::text, k.conname::text, k.contype::text,
       pg_catalog.pg_get_constraintdef(k.oid)::text, k.convalidated
FROM pg_catalog.pg_constraint k
JOIN pg_catalog.pg_class c ON c.oid = k.conrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND ",
    in_scope!(),
    "
  AND ((k.contype = 'c' AND k.conislocal)
       OR (k.contype IN ('f', 'p', 'u', 'x') AND k.conparentid = 0::pg_catalog.oid))
ORDER BY n.nspname, c.relname, k.conname"
);

/// Indexes no constraint owns. A partition's index attached to its
/// parent's is made by the parent's statement. An invalid index is a
/// build that failed, except on a partitioned table, where it waits for
/// its partitions.
pub(crate) const INDEXES_SQL: &str = concat!(
    "SELECT n.nspname::text, c.relname::text, ic.relname::text,
       pg_catalog.pg_get_indexdef(i.indexrelid)::text, ic.relkind = 'I', i.indisunique,
       pg_catalog.quote_ident(ic.relname)::text, pg_catalog.quote_ident(ts.spcname)::text,
       pg_catalog.pg_get_expr(i.indpred, i.indrelid)::text
FROM pg_catalog.pg_index i
JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
JOIN pg_catalog.pg_class c ON c.oid = i.indrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_tablespace ts ON ts.oid = ic.reltablespace
WHERE c.relkind IN ('r', 'p', 'm') AND ",
    in_scope!(),
    "
  AND i.indislive AND (i.indisvalid OR ic.relkind = 'I')
  AND NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint k
      WHERE k.conindid = i.indexrelid AND k.conrelid = i.indrelid AND k.contype IN ('p', 'u', 'x'))
  AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_inherits h WHERE h.inhrelid = i.indexrelid)
ORDER BY n.nspname, c.relname, ic.relname"
);

pub(crate) const VIEWS_SQL: &str = concat!(
    "SELECT n.nspname::text, c.relname::text, c.relkind::text, pg_catalog.pg_get_viewdef(c.oid)::text,
       c.reloptions::text[], c.relispopulated, am.amname::text, ts.spcname::text,
       pg_catalog.obj_description(c.oid, 'pg_class')::text
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_am am ON am.oid = c.relam AND am.amname <> 'heap'
LEFT JOIN pg_catalog.pg_tablespace ts ON ts.oid = c.reltablespace
WHERE c.relkind IN ('v', 'm') AND ",
    in_scope!(),
    "
  AND ",
    not_extension_member!("pg_class", "c.oid"),
    "
ORDER BY n.nspname, c.relname"
);

/// A partition's copy of its parent's trigger comes with the parent's.
/// Not pretty-printed, so the table is named with its schema.
pub(crate) const TRIGGERS_SQL: &str = concat!(
    "SELECT n.nspname::text, c.relname::text, t.tgname::text,
       pg_catalog.pg_get_triggerdef(t.oid, false)::text, t.tgenabled::text
FROM pg_catalog.pg_trigger t
JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal AND t.tgparentid = 0::pg_catalog.oid AND c.relkind IN ('r', 'p', 'v') AND ",
    in_scope!(),
    "
  AND ",
    not_extension_member!("pg_class", "c.oid"),
    "
ORDER BY n.nspname, c.relname, t.tgname"
);
