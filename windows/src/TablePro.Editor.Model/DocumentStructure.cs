using System.Buffers;

namespace TablePro.Editor.Model;

// The lexer's kinds that carry structure: a bracket pairs only as a Punctuation or Operator token, BEGIN and END only
// as keywords, and only a comment folds as one.
public sealed record SyntaxRoles(byte Keyword, byte Comment, byte Punctuation, byte Operator);

// What a lexer knows beyond colors, for the statement band, folds and bracket pairs. Called off the UI thread.
public interface ISqlStructure
{
    SyntaxRoles Roles { get; }

    // Each statement's text without its terminator, in order.
    void SplitStatements(ReadOnlySpan<char> text, List<(int Start, int End)> statements);
}

// Statements and fold regions of one version of the text, read from a snapshot so it can run off the UI thread.
public sealed class DocumentStructure
{
    // The same limit the macOS editor stops folding and statement markers at.
    public const int SizeLimit = 2_000_000;

    private static readonly string[] s_notBlocks = ["TRANSACTION", "TRAN", "WORK", "DEFERRED", "IMMEDIATE", "EXCLUSIVE", "DISTRIBUTED"];
    private static readonly string[] s_otherEnds = ["IF", "LOOP", "WHILE", "REPEAT", "FOR"];

    private readonly List<(int Start, int End)> _statements;
    private readonly List<FoldRegion> _regions;

    private DocumentStructure(long version, List<(int Start, int End)> statements, List<FoldRegion> regions)
    {
        Version = version;
        _statements = statements;
        _regions = regions;
    }

    public static DocumentStructure Empty { get; } = new(-1, [], []);

    // The text version it was read from; one mapped through later edits keeps it, so a fresh read can replace it.
    public long Version { get; }

    public IReadOnlyList<(int Start, int End)> Statements => _statements;

    // Sorted by first line, one per line: where several start on a line, the one reaching furthest.
    public IReadOnlyList<FoldRegion> Regions => _regions;

