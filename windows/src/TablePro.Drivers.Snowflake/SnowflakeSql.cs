using System.Text;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Snowflake;

/// <summary>
/// Catalog statements. SHOW and DESCRIBE run on the metadata service and need no running warehouse, unlike
/// INFORMATION_SCHEMA queries, so the sidebar works before a warehouse resumes.
/// </summary>
internal static class SnowflakeSql
{
    public const string ShowDatabases = "SHOW TERSE DATABASES";

    public const string Activity =
        "SELECT QUERY_ID, USER_NAME, WAREHOUSE_NAME, EXECUTION_STATUS, START_TIME, TOTAL_ELAPSED_TIME, QUERY_TEXT "
        + "FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT => 200)) ORDER BY START_TIME DESC";

    public const string CancelQuery = "SELECT SYSTEM$CANCEL_QUERY(:1)";

    public static string Quote(string identifier) => SnowflakeDialect.Instance.QuoteIdentifier(identifier);

    /// <summary>Snowflake strings honour backslash escapes, so both the backslash and the quote are doubled.</summary>
    public static string Literal(string value) =>
        string.Concat("'", value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("'", "''", StringComparison.Ordinal), "'");

    public static string ShowSchemas(string? database) =>
        database is null ? "SHOW TERSE SCHEMAS" : "SHOW TERSE SCHEMAS IN DATABASE " + Quote(database);

    public static string SchemaPath(string? database, string schema) =>
        database is null ? Quote(schema) : string.Concat(Quote(database), ".", Quote(schema));

    public static string TablePath(string? database, ObjectName table, string defaultSchema) =>
        string.Concat(SchemaPath(database, string.IsNullOrEmpty(table.Schema) ? defaultSchema : table.Schema), ".", Quote(table.Name));

    public static string ShowObjects(string schemaPath) => "SHOW TERSE OBJECTS IN SCHEMA " + schemaPath;

    public static string ShowProcedures(string schemaPath) => "SHOW PROCEDURES IN SCHEMA " + schemaPath;

    public static string ShowFunctions(string schemaPath) => "SHOW USER FUNCTIONS IN SCHEMA " + schemaPath;

    public static string ShowSequences(string schemaPath) => "SHOW SEQUENCES IN SCHEMA " + schemaPath;

    public static string Describe(string kind, string tablePath) => $"DESCRIBE {kind} {tablePath}";

    public static string ShowPrimaryKeys(string tablePath) => "SHOW PRIMARY KEYS IN TABLE " + tablePath;

    public static string ShowUniqueKeys(string tablePath) => "SHOW UNIQUE KEYS IN TABLE " + tablePath;

    public static string ShowImportedKeys(string tablePath) => "SHOW IMPORTED KEYS IN TABLE " + tablePath;

    /// <summary>
    /// GET_DDL takes the object as text. A routine is addressed with its argument types, which SHOW reports inside
    /// its <c>arguments</c> column as <c>NAME(NUMBER, VARCHAR) RETURN NUMBER</c>.
    /// </summary>
    public static string GetDdl(ObjectKind kind, string objectPath, string? arguments)
    {
        var type = kind switch
        {
            ObjectKind.View or ObjectKind.MaterializedView => "VIEW",
            ObjectKind.Procedure => "PROCEDURE",
            ObjectKind.Function => "FUNCTION",
            ObjectKind.Sequence => "SEQUENCE",
            _ => "TABLE",
        };

        var path = kind is ObjectKind.Procedure or ObjectKind.Function ? objectPath + ArgumentTypes(arguments) : objectPath;
        return string.Concat("SELECT GET_DDL('", type, "', ", Literal(path), ", TRUE)");
    }

    /// <summary>The parenthesized type list from SHOW's arguments column, or <c>()</c>.</summary>
    public static string ArgumentTypes(string? arguments)
    {
        if (string.IsNullOrWhiteSpace(arguments))
        {
            return "()";
        }

        var open = arguments.IndexOf('(', StringComparison.Ordinal);
        if (open < 0)
        {
            return "()";
        }

        // The types may nest parentheses, as in NUMBER(38,0); the list closes at depth zero.
        var depth = 0;
        var sb = new StringBuilder();
        for (var i = open; i < arguments.Length; i++)
        {
            var c = arguments[i];
            sb.Append(c);
            if (c == '(')
            {
                depth++;
            }
            else if (c == ')' && --depth == 0)
            {
                break;
            }
        }

        return sb.ToString();
    }
}
