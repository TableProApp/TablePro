using TablePro.Core.Schema;
using TablePro.Drivers.Odbc;

namespace TablePro.Drivers.Dameng;

/// <summary>
/// DM8's dictionary SQL, bound by position with <c>?</c>, and the pure mappers from its rows. DM8 publishes
/// Oracle-shaped <c>ALL_*</c> views, read with their SYS owner so a schema the session switched into cannot plant a
/// same-named view. Long columns come last in each select, the order ODBC lets them be read in.
/// </summary>
internal static class DamengCatalog
{
    public const string Ping = "SELECT 1";

    public const string CurrentSchema = "SELECT SF_GET_SCHEMA_NAME_BY_ID(CURRENT_SCHID)";

    public const string DatabaseName = "SELECT NAME FROM V$DATABASE";

    /// <summary>
    /// <c>BACKSLASH_ESCAPE</c> is a static dm.ini setting: 1 when <c>'\\'</c> is one escaped backslash, 2 when
    /// backslashes are literal. DM8 evaluates a SELECT with no FROM, so the probe reads no table a schema could plant.
    /// </summary>
    public const string BackslashProbe = @"SELECT LENGTH('\\')";

    public const string ReadOnly = "CALL SP_SET_SESSION_READONLY(1)";

    // A schema is an object of type SCH in DM8's dictionary.
    public const string Schemas = "SELECT OBJECT_NAME FROM SYS.ALL_OBJECTS WHERE OBJECT_TYPE = 'SCH' ORDER BY OBJECT_NAME";

    /// <summary>Bound with the schema four times.</summary>
    public const string Objects = """
        SELECT t.TABLE_NAME, 'TABLE', t.NUM_ROWS, c.COMMENTS
        FROM SYS.ALL_TABLES t
        LEFT JOIN SYS.ALL_TAB_COMMENTS c ON c.OWNER = t.OWNER AND c.TABLE_NAME = t.TABLE_NAME
        WHERE t.OWNER = ?
        UNION ALL
        SELECT v.VIEW_NAME, 'VIEW', NULL, NULL FROM SYS.ALL_VIEWS v WHERE v.OWNER = ?
        UNION ALL
        SELECT o.OBJECT_NAME, o.OBJECT_TYPE, NULL, NULL FROM SYS.ALL_OBJECTS o
        WHERE o.OWNER = ? AND o.OBJECT_TYPE IN ('PROCEDURE', 'FUNCTION', 'SEQUENCE')
        UNION ALL
        SELECT g.TRIGGER_NAME, 'TRIGGER', NULL, NULL FROM SYS.ALL_TRIGGERS g WHERE g.OWNER = ?
        ORDER BY 2, 1
        """;

    /// <summary>
    /// Bound with owner, table, owner, table. ALL_COL_COMMENTS keys its schema as SCHEMA_NAME, unlike every other
    /// view here, whose OWNER is the schema.
    /// </summary>
    public const string Columns = """
        SELECT c.COLUMN_NAME, c.DATA_TYPE, c.DATA_LENGTH, c.DATA_PRECISION, c.DATA_SCALE, c.NULLABLE,
               CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 'Y' ELSE 'N' END AS IS_PK,
               com.COMMENTS, c.DATA_DEFAULT
        FROM SYS.ALL_TAB_COLUMNS c
        LEFT JOIN (
            SELECT acc.COLUMN_NAME
            FROM SYS.ALL_CONS_COLUMNS acc
            JOIN SYS.ALL_CONSTRAINTS ac ON acc.CONSTRAINT_NAME = ac.CONSTRAINT_NAME AND acc.OWNER = ac.OWNER
            WHERE ac.CONSTRAINT_TYPE = 'P' AND ac.OWNER = ? AND ac.TABLE_NAME = ?
        ) pk ON c.COLUMN_NAME = pk.COLUMN_NAME
        LEFT JOIN SYS.ALL_COL_COMMENTS com
               ON c.OWNER = com.SCHEMA_NAME AND c.TABLE_NAME = com.TABLE_NAME AND c.COLUMN_NAME = com.COLUMN_NAME
        WHERE c.OWNER = ? AND c.TABLE_NAME = ?
        ORDER BY c.COLUMN_ID
        """;

