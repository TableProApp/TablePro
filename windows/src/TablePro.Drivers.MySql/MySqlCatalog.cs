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
