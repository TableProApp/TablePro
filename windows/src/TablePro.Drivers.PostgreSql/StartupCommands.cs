using TablePro.Core.Sql;

namespace TablePro.Drivers.PostgreSql;

internal static class StartupCommands
{
    /// <summary>Split once per session, since the statements run on every connection the session opens.</summary>
    public static string[] Split(string? text, SqlDialect dialect)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return [];
        }

        var statements = SqlScript.Split(text, dialect);
        var result = new string[statements.Length];
        for (var i = 0; i < statements.Length; i++)
        {
            result[i] = statements[i].Text;
        }

        return result;
    }
}
