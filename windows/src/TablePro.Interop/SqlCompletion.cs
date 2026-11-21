using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

public enum CompletionKind
{
    Keyword,
    Schema,
    Table,
    View,
    MaterializedView,
    Column,
    Function,
}

// UTF-16 units of the label.
public readonly record struct MatchedSpan(int Start, int Length);

// Label and InsertText are cased for the word ranked. DataType and Table are a column's.
public sealed record CompletionItem(
    string Label,
    string InsertText,
    CompletionKind Kind,
    string? DataType,
    TableName? Table,
    IReadOnlyList<MatchedSpan> Matched);

// Total counts every match; Items holds the closest of them.
public sealed record CompletionPage(int Total, IReadOnlyList<CompletionItem> Items);

// What one completion offers, ranked again for each word typed without reading the catalog again.
public sealed class SqlCompletion : IDisposable
{
    private readonly Native.CompletionList _list;

    internal SqlCompletion(Native.CompletionList list)
    {
        _list = list;
        WordStart = checked((int)list.WordStart());
        Word = list.Word();
    }

    // In UTF-16 units of the text the completion was asked for.
    public int WordStart { get; }

    public string Word { get; }

    // Ranking a catalog of 50,000 names takes milliseconds, so a UI thread calls this from the pool.
    public CompletionPage Rank(string word, int limit)
    {
        ArgumentNullException.ThrowIfNull(word);
        ArgumentOutOfRangeException.ThrowIfNegative(limit);
        var page = _list.Rank(word, checked((uint)limit));
        return new CompletionPage(checked((int)page.Total), [.. page.Items.Select(Mapping.CompletionItem)]);
    }

    public void Dispose() => _list.Dispose();
}

// UTF-16 units, as the editor counts them.
public sealed record FormattedSql(string Text, int Caret);

// A statement the formatter would change the meaning of is kept as typed, so a format never changes what runs.
public static class SqlFormatter
{
    public static FormattedSql Format(SqlGrammar grammar, string text, int caret)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentOutOfRangeException.ThrowIfNegative(caret);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(caret, text.Length);
        var formatted = CoreCall.Run(
            () => Native.CoreMethods.FormatSql(text, Mapping.Grammar(grammar), checked((uint)caret)));
        return new FormattedSql(formatted.Text, checked((int)formatted.Caret));
    }

    // The text between start and end, formatted where the whole text keeps its meaning, as it is elsewhere.
    public static string FormatSelection(SqlGrammar grammar, string text, int start, int end)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentOutOfRangeException.ThrowIfNegative(start);
        ArgumentOutOfRangeException.ThrowIfLessThan(end, start);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(end, text.Length);
        return CoreCall.Run(() => Native.CoreMethods.FormatSqlSelection(
            text,
            Mapping.Grammar(grammar),
            checked((uint)start),
            checked((uint)end)));
    }
}
