import Foundation

// scripts/probes/check-table-health-catalogs.sh runs these literals against real servers: keep them free of interpolation.
// Every query leaves out what an extension owns, by relation and by schema: TimescaleDB's chunk tables are not extension
// members themselves, but their schema is, and a fix there would change the extension's own objects.
struct PostgreSQLTableHealthProvider: TableHealthProvider {
    let checks: [TableHealthCheckKind] = [
        .bloat, .unusedIndex, .redundantIndex, .invalidIndex, .missingPrimaryKey, .unindexedForeignKey,
        .nearLimit, .transactionIdAge, .staleStatistics
    ]

    // The checks that read activity counters, which a standby keeps for its own queries only.
    private static let counterChecks: [TableHealthCheckKind] = [.bloat, .unusedIndex, .staleStatistics]

    static let statisticsQuery = """
        SELECT pg_catalog.current_setting('track_counts') AS track_counts,
               pg_catalog.date_part('epoch', d.stats_reset) AS stats_reset,
               pg_catalog.current_setting('server_version_num') AS server_version_num,
               pg_catalog.pg_is_in_recovery() AS in_recovery
        FROM pg_catalog.pg_stat_database d
        WHERE d.datname = pg_catalog.current_database()
        """

    // The floor keeps tiny tables out. A pg_ schema is another session's temporary one.
    static let bloatQuery = """
        SELECT s.schemaname AS schema_name,
               s.relname AS table_name,
               s.n_live_tup AS live_rows,
               s.n_dead_tup AS dead_rows,
               pg_catalog.date_part('epoch', GREATEST(s.last_vacuum, s.last_autovacuum)) AS last_vacuum,
               pg_catalog.pg_table_size(c.oid) AS table_bytes
        FROM pg_catalog.pg_stat_user_tables s
        JOIN pg_catalog.pg_class c ON c.oid = s.relid
        WHERE c.relkind = 'r'
          AND pg_catalog.left(s.schemaname, 3) <> 'pg_'
          AND s.n_dead_tup >= 1000
          AND s.n_dead_tup >= s.n_live_tup / 5
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                AND x.objid = c.oid
                AND x.deptype = 'e'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
                AND x.objid = c.relnamespace
                AND x.deptype = 'e'
          )
        ORDER BY s.n_dead_tup DESC, s.schemaname, s.relname
        """

    // A unique or constraint index enforces something no scan counts, an index a foreign key's
    // checks use is needed the first time the referenced table deletes, and a partition's index
    // that a parent index owns cannot be dropped alone. The foreign key test is the one
    // unindexedForeignKeyQuery uses.
    static let unusedIndexQuery = """
        SELECT s.schemaname AS schema_name,
               s.relname AS table_name,
               s.indexrelname AS index_name,
               pg_catalog.pg_relation_size(s.indexrelid) AS index_bytes
        FROM pg_catalog.pg_stat_user_indexes s
        JOIN pg_catalog.pg_index i ON i.indexrelid = s.indexrelid
        JOIN pg_catalog.pg_class t ON t.oid = s.relid
        WHERE s.idx_scan = 0
          AND t.relkind = 'r'
          AND pg_catalog.left(s.schemaname, 3) <> 'pg_'
          AND NOT i.indisunique
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint c WHERE c.conindid = s.indexrelid)
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_inherits h WHERE h.inhrelid = s.indexrelid)
          AND NOT (
              i.indpred IS NULL
              AND i.indisvalid
              AND EXISTS (
                  SELECT 1 FROM pg_catalog.pg_constraint fk
                  WHERE fk.contype = 'f'
                    AND fk.conrelid = i.indrelid
                    AND pg_catalog.array_length(fk.conkey, 1)
                        <= COALESCE((pg_catalog.row_to_json(i) OPERATOR(pg_catalog.->>) 'indnkeyatts'::pg_catalog.text)::pg_catalog.int4, i.indnatts)
                    AND (i.indkey::pg_catalog.int2[])[0:pg_catalog.array_length(fk.conkey, 1) - 1] OPERATOR(pg_catalog.@>) fk.conkey
              )
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                AND x.objid = t.oid
                AND x.deptype = 'e'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
                AND x.objid = t.relnamespace
                AND x.deptype = 'e'
          )
        ORDER BY index_bytes DESC, schema_name, index_name
        """

    // A partition takes its primary key from its parent, so only the parent is listed.
    static let missingPrimaryKeyQuery = """
        SELECT n.nspname AS schema_name,
               c.relname AS table_name,
               GREATEST(c.reltuples, 0)::pg_catalog.int8 AS estimated_rows,
               pg_catalog.pg_table_size(c.oid) AS table_bytes
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p')
          AND n.nspname <> 'information_schema'
          AND pg_catalog.left(n.nspname, 3) <> 'pg_'
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_constraint con
              WHERE con.conrelid = c.oid AND con.contype = 'p'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_inherits h
              JOIN pg_catalog.pg_class p ON p.oid = h.inhparent
              WHERE h.inhrelid = c.oid AND p.relkind = 'p'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                AND x.objid = c.oid
                AND x.deptype = 'e'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
                AND x.objid = c.relnamespace
                AND x.deptype = 'e'
          )
        ORDER BY n.nspname, c.relname
        """

    // One row per referencing column. An index covers the key when its leading key columns are the
    // key's columns in any order; a partial or invalid index does not, nor does an INCLUDE column.
    // A partition's clone of its parent's key (conparentid) is left to the parent's finding.
    // indnkeyatts and conparentid go through row_to_json because servers before 11 lack them.
    static let unindexedForeignKeyQuery = """
        SELECT n.nspname AS schema_name,
               c.relname AS table_name,
               c.relkind AS table_kind,
               con.conname AS constraint_name,
               a.attname AS column_name,
               rn.nspname AS referenced_schema,
               rc.relname AS referenced_table,
               GREATEST(c.reltuples, 0)::pg_catalog.int8 AS estimated_rows,
               pg_catalog.pg_table_size(c.oid) AS table_bytes
        FROM pg_catalog.pg_constraint con
        JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_class rc ON rc.oid = con.confrelid
        JOIN pg_catalog.pg_namespace rn ON rn.oid = rc.relnamespace
        CROSS JOIN LATERAL pg_catalog.unnest(con.conkey) WITH ORDINALITY AS k(attnum, position)
        JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
        WHERE con.contype = 'f'
          AND pg_catalog.left(n.nspname, 3) <> 'pg_'
          AND COALESCE(pg_catalog.row_to_json(con) OPERATOR(pg_catalog.->>) 'conparentid'::pg_catalog.text, '0') = '0'
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_index i
              WHERE i.indrelid = con.conrelid
                AND i.indpred IS NULL
                AND i.indisvalid
                AND pg_catalog.array_length(con.conkey, 1)
                    <= COALESCE((pg_catalog.row_to_json(i) OPERATOR(pg_catalog.->>) 'indnkeyatts'::pg_catalog.text)::pg_catalog.int4, i.indnatts)
                AND (i.indkey::pg_catalog.int2[])[0:pg_catalog.array_length(con.conkey, 1) - 1] OPERATOR(pg_catalog.@>) con.conkey
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                AND x.objid = c.oid
                AND x.deptype = 'e'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
                AND x.objid = c.relnamespace
                AND x.deptype = 'e'
          )
        ORDER BY n.nspname, c.relname, con.conname, k.position
        """

