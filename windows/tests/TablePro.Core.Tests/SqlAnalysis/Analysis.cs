using System.Collections.Immutable;
using TablePro.Core.Sql;
using TablePro.Core.Sql.Analysis;
using Analyzed = TablePro.Core.Sql.Analysis.SqlAnalysis;

namespace TablePro.Core.Tests.SqlAnalysis;

/// <summary>Shared fixtures: a small shop catalog and helpers that find ranges by the text they cover.</summary>
internal static class Analysis
{
    /// <summary>
    /// users and orders have loaded columns; active_users is a view whose structure has not been opened, so nothing can
    /// be said about its columns.
    /// </summary>
    public static CompletionCatalog Shop { get; } = new(
        ["public", "sales"],
        [("users", false), ("orders", false), ("active_users", true)],
        new Dictionary<string, IReadOnlyList<(string Name, string Type)>>
        {
            ["users"] = [("id", "integer"), ("name", "text"), ("email", "text")],
            ["orders"] = [("id", "integer"), ("user_id", "integer"), ("total", "numeric")],
        });

    public static Analyzed Analyze(string text, SqlDialect? dialect = null, CompletionCatalog? catalog = null, int? caret = null) =>
        SqlAnalyzer.Analyze(text, dialect ?? PostgreSqlDialect.Instance, catalog ?? Shop, caret);

    public static ImmutableArray<SqlDiagnostic> Diagnose(string text, SqlDialect? dialect = null, CompletionCatalog? catalog = null, int? caret = null) =>
        Analyze(text, dialect, catalog, caret).Diagnostics;

    public static SqlDiagnosticCode[] Codes(string text, SqlDialect? dialect = null, CompletionCatalog? catalog = null, int? caret = null) =>
        [.. Diagnose(text, dialect, catalog, caret).Select(d => d.Code)];

    /// <summary>The range of the <paramref name="nth"/> occurrence of <paramref name="needle"/>, counted from zero.</summary>
    public static SqlTextRange Range(string text, string needle, int nth = 0)
    {
        var at = -1;
        for (var i = 0; i <= nth; i++)
        {
            at = text.IndexOf(needle, at + 1, StringComparison.Ordinal);
            Assert.True(at >= 0, $"'{needle}' #{nth} is not in the text");
        }

        return new SqlTextRange(at, needle.Length);
    }

    public static int At(string text, string needle, int nth = 0) => Range(text, needle, nth).Start;
}
