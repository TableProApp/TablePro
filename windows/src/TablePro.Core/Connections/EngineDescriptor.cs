using System.Collections.Frozen;

namespace TablePro.Core.Connections;

/// <summary>What the app knows about an engine before any connection exists.</summary>
public sealed record EngineDescriptor(
    DatabaseEngine Engine,
    string DisplayName,
    int DefaultPort,
    bool IsFileBased,
    bool HasSchemas,
    string DefaultUser,
    string FileExtensions)
{
    private static readonly FrozenDictionary<DatabaseEngine, EngineDescriptor> All = new EngineDescriptor[]
    {
        new(DatabaseEngine.PostgreSql, "PostgreSQL", 5432, IsFileBased: false, HasSchemas: true, "postgres", ""),
        new(DatabaseEngine.MySql, "MySQL", 3306, IsFileBased: false, HasSchemas: false, "root", ""),
        new(DatabaseEngine.MariaDb, "MariaDB", 3306, IsFileBased: false, HasSchemas: false, "root", ""),
        new(DatabaseEngine.SqlServer, "SQL Server", 1433, IsFileBased: false, HasSchemas: true, "sa", ""),
        new(DatabaseEngine.Sqlite, "SQLite", 0, IsFileBased: true, HasSchemas: false, "", ".sqlite;.sqlite3;.db;.db3"),
        new(DatabaseEngine.DuckDb, "DuckDB", 0, IsFileBased: true, HasSchemas: true, "", ".duckdb;.ddb"),
    }.ToFrozenDictionary(d => d.Engine);

    public static IEnumerable<EngineDescriptor> Engines => All.Values.OrderBy(d => d.Engine);

    public static EngineDescriptor For(DatabaseEngine engine) => All[engine];
}
