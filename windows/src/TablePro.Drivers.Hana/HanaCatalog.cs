using TablePro.Core.Schema;
using TablePro.Drivers.Odbc;

namespace TablePro.Drivers.Hana;

/// <summary>
/// HANA's catalog SQL over the SYS views, bound by position with <c>?</c>, and the pure mappers from its rows, which
/// follow the macOS driver's. Flags in these views are the strings TRUE and FALSE. Long columns come last in each
/// select, the order ODBC lets them be read in.
/// </summary>
internal static class HanaCatalog
{
    public const string Ping = "SELECT 1 FROM DUMMY";

    public const string CurrentSchema = "SELECT CURRENT_SCHEMA FROM DUMMY";

    public const string DatabaseName = "SELECT DATABASE_NAME FROM SYS.M_DATABASE";

    /// <summary>The session's access mode, which later transactions on the connection inherit.</summary>
    public const string ReadOnly = "SET TRANSACTION READ ONLY";

    public const string Schemas = "SELECT SCHEMA_NAME FROM SYS.SCHEMAS ORDER BY SCHEMA_NAME";

    /// <summary>
    /// Bound with the schema seven times. M_TABLES can hold a row per host for a distributed table, so its counts are
    /// summed before the join.
    /// </summary>
    public const string Objects = """
        SELECT T.TABLE_NAME, 'TABLE', M.RECORD_COUNT, T.COMMENTS
        FROM SYS.TABLES T
        LEFT JOIN (
            SELECT TABLE_NAME, SUM(RECORD_COUNT) AS RECORD_COUNT FROM SYS.M_TABLES WHERE SCHEMA_NAME = ? GROUP BY TABLE_NAME
        ) M ON M.TABLE_NAME = T.TABLE_NAME
        WHERE T.SCHEMA_NAME = ? AND T.IS_USER_DEFINED_TYPE = 'FALSE'
        UNION ALL
        SELECT VIEW_NAME, 'VIEW', NULL, COMMENTS FROM SYS.VIEWS WHERE SCHEMA_NAME = ?
        UNION ALL
        SELECT PROCEDURE_NAME, 'PROCEDURE', NULL, NULL FROM SYS.PROCEDURES WHERE SCHEMA_NAME = ?
        UNION ALL
        SELECT FUNCTION_NAME, 'FUNCTION', NULL, NULL FROM SYS.FUNCTIONS WHERE SCHEMA_NAME = ?
        UNION ALL
        SELECT SEQUENCE_NAME, 'SEQUENCE', NULL, NULL FROM SYS.SEQUENCES WHERE SCHEMA_NAME = ?
        UNION ALL
        SELECT TRIGGER_NAME, 'TRIGGER', NULL, NULL FROM SYS.TRIGGERS WHERE SCHEMA_NAME = ?
        ORDER BY 2, 1
        """;

    /// <summary>A table's or a view's columns, bound with schema, table, schema, view.</summary>
    public const string Columns = """
        SELECT C.COLUMN_NAME, C.DATA_TYPE_NAME, C.LENGTH, C.SCALE, C.IS_NULLABLE, C.GENERATION_TYPE,
               K.POSITION AS KEY_POSITION, C.COMMENTS, C.DEFAULT_VALUE, C.GENERATED_ALWAYS_AS
        FROM (
            SELECT SCHEMA_NAME, TABLE_NAME, COLUMN_NAME, POSITION, DATA_TYPE_NAME, LENGTH, SCALE,
                   IS_NULLABLE, DEFAULT_VALUE, COMMENTS, GENERATION_TYPE, GENERATED_ALWAYS_AS
            FROM SYS.TABLE_COLUMNS
            WHERE SCHEMA_NAME = ? AND TABLE_NAME = ?
            UNION ALL
            SELECT SCHEMA_NAME, VIEW_NAME, COLUMN_NAME, POSITION, DATA_TYPE_NAME, LENGTH, SCALE,
                   IS_NULLABLE, DEFAULT_VALUE, COMMENTS, GENERATION_TYPE, GENERATED_ALWAYS_AS
            FROM SYS.VIEW_COLUMNS
            WHERE SCHEMA_NAME = ? AND VIEW_NAME = ?
        ) C
        LEFT JOIN SYS.CONSTRAINTS K
               ON K.SCHEMA_NAME = C.SCHEMA_NAME AND K.TABLE_NAME = C.TABLE_NAME
              AND K.COLUMN_NAME = C.COLUMN_NAME AND K.IS_PRIMARY_KEY = 'TRUE'
        ORDER BY C.POSITION
        """;