    // One row per index column; PostgreSQLIndexShape compares them. A key part is the deparsed column or expression
    // with its operator class, collation and sort flags. indnkeyatts (11+) and indnullsnotdistinct (15+) go through
    // row_to_json for older servers.
    static let redundantIndexQuery = """
        SELECT n.nspname AS schema_name,
               t.relname AS table_name,
               t.relkind AS table_kind,
               ic.relname AS index_name,
               am.amname AS access_method,
               i.indisunique AS is_unique,
               i.indisprimary AS is_primary,
               i.indimmediate AS is_immediate,
               COALESCE(pg_catalog.row_to_json(i) OPERATOR(pg_catalog.->>) 'indnullsnotdistinct'::pg_catalog.text, 'false') AS nulls_not_distinct,
               (i.indisreplident
                OR EXISTS (SELECT 1 FROM pg_catalog.pg_constraint con WHERE con.conindid = i.indexrelid)
                OR EXISTS (SELECT 1 FROM pg_catalog.pg_inherits h WHERE h.inhrelid = i.indexrelid)) AS is_protected,
               pg_catalog.pg_get_expr(i.indpred, i.indrelid) AS predicate,
               pg_catalog.pg_relation_size(i.indexrelid) AS index_bytes,
               CASE WHEN p.position = 1 THEN pg_catalog.pg_get_indexdef(i.indexrelid) END AS index_definition,
               k.key_count,
               p.position,
               pg_catalog.pg_get_indexdef(i.indexrelid, p.position, true) AS column_text,
               CASE WHEN p.position <= k.key_count THEN (i.indclass::pg_catalog.oid[])[p.position - 1] END AS opclass,
               CASE WHEN p.position <= k.key_count THEN (i.indcollation::pg_catalog.oid[])[p.position - 1] END AS collation,
               CASE WHEN p.position <= k.key_count THEN (i.indoption::pg_catalog.int2[])[p.position - 1] END AS sort_option
        FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
        JOIN pg_catalog.pg_class t ON t.oid = i.indrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_catalog.pg_am am ON am.oid = ic.relam
        CROSS JOIN LATERAL (
            SELECT COALESCE((pg_catalog.row_to_json(i) OPERATOR(pg_catalog.->>) 'indnkeyatts'::pg_catalog.text)::pg_catalog.int4, i.indnatts) AS key_count
        ) k
        CROSS JOIN LATERAL pg_catalog.generate_series(1, i.indnatts) AS p(position)
        WHERE i.indisvalid
          AND t.relkind IN ('r', 'p', 'm')
          AND n.nspname <> 'information_schema'
          AND pg_catalog.left(n.nspname, 3) <> 'pg_'
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                AND x.objid = t.oid
                AND x.deptype = 'e'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
                AND x.objid = t.relnamespace
                AND x.deptype = 'e'
          )
        ORDER BY n.nspname, t.relname, ic.relname, p.position
        """

    // A build still running holds SHARE UPDATE EXCLUSIVE on its table for the whole build, which any role can see in
    // pg_locks. An index built ON ONLY a partitioned table (relkind I) stays invalid by design until every partition
    // attaches one, so it is not a leftover.
    static let invalidIndexQuery = """
        SELECT n.nspname AS schema_name,
               t.relname AS table_name,
               c.relname AS index_name,
               i.indisunique AS is_unique,
               i.indisready AS is_ready,
               pg_catalog.pg_relation_size(i.indexrelid) AS index_bytes,
               pg_catalog.pg_get_indexdef(i.indexrelid) AS index_definition
        FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_class c ON c.oid = i.indexrelid
        JOIN pg_catalog.pg_class t ON t.oid = i.indrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
        WHERE NOT i.indisvalid
          AND c.relkind = 'i'
          AND pg_catalog.left(n.nspname, 3) <> 'pg_'
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_locks l
              WHERE l.locktype = 'relation'
                AND l.database = (SELECT d.oid FROM pg_catalog.pg_database d WHERE d.datname = pg_catalog.current_database())
                AND l.relation = i.indrelid
                AND l.mode = 'ShareUpdateExclusiveLock'
                AND l.granted
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                AND x.objid = t.oid
                AND x.deptype = 'e'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
                AND x.objid = t.relnamespace
                AND x.deptype = 'e'
          )
        ORDER BY n.nspname, t.relname, c.relname
        """

