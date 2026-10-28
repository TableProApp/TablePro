namespace TablePro.Core.Connections;

/// <summary>The engines the Windows app ships a driver for. The value is stored in connections.json.</summary>
public enum DatabaseEngine
{
    PostgreSql,
    MySql,
    MariaDb,
    SqlServer,
    Sqlite,
    DuckDb,
}