    public const string Indexes = """
        SELECT I.INDEX_NAME, I.INDEX_TYPE, C.CONSTRAINT, C.COLUMN_NAME, C.ASCENDING_ORDER
        FROM SYS.INDEXES I
        JOIN SYS.INDEX_COLUMNS C
          ON C.SCHEMA_NAME = I.SCHEMA_NAME AND C.TABLE_NAME = I.TABLE_NAME AND C.INDEX_NAME = I.INDEX_NAME
        WHERE I.SCHEMA_NAME = ? AND I.TABLE_NAME = ?
        ORDER BY I.INDEX_NAME, C.POSITION
        """;

    public const string ForeignKeys = """
        SELECT CONSTRAINT_NAME, COLUMN_NAME, REFERENCED_SCHEMA_NAME, REFERENCED_TABLE_NAME,
               REFERENCED_COLUMN_NAME, UPDATE_RULE, DELETE_RULE
        FROM SYS.REFERENTIAL_CONSTRAINTS
        WHERE SCHEMA_NAME = ? AND TABLE_NAME = ?
        ORDER BY CONSTRAINT_NAME, POSITION
        """;

    public const string TableTriggers = """
        SELECT TRIGGER_NAME, TRIGGER_ACTION_TIME, TRIGGER_EVENT, DEFINITION
        FROM SYS.TRIGGERS
        WHERE SUBJECT_TABLE_SCHEMA = ? AND SUBJECT_TABLE_NAME = ?
        ORDER BY TRIGGER_NAME
        """;

    /// <summary>The server's own CREATE statement for any object, when the login may run it.</summary>
    public const string ObjectDefinition = "CALL SYS.GET_OBJECT_DEFINITION(?, ?)";

    public const string TableStore = "SELECT IS_COLUMN_TABLE FROM SYS.TABLES WHERE SCHEMA_NAME = ? AND TABLE_NAME = ?";

    public const string TableComment = "SELECT COMMENTS FROM SYS.TABLES WHERE SCHEMA_NAME = ? AND TABLE_NAME = ?";

    public const string ViewDefinition = "SELECT DEFINITION FROM SYS.VIEWS WHERE SCHEMA_NAME = ? AND VIEW_NAME = ?";

    public const string ProcedureDefinition = "SELECT DEFINITION FROM SYS.PROCEDURES WHERE SCHEMA_NAME = ? AND PROCEDURE_NAME = ?";

    public const string FunctionDefinition = "SELECT DEFINITION FROM SYS.FUNCTIONS WHERE SCHEMA_NAME = ? AND FUNCTION_NAME = ?";

    public const string TriggerDefinition = "SELECT DEFINITION FROM SYS.TRIGGERS WHERE SCHEMA_NAME = ? AND TRIGGER_NAME = ?";

    public const string Sequence = """
        SELECT START_NUMBER, MIN_VALUE, MAX_VALUE, INCREMENT_BY, IS_CYCLED, CACHE_SIZE
        FROM SYS.SEQUENCES
        WHERE SCHEMA_NAME = ? AND SEQUENCE_NAME = ?
        """;

    /// <summary>
    /// M_CONNECTIONS keeps closed connections for a while with an empty status; only open ones are listed, each with
    /// the statement it is running.
    /// </summary>
    public const string Activity = """
        SELECT C.CONNECTION_ID, C.USER_NAME, C.CONNECTION_STATUS, C.CLIENT_HOST, C.CLIENT_IP, C.CURRENT_SCHEMA_NAME,
               C.START_TIME, C.IDLE_TIME, S.STATEMENT_STRING
        FROM SYS.M_CONNECTIONS C
        LEFT JOIN SYS.M_ACTIVE_STATEMENTS S ON S.CONNECTION_ID = C.CONNECTION_ID AND S.STATEMENT_STATUS = 'ACTIVE'
        WHERE C.CONNECTION_ID > 0 AND C.CONNECTION_STATUS <> ''
        ORDER BY C.CONNECTION_STATUS DESC, C.START_TIME
        """;

