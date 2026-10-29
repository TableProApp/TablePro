namespace TablePro.Drivers.MySql;

/// <summary>
/// Catalog reads against <c>information_schema</c>, bound to <c>@schema</c> (the database; NULL means the
/// connection's own) and <c>@table</c>. Definitions come from SHOW CREATE, the only form the server guarantees runs back.
/// </summary>
internal static class MySqlCatalog
{
    public const string Databases = "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME";

    // TABLE_ROWS is the storage engine's estimate, cheap to read and exact for MyISAM.
    public const string Objects = """
        SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS, TABLE_COMMENT
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = COALESCE(@schema, DATABASE())
        UNION ALL
        SELECT ROUTINE_NAME, ROUTINE_TYPE, NULL, ROUTINE_COMMENT
        FROM information_schema.ROUTINES
        WHERE ROUTINE_SCHEMA = COALESCE(@schema, DATABASE())
        ORDER BY 2, 1
        """;

    public const string Columns = """
        SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE = 'YES', COLUMN_DEFAULT, COLUMN_KEY = 'PRI',
               EXTRA LIKE '%auto_increment%', COLUMN_COMMENT
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = COALESCE(@schema, DATABASE()) AND TABLE_NAME = @table
        ORDER BY ORDINAL_POSITION
        """;

    // A functional index part has no COLUMN_NAME.
    public const string Indexes = """
        SELECT INDEX_NAME, NON_UNIQUE, COALESCE(COLUMN_NAME, '(expression)'), INDEX_TYPE
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = COALESCE(@schema, DATABASE()) AND TABLE_NAME = @table
        ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX
        """;

    public const string ForeignKeys = """
        SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.TABLE_SCHEMA, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME,
               k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE
        FROM information_schema.KEY_COLUMN_USAGE k
        JOIN information_schema.REFERENTIAL_CONSTRAINTS r
          ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME
        WHERE k.TABLE_SCHEMA = COALESCE(@schema, DATABASE()) AND k.TABLE_NAME = @table AND k.REFERENCED_TABLE_NAME IS NOT NULL
        ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
        """;

    public const string Triggers = """
        SELECT TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION, ACTION_STATEMENT
        FROM information_schema.TRIGGERS
        WHERE EVENT_OBJECT_SCHEMA = COALESCE(@schema, DATABASE()) AND EVENT_OBJECT_TABLE = @table
        ORDER BY TRIGGER_NAME
        """;

    // TABLE_CONSTRAINTS carries the table; MySQL's CHECK_CONSTRAINTS does not. ENFORCED arrived with the checks, in 8.0.16.
    public const string MySqlCheckConstraints = """
        SELECT cc.CONSTRAINT_NAME, cc.CHECK_CLAUSE, tc.ENFORCED
        FROM information_schema.CHECK_CONSTRAINTS cc
        JOIN information_schema.TABLE_CONSTRAINTS tc
          ON tc.CONSTRAINT_SCHEMA = cc.CONSTRAINT_SCHEMA AND tc.CONSTRAINT_NAME = cc.CONSTRAINT_NAME
        WHERE cc.CONSTRAINT_SCHEMA = COALESCE(@schema, DATABASE()) AND tc.TABLE_NAME = @table AND tc.CONSTRAINT_TYPE = 'CHECK'
        ORDER BY cc.CONSTRAINT_NAME
        """;

    // MariaDB's CHECK_CONSTRAINTS names the table itself and has no ENFORCED: every check it keeps is enforced.
    public const string MariaDbCheckConstraints = """
        SELECT CONSTRAINT_NAME, CHECK_CLAUSE, 'YES'
        FROM information_schema.CHECK_CONSTRAINTS
        WHERE CONSTRAINT_SCHEMA = COALESCE(@schema, DATABASE()) AND TABLE_NAME = @table
        ORDER BY CONSTRAINT_NAME
        """;

    public const string TableOptions = """
        SELECT ENGINE, TABLE_COLLATION, ROW_FORMAT, AUTO_INCREMENT, TABLE_COMMENT
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = COALESCE(@schema, DATABASE()) AND TABLE_NAME = @table
        """;

    /// <summary>
    /// The storage engine of each named table in one database, a bound <c>@t0</c>, <c>@t1</c>... per name. A view has
    /// no engine and is left out.
    /// </summary>
    public static string StorageEngines(int tableCount)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(tableCount, 1);
        var names = string.Join(", ", Enumerable.Range(0, tableCount).Select(i => "@t" + i.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        return $"""
            SELECT TABLE_NAME, ENGINE
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = COALESCE(@schema, DATABASE()) AND ENGINE IS NOT NULL AND TABLE_NAME IN ({names})
            """;
    }

    // One row per subpartition, or per partition when there are none; an unpartitioned table has one row with no name.
    public const string Partitions = """
        SELECT PARTITION_NAME, SUBPARTITION_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION,
               PARTITION_ORDINAL_POSITION, SUBPARTITION_ORDINAL_POSITION, TABLE_ROWS, DATA_LENGTH + INDEX_LENGTH,
               SUBPARTITION_METHOD, SUBPARTITION_EXPRESSION
        FROM information_schema.PARTITIONS
        WHERE TABLE_SCHEMA = COALESCE(@schema, DATABASE()) AND TABLE_NAME = @table AND PARTITION_NAME IS NOT NULL
        ORDER BY PARTITION_ORDINAL_POSITION, SUBPARTITION_ORDINAL_POSITION
        """;

    public const string ReadOnlySession = "SET SESSION TRANSACTION READ ONLY";

    public const string ProcessList = "SHOW FULL PROCESSLIST";

    public const string MySqlUsers = """
        SELECT User, Host, plugin, account_locked, password_expired, password_last_changed
        FROM mysql.user ORDER BY User, Host
        """;

    // MariaDB's mysql.user is a view over global_priv and has no account_locked before 10.4.
    public const string MariaDbUsers = "SELECT User, Host, plugin, password_expired, is_role FROM mysql.user ORDER BY User, Host";

    // MySQL 5.7 moved these tables to performance_schema; MariaDB keeps them in information_schema.
    public const string MySqlVariables = """
        SELECT 'variable' AS kind, VARIABLE_NAME AS name, VARIABLE_VALUE AS value FROM performance_schema.global_variables
        UNION ALL
        SELECT 'status', VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_status
        ORDER BY 1 DESC, 2
        """;

    public const string MariaDbVariables = """
        SELECT 'variable' AS kind, VARIABLE_NAME AS name, VARIABLE_VALUE AS value FROM information_schema.GLOBAL_VARIABLES
        UNION ALL
        SELECT 'status', VARIABLE_NAME, VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS
        ORDER BY 1 DESC, 2
        """;
}
