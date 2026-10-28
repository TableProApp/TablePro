namespace TablePro.Drivers.Oracle;

/// <summary>
/// Dictionary SQL, bound by name (<c>:owner</c>, <c>:tbl</c>). Every view is named with its SYS owner, because Oracle
/// resolves an unqualified name to an object in the current schema before the public synonym, so a schema could
/// otherwise plant a same-named view the app would read.
/// </summary>
internal static class OracleCatalog
{
    public const string ServiceName = "SELECT SYS_CONTEXT('USERENV', 'SERVICE_NAME') FROM DUAL";

    // ORACLE_MAINTAINED (12c) leaves out SYS, SYSTEM and the other accounts the database installs.
    public const string Schemas = """
        SELECT u.USERNAME FROM SYS.ALL_USERS u
        WHERE u.USERNAME = USER
           OR (u.ORACLE_MAINTAINED = 'N' AND EXISTS (SELECT 1 FROM SYS.ALL_OBJECTS o WHERE o.OWNER = u.USERNAME))
        ORDER BY u.USERNAME
        """;

    // A materialized view has a TABLE row of the same name for its container, which belongs to the view.
    public const string Objects = """
        SELECT o.OBJECT_NAME, o.OBJECT_TYPE, t.NUM_ROWS, c.COMMENTS, s.TABLE_OWNER, s.TABLE_NAME
        FROM SYS.ALL_OBJECTS o
        LEFT JOIN SYS.ALL_TABLES t ON o.OBJECT_TYPE = 'TABLE' AND t.OWNER = o.OWNER AND t.TABLE_NAME = o.OBJECT_NAME
        LEFT JOIN SYS.ALL_TAB_COMMENTS c ON o.OBJECT_TYPE IN ('TABLE', 'VIEW') AND c.OWNER = o.OWNER AND c.TABLE_NAME = o.OBJECT_NAME
        LEFT JOIN SYS.ALL_SYNONYMS s ON o.OBJECT_TYPE = 'SYNONYM' AND s.OWNER = o.OWNER AND s.SYNONYM_NAME = o.OBJECT_NAME
        WHERE o.OWNER = :owner
          AND o.OBJECT_TYPE IN ('TABLE', 'VIEW', 'MATERIALIZED VIEW', 'PROCEDURE', 'FUNCTION', 'PACKAGE', 'SEQUENCE', 'SYNONYM')
          AND o.GENERATED = 'N' AND o.SECONDARY = 'N' AND o.OBJECT_NAME NOT LIKE 'BIN$%'
          AND NOT (o.OBJECT_TYPE = 'TABLE' AND EXISTS (
              SELECT 1 FROM SYS.ALL_MVIEWS m WHERE m.OWNER = o.OWNER AND m.MVIEW_NAME = o.OBJECT_NAME))
        ORDER BY o.OBJECT_TYPE, o.OBJECT_NAME
        """;

    // DATA_DEFAULT is a LONG, read whole because the session's commands fetch LONGs in full.
    public const string Columns = """
        SELECT c.COLUMN_NAME, c.DATA_TYPE, c.DATA_LENGTH, c.CHAR_LENGTH, c.CHAR_USED, c.DATA_PRECISION, c.DATA_SCALE,
               c.NULLABLE, c.IDENTITY_COLUMN, cc.COMMENTS,
               CASE WHEN EXISTS (
                   SELECT 1 FROM SYS.ALL_CONSTRAINTS k
                   JOIN SYS.ALL_CONS_COLUMNS kc ON kc.OWNER = k.OWNER AND kc.CONSTRAINT_NAME = k.CONSTRAINT_NAME
                   WHERE k.OWNER = c.OWNER AND k.TABLE_NAME = c.TABLE_NAME AND k.CONSTRAINT_TYPE = 'P' AND kc.COLUMN_NAME = c.COLUMN_NAME)
               THEN 1 ELSE 0 END AS IS_PK,
               c.DATA_DEFAULT
        FROM SYS.ALL_TAB_COLUMNS c
        LEFT JOIN SYS.ALL_COL_COMMENTS cc ON cc.OWNER = c.OWNER AND cc.TABLE_NAME = c.TABLE_NAME AND cc.COLUMN_NAME = c.COLUMN_NAME
        WHERE c.OWNER = :owner AND c.TABLE_NAME = :tbl
        ORDER BY c.COLUMN_ID
        """;