    public const string Variables = """
        SELECT FILE_NAME, SECTION, KEY, VALUE, LAYER_NAME, TENANT_NAME, HOST
        FROM SYS.M_INIFILE_CONTENTS
        ORDER BY FILE_NAME, SECTION, KEY, LAYER_NAME
        """;

    /// <summary>The ini files need INIFILE ADMIN or catalog read; the system overview is open to any login.</summary>
    public const string SystemOverview = "SELECT SECTION, NAME, STATUS, VALUE FROM SYS.M_SYSTEM_OVERVIEW ORDER BY SECTION, NAME";

    public const string Users = """
        SELECT USER_NAME, USER_DEACTIVATED, IS_PASSWORD_ENABLED, CREATOR, CREATE_TIME, VALID_FROM, VALID_UNTIL, LAST_SUCCESSFUL_CONNECT
        FROM SYS.USERS
        ORDER BY USER_NAME
        """;

    public const string ExplainPlanColumns =
        "OPERATOR_ID, PARENT_OPERATOR_ID, POSITION, OPERATOR_NAME, OPERATOR_DETAILS, SCHEMA_NAME, TABLE_NAME, OUTPUT_SIZE, SUBTREE_COST";

    /// <summary>The schemas HANA installs for itself, from the macOS driver's list; every <c>_SYS</c> schema is one.</summary>
    public static readonly IReadOnlyList<string> SystemSchemas = ["SYS", "SYS_DATABASES"];

    private static readonly string[] LengthTypes = ["CHAR", "NCHAR", "VARCHAR", "NVARCHAR", "ALPHANUM", "SHORTTEXT", "VARBINARY", "BINARY"];

    private static readonly string[] UniqueConstraints = ["PRIMARY_KEY", "UNIQUE", "NOT_NULL_UNIQUE"];

    public static bool IsSystemSchema(string schema) =>
        schema.StartsWith("_SYS", StringComparison.OrdinalIgnoreCase) || SystemSchemas.Contains(schema, StringComparer.OrdinalIgnoreCase);

    /// <summary>The sidebar's schemas: the system ones are left out unless the session is in one.</summary>
    public static IReadOnlyList<string> UserSchemas(IEnumerable<string> schemas, string? current) =>
        schemas.Where(s => !IsSystemSchema(s) || string.Equals(s, current, StringComparison.Ordinal)).ToArray();

    public static DatabaseObject MapObject(string schema, object?[] row)
    {
        var name = new ObjectName(schema, CatalogValues.Text(row[0]) ?? string.Empty);
        var comment = CatalogValues.NonEmpty(CatalogValues.At(row, 3));
        return (CatalogValues.Text(row[1]) ?? string.Empty).Trim() switch
        {
            "TABLE" => new DatabaseObject(name, ObjectKind.Table, CatalogValues.Int64(CatalogValues.At(row, 2)), comment),
            "VIEW" => new DatabaseObject(name, ObjectKind.View, null, comment),
            "PROCEDURE" => new DatabaseObject(name, ObjectKind.Procedure),
            "FUNCTION" => new DatabaseObject(name, ObjectKind.Function),
            "SEQUENCE" => new DatabaseObject(name, ObjectKind.Sequence),
            "TRIGGER" => new DatabaseObject(name, ObjectKind.Trigger),
            var other => throw new InvalidOperationException($"SAP HANA listed {name} as an unexpected {other}."),
        };
    }