    public static DocumentStructure Analyze(string text, long version, ISyntaxLexer? lexer, ISqlStructure? structure)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (structure is null || text.Length == 0 || text.Length > SizeLimit)
        {
            return new DocumentStructure(version, [], []);
        }
        var statements = new List<(int Start, int End)>();
        structure.SplitStatements(text, statements);
        var spans = lexer is null ? null : ArrayPool<SyntaxSpan>.Shared.Rent(text.Length);
        try
        {
            var count = lexer is null ? 0 : lexer.Tokenize(text, spans);
            var regions = FindRegions(text, spans.AsSpan(0, count), statements, structure.Roles);
            return new DocumentStructure(version, statements, regions);
        }
        finally
        {
            if (spans is not null)
            {
                ArrayPool<SyntaxSpan>.Shared.Return(spans);
            }
        }
    }

    // As the core's statement_at reads the caret: the statement it is in, or the last one that starts before it.
    public (int Start, int End)? StatementAt(int offset)
    {
        if (_statements.Count == 0)
        {
            return null;
        }
        var low = 0;
        var high = _statements.Count;
        while (low < high)
        {
            var middle = (low + high) >>> 1;
            if (_statements[middle].Start <= offset)
            {
                low = middle + 1;
            }
            else
            {
                high = middle;
            }
        }
        return _statements[Math.Max(0, low - 1)];
    }

    public FoldRegion? RegionAt(int startLine) => FoldSet.FindStart(_regions, startLine);

    // The innermost region whose lines hold the line, for Fold at the caret.
    public FoldRegion? InnermostAround(int line)
    {
        FoldRegion? found = null;
        foreach (var region in _regions)
        {
            if (region.StartLine > line)
            {
                break;
            }
            if (line <= region.EndLine && (found is not { } inner || region.StartLine >= inner.StartLine))
            {
                found = region;
            }
        }
        return found;
    }

    // Regions no other region holds, which Fold All folds, as the macOS editor folds top-level statements only.
    public IEnumerable<FoldRegion> TopLevel()
    {
        var end = -1;
        foreach (var region in _regions)
        {
            if (region.StartLine > end)
            {
                yield return region;
                end = region.EndLine;
            }
        }
    }

    // Until a fresh read replaces it, an edit shifts what lies after it and drops what it touched.
    public DocumentStructure Map(TextChange change)
    {
        ArgumentNullException.ThrowIfNull(change);
        var statements = new List<(int Start, int End)>(_statements.Count);
        var removedEnd = change.Offset + change.RemovedLength;
        var delta = change.InsertedLength - change.RemovedLength;
        foreach (var (start, end) in _statements)
        {
            if (end < change.Offset)
            {
                statements.Add((start, end));
            }
            else if (start >= removedEnd)
            {
                statements.Add((start + delta, end + delta));
            }
            else if (start <= change.Offset && end >= removedEnd)
            {
                statements.Add((start, end + delta));
            }
        }
        var regions = new List<FoldRegion>(_regions.Count);
        foreach (var region in _regions)
        {
            if (region.Map(change) is { } mapped)
            {
                regions.Add(mapped);
            }
        }
        return new DocumentStructure(Version, statements, regions);
    }

    private static List<FoldRegion> FindRegions(string text, ReadOnlySpan<SyntaxSpan> tokens,
        List<(int Start, int End)> statements, SyntaxRoles roles)
    {
        var lineStarts = LineStarts(text);
        int LineOf(int offset)
        {
            var index = Array.BinarySearch(lineStarts, offset);
            return index >= 0 ? index : ~index - 1;
        }

        var found = new List<FoldRegion>();
        void Add(int startLine, int endLine)
        {
            if (endLine > startLine)
            {
                found.Add(new FoldRegion(startLine, endLine));
            }
        }

        foreach (var (start, end) in statements)
        {
            Add(LineOf(start), LineOf(Math.Max(start, end - 1)));
        }
        var brackets = new Stack<(char Closer, int Line)>();
        var blocks = new Stack<(bool IsCase, int Line)>();
        for (var i = 0; i < tokens.Length; i++)
        {
            var token = tokens[i];
            if (token.Length <= 0 || token.End > text.Length)
            {
                continue;
            }
            if (token.Kind == roles.Comment)
            {
                Add(LineOf(token.Start), LineOf(token.End - 1));
            }
            else if (token.Length == 1 && (token.Kind == roles.Punctuation || token.Kind == roles.Operator))
            {
                var c = text[token.Start];
                var opener = "([{".IndexOf(c, StringComparison.Ordinal);
                if (opener >= 0)
                {
                    brackets.Push((")]}"[opener], LineOf(token.Start)));
                }
                else if (brackets.TryPeek(out var open) && open.Closer == c)
                {
                    brackets.Pop();
                    // The closer's line stays on screen, as VS Code folds a bracket.
                    Add(open.Line, LineOf(token.Start) - 1);
                }
            }
            else if (token.Kind == roles.Keyword)
            {
                var word = text.AsSpan(token.Start, token.Length);
                if (Is(word, "BEGIN"))
                {
                    var after = NextWord(text, tokens, i, roles);
                    if (!after.IsEmpty && after is not ";" && !IsAny(after, s_notBlocks))
                    {
                        blocks.Push((false, LineOf(token.Start)));
                    }
                }
                else if (Is(word, "CASE"))
                {
                    blocks.Push((true, LineOf(token.Start)));
                }
                else if (Is(word, "END"))
                {
                    var after = NextWord(text, tokens, i, roles);
                    if (IsAny(after, s_otherEnds))
                    {
                        continue;
                    }
                    if (Is(after, "CASE"))
                    {
                        // END CASE closes the CASE; the CASE after it opens nothing.
                        i = NextIndex(tokens, i, roles);
                    }
                    if (blocks.TryPop(out var block))
                    {
                        Add(block.Line, LineOf(token.Start) - 1);
                    }
                }
            }
        }
        found.Sort((a, b) => a.StartLine != b.StartLine ? a.StartLine.CompareTo(b.StartLine) : b.EndLine.CompareTo(a.EndLine));
        var regions = new List<FoldRegion>(found.Count);
        foreach (var region in found)
        {
            if (regions.Count == 0 || regions[^1].StartLine != region.StartLine)
            {
                regions.Add(region);
            }
        }
        return regions;
    }

    private static int[] LineStarts(string text)
    {
        var starts = new List<int> { 0 };
        var at = text.IndexOf('\n', StringComparison.Ordinal);
        while (at >= 0)
        {
            starts.Add(at + 1);
            at = at + 1 < text.Length ? text.IndexOf('\n', at + 1) : -1;
        }
        return [.. starts];
    }

    private static int NextIndex(ReadOnlySpan<SyntaxSpan> tokens, int i, SyntaxRoles roles)
    {
        for (var next = i + 1; next < tokens.Length; next++)
        {
            if (tokens[next].Kind != roles.Comment)
            {
                return next;
            }
        }
        return tokens.Length;
    }

    private static ReadOnlySpan<char> NextWord(string text, ReadOnlySpan<SyntaxSpan> tokens, int i, SyntaxRoles roles)
    {
        var next = NextIndex(tokens, i, roles);
        if (next >= tokens.Length || tokens[next].End > text.Length)
        {
            return default;
        }
        return text.AsSpan(tokens[next].Start, tokens[next].Length);
    }

    private static bool Is(ReadOnlySpan<char> word, string keyword) => word.Equals(keyword, StringComparison.OrdinalIgnoreCase);

    private static bool IsAny(ReadOnlySpan<char> word, string[] keywords)
    {
        foreach (var keyword in keywords)
        {
            if (Is(word, keyword))
            {
                return true;
            }
        }
        return false;
    }
}
