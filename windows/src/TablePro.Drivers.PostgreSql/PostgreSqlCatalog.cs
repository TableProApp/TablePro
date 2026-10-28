namespace TablePro.Drivers.PostgreSql;

/// <summary>
/// Catalog reads against <c>pg_catalog</c>, bound to <c>@schema</c> and <c>@table</c>. They read the catalog
/// directly rather than <c>information_schema</c>, whose views filter by privilege and cost a planner trip each.
/// Columns that only newer servers have (<c>attidentity</c>, <c>attgenerated</c>) are read through
/// <c>to_jsonb(row)</c>, which yields NULL on a server without them instead of failing the query.
/// The floor is PostgreSQL 11, for <c>prokind</c> and <c>indnkeyatts</c>.
/// </summary>
internal static class PostgreSqlCatalog
{
    public const string Databases = """
        SELECT datname FROM pg_catalog.pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname
        """;

    // pg_ covers pg_catalog, pg_toast and every pg_temp_N.
    public const string Schemas = """
        SELECT nspname FROM pg_catalog.pg_namespace
        WHERE nspname NOT LIKE 'pg!_%' ESCAPE '!' AND nspname <> 'information_schema'
        ORDER BY nspname
        """;

    // A partition is reached through its parent, so only the parent is listed. A function an extension installed
    // is the extension's, not the user's. reltuples is -1 until the first ANALYZE on PostgreSQL 14 and later.
    public const string Objects = """
        SELECT c.relname, c.relkind::text, CASE WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END, d.description
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_catalog.pg_description d
               ON d.objoid = c.oid AND d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass AND d.objsubid = 0
        WHERE n.nspname = @schema
          AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
          AND NOT c.relispartition
        UNION ALL
        SELECT p.proname, CASE WHEN p.prokind = 'p' THEN 'P' ELSE 'F' END, NULL, min(d.description)
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        LEFT JOIN pg_catalog.pg_description d
               ON d.objoid = p.oid AND d.classoid = 'pg_catalog.pg_proc'::pg_catalog.regclass AND d.objsubid = 0
        WHERE n.nspname = @schema
          AND p.prokind IN ('f', 'p')
          AND NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_depend dep
                WHERE dep.classid = 'pg_catalog.pg_proc'::pg_catalog.regclass AND dep.objid = p.oid AND dep.deptype = 'e')
        GROUP BY p.proname, p.prokind
        ORDER BY 2, 1
        """;

    public const string Columns = """
        SELECT a.attname,
               pg_catalog.format_type(a.atttypid, a.atttypmod),
               NOT a.attnotnull,
               CASE WHEN COALESCE(to_jsonb(a) ->> 'attgenerated', '') = '' THEN pg_catalog.pg_get_expr(ad.adbin, ad.adrelid) END,
               EXISTS (SELECT 1 FROM pg_catalog.pg_index i WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY (i.indkey)),
               COALESCE(to_jsonb(a) ->> 'attidentity', '') <> ''
                   OR COALESCE(pg_catalog.pg_get_expr(ad.adbin, ad.adrelid), '') LIKE 'nextval(%',
               pg_catalog.col_description(c.oid, a.attnum)
        FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
        WHERE n.nspname = @schema AND c.relname = @table AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
        """;

    // indkey is an int2vector, subscripted from 0; a 0 entry is an expression, which pg_get_indexdef spells.
    public const string Indexes = """
        SELECT ic.relname, i.indisunique, i.indisprimary, am.amname,
               ARRAY(SELECT COALESCE(a.attname::text, pg_catalog.pg_get_indexdef(i.indexrelid, k.n, true))
                     FROM generate_series(1, i.indnkeyatts) AS k(n)
                     LEFT JOIN pg_catalog.pg_attribute a
                            ON a.attrelid = i.indrelid AND a.attnum = i.indkey[k.n - 1] AND i.indkey[k.n - 1] <> 0
                     ORDER BY k.n)
        FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
        JOIN pg_catalog.pg_class c ON c.oid = i.indrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_am am ON am.oid = ic.relam
        WHERE n.nspname = @schema AND c.relname = @table
        ORDER BY i.indisprimary DESC, ic.relname
        """;

    public const string ForeignKeys = """
        SELECT con.conname,
               ARRAY(SELECT a.attname::text FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
                     JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum ORDER BY k.ord),
               fn.nspname, fc.relname,
               ARRAY(SELECT a.attname::text FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
                     JOIN pg_catalog.pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum ORDER BY k.ord),
               con.confupdtype::text, con.confdeltype::text
        FROM pg_catalog.pg_constraint con
        JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_class fc ON fc.oid = con.confrelid
        JOIN pg_catalog.pg_namespace fn ON fn.oid = fc.relnamespace
        WHERE con.contype = 'f' AND n.nspname = @schema AND c.relname = @table
        ORDER BY con.conname
        """;

    public const string Triggers = """
        SELECT t.tgname, t.tgtype, pg_catalog.pg_get_triggerdef(t.oid, true)
        FROM pg_catalog.pg_trigger t
        JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE NOT t.tgisinternal AND n.nspname = @schema AND c.relname = @table
        ORDER BY t.tgname
        """;

    public const string RelationKind = """
        SELECT c.relkind::text, CASE WHEN c.relkind = 'p' THEN pg_catalog.pg_get_partkeydef(c.oid) END
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = @schema AND c.relname = @table
        """;