    // pg_sequence is 10+. The range is the narrower of the sequence's own limits and the integer column it feeds
    // through OWNED BY, an identity or a nextval default; the narrowest such column wins. last_value reads as
    // pg_sequences reads it: NULL without SELECT or USAGE, and for an unlogged sequence on a standby, where reading
    // one fails before 17. A cycling sequence wraps by design. Unreadable sequences come back for the check's note.
    static let nearLimitQuery = """
        SELECT r.sequence_schema, r.sequence_name, r.sequence_type, r.increment_by, r.sequence_min, r.sequence_max,
               r.last_value, r.lower_bound, r.upper_bound, r.used_fraction, r.readable,
               r.table_schema, r.table_name, r.column_name, r.column_type, r.column_min, r.column_max, r.ownership,
               r.table_bytes, r.referencing_columns
        FROM (
            SELECT sn.nspname AS sequence_schema,
                   s.relname AS sequence_name,
                   pg_catalog.format_type(q.seqtypid, NULL) AS sequence_type,
                   q.seqincrement AS increment_by,
                   q.seqmin AS sequence_min,
                   q.seqmax AS sequence_max,
                   v.last_value,
                   b.lower_bound,
                   b.upper_bound,
                   CASE WHEN q.seqincrement > 0
                        THEN v.last_value::pg_catalog.numeric - b.lower_bound::pg_catalog.numeric
                        ELSE b.upper_bound::pg_catalog.numeric - v.last_value::pg_catalog.numeric
                   END / NULLIF(b.upper_bound::pg_catalog.numeric - b.lower_bound::pg_catalog.numeric, 0::pg_catalog.numeric)
                   AS used_fraction,
                   v.readable,
                   col.table_schema,
                   col.table_name,
                   col.column_name,
                   col.column_type,
                   col.column_min,
                   col.column_max,
                   col.ownership,
                   col.table_bytes,
                   col.referencing_columns
            FROM pg_catalog.pg_sequence q
            JOIN pg_catalog.pg_class s ON s.oid = q.seqrelid
            JOIN pg_catalog.pg_namespace sn ON sn.oid = s.relnamespace
            CROSS JOIN LATERAL (
                SELECT pg_catalog.has_sequence_privilege(s.oid, 'SELECT,USAGE') AS readable,
                       CASE WHEN pg_catalog.has_sequence_privilege(s.oid, 'SELECT,USAGE')
                                 AND (s.relpersistence = 'p' OR (s.relpersistence = 'u' AND NOT pg_catalog.pg_is_in_recovery()))
                            THEN pg_catalog.pg_sequence_last_value(s.oid)
                       END AS last_value
            ) v
            LEFT JOIN LATERAL (
                SELECT tn.nspname AS table_schema,
                       t.relname AS table_name,
                       a.attname AS column_name,
                       pg_catalog.format_type(a.atttypid, a.atttypmod) AS column_type,
                       f.ownership,
                       pg_catalog.pg_table_size(t.oid) AS table_bytes,
                       CASE WHEN ty.base OPERATOR(pg_catalog.=) 'pg_catalog.int2'::pg_catalog.regtype THEN -32768::pg_catalog.int8
                            WHEN ty.base OPERATOR(pg_catalog.=) 'pg_catalog.int4'::pg_catalog.regtype THEN -2147483648::pg_catalog.int8
                       END AS column_min,
                       CASE WHEN ty.base OPERATOR(pg_catalog.=) 'pg_catalog.int2'::pg_catalog.regtype THEN 32767::pg_catalog.int8
                            WHEN ty.base OPERATOR(pg_catalog.=) 'pg_catalog.int4'::pg_catalog.regtype THEN 2147483647::pg_catalog.int8
                       END AS column_max,
                       (SELECT pg_catalog.string_agg(pg_catalog.concat_ws('.', rn.nspname, rc.relname, ra.attname), ', '
                                                     ORDER BY rn.nspname, rc.relname, ra.attname)
                        FROM pg_catalog.pg_constraint fk
                        JOIN pg_catalog.pg_class rc ON rc.oid = fk.conrelid
                        JOIN pg_catalog.pg_namespace rn ON rn.oid = rc.relnamespace
                        CROSS JOIN LATERAL ROWS FROM (pg_catalog.unnest(fk.conkey), pg_catalog.unnest(fk.confkey)) AS fkc(attnum, refnum)
                        JOIN pg_catalog.pg_attribute ra ON ra.attrelid = fk.conrelid AND ra.attnum = fkc.attnum
                        WHERE fk.contype = 'f'
                          AND fk.confrelid = f.table_oid
                          AND fkc.refnum = f.column_number
                          AND COALESCE(pg_catalog.row_to_json(fk) OPERATOR(pg_catalog.->>) 'conparentid'::pg_catalog.text, '0') = '0'
                          AND (ra.atttypid OPERATOR(pg_catalog.=) 'pg_catalog.int2'::pg_catalog.regtype
                               OR ra.atttypid OPERATOR(pg_catalog.=) 'pg_catalog.int4'::pg_catalog.regtype)) AS referencing_columns
                FROM (
                    SELECT d.refobjid AS table_oid,
                           d.refobjsubid AS column_number,
                           CASE d.deptype WHEN 'i' THEN 'identity' ELSE 'owned' END AS ownership
                    FROM pg_catalog.pg_depend d
                    WHERE d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                      AND d.objid = s.oid
                      AND d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                      AND d.refobjsubid > 0
                      AND d.deptype IN ('a', 'i')
                    UNION
                    SELECT ad.adrelid, ad.adnum, 'default'
                    FROM pg_catalog.pg_depend d
                    JOIN pg_catalog.pg_attrdef ad ON ad.oid = d.objid
                    WHERE d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_attrdef'::pg_catalog.regclass
                      AND d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                      AND d.refobjid = s.oid
                ) f
                JOIN pg_catalog.pg_class t ON t.oid = f.table_oid
                JOIN pg_catalog.pg_namespace tn ON tn.oid = t.relnamespace
                JOIN pg_catalog.pg_attribute a ON a.attrelid = f.table_oid AND a.attnum = f.column_number
                JOIN pg_catalog.pg_type ct ON ct.oid = a.atttypid
                CROSS JOIN LATERAL (SELECT CASE WHEN ct.typtype = 'd' THEN ct.typbasetype ELSE ct.oid END AS base) ty
                WHERE NOT a.attisdropped
                ORDER BY column_max NULLS LAST, f.ownership DESC
                LIMIT 1
            ) col ON true
            CROSS JOIN LATERAL (
                SELECT GREATEST(q.seqmin, COALESCE(col.column_min, q.seqmin)) AS lower_bound,
                       LEAST(q.seqmax, COALESCE(col.column_max, q.seqmax)) AS upper_bound
            ) b
            WHERE NOT q.seqcycle
              AND pg_catalog.left(sn.nspname, 3) <> 'pg_'
              AND NOT EXISTS (
                  SELECT 1 FROM pg_catalog.pg_depend x
                  WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                    AND x.objid = s.oid
                    AND x.deptype = 'e'
              )
              AND NOT EXISTS (
                  SELECT 1 FROM pg_catalog.pg_depend x
                  WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
                    AND x.objid = s.relnamespace
                    AND x.deptype = 'e'
              )
        ) r
        WHERE NOT r.readable OR r.used_fraction >= 0.75
        ORDER BY r.used_fraction DESC NULLS LAST, r.sequence_schema, r.sequence_name
        """