    /// <summary>
    /// An identity's default is its sequence and a computed column's is its expression, neither of which anyone typed,
    /// so both report no default.
    /// </summary>
    public static ColumnInfo MapColumn(object?[] row, int ordinal)
    {
        var generation = Normalize(CatalogValues.Text(row[5]));
        var identity = generation?.EndsWith("AS IDENTITY", StringComparison.Ordinal) == true;
        var generated = generation is not null;
        return new ColumnInfo(
            CatalogValues.Text(row[0]) ?? string.Empty,
            RenderType(CatalogValues.Text(row[1]) ?? "NVARCHAR", CatalogValues.Int32(row[2]), CatalogValues.Int32(row[3])),
            CatalogValues.Flag(row[4]),
            generated ? null : CatalogValues.Text(CatalogValues.At(row, 8)),
            row[6] is not null,
            identity,
            ordinal,
            CatalogValues.NonEmpty(CatalogValues.At(row, 7)));
    }

    /// <summary>The type as CREATE TABLE spells it: a length for string and binary types, precision and scale for DECIMAL.</summary>
    public static string RenderType(string name, int? length, int? scale)
    {
        var upper = name.Trim().ToUpperInvariant();
        if (LengthTypes.Contains(upper) && length is > 0)
        {
            return string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{name}({length})");
        }

        // A DECIMAL with no scale is HANA's floating decimal, which has no precision to write.
        return upper == "DECIMAL" && length is not null && scale is not null
            ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{name}({length},{scale})")
            : name;
    }

    public static IReadOnlyList<IndexInfo> MapIndexes(IReadOnlyList<object?[]> rows)
    {
        var order = new List<string>();
        var types = new Dictionary<string, string?>(StringComparer.Ordinal);
        var constraints = new Dictionary<string, string>(StringComparer.Ordinal);
        var columns = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            if (CatalogValues.Text(row[0]) is not { } name || CatalogValues.Text(row[3]) is not { } column)
            {
                continue;
            }

            if (!columns.TryGetValue(name, out var list))
            {
                order.Add(name);
                columns[name] = list = [];
                types[name] = Normalize(CatalogValues.Text(row[1]));
            }

            if (!constraints.ContainsKey(name) && Constraint(row[2]) is { } constraint)
            {
                constraints[name] = constraint;
            }

            list.Add(string.Equals(CatalogValues.Text(row[4]), "FALSE", StringComparison.OrdinalIgnoreCase) ? column + " DESC" : column);
        }

        return order.Select(n =>
            {
                var constraint = constraints.GetValueOrDefault(n);
                return new IndexInfo(n, columns[n], constraint is not null && UniqueConstraints.Contains(constraint), constraint == "PRIMARY_KEY", types[n]);
            })
            .ToArray();
    }

    /// <summary>HANA's default referential action is RESTRICT, which is what an empty rule means.</summary>
    public static IReadOnlyList<ForeignKeyInfo> MapForeignKeys(IReadOnlyList<object?[]> rows) =>
        rows.GroupBy(r => CatalogValues.Text(r[0]) ?? string.Empty, StringComparer.Ordinal)
            .Select(g =>
            {
                var first = g.First();
                return new ForeignKeyInfo(
                    g.Key,
                    g.Select(r => CatalogValues.Text(r[1]) ?? string.Empty).ToArray(),
                    new ObjectName(CatalogValues.NonEmpty(first[2]), CatalogValues.Text(first[3]) ?? string.Empty),
                    g.Select(r => CatalogValues.Text(r[4]) ?? string.Empty).ToArray(),
                    CatalogValues.NonEmpty(first[5]) ?? "RESTRICT",
                    CatalogValues.NonEmpty(first[6]) ?? "RESTRICT");
            })
            .ToArray();

    public static TriggerInfo MapTrigger(object?[] row) =>
        new(
            CatalogValues.Text(row[0]) ?? string.Empty,
            Normalize(CatalogValues.Text(row[1])) ?? string.Empty,
            Normalize(CatalogValues.Text(row[2])) ?? string.Empty,
            CatalogValues.NonEmpty(CatalogValues.At(row, 3)));

    private static string? Constraint(object? value) =>
        CatalogValues.NonEmpty(value) is { } text ? string.Join('_', text.ToUpperInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries)) : null;

    private static string? Normalize(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : string.Join(' ', value.ToUpperInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
}