    /// <summary>
    /// The dictionary views have no identity flag; bit 0 of SYSCOLUMNS.INFO2 marks one. Bound with schema, table.
    /// Read separately and allowed to fail, since it reaches below the documented views.
    /// </summary>
    public const string IdentityColumns = """
        SELECT col.NAME
        FROM SYS.SYSCOLUMNS col
        JOIN SYS.SYSOBJECTS tab ON tab.ID = col.ID
        JOIN SYS.SYSOBJECTS sch ON sch.ID = tab.SCHID AND sch.TYPE$ = 'SCH'
        WHERE sch.NAME = ? AND tab.NAME = ? AND BITAND(col.INFO2, 1) = 1
        """;

    /// <summary>Bound with table, owner.</summary>
    public const string Indexes = """
        SELECT i.INDEX_NAME, i.UNIQUENESS, ic.COLUMN_NAME,
               CASE WHEN c.CONSTRAINT_TYPE = 'P' THEN 'Y' ELSE 'N' END AS IS_PK
        FROM SYS.ALL_INDEXES i
        JOIN SYS.ALL_IND_COLUMNS ic ON i.INDEX_NAME = ic.INDEX_NAME AND i.OWNER = ic.INDEX_OWNER
        LEFT JOIN SYS.ALL_CONSTRAINTS c ON i.INDEX_NAME = c.INDEX_NAME AND i.OWNER = c.OWNER AND c.CONSTRAINT_TYPE = 'P'
        WHERE i.TABLE_NAME = ? AND i.OWNER = ?
        ORDER BY i.INDEX_NAME, ic.COLUMN_POSITION
        """;

    /// <summary>Bound with table, owner.</summary>
    public const string ForeignKeys = """
        SELECT ac.CONSTRAINT_NAME, acc.COLUMN_NAME, rc.OWNER, rc.TABLE_NAME, rcc.COLUMN_NAME, ac.DELETE_RULE
        FROM SYS.ALL_CONSTRAINTS ac
        JOIN SYS.ALL_CONS_COLUMNS acc ON ac.CONSTRAINT_NAME = acc.CONSTRAINT_NAME AND ac.OWNER = acc.OWNER
        JOIN SYS.ALL_CONSTRAINTS rc ON ac.R_CONSTRAINT_NAME = rc.CONSTRAINT_NAME AND ac.R_OWNER = rc.OWNER
        JOIN SYS.ALL_CONS_COLUMNS rcc
          ON rc.CONSTRAINT_NAME = rcc.CONSTRAINT_NAME AND rc.OWNER = rcc.OWNER AND acc.POSITION = rcc.POSITION
        WHERE ac.CONSTRAINT_TYPE = 'R' AND ac.TABLE_NAME = ? AND ac.OWNER = ?
        ORDER BY ac.CONSTRAINT_NAME, acc.POSITION
        """;

    /// <summary>The triggers on one table: TABLE_OWNER plus TABLE_NAME. TRIGGER_BODY is long and stays last.</summary>
    public const string TableTriggers = """
        SELECT TRIGGER_NAME, TRIGGER_TYPE, TRIGGERING_EVENT, DESCRIPTION, TRIGGER_BODY
        FROM SYS.ALL_TRIGGERS
        WHERE TABLE_OWNER = ? AND TABLE_NAME = ?
        ORDER BY TRIGGER_NAME
        """;

    /// <summary>One trigger the schema owns, by OWNER, for its definition.</summary>
    public const string Trigger = """
        SELECT TRIGGER_NAME, TRIGGER_TYPE, TRIGGERING_EVENT, DESCRIPTION, TRIGGER_BODY
        FROM SYS.ALL_TRIGGERS
        WHERE OWNER = ? AND TRIGGER_NAME = ?
        """;

    /// <summary>DM8 keeps the statement that created the view, not only its query.</summary>
    public const string ViewText = "SELECT TEXT FROM SYS.ALL_VIEWS WHERE OWNER = ? AND VIEW_NAME = ?";

    /// <summary>ALL_SOURCE returns no rows when the caller cannot see the object, which is a privilege answer.</summary>
    public const string Source = "SELECT TEXT FROM SYS.ALL_SOURCE WHERE OWNER = ? AND NAME = ? AND TYPE = ? ORDER BY LINE";

    public const string Sequence = """
        SELECT MIN_VALUE, MAX_VALUE, INCREMENT_BY, CYCLE_FLAG, CACHE_SIZE, LAST_NUMBER
        FROM SYS.ALL_SEQUENCES
        WHERE SEQUENCE_OWNER = ? AND SEQUENCE_NAME = ?
        """;