    // Past its effective autovacuum_freeze_max_age a table has already had a forced freeze, so one still above it
    // is not getting frozen. A table's own setting counts only when lower: autovacuum ignores a larger one. The TOAST
    // table can lag its heap. A partitioned table has no storage and reads as 2^31 - 1, so it is left out.
    static let transactionIdAgeQuery = """
        SELECT r.schema_name, r.table_name, r.table_xid_age, r.toast_xid_age, r.xid_age, r.freeze_max_age,
               r.transactions_left, r.last_vacuum, r.table_bytes
        FROM (
            SELECT n.nspname AS schema_name,
                   c.relname AS table_name,
                   pg_catalog.age(c.relfrozenxid) AS table_xid_age,
                   pg_catalog.age(t.relfrozenxid) AS toast_xid_age,
                   GREATEST(pg_catalog.age(c.relfrozenxid), COALESCE(pg_catalog.age(t.relfrozenxid), 0)) AS xid_age,
                   f.freeze_max_age,
                   2147483648 - GREATEST(pg_catalog.age(c.relfrozenxid), COALESCE(pg_catalog.age(t.relfrozenxid), 0)) AS transactions_left,
                   pg_catalog.date_part('epoch', GREATEST(s.last_vacuum, s.last_autovacuum)) AS last_vacuum,
                   pg_catalog.pg_table_size(c.oid) AS table_bytes
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_catalog.pg_class t ON t.oid = c.reltoastrelid
            LEFT JOIN pg_catalog.pg_stat_all_tables s ON s.relid = c.oid
            CROSS JOIN LATERAL (
                SELECT LEAST(
                           pg_catalog.current_setting('autovacuum_freeze_max_age')::pg_catalog.int8,
                           COALESCE((SELECT o.option_value::pg_catalog.int8
                                     FROM pg_catalog.pg_options_to_table(c.reloptions) o
                                     WHERE o.option_name = 'autovacuum_freeze_max_age'),
                                    pg_catalog.current_setting('autovacuum_freeze_max_age')::pg_catalog.int8)
                       ) AS freeze_max_age
            ) f
            WHERE c.relkind IN ('r', 'm')
              AND n.nspname <> 'information_schema'
              AND pg_catalog.left(n.nspname, 3) <> 'pg_'
              AND NOT EXISTS (
                  SELECT 1 FROM pg_catalog.pg_depend x
                  WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                    AND x.objid = c.oid
                    AND x.deptype = 'e'
              )
              AND NOT EXISTS (
                  SELECT 1 FROM pg_catalog.pg_depend x
                  WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
                    AND x.objid = c.relnamespace
                    AND x.deptype = 'e'
              )
        ) r
        WHERE r.xid_age > r.freeze_max_age
        ORDER BY r.xid_age DESC, r.schema_name, r.table_name
        """

    // Autoanalyze's default rule: more rows modified than 10% of reltuples plus 50. reltuples is -1 before the
    // first analyze on 14+. Autovacuum never analyzes a partitioned table, and its activity counters stay empty, so
    // a parent counts as never analyzed while pg_stats holds no inherited rows for it.
    static let staleStatisticsQuery = """
        SELECT n.nspname AS schema_name,
               c.relname AS table_name,
               c.relkind AS table_kind,
               COALESCE(s.n_live_tup, 0) AS live_rows,
               COALESCE(s.n_mod_since_analyze, 0) AS modified_rows,
               th.analyze_threshold::pg_catalog.int8 AS analyze_threshold,
               CASE WHEN c.relkind = 'p'
                    THEN NOT EXISTS (SELECT 1 FROM pg_catalog.pg_stats st
                                     WHERE st.schemaname = n.nspname AND st.tablename = c.relname AND st.inherited)
                    ELSE s.last_analyze IS NULL AND s.last_autoanalyze IS NULL
               END AS never_analyzed,
               pg_catalog.date_part('epoch', GREATEST(s.last_analyze, s.last_autoanalyze)) AS last_analyze,
               pg_catalog.pg_table_size(c.oid) AS table_bytes
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_catalog.pg_stat_user_tables s ON s.relid = c.oid
        CROSS JOIN LATERAL (
            SELECT 50::pg_catalog.float8
                   + 0.1::pg_catalog.float8 * GREATEST(c.reltuples::pg_catalog.float8, 0::pg_catalog.float8) AS analyze_threshold
        ) th
        WHERE c.relkind IN ('r', 'm', 'p')
          AND n.nspname <> 'information_schema'
          AND pg_catalog.left(n.nspname, 3) <> 'pg_'
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
                AND x.objid = c.oid
                AND x.deptype = 'e'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_depend x
              WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
                AND x.objid = c.relnamespace
                AND x.deptype = 'e'
          )
          AND (
              (c.relkind = 'p'
               AND pg_catalog.has_table_privilege(c.oid, 'SELECT')
               AND EXISTS (SELECT 1 FROM pg_catalog.pg_inherits h
                           JOIN pg_catalog.pg_stat_user_tables ps ON ps.relid = h.inhrelid
                           WHERE h.inhparent = c.oid AND ps.n_live_tup > 0)
               AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_stats st
                               WHERE st.schemaname = n.nspname AND st.tablename = c.relname AND st.inherited))
              OR (c.relkind <> 'p'
                  AND ((s.last_analyze IS NULL AND s.last_autoanalyze IS NULL AND s.n_live_tup > 0)
                       OR s.n_mod_since_analyze::pg_catalog.float8 > th.analyze_threshold))
          )
        ORDER BY modified_rows DESC, n.nspname, c.relname
        """

    var statisticsQueries: [String] { [Self.statisticsQuery] }

