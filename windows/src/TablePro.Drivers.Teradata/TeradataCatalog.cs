namespace TablePro.Drivers.Teradata;

/// <summary>
/// Dictionary SQL over the DBC views. Teradata binds <c>?</c> by position, so a query that names the table twice takes
/// its parameters twice, in the order they appear.
/// </summary>
internal static class TeradataCatalog
{
    // The databases and users a Teradata system creates for itself.
    public const string Schemas = """
        SELECT TRIM(DatabaseName) FROM DBC.DatabasesV
        WHERE DatabaseName NOT IN ('All', 'console', 'Crashdumps', 'DBC', 'dbcmngr', 'Default', 'External_AP', 'EXTUSER',
            'LockLogShredder', 'PUBLIC', 'SQLJ', 'Sys_Calendar', 'SysAdmin', 'SYSBAR', 'SYSJDBC', 'SYSLIB', 'SYSSPATIAL',
            'SystemFe', 'SYSUDTLIB', 'SYSUIF', 'TD_SERVER_DB', 'TD_SYSFNLIB', 'TD_SYSGPL', 'TD_SYSXML', 'TDMaps',
            'TDPUSER', 'TDQCD', 'TDStats', 'tdwm', 'viewpoint')
        ORDER BY 1
        """;

    public const string Objects = """
        SELECT TRIM(TableName), TableKind, CommentString
        FROM DBC.TablesV
        WHERE DatabaseName = ? AND TableKind IN ('T', 'O', 'Q', 'V', 'M', 'P', 'E', 'F', 'R', 'A', 'B', 'G')
        ORDER BY TableName
        """;

    // Takes the database and table twice: the key ranks first, then the columns. A PRIMARY KEY ranks above a unique
    // primary index, and the session keys rows by the best rank present.
    public const string Columns = """
        SELECT TRIM(c.ColumnName), c.ColumnType, c.ColumnLength, c.DecimalTotalDigits, c.DecimalFractionalDigits, c.Nullable,
               c.DefaultValue, c.IdColType, c.CommentString, c.CharType, k.KeyRank
        FROM DBC.ColumnsV c
        LEFT JOIN (
            SELECT ColumnName, MIN(CASE WHEN IndexType = 'K' THEN 1 ELSE 2 END) AS KeyRank
            FROM DBC.IndicesV
            WHERE DatabaseName = ? AND TableName = ? AND (IndexType = 'K' OR (IndexType IN ('P', 'Q') AND UniqueFlag = 'Y'))
            GROUP BY ColumnName) k
          ON k.ColumnName = c.ColumnName
        WHERE c.DatabaseName = ? AND c.TableName = ?
        ORDER BY c.ColumnId
        """;

    public const string Indexes = """
        SELECT IndexNumber, TRIM(IndexName), IndexType, UniqueFlag, TRIM(ColumnName)
        FROM DBC.IndicesV
        WHERE DatabaseName = ? AND TableName = ?
        ORDER BY IndexNumber, ColumnPosition
        """;

    public const string ForeignKeys = """
        SELECT IndexID, TRIM(IndexName), TRIM(ChildKeyColumn), TRIM(ParentDB), TRIM(ParentTable), TRIM(ParentKeyColumn)
        FROM DBC.All_RI_ChildrenV
        WHERE ChildDB = ? AND ChildTable = ?
        ORDER BY IndexID
        """;

    public const string Triggers = """
        SELECT TRIM(TriggerName), ActionTime, Event, EnabledFlag, RequestText
        FROM DBC.TriggersV
        WHERE SubjectTableDataBaseName = ? AND TableName = ?
        ORDER BY TriggerName
        """;

    public const string TableKind = "SELECT TableKind FROM DBC.TablesV WHERE DatabaseName = ? AND TableName = ?";

    public const string Users = """
        SELECT TRIM(UserName) AS UserName, TRIM(CreatorName) AS CreatorName, TRIM(DefaultDatabase) AS DefaultDatabase,
               CreateTimeStamp, LastAlterTimeStamp
        FROM DBC.UsersV
        ORDER BY UserName
        """;
}