    // A function-based index keys on a hidden SYS_NC column; its expression (a LONG) is what the user wrote.
    public const string Indexes = """
        SELECT i.INDEX_NAME, i.UNIQUENESS, i.INDEX_TYPE, ic.COLUMN_NAME, ic.DESCEND,
               CASE WHEN EXISTS (
                   SELECT 1 FROM SYS.ALL_CONSTRAINTS k
                   WHERE k.OWNER = i.TABLE_OWNER AND k.TABLE_NAME = i.TABLE_NAME AND k.CONSTRAINT_TYPE = 'P' AND k.INDEX_NAME = i.INDEX_NAME)
               THEN 1 ELSE 0 END AS IS_PK,
               e.COLUMN_EXPRESSION
        FROM SYS.ALL_INDEXES i
        JOIN SYS.ALL_IND_COLUMNS ic ON ic.INDEX_OWNER = i.OWNER AND ic.INDEX_NAME = i.INDEX_NAME
        LEFT JOIN SYS.ALL_IND_EXPRESSIONS e
               ON e.INDEX_OWNER = ic.INDEX_OWNER AND e.INDEX_NAME = ic.INDEX_NAME AND e.COLUMN_POSITION = ic.COLUMN_POSITION
        WHERE i.TABLE_OWNER = :owner AND i.TABLE_NAME = :tbl AND i.INDEX_TYPE <> 'LOB'
        ORDER BY i.INDEX_NAME, ic.COLUMN_POSITION
        """;

    public const string ForeignKeys = """
        SELECT c.CONSTRAINT_NAME, cc.COLUMN_NAME, r.OWNER, r.TABLE_NAME, rc.COLUMN_NAME, c.DELETE_RULE
        FROM SYS.ALL_CONSTRAINTS c
        JOIN SYS.ALL_CONS_COLUMNS cc ON cc.OWNER = c.OWNER AND cc.CONSTRAINT_NAME = c.CONSTRAINT_NAME
        JOIN SYS.ALL_CONSTRAINTS r ON r.OWNER = c.R_OWNER AND r.CONSTRAINT_NAME = c.R_CONSTRAINT_NAME
        JOIN SYS.ALL_CONS_COLUMNS rc ON rc.OWNER = r.OWNER AND rc.CONSTRAINT_NAME = r.CONSTRAINT_NAME AND rc.POSITION = cc.POSITION
        WHERE c.OWNER = :owner AND c.TABLE_NAME = :tbl AND c.CONSTRAINT_TYPE = 'R'
        ORDER BY c.CONSTRAINT_NAME, cc.POSITION
        """;

    // TRIGGER_BODY is a LONG and stays last.
    public const string Triggers = """
        SELECT TRIGGER_NAME, TRIGGER_TYPE, TRIGGERING_EVENT, DESCRIPTION, WHEN_CLAUSE, STATUS, ACTION_TYPE, TRIGGER_BODY
        FROM SYS.ALL_TRIGGERS
        WHERE TABLE_OWNER = :owner AND TABLE_NAME = :tbl
        ORDER BY TRIGGER_NAME
        """;

    public const string ObjectTypes = """
        SELECT OBJECT_TYPE FROM SYS.ALL_OBJECTS
        WHERE OWNER = :owner AND OBJECT_NAME = :tbl
          AND OBJECT_TYPE IN ('VIEW', 'SYNONYM', 'PROCEDURE', 'PACKAGE', 'FUNCTION', 'TABLE', 'MATERIALIZED VIEW', 'SEQUENCE', 'TRIGGER')
        """;

    // A terminator and no storage clauses, so the text replays as a script on another database.
    public const string MetadataTransforms = """
        BEGIN
          DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SQLTERMINATOR', TRUE);
          DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'PRETTY', TRUE);
          DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SEGMENT_ATTRIBUTES', FALSE);
        END;
        """;

    public const string Ddl = "SELECT DBMS_METADATA.GET_DDL(:objtype, :tbl, :owner) FROM DUAL";

    // GET_DDL needs SELECT_CATALOG_ROLE for another schema's objects; ALL_SOURCE answers for whatever the user may run.
    public const string Source = """
        SELECT TEXT FROM SYS.ALL_SOURCE
        WHERE OWNER = :owner AND NAME = :tbl AND TYPE = :objtype
        ORDER BY LINE
        """;

    public const string ViewText = "SELECT TEXT FROM SYS.ALL_VIEWS WHERE OWNER = :owner AND VIEW_NAME = :tbl";

    public const string Activity = """
        SELECT s.SID || ',' || s.SERIAL# AS SESSION_ID, s.USERNAME, s.STATUS, s.OSUSER, s.MACHINE, s.PROGRAM,
               s.LAST_CALL_ET AS SECONDS_IN_STATE, s.SQL_ID, q.SQL_TEXT
        FROM V$SESSION s
        LEFT JOIN V$SQL q ON q.SQL_ID = s.SQL_ID AND q.CHILD_NUMBER = s.SQL_CHILD_NUMBER
        WHERE s.TYPE = 'USER'
        ORDER BY s.STATUS, s.LAST_CALL_ET DESC
        """;

