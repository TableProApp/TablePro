using System.Text.Json;

namespace TablePro.Mcp.Tools;

/// <summary>A tool as <c>tools/list</c> describes it. The schema is JSON Schema text written by hand, so no reflection builds it.</summary>
public sealed record McpToolDefinition(string Name, string Title, string Description, string InputSchema, bool ReadOnly);

public static class McpToolCatalog
{
    public const string Instructions =
        "TablePro reaches the database connections the user saved in it. Start with list_connections. A connection has "
        + "to be open in a TablePro window: call connect for one whose is_open is false, and the user may have to answer "
        + "TablePro first. Call describe_table before writing SQL against a table. execute_query runs one statement: a "
        + "read runs read-only, and a write runs only where the connection's External Clients level allows it and after "
        + "the user approves it in TablePro. A refusal is the user's setting, not a passing failure, so do not retry it.";

    private const string ConnectionId = """
        "connection_id": { "type": "string", "description": "A connection id from list_connections." }
        """;

    private const string Table = """
        "table": { "type": "string", "description": "The table or view name, unquoted." }
        """;

    private const string Schema = """
        "schema": { "type": "string", "description": "The table's schema. Omit it for the connection's default schema." }
        """;

    private const string Logic = """
        "logic": { "type": "string", "enum": ["and", "or"], "description": "How the filters combine. Defaults to and." }
        """;

    private const string Filters = """
        "filters": {
          "type": "array",
          "description": "Conditions on columns, joined by logic.",
          "items": {
            "type": "object",
            "properties": {
              "column": { "type": "string", "description": "The column name, unquoted." },
              "operator": { "type": "string", "enum": ["eq", "not_eq", "gt", "gt_eq", "lt", "lt_eq", "contains", "not_contains", "starts_with", "ends_with", "is_null", "is_not_null", "is_empty", "is_not_empty", "in", "not_in", "between"] },
              "value": { "type": "string", "description": "The value to compare with, as text. Not used by is_null, is_not_null, is_empty, is_not_empty, in, not_in and between." },
              "values": { "type": "array", "items": { "type": "string" }, "description": "The list for in and not_in, or the low and high bounds for between." }
            },
            "required": ["column", "operator"],
            "additionalProperties": false
          }
        }
        """;

    public static IReadOnlyList<McpToolDefinition> All { get; } =
    [
        new("list_connections", "List Connections",
            "The saved connections a client may use, with whether each is open in TablePro, its External Clients level (read_only or read_write) and its Safe Mode level.",
            """{ "type": "object", "properties": {}, "additionalProperties": false }""", ReadOnly: true),
        new("connect", "Open a Connection",
            "Open a saved connection in a TablePro window, as the user would. The user may have to answer TablePro first, such as for a password; then the status is connecting, and calling connect again tells when it is open.",
            Object(ConnectionId, required: "\"connection_id\""), ReadOnly: true),
        new("list_schemas", "List Schemas",
            "The schemas of an open connection, with the default one marked.",
            Object(ConnectionId, required: "\"connection_id\""), ReadOnly: true),
        new("list_tables", "List Tables",
            "The tables and views of one schema, read again from the server.",
            Object($"{ConnectionId}, \"schema\": {{ \"type\": \"string\", \"description\": \"The schema to list. Omit it for the connection's default schema.\" }}", required: "\"connection_id\""), ReadOnly: true),
        new("describe_table", "Describe a Table",
            "A table's columns with their types, nullability, keys and defaults, its indexes and foreign keys.",
            Object($"{ConnectionId}, {Table}, {Schema}", required: "\"connection_id\", \"table\""), ReadOnly: true),
        new("get_table_ddl", "Show CREATE TABLE",
            "The statement that creates the table or view as it is defined now, in the connection's own dialect.",
            Object($"{ConnectionId}, {Table}, {Schema}", required: "\"connection_id\", \"table\""), ReadOnly: true),
        new("browse_table", "Browse a Table",
            "Rows of a table or view, filtered and sorted without writing SQL. Identifiers are quoted for the engine and values are bound as parameters.",
            Object($$"""
                {{ConnectionId}}, {{Table}}, {{Schema}}, {{Filters}}, {{Logic}},
                "sort": {
                  "type": "array",
                  "description": "Columns to sort by, in order.",
                  "items": {
                    "type": "object",
                    "properties": {
                      "column": { "type": "string", "description": "The column name, unquoted." },
                      "direction": { "type": "string", "enum": ["ascending", "descending"], "description": "Defaults to ascending." }
                    },
                    "required": ["column"],
                    "additionalProperties": false
                  }
                },
                "limit": { "type": "integer", "minimum": 1, "maximum": 1000, "description": "Rows to return, 1 to 1000. Defaults to 100." },
                "offset": { "type": "integer", "minimum": 0, "description": "Rows to skip first. Defaults to 0." }
                """, required: "\"connection_id\", \"table\""), ReadOnly: true),
        new("count_rows", "Count Rows",
            "The exact number of rows in a table, under optional filters.",
            Object($"{ConnectionId}, {Table}, {Schema}, {Filters}, {Logic}", required: "\"connection_id\", \"table\""), ReadOnly: true),
        new("execute_query", "Run a Statement",
            "Run one SQL statement, or one batch on SQL Server. A read runs read-only. A write runs only on a connection whose External Clients level is Read & Write and whose Safe Mode is not Read-Only, and only after the user approves it in TablePro. An answer keeps at most 20 result sets of 1,000 rows each.",
            Object($$"""
                {{ConnectionId}},
                "query": { "type": "string", "description": "One SQL statement, or one batch on SQL Server, in the connection's own dialect. 100 KB at most." },
                "max_rows": { "type": "integer", "minimum": 1, "maximum": 1000, "description": "Rows to keep per result set, 1 to 1000. Defaults to 100." },
                "timeout_seconds": { "type": "integer", "minimum": 1, "maximum": 300, "description": "Seconds before the statement is stopped, 1 to 300. Defaults to 30." }
                """, required: "\"connection_id\", \"query\""), ReadOnly: false),
    ];

    public static McpToolDefinition? Find(string name) => All.FirstOrDefault(t => t.Name == name);

    internal static void WriteTool(Utf8JsonWriter writer, McpToolDefinition tool)
    {
        writer.WriteStartObject();
        writer.WriteString("name", tool.Name);
        writer.WriteString("title", tool.Title);
        writer.WriteString("description", tool.Description);
        writer.WritePropertyName("inputSchema");
        writer.WriteRawValue(tool.InputSchema);
        writer.WriteStartObject("annotations");
        writer.WriteString("title", tool.Title);
        writer.WriteBoolean("readOnlyHint", tool.ReadOnly);
        writer.WriteBoolean("destructiveHint", !tool.ReadOnly);
        writer.WriteBoolean("idempotentHint", tool.ReadOnly);
        writer.WriteBoolean("openWorldHint", false);
        writer.WriteEndObject();
        writer.WriteEndObject();
    }

    private static string Object(string properties, string required) =>
        $$"""{ "type": "object", "properties": { {{properties}} }, "required": [{{required}}], "additionalProperties": false }""";
}