    func check(_ kind: TableHealthCheckKind) -> TableHealthCheck {
        switch kind {
        case .bloat:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Tables with at least 1,000 dead rows, and at least 20% as many dead rows as live ones."
            ))
        case .unusedIndex:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Indexes never scanned since the statistics were last reset, leaving out unique, constraint and foreign key indexes."
            ))
        case .missingPrimaryKey:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Tables with no primary key; a partition takes its key from its parent, so only the parent is listed."
            ))
        case .unindexedForeignKey:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Foreign keys whose columns lead no valid, non-partial index, so a delete on the referenced table scans this one."
            ))
        case .redundantIndex:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Indexes whose keys lead another index with the same method, predicate and uniqueness; primary key and constraint indexes stay."
            ))
        case .invalidIndex:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Indexes a failed or cancelled CREATE INDEX CONCURRENTLY or REINDEX CONCURRENTLY left invalid, leaving out builds still running."
            ))
        case .nearLimit:
            return TableHealthCheck(kind: kind, title: String(localized: "Sequences Near Their Limit"), summary: String(
                localized: "Sequences that have used at least 75% of what their type, limits and integer column allow, leaving out cycling ones."
            ))
        case .transactionIdAge:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Tables whose oldest unfrozen row is more than autovacuum_freeze_max_age transactions old (200,000,000 unless set lower)."
            ))
        case .staleStatistics:
            return TableHealthCheck(kind: kind, summary: String(
                localized: "Tables never analyzed, or with more rows modified since the last ANALYZE than 10% of their rows plus 50."
            ))
        case .reclaimableSpace:
            return TableHealthCheck(kind: kind, summary: "")
        }
    }

    func queries(for check: TableHealthCheckKind, statistics: TableHealthStatistics) -> [String] {
        switch check {
        case .bloat: return [Self.bloatQuery]
        case .unusedIndex: return [Self.unusedIndexQuery]
        case .redundantIndex: return [Self.redundantIndexQuery]
        case .invalidIndex: return [Self.invalidIndexQuery]
        case .missingPrimaryKey: return [Self.missingPrimaryKeyQuery]
        case .unindexedForeignKey: return [Self.unindexedForeignKeyQuery]
        case .nearLimit: return [Self.nearLimitQuery]
        case .transactionIdAge: return [Self.transactionIdAgeQuery]
        case .staleStatistics: return [Self.staleStatisticsQuery]
        case .reclaimableSpace: return []
        }
    }

    func statistics(from results: [QueryResult?], now: Date) -> TableHealthStatistics {
        guard let result = results.first.flatMap({ $0 }),
              let row = TableHealthRow.rows(of: result).first
        else { return TableHealthStatistics() }

        var statistics = TableHealthStatistics(
            serverVersion: row.int64("server_version_num").map { Int($0) },
            isStandby: row.flag("in_recovery") == true
        )
        if let version = statistics.serverVersion, version < 100_000, checks.contains(.nearLimit) {
            statistics.skippedChecks[.nearLimit] = String(localized: "Needs PostgreSQL 10 or later.")
        }
        let counterChecks = Self.counterChecks.filter(checks.contains)
        func skipCounterChecks(_ reason: String) {
            for kind in counterChecks {
                statistics.skippedChecks[kind] = reason
            }
        }

        if statistics.isStandby {
            statistics.notes.append(String(localized: "This server is a read-only standby. Run the fixes on the primary."))
            skipCounterChecks(String(localized: "This server is a standby. Its activity counters do not reflect the primary."))
        } else if row["track_counts"] == "off" {
            skipCounterChecks(String(localized: "track_counts is off, so the server records no table or index activity."))
        } else if let reset = row.date("stats_reset") {
            statistics.notes.append(String(
                format: String(localized: "Index usage counts since the statistics were last reset at %@."),
                TableHealthFormatting.date(reset)
            ))
        } else {
            statistics.notes.append(
                String(localized: "Index usage counts since the statistics were first collected; they have never been reset.")
            )
        }
        return statistics
    }

    func findings(
        for check: TableHealthCheckKind,
        from results: [QueryResult],
        context: TableHealthQueryContext,
        statistics: TableHealthStatistics
    ) -> (findings: [TableHealthFinding], note: String?) {
        guard let result = results.first else { return ([], nil) }
        let rows = TableHealthRow.rows(of: result)
        switch check {
        case .bloat:
            return (rows.map { bloatFinding($0, context) }, nil)
        case .unusedIndex:
            return (rows.map { unusedIndexFinding($0, context) }, nil)
        case .missingPrimaryKey:
            return (rows.map { missingPrimaryKeyFinding($0, context) }, nil)
        case .unindexedForeignKey:
            return (unindexedForeignKeyFindings(rows, context), nil)
        case .redundantIndex:
            return (redundantIndexFindings(PostgreSQLIndexShape.tables(from: rows), context), nil)
        case .invalidIndex:
            return (rows.map { invalidIndexFinding($0, context, serverVersion: statistics.serverVersion) }, nil)
        case .nearLimit:
            return nearLimitFindings(rows, context)
        case .transactionIdAge:
            return (rows.map { transactionIdAgeFinding($0, context) }, nil)
        case .staleStatistics:
            return (rows.map { staleStatisticsFinding($0, context) }, nil)
        case .reclaimableSpace:
            return ([], nil)
        }
    }

    private func bloatFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding {
        let schema = row["schema_name"], table = row["table_name"]
        let deadRows = row.int64("dead_rows"), liveRows = row.int64("live_rows")
        let lastVacuum = row.date("last_vacuum")
        let dead = deadRows?.formatted() ?? row["dead_rows"]
        let live = liveRows?.formatted() ?? row["live_rows"]
        let detail = lastVacuum.map {
            String(format: String(localized: "%1$@ dead rows, %2$@ live. Last vacuumed %3$@."), dead, live, TableHealthFormatting.date($0))
        } ?? String(format: String(localized: "%1$@ dead rows, %2$@ live. Never vacuumed."), dead, live)

        var metrics: [TableHealthMetric] = []
        if let deadRows {
            metrics.append(TableHealthMetric(id: "dead_rows", label: String(localized: "Dead Rows"), value: .count(deadRows)))
        }
        if let liveRows {
            metrics.append(TableHealthMetric(id: "live_rows", label: String(localized: "Live Rows"), value: .count(liveRows)))
        }
        if let deadRows, let liveRows, Double(deadRows) + Double(liveRows) > 0 {
            let share = Double(deadRows) / (Double(deadRows) + Double(liveRows))
            metrics.append(TableHealthMetric(id: "dead_percent", label: String(localized: "Dead Row Share"), value: .percent(share)))
        }
        if let lastVacuum {
            metrics.append(TableHealthMetric(id: "last_vacuum", label: String(localized: "Last Vacuum"), value: .date(lastVacuum)))
        }
        return TableHealthFinding(
            kind: .bloat, schema: schema, table: table, objectName: nil, detail: detail,
            sizeBytes: row.int64("table_bytes"), metrics: metrics,
            fixSQL: "VACUUM (ANALYZE) \(context.qualified(schema, table));"
        )
    }

    private func unusedIndexFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding {
        let schema = row["schema_name"], index = row["index_name"]
        let size = ByteSizeFormatting.string(byteString: row["index_bytes"])
        return TableHealthFinding(
            kind: .unusedIndex, schema: schema, table: row["table_name"], objectName: index,
            detail: String(format: String(localized: "%1$@ has never been scanned. It takes %2$@."), index, size),
            sizeBytes: row.int64("index_bytes"),
            fixSQL: "DROP INDEX CONCURRENTLY \(context.qualified(schema, index));"
        )
    }

    private func missingPrimaryKeyFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding {
        let schema = row["schema_name"], table = row["table_name"]
        return TableHealthFinding(
            kind: .missingPrimaryKey, schema: schema, table: table, objectName: nil,
            detail: String(localized: "No primary key. Replace column_name with the columns that identify a row."),
            sizeBytes: row.int64("table_bytes"),
            metrics: row.int64("estimated_rows").map { [TableHealthMetric.estimatedRows($0)] } ?? [],
            fixSQL: "ALTER TABLE \(context.qualified(schema, table)) ADD PRIMARY KEY (column_name);"
        )
    }

    private struct ForeignKey {
        let schema: String
        let table: String
        let isPartitioned: Bool
        let constraint: String
        var columns: [String]
        let referencedTable: String?
        let estimatedRows: Int64?
        let tableBytes: Int64?
    }

    private func unindexedForeignKeyFindings(
        _ rows: [TableHealthRow],
        _ context: TableHealthQueryContext
    ) -> [TableHealthFinding] {
        var keys: [ForeignKey] = []
        for row in rows {
            let schema = row["schema_name"], table = row["table_name"], constraint = row["constraint_name"]
            if let last = keys.last, last.schema == schema, last.table == table, last.constraint == constraint {
                keys[keys.count - 1].columns.append(row["column_name"])
            } else {
                let referenced = [row["referenced_schema"], row["referenced_table"]].filter { !$0.isEmpty }
                keys.append(ForeignKey(
                    schema: schema, table: table, isPartitioned: row["table_kind"] == "p",
                    constraint: constraint, columns: [row["column_name"]],
                    referencedTable: referenced.isEmpty ? nil : referenced.joined(separator: "."),
                    estimatedRows: row.int64("estimated_rows"),
                    tableBytes: row.int64("table_bytes")
                ))
            }
        }
        return keys.map { key in
            let columnList = key.columns.map(context.quote).joined(separator: ", ")
            // PostgreSQL cannot build an index on a partitioned table concurrently.
            let create = key.isPartitioned ? "CREATE INDEX" : "CREATE INDEX CONCURRENTLY"
            var metrics = [
                TableHealthMetric(id: "columns", label: String(localized: "Columns"), value: .text(key.columns.joined(separator: ", ")))
            ]
            if let referenced = key.referencedTable {
                metrics.append(TableHealthMetric(
                    id: "referenced_table", label: String(localized: "Referenced Table"), value: .text(referenced)
                ))
            }
            if let rows = key.estimatedRows {
                metrics.append(.estimatedRows(rows))
            }
            return TableHealthFinding(
                kind: .unindexedForeignKey, schema: key.schema, table: key.table, objectName: key.constraint,
                detail: String(
                    format: String(localized: "%1$@ on (%2$@) has no index, so deletes and updates on the referenced table scan this one."),
                    key.constraint,
                    key.columns.joined(separator: ", ")
                ),
                sizeBytes: key.tableBytes,
                metrics: metrics,
                fixSQL: "\(create) ON \(context.qualified(key.schema, key.table)) (\(columnList));"
            )
        }
    }
}