    /// <summary>DM8's own table DDL, with storage and constraints as the server spells them.</summary>
    public const string TableDefinition = "CALL SP_TABLEDEF(?, ?)";

    /// <summary>Bound with table, owner. Every index except the primary key's, which CREATE TABLE declares inline.</summary>
    public const string IndexDefinitions = """
        SELECT i.INDEX_NAME, i.UNIQUENESS, ic.COLUMN_NAME
        FROM SYS.ALL_INDEXES i
        JOIN SYS.ALL_IND_COLUMNS ic ON i.INDEX_NAME = ic.INDEX_NAME AND i.OWNER = ic.INDEX_OWNER
        WHERE i.TABLE_NAME = ? AND i.OWNER = ?
          AND NOT EXISTS (
              SELECT 1 FROM SYS.ALL_CONSTRAINTS c
              WHERE c.INDEX_NAME = i.INDEX_NAME AND c.OWNER = i.OWNER AND c.CONSTRAINT_TYPE = 'P')
        ORDER BY i.INDEX_NAME, ic.COLUMN_POSITION
        """;

    public const string Activity = """
        SELECT SESS_ID, USER_NAME, CURR_SCH, STATE, CLNT_HOST, CLNT_IP, APPNAME, CREATE_TIME, SQL_TEXT
        FROM V$SESSIONS
        ORDER BY STATE, CREATE_TIME
        """;

    public const string Kill = "CALL SP_CLOSE_SESSION(?)";

    public const string Variables = """
        SELECT PARA_NAME, PARA_VALUE, SESS_VALUE, FILE_VALUE, MIN_VALUE, MAX_VALUE, PARA_TYPE, DESCRIPTION
        FROM V$DM_INI
        ORDER BY PARA_NAME
        """;

    public const string DbaUsers = """
        SELECT USERNAME, USER_ID, ACCOUNT_STATUS, LOCK_DATE, EXPIRY_DATE, DEFAULT_TABLESPACE, CREATED
        FROM SYS.DBA_USERS
        ORDER BY USERNAME
        """;

    public const string AllUsers = "SELECT USERNAME, USER_ID, CREATED FROM SYS.ALL_USERS ORDER BY USERNAME";

    /// <summary>
    /// Schemas holding the engine's own objects. SYSDBA is not one: it is the administrator's default schema and where
    /// that login's tables land.
    /// </summary>
    public static readonly IReadOnlyList<string> SystemSchemas = ["SYS", "SYSAUDITOR", "SYSSSO", "CTISYS", "SYSJOB", "SYSGEO2"];

    /// <summary>The sidebar's schemas: the system ones are left out unless the session is in one.</summary>
    public static IReadOnlyList<string> UserSchemas(IEnumerable<string> schemas, string? current) =>
        schemas.Where(s => !SystemSchemas.Contains(s, StringComparer.OrdinalIgnoreCase) || string.Equals(s, current, StringComparison.OrdinalIgnoreCase)).ToArray();

    public static DatabaseObject MapObject(string schema, object?[] row)
    {
        var name = new ObjectName(schema, CatalogValues.Text(row[0]) ?? string.Empty);
        return (CatalogValues.Text(row[1]) ?? string.Empty).Trim().ToUpperInvariant() switch
        {
            "TABLE" => new DatabaseObject(name, ObjectKind.Table, CatalogValues.Int64(CatalogValues.At(row, 2)), CatalogValues.NonEmpty(CatalogValues.At(row, 3))),
            "VIEW" => new DatabaseObject(name, ObjectKind.View),
            "PROCEDURE" => new DatabaseObject(name, ObjectKind.Procedure),
            "FUNCTION" => new DatabaseObject(name, ObjectKind.Function),
            "SEQUENCE" => new DatabaseObject(name, ObjectKind.Sequence),
            "TRIGGER" => new DatabaseObject(name, ObjectKind.Trigger),
            var other => throw new InvalidOperationException($"Dameng listed {name} as an unexpected {other}."),
        };
    }

