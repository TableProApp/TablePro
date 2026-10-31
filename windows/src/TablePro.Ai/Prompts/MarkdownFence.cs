namespace TablePro.Ai.Prompts;

/// <summary>A fenced code block of a reply. <see cref="IsClosed"/> is false while a streamed reply is still inside it.</summary>
public sealed record CodeBlock(string Language, string Code, bool IsClosed);

public static class MarkdownFence
{
    private static readonly string[] SqlLanguages = ["sql", "mysql", "postgresql", "postgres", "psql", "pgsql", "tsql", "t-sql", "mssql", "sqlite", "duckdb", "mariadb", "plsql", "plpgsql"];

    /// <summary>Wraps text in a fence no run of backticks inside it can close.</summary>
    public static string Wrap(string text, string language = "")
    {
        ArgumentNullException.ThrowIfNull(text);
        var fence = new string('`', Math.Max(3, LongestBacktickRun(text) + 1));
        return $"{fence}{language}\n{text}\n{fence}";
    }

    public static int LongestBacktickRun(ReadOnlySpan<char> text)
    {
        var longest = 0;
        var current = 0;
        foreach (var c in text)
        {
            if (c == '`')
            {
                current++;
                longest = Math.Max(longest, current);
            }
            else
            {
                current = 0;
            }
        }

        return longest;
    }

    /// <summary>
    /// The fenced blocks of a Markdown reply, in order, following CommonMark: up to three spaces of indent, a run of
    /// three or more backticks or tildes, and a closing run of the same character at least as long.
    /// </summary>
    public static IReadOnlyList<CodeBlock> ExtractCodeBlocks(string markdown)
    {
        ArgumentNullException.ThrowIfNull(markdown);
        var blocks = new List<CodeBlock>();
        var text = markdown.AsSpan();
        char fenceChar = default;
        var fenceLength = 0;
        var language = string.Empty;
        var bodyStart = -1;
        var position = 0;

        while (position <= text.Length)
        {
            var rest = text[position..];
            var newline = rest.IndexOf('\n');
            var lineLength = newline < 0 ? rest.Length : newline;
            var line = rest[..lineLength].TrimEnd('\r');
            var lineStart = position;
            position += newline < 0 ? lineLength + 1 : newline + 1;

            if (bodyStart < 0)
            {
                if (TryReadFence(line, out fenceChar, out fenceLength, out var info))
                {
                    language = info;
                    bodyStart = Math.Min(position, text.Length);
                }
            }
            else if (IsClosingFence(line, fenceChar, fenceLength))
            {
                blocks.Add(new CodeBlock(language, Body(text, bodyStart, lineStart), IsClosed: true));
                bodyStart = -1;
            }

            if (newline < 0)
            {
                break;
            }
        }

        if (bodyStart >= 0)
        {
            blocks.Add(new CodeBlock(language, Body(text, bodyStart, text.Length), IsClosed: false));
        }

        return blocks;
    }

    /// <summary>
    /// The SQL a reply proposes: its first closed block marked as SQL, else its first closed block with no language,
    /// else null. Unclosed blocks are skipped so Insert never takes half a statement from a reply still streaming.
    /// </summary>
    public static string? ExtractSql(string markdown)
    {
        CodeBlock? unmarked = null;
        foreach (var block in ExtractCodeBlocks(markdown))
        {
            if (!block.IsClosed)
            {
                continue;
            }

            if (IsSqlLanguage(block.Language))
            {
                return block.Code;
            }

            if (block.Language.Length == 0)
            {
                unmarked ??= block;
            }
        }

        return unmarked?.Code;
    }

    public static bool IsSqlLanguage(string language) =>
        SqlLanguages.Contains(language, StringComparer.OrdinalIgnoreCase);

    private static string Body(ReadOnlySpan<char> text, int start, int end)
    {
        if (end <= start)
        {
            return string.Empty;
        }

        return text[start..end].TrimEnd(['\r', '\n']).ToString();
    }

    private static bool TryReadFence(ReadOnlySpan<char> line, out char fenceChar, out int length, out string info)
    {
        fenceChar = default;
        length = 0;
        info = string.Empty;
        var indent = CountIndent(line);
        if (indent > 3)
        {
            return false;
        }

        line = line[indent..];
        if (line.IsEmpty || line[0] is not ('`' or '~'))
        {
            return false;
        }

        var c = line[0];
        var run = 0;
        while (run < line.Length && line[run] == c)
        {
            run++;
        }

        if (run < 3)
        {
            return false;
        }

        var rest = line[run..].Trim();

        // A backtick in a backtick fence's info string makes the line inline code, not a fence.
        if (c == '`' && rest.Contains('`'))
        {
            return false;
        }

        var space = rest.IndexOfAny(' ', '\t');
        fenceChar = c;
        length = run;
        info = (space < 0 ? rest : rest[..space]).ToString();
        return true;
    }

    private static bool IsClosingFence(ReadOnlySpan<char> line, char fenceChar, int length)
    {
        var indent = CountIndent(line);
        if (indent > 3)
        {
            return false;
        }

        line = line[indent..].TrimEnd();
        if (line.Length < length)
        {
            return false;
        }

        foreach (var c in line)
        {
            if (c != fenceChar)
            {
                return false;
            }
        }

        return true;
    }

    private static int CountIndent(ReadOnlySpan<char> line)
    {
        var count = 0;
        while (count < line.Length && line[count] == ' ')
        {
            count++;
        }

        return count;
    }
}