extension PostgreSQLTableHealthProvider {
    private static func countText(_ row: TableHealthRow, _ name: String) -> String {
        row.int64(name)?.formatted() ?? row[name]
    }

    private func redundantIndexFindings(
        _ tables: [PostgreSQLIndexShape],
        _ context: TableHealthQueryContext
    ) -> [TableHealthFinding] {
        var findings: [TableHealthFinding] = []
        for table in tables {
            for redundancy in table.redundantIndexes {
                let index = redundancy.index, covering = redundancy.coveredBy
                var detail = String(format: String(localized: "%1$@ is covered by %2$@."), index.name, covering.name)
                if table.isPartitioned {
                    detail += " " + String(
                        localized: "On a partitioned table the drop cannot run concurrently, and it removes the index from every partition."
                    )
                }
                var metrics = [
                    TableHealthMetric(id: "covering_index", label: String(localized: "Covering Index"), value: .text(covering.name))
                ]
                if let definition = index.definition {
                    metrics.append(TableHealthMetric(
                        id: "index_definition", label: String(localized: "Definition"), value: .text(definition)
                    ))
                }
                if let definition = covering.definition {
                    metrics.append(TableHealthMetric(
                        id: "covering_definition", label: String(localized: "Covering Definition"), value: .text(definition)
                    ))
                }
                // PostgreSQL refuses to drop an index on a partitioned table concurrently.
                let drop = table.isPartitioned ? "DROP INDEX" : "DROP INDEX CONCURRENTLY"
                findings.append(TableHealthFinding(
                    kind: .redundantIndex, schema: table.schema, table: table.table, objectName: index.name,
                    detail: detail, sizeBytes: index.sizeBytes, metrics: metrics,
                    fixSQL: "\(drop) \(context.qualified(table.schema, index.name));"
                ))
            }
        }
        return findings
    }

