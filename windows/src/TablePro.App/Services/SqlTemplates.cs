using System.Text;
using TablePro.Core.Connections;
using TablePro.Core.Schema;

namespace TablePro.App.Services;

/// <summary>Statement skeletons for a table, written with its real columns and the engine's quoting.</summary>
public static class SqlTemplates
{
    public static async Task<string> SelectAsync(ConnectionSession session, DatabaseObject table)
    {
        var structure = await session.GetStructureAsync(table.Name, CancellationToken.None);
        var d = session.Dialect;
        var columns = string.Join(",\n    ", structure.Columns.Select(c => d.QuoteIdentifier(c.Name)));
        var top = session.Profile.Engine == DatabaseEngine.SqlServer ? "TOP 100 " : string.Empty;
        var limit = session.Profile.Engine == DatabaseEngine.SqlServer ? string.Empty : "\nLIMIT 100";
        return $"SELECT {top}\n    {columns}\nFROM {d.Qualify(table.Name)}{limit};";
    }

    public static async Task<string> InsertAsync(ConnectionSession session, DatabaseObject table)
    {
        var structure = await session.GetStructureAsync(table.Name, CancellationToken.None);
        var d = session.Dialect;
        var columns = structure.Columns.Where(c => !c.IsIdentity).ToArray();
        return $"INSERT INTO {d.Qualify(table.Name)} (\n    {string.Join(",\n    ", columns.Select(c => d.QuoteIdentifier(c.Name)))}\n) VALUES (\n    {string.Join(",\n    ", columns.Select(c => Placeholder(c)))}\n);";
    }

    public static async Task<string> UpdateAsync(ConnectionSession session, DatabaseObject table)
    {
        var structure = await session.GetStructureAsync(table.Name, CancellationToken.None);
        var d = session.Dialect;
        var sb = new StringBuilder($"UPDATE {d.Qualify(table.Name)}\nSET\n    ");
        sb.AppendJoin(",\n    ", structure.Columns.Where(c => !c.IsPrimaryKey).Select(c => $"{d.QuoteIdentifier(c.Name)} = {Placeholder(c)}"));
        sb.Append("\nWHERE ").Append(KeyCondition(session, structure)).Append(';');
        return sb.ToString();
    }

    public static async Task<string> DeleteAsync(ConnectionSession session, DatabaseObject table)
    {
        var structure = await session.GetStructureAsync(table.Name, CancellationToken.None);
        return $"DELETE FROM {session.Dialect.Qualify(table.Name)}\nWHERE {KeyCondition(session, structure)};";
    }

    private static string KeyCondition(ConnectionSession session, TableStructure structure)
    {
        var keys = structure.Columns.Where(c => c.IsPrimaryKey).ToArray();
        if (keys.Length == 0)
        {
            keys = structure.Columns.Take(1).ToArray();
        }

        return string.Join(" AND ", keys.Select(k => $"{session.Dialect.QuoteIdentifier(k.Name)} = {Placeholder(k)}"));
    }

    private static string Placeholder(ColumnInfo column) => column.DataType.ToUpperInvariant() switch
    {
        var t when t.Contains("INT", StringComparison.Ordinal) || t.Contains("NUM", StringComparison.Ordinal) || t.Contains("DEC", StringComparison.Ordinal)
            || t.Contains("REAL", StringComparison.Ordinal) || t.Contains("FLOAT", StringComparison.Ordinal) || t.Contains("DOUBLE", StringComparison.Ordinal) => "0",
        var t when t.Contains("BOOL", StringComparison.Ordinal) || t == "BIT" => "FALSE",
        _ => $"'{column.Name}'",
    };
}