    public const string Variables = "SELECT NAME, VALUE, ISDEFAULT, DESCRIPTION FROM V$PARAMETER ORDER BY NAME";

    public const string DbaUsers = """
        SELECT USERNAME, ACCOUNT_STATUS, DEFAULT_TABLESPACE, PROFILE, CREATED, ORACLE_MAINTAINED
        FROM SYS.DBA_USERS ORDER BY USERNAME
        """;

    public const string AllUsers = "SELECT USERNAME, USER_ID, CREATED, ORACLE_MAINTAINED FROM SYS.ALL_USERS ORDER BY USERNAME";

    // SEARCH_CONDITION is a LONG, read whole because the command fetches LONGs in full. A NOT NULL column is a
    // check here too; the session leaves those out, as they are the column's nullability.
    public const string CheckConstraints = """
        SELECT c.CONSTRAINT_NAME, c.SEARCH_CONDITION, c.VALIDATED
        FROM SYS.ALL_CONSTRAINTS c
        WHERE c.OWNER = :owner AND c.TABLE_NAME = :tbl AND c.CONSTRAINT_TYPE = 'C'
        ORDER BY c.CONSTRAINT_NAME
        """;

    public const string CheckConstraintColumns = """
        SELECT cc.CONSTRAINT_NAME, cc.COLUMN_NAME
        FROM SYS.ALL_CONS_COLUMNS cc
        JOIN SYS.ALL_CONSTRAINTS c ON c.OWNER = cc.OWNER AND c.CONSTRAINT_NAME = cc.CONSTRAINT_NAME
        WHERE c.OWNER = :owner AND c.TABLE_NAME = :tbl AND c.CONSTRAINT_TYPE = 'C'
        ORDER BY cc.CONSTRAINT_NAME, cc.COLUMN_NAME
        """;

    public const string TableOptions = """
        SELECT t.TABLESPACE_NAME, t.PCT_FREE, t.LOGGING, t.COMPRESSION, t.ROW_MOVEMENT, tc.COMMENTS
        FROM SYS.ALL_TABLES t
        LEFT JOIN SYS.ALL_TAB_COMMENTS tc ON tc.OWNER = t.OWNER AND tc.TABLE_NAME = t.TABLE_NAME
        WHERE t.OWNER = :owner AND t.TABLE_NAME = :tbl
        """;

    public const string Partitioning = """
        SELECT p.PARTITIONING_TYPE, p.SUBPARTITIONING_TYPE,
               (SELECT LISTAGG(k.COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY k.COLUMN_POSITION)
                FROM SYS.ALL_PART_KEY_COLUMNS k WHERE k.OWNER = p.OWNER AND k.NAME = p.TABLE_NAME AND k.OBJECT_TYPE = 'TABLE'),
               (SELECT LISTAGG(k.COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY k.COLUMN_POSITION)
                FROM SYS.ALL_SUBPART_KEY_COLUMNS k WHERE k.OWNER = p.OWNER AND k.NAME = p.TABLE_NAME AND k.OBJECT_TYPE = 'TABLE')
        FROM SYS.ALL_PART_TABLES p
        WHERE p.OWNER = :owner AND p.TABLE_NAME = :tbl
        """;

    // HIGH_VALUE is a LONG holding the bound as SQL text, such as TO_DATE(' 2025-01-01 00:00:00', ...).
    public const string Partitions = """
        SELECT p.PARTITION_NAME, p.HIGH_VALUE, p.PARTITION_POSITION, p.NUM_ROWS, p.SUBPARTITION_COUNT
        FROM SYS.ALL_TAB_PARTITIONS p
        WHERE p.TABLE_OWNER = :owner AND p.TABLE_NAME = :tbl
        ORDER BY p.PARTITION_POSITION
        """;

    // Every subpartition of the table in one read, grouped by the parent name in memory, rather than one read each.
    public const string Subpartitions = """
        SELECT s.PARTITION_NAME, s.SUBPARTITION_NAME, s.SUBPARTITION_POSITION, s.NUM_ROWS
        FROM SYS.ALL_TAB_SUBPARTITIONS s
        WHERE s.TABLE_OWNER = :owner AND s.TABLE_NAME = :tbl
        ORDER BY s.PARTITION_NAME, s.SUBPARTITION_POSITION
        """;

    /// <summary>
    /// Fixes the text forms of dates and numbers, so a value the grid sends as text converts the same way on every
    /// server whatever its NLS defaults.
    /// </summary>
    public const string SessionSettings =
        "ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS' NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF' "
        + "NLS_TIMESTAMP_TZ_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF TZH:TZM' NLS_NUMERIC_CHARACTERS = '.,'";
}