    private func invalidIndexFinding(
        _ row: TableHealthRow,
        _ context: TableHealthQueryContext,
        serverVersion: Int?
    ) -> TableHealthFinding {
        let schema = row["schema_name"], index = row["index_name"]
        let definition = row.text("index_definition")
        let isUnique = row.flag("is_unique") == true, isReady = row.flag("is_ready") == true
        let target = context.qualified(schema, index)
        let canReindexConcurrently = (serverVersion ?? 0) >= 120_000
        // REINDEX CONCURRENTLY (12+) builds <index>_ccnew and keeps the old copy as <index>_ccold, adding a digit to
        // a name already taken. Either one left invalid is dropped, not rebuilt.
        let leftover = index.range(of: "_cc(new|old)[0-9]*$", options: .regularExpression).map { String(index[$0]) }

        let detail: String
        let fixSQL: String
        if let leftover, serverVersion.map({ $0 >= 120_000 }) ?? true {
            detail = leftover.hasPrefix("_ccold")
                ? String(format: String(
                    localized: "%@ is the old copy a REINDEX CONCURRENTLY left behind after the rebuild finished."
                ), index)
                : String(format: String(
                    localized: "%@ is the new copy an interrupted REINDEX CONCURRENTLY left behind. Drop it, then run the rebuild again."
                ), index)
            fixSQL = "DROP INDEX CONCURRENTLY \(target);"
        } else {
            var sentences = [
                isReady
                    ? String(format: String(
                        localized: "%@ is invalid after a failed or cancelled concurrent build. Queries never use it, but every write still updates it."
                    ), index)
                    : String(format: String(
                        localized: "%@ is invalid after a failed or cancelled concurrent build. Queries never use it."
                    ), index)
            ]
            if isUnique {
                sentences.append(String(localized: "Rebuilding a unique index fails while the table holds duplicate values."))
            }
            detail = sentences.joined(separator: " ")
            if canReindexConcurrently {
                fixSQL = "REINDEX INDEX CONCURRENTLY \(target);"
            } else if let create = definition.flatMap(Self.concurrentCreate) {
                fixSQL = "DROP INDEX CONCURRENTLY \(target);\n\(create);"
            } else {
                fixSQL = "REINDEX INDEX \(target);"
            }
        }

        var metrics: [TableHealthMetric] = []
        if let definition {
            metrics.append(TableHealthMetric(id: "index_definition", label: String(localized: "Definition"), value: .text(definition)))
        }
        metrics.append(TableHealthMetric(id: "is_unique", label: String(localized: "Unique"), value: .flag(isUnique)))
        metrics.append(TableHealthMetric(id: "is_ready", label: String(localized: "Updated by Writes"), value: .flag(isReady)))
        return TableHealthFinding(
            kind: .invalidIndex, schema: schema, table: row["table_name"], objectName: index, detail: detail,
            sizeBytes: row.int64("index_bytes"), metrics: metrics, fixSQL: fixSQL
        )
    }

    // pg_get_indexdef writes CREATE INDEX or CREATE UNIQUE INDEX, then the name.
    private static func concurrentCreate(_ definition: String) -> String? {
        for prefix in ["CREATE UNIQUE INDEX ", "CREATE INDEX "] where definition.hasPrefix(prefix) {
            return prefix + "CONCURRENTLY " + String(definition.dropFirst(prefix.count))
        }
        return nil
    }

    private func nearLimitFindings(
        _ rows: [TableHealthRow],
        _ context: TableHealthQueryContext
    ) -> (findings: [TableHealthFinding], note: String?) {
        var findings: [TableHealthFinding] = []
        var unreadable = 0
        for row in rows {
            if row.flag("readable") == false {
                unreadable += 1
            } else if let finding = nearLimitFinding(row, context) {
                findings.append(finding)
            }
        }
        let note: String?
        switch unreadable {
        case 0:
            note = nil
        case 1:
            note = String(localized: "One sequence is not readable by this user, so its counter was not checked.")
        default:
            note = String(
                format: String(localized: "%lld sequences are not readable by this user, so their counters were not checked."),
                unreadable
            )
        }
        return (findings, note)
    }

    private static func typeLimit(of type: String, ascending: Bool) -> Int64? {
        switch type {
        case "smallint": return ascending ? Int64(Int16.max) : Int64(Int16.min)
        case "integer": return ascending ? Int64(Int32.max) : Int64(Int32.min)
        case "bigint": return ascending ? Int64.max : Int64.min
        default: return nil
        }
    }

    private static func ownershipLabel(_ ownership: String) -> String? {
        switch ownership {
        case "identity": return String(localized: "Identity column")
        case "owned": return String(localized: "Owned by the column")
        case "default": return String(localized: "Column default")
        default: return nil
        }
    }