    // The same column clauses pg_dump writes, so the statement recreates identity, generated and collated columns.
    public const string ColumnDefinitions = """
        SELECT pg_catalog.quote_ident(a.attname) || ' ' || pg_catalog.format_type(a.atttypid, a.atttypmod)
               || CASE WHEN a.attcollation <> 0 AND a.attcollation <> t.typcollation
                       THEN ' COLLATE ' || pg_catalog.quote_ident(co.collname) ELSE '' END
               || CASE to_jsonb(a) ->> 'attidentity'
                       WHEN 'a' THEN ' GENERATED ALWAYS AS IDENTITY'
                       WHEN 'd' THEN ' GENERATED BY DEFAULT AS IDENTITY' ELSE '' END
               || CASE to_jsonb(a) ->> 'attgenerated'
                       WHEN 's' THEN ' GENERATED ALWAYS AS (' || pg_catalog.pg_get_expr(ad.adbin, ad.adrelid) || ') STORED'
                       WHEN 'v' THEN ' GENERATED ALWAYS AS (' || pg_catalog.pg_get_expr(ad.adbin, ad.adrelid) || ') VIRTUAL'
                       ELSE '' END
               || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
               || CASE WHEN ad.adbin IS NOT NULL AND COALESCE(to_jsonb(a) ->> 'attgenerated', '') = ''
                       THEN ' DEFAULT ' || pg_catalog.pg_get_expr(ad.adbin, ad.adrelid) ELSE '' END
        FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
        LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation
        LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
        WHERE n.nspname = @schema AND c.relname = @table AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
        """;

    public const string ConstraintDefinitions = """
        SELECT 'CONSTRAINT ' || pg_catalog.quote_ident(con.conname) || ' ' || pg_catalog.pg_get_constraintdef(con.oid, true)
        FROM pg_catalog.pg_constraint con
        JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = @schema AND c.relname = @table AND con.contype IN ('p', 'u', 'c', 'f', 'x')
        ORDER BY CASE con.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'c' THEN 2 WHEN 'f' THEN 3 ELSE 4 END, con.conname
        """;

    // An index that backs a key or exclusion constraint is written by the constraint itself.
    public const string StandaloneIndexDefinitions = """
        SELECT pg_catalog.pg_get_indexdef(i.indexrelid)
        FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_class c ON c.oid = i.indrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
        WHERE n.nspname = @schema AND c.relname = @table
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint con WHERE con.conindid = i.indexrelid AND con.contype IN ('p', 'u', 'x'))
        ORDER BY ic.relname
        """;

    public const string CommentStatements = """
        SELECT format('COMMENT ON %s %I.%I IS %L',
                      CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE' END,
                      n.nspname, c.relname, d.description)
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_description d ON d.objoid = c.oid AND d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass AND d.objsubid = 0
        WHERE n.nspname = @schema AND c.relname = @table
        UNION ALL
        SELECT format('COMMENT ON COLUMN %I.%I.%I IS %L', n.nspname, c.relname, a.attname, d.description)
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        JOIN pg_catalog.pg_description d ON d.objoid = c.oid AND d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass AND d.objsubid = a.attnum
        WHERE n.nspname = @schema AND c.relname = @table
        """;

    public const string ViewDefinition = """
        SELECT c.relkind::text, pg_catalog.pg_get_viewdef(c.oid, true)
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = @schema AND c.relname = @table AND c.relkind IN ('v', 'm')
        """;

    // Every overload, since an ObjectName carries no argument list. pg_get_functiondef raises on an aggregate.
    public const string RoutineDefinitions = """
        SELECT pg_catalog.pg_get_functiondef(p.oid)
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = @schema AND p.proname = @table AND p.prokind IN ('f', 'p')
        ORDER BY p.oid
        """;

    public const string SequenceDefinition = """
        SELECT pg_catalog.format_type(s.seqtypid, NULL), s.seqstart, s.seqincrement, s.seqmin, s.seqmax, s.seqcache, s.seqcycle
        FROM pg_catalog.pg_sequence s
        JOIN pg_catalog.pg_class c ON c.oid = s.seqrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = @schema AND c.relname = @table
        """;

    public const string TriggerDefinition = """
        SELECT pg_catalog.pg_get_triggerdef(t.oid, true)
        FROM pg_catalog.pg_trigger t
        JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = @schema AND t.tgname = @table AND NOT t.tgisinternal
        """;

    public const string Activity = """
        SELECT pid, usename, datname, application_name, client_addr::text AS client_addr, state,
               backend_start, xact_start, query_start, wait_event_type, wait_event, query
        FROM pg_catalog.pg_stat_activity
        WHERE backend_type = 'client backend'
        ORDER BY backend_start
        """;

    public const string Terminate = "SELECT pg_catalog.pg_terminate_backend(@pid)";

    public const string Users = """
        SELECT r.rolname, r.rolsuper, r.rolinherit, r.rolcreaterole, r.rolcreatedb, r.rolcanlogin, r.rolreplication,
               r.rolconnlimit, r.rolvaliduntil,
               ARRAY(SELECT b.rolname::text FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles b ON b.oid = m.roleid
                     WHERE m.member = r.oid ORDER BY b.rolname) AS member_of
        FROM pg_catalog.pg_roles r
        WHERE r.rolname NOT LIKE 'pg!_%' ESCAPE '!'
        ORDER BY r.rolname
        """;

    public const string Settings = """
        SELECT name, setting, unit, category, short_desc, source, context FROM pg_catalog.pg_settings ORDER BY name
        """;
}