    public static ColumnInfo MapColumn(object?[] row, int ordinal, IReadOnlySet<string> identityColumns)
    {
        var name = CatalogValues.Text(row[0]) ?? string.Empty;
        var identity = identityColumns.Contains(name);
        var defaultValue = CatalogValues.NonEmpty(CatalogValues.At(row, 8));
        return new ColumnInfo(
            name,
            DamengDdl.FormatType(CatalogValues.Text(row[1]) ?? "VARCHAR", CatalogValues.Int32(row[2]), CatalogValues.Int32(row[3]), CatalogValues.Int32(row[4])),
            CatalogValues.Text(row[5]) == "Y",
            identity ? null : defaultValue,
            CatalogValues.Flag(row[6]),
            identity,
            ordinal,
            CatalogValues.NonEmpty(CatalogValues.At(row, 7)));
    }

    public static IReadOnlyList<IndexInfo> MapIndexes(IReadOnlyList<object?[]> rows)
    {
        var order = new List<string>();
        var columns = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var unique = new Dictionary<string, bool>(StringComparer.Ordinal);
        var primary = new Dictionary<string, bool>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            if (CatalogValues.Text(row[0]) is not { } name || CatalogValues.Text(row[2]) is not { } column)
            {
                continue;
            }

            if (!columns.TryGetValue(name, out var list))
            {
                order.Add(name);
                columns[name] = list = [];
                unique[name] = string.Equals(CatalogValues.Text(row[1]), "UNIQUE", StringComparison.OrdinalIgnoreCase);
                primary[name] = CatalogValues.Flag(row[3]);
            }

            list.Add(column);
        }

        return order.Select(n => new IndexInfo(n, columns[n], unique[n] || primary[n], primary[n])).ToArray();
    }

    /// <summary>DM8, like Oracle, has no ON UPDATE action, so every key reports NO ACTION for it.</summary>
    public static IReadOnlyList<ForeignKeyInfo> MapForeignKeys(IReadOnlyList<object?[]> rows) =>
        rows.GroupBy(r => CatalogValues.Text(r[0]) ?? string.Empty, StringComparer.Ordinal)
            .Select(g =>
            {
                var first = g.First();
                return new ForeignKeyInfo(
                    g.Key,
                    g.Select(r => CatalogValues.Text(r[1]) ?? string.Empty).ToArray(),
                    new ObjectName(CatalogValues.Text(first[2]), CatalogValues.Text(first[3]) ?? string.Empty),
                    g.Select(r => CatalogValues.Text(r[4]) ?? string.Empty).ToArray(),
                    "NO ACTION",
                    CatalogValues.NonEmpty(first[5]) ?? "NO ACTION");
            })
            .ToArray();

    public static TriggerInfo MapTrigger(object?[] row)
    {
        var type = (CatalogValues.Text(row[1]) ?? string.Empty).ToUpperInvariant();
        var timing = type.Contains("INSTEAD OF", StringComparison.Ordinal) ? "INSTEAD OF" : type.StartsWith("BEFORE", StringComparison.Ordinal) ? "BEFORE" : "AFTER";
        return new TriggerInfo(CatalogValues.Text(row[0]) ?? string.Empty, timing, CatalogValues.Text(row[2]) ?? string.Empty, TriggerDefinition(row));
    }

    /// <summary>DESCRIPTION is the header up to the body, as in Oracle; the body follows it.</summary>
    public static string TriggerDefinition(object?[] row)
    {
        var header = CatalogValues.NonEmpty(CatalogValues.At(row, 3));
        var body = CatalogValues.NonEmpty(CatalogValues.At(row, 4));
        if (header is null)
        {
            return body ?? string.Empty;
        }

        return body is null ? "CREATE OR REPLACE TRIGGER " + header : string.Concat("CREATE OR REPLACE TRIGGER ", header, "\n", body);
    }

    /// <summary>The stored statement as it was written, or one built around a bare query.</summary>
    public static string ViewDefinition(ObjectName view, string text)
    {
        var trimmed = text.Trim();
        return trimmed.StartsWith("CREATE", StringComparison.OrdinalIgnoreCase)
            ? trimmed
            : string.Concat("CREATE OR REPLACE VIEW ", DamengDdl.Qualify(view), " AS\n", trimmed);
    }

    public static string RoutineDefinition(IEnumerable<string?> lines)
    {
        var body = string.Concat(lines).Trim();
        return body.StartsWith("CREATE", StringComparison.OrdinalIgnoreCase) ? body : "CREATE OR REPLACE " + body;
    }
}
