using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

internal static partial class Mapping
{
    public static Native.SqlGrammarTag Grammar(SqlGrammar grammar) => grammar switch
    {
        SqlGrammar.PostgreSql => Native.SqlGrammarTag.PostgreSql,
        SqlGrammar.MySql => Native.SqlGrammarTag.MySql,
        SqlGrammar.Sqlite => Native.SqlGrammarTag.Sqlite,
        SqlGrammar.MsSql => Native.SqlGrammarTag.MsSql,
        SqlGrammar.ClickHouse => Native.SqlGrammarTag.ClickHouse,
        SqlGrammar.DuckDb => Native.SqlGrammarTag.DuckDb,
        SqlGrammar.Cql => Native.SqlGrammarTag.Cql,
        SqlGrammar.Redis => Native.SqlGrammarTag.Redis,
        SqlGrammar.Mongo => Native.SqlGrammarTag.Mongo,
        _ => throw new ArgumentOutOfRangeException(nameof(grammar), grammar, "Not a grammar the core knows."),
    };

    public static CompletionItem CompletionItem(Native.CompletionItem item) => new(
        item.Label,
        item.InsertText,
        item.Kind switch
        {
            Native.CompletionKindTag.Schema => CompletionKind.Schema,
            Native.CompletionKindTag.Table => CompletionKind.Table,
            Native.CompletionKindTag.View => CompletionKind.View,
            Native.CompletionKindTag.MaterializedView => CompletionKind.MaterializedView,
            Native.CompletionKindTag.Column => CompletionKind.Column,
            Native.CompletionKindTag.Function => CompletionKind.Function,
            _ => CompletionKind.Keyword,
        },
        item.DataType,
        item.Table is { } table ? new TableName(table.Schema, table.Name) : null,
        [.. item.Matched.Select(span => new MatchedSpan(checked((int)span.Start), checked((int)span.Length)))]);
}