    private func nearLimitFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding? {
        guard let increment = row.int64("increment_by"), let lastValue = row.int64("last_value"),
              let lowerBound = row.int64("lower_bound"), let upperBound = row.int64("upper_bound"),
              let sequenceMin = row.int64("sequence_min"), let sequenceMax = row.int64("sequence_max"),
              let used = row.double("used_fraction")
        else { return nil }
        let sequenceSchema = row["sequence_schema"], sequence = row["sequence_name"], sequenceType = row["sequence_type"]
        let table = row.text("table_name"), column = row.text("column_name")
        let tableSchema = row.text("table_schema") ?? sequenceSchema
        let ascending = increment > 0
        let sequenceLimit = ascending ? sequenceMax : sequenceMin
        let columnLimit = ascending ? row.int64("column_max") : row.int64("column_min")
        let columnRunsOutFirst = columnLimit.map { ascending ? $0 <= sequenceLimit : $0 >= sequenceLimit } ?? false

        var statements: [String] = []
        let widensColumn = columnRunsOutFirst && table != nil && column != nil
        if widensColumn, let table, let column {
            statements.append("ALTER TABLE \(context.qualified(tableSchema, table)) ALTER COLUMN \(context.quote(column)) TYPE bigint;")
        }
        var sequenceChanges: [String] = []
        // An identity sequence takes the column's new type by itself; a serial one keeps its own.
        if sequenceType != "bigint", !(widensColumn && row["ownership"] == "identity") {
            sequenceChanges.append("AS bigint")
        }
        // AS bigint moves a limit only when it was the old type's own, so a limit set lower stays until removed.
        if !widensColumn, let typeLimit = Self.typeLimit(of: sequenceType, ascending: ascending), typeLimit != sequenceLimit {
            sequenceChanges.append(ascending ? "NO MAXVALUE" : "NO MINVALUE")
        }
        if !sequenceChanges.isEmpty {
            statements.append("ALTER SEQUENCE \(context.qualified(sequenceSchema, sequence)) \(sequenceChanges.joined(separator: " "));")
        }

        let limit = ascending ? upperBound : lowerBound
        var sentences = [String(
            format: String(localized: "%1$@ has used %2$@ of its range: its last value is %3$@ and its limit %4$@."),
            sequence, TableHealthMetric.Value.percent(used).formatted, lastValue.formatted(), limit.formatted()
        )]
        if widensColumn {
            sentences.append(String(localized: "Changing the column type rewrites the table and its indexes under an exclusive lock."))
        }
        let referencing = row.text("referencing_columns").flatMap { $0.isEmpty ? nil : $0 }
        if let referencing {
            sentences.append(String(
                format: String(localized: "These foreign key columns reference it and keep their narrower type: %@."), referencing
            ))
        }
        if statements.isEmpty {
            sentences.append(String(localized: "The sequence and its column are already bigint, so no wider type exists."))
        }

        var metrics = [
            TableHealthMetric(id: "used_percent", label: String(localized: "Used"), value: .percent(used)),
            TableHealthMetric(id: "last_value", label: String(localized: "Last Value"), value: .count(lastValue)),
            TableHealthMetric(id: "lower_bound", label: String(localized: "Lower Bound"), value: .count(lowerBound)),
            TableHealthMetric(id: "upper_bound", label: String(localized: "Upper Bound"), value: .count(upperBound)),
            TableHealthMetric(id: "sequence_type", label: String(localized: "Sequence Type"), value: .text(sequenceType))
        ]
        if let column {
            metrics.append(TableHealthMetric(id: "column", label: String(localized: "Column"), value: .text(column)))
        }
        if let columnType = row.text("column_type") {
            metrics.append(TableHealthMetric(id: "column_type", label: String(localized: "Column Type"), value: .text(columnType)))
        }
        if let ownership = Self.ownershipLabel(row["ownership"]) {
            metrics.append(TableHealthMetric(id: "ownership", label: String(localized: "Ownership"), value: .text(ownership)))
        }
        if let referencing {
            metrics.append(TableHealthMetric(
                id: "referencing_columns", label: String(localized: "Referencing Columns"), value: .text(referencing)
            ))
        }
        return TableHealthFinding(
            kind: .nearLimit, schema: table == nil ? sequenceSchema : tableSchema, table: table, objectName: sequence,
            detail: sentences.joined(separator: " "),
            sizeBytes: table == nil ? nil : row.int64("table_bytes"),
            metrics: metrics,
            fixSQL: statements.isEmpty ? nil : statements.joined(separator: "\n")
        )
    }

    private func transactionIdAgeFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding {
        let schema = row["schema_name"], table = row["table_name"]
        let detail = [
            String(
                format: String(localized: "%1$@ transactions old, past the %2$@ at which autovacuum forces a freeze. %3$@ remain before wraparound."),
                Self.countText(row, "xid_age"), Self.countText(row, "freeze_max_age"), Self.countText(row, "transactions_left")
            ),
            String(localized: "A freeze cannot pass the oldest open transaction, prepared transaction or replication slot.")
        ].joined(separator: " ")

        var metrics: [TableHealthMetric] = []
        let counts = [
            ("xid_age", String(localized: "Transaction Age")),
            ("table_xid_age", String(localized: "Table Age")),
            ("toast_xid_age", String(localized: "TOAST Age")),
            ("freeze_max_age", String(localized: "Freeze Max Age")),
            ("transactions_left", String(localized: "Transactions Left"))
        ]
        for (id, label) in counts {
            if let value = row.int64(id) {
                metrics.append(TableHealthMetric(id: id, label: label, value: .count(value)))
            }
        }
        if let lastVacuum = row.date("last_vacuum") {
            metrics.append(TableHealthMetric(id: "last_vacuum", label: String(localized: "Last Vacuum"), value: .date(lastVacuum)))
        }
        return TableHealthFinding(
            kind: .transactionIdAge, schema: schema, table: table, objectName: nil, detail: detail,
            sizeBytes: row.int64("table_bytes"), metrics: metrics,
            fixSQL: "VACUUM (FREEZE) \(context.qualified(schema, table));"
        )
    }

    private func staleStatisticsFinding(_ row: TableHealthRow, _ context: TableHealthQueryContext) -> TableHealthFinding {
        let schema = row["schema_name"], table = row["table_name"]
        let isPartitioned = row["table_kind"] == "p"
        let neverAnalyzed = row.flag("never_analyzed") == true
        let lastAnalyze = row.date("last_analyze")
        let modified = Self.countText(row, "modified_rows"), threshold = Self.countText(row, "analyze_threshold")
        let detail: String
        if isPartitioned {
            detail = String(
                localized: "Never analyzed. Autovacuum does not analyze a partitioned table, so only a manual ANALYZE gives it statistics."
            )
        } else if neverAnalyzed {
            detail = String(localized: "Never analyzed, so the planner has no statistics for it.")
        } else if let lastAnalyze {
            detail = String(
                format: String(localized: "%1$@ rows modified since it was last analyzed %2$@, more than the %3$@ that start an autoanalyze."),
                modified, TableHealthFormatting.date(lastAnalyze), threshold
            )
        } else {
            detail = String(
                format: String(localized: "%1$@ rows modified since it was last analyzed, more than the %2$@ that start an autoanalyze."),
                modified, threshold
            )
        }

        var metrics: [TableHealthMetric] = []
        // A partitioned table's activity counters stay empty, so only its children's would mean anything.
        if !isPartitioned {
            let counts = [
                ("modified_rows", String(localized: "Modified Rows")),
                ("live_rows", String(localized: "Live Rows")),
                ("analyze_threshold", String(localized: "Analyze Threshold"))
            ]
            for (id, label) in counts {
                if let value = row.int64(id) {
                    metrics.append(TableHealthMetric(id: id, label: label, value: .count(value)))
                }
            }
        }
        metrics.append(TableHealthMetric(id: "never_analyzed", label: String(localized: "Never Analyzed"), value: .flag(neverAnalyzed)))
        if let lastAnalyze {
            metrics.append(TableHealthMetric(id: "last_analyze", label: String(localized: "Last Analyze"), value: .date(lastAnalyze)))
        }
        return TableHealthFinding(
            kind: .staleStatistics, schema: schema, table: table, objectName: nil, detail: detail,
            sizeBytes: row.int64("table_bytes"), metrics: metrics,
            fixSQL: "ANALYZE \(context.qualified(schema, table));"
        )
    }
}
