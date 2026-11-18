using System.Text;

namespace TablePro.App.Model;

public enum ReplySpanStyle
{
    Plain,
    Bold,
    Code,
}

public sealed record ReplySpan(string Text, ReplySpanStyle Style);

public abstract record ReplyBlock
{
    private ReplyBlock()
    {
    }

    // Lines in one paragraph keep their breaks, since a list is written a line per item.
    public sealed record Paragraph(IReadOnlyList<ReplySpan> Spans, bool IsHeading = false) : ReplyBlock;

    // Language is the fence's info string, such as sql; empty for none.
    public sealed record Code(string Language, string Text) : ReplyBlock;
}

// The Markdown a model writes, read into what a RichTextBlock shows: paragraphs with bold and inline code, headings,
// and fenced code blocks, which get Copy and Insert. A fence still open, as a reply streams in, runs to the end.
public static class ReplyMarkdown
{
    public static IReadOnlyList<ReplyBlock> Read(string markdown)
    {
        ArgumentNullException.ThrowIfNull(markdown);
        var blocks = new List<ReplyBlock>();
        var prose = new List<string>();
        var lines = markdown.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        for (var index = 0; index < lines.Length; index++)
        {
            var line = lines[index];
            if (Fence(line) is { } open)
            {
                Flush(prose, blocks);
                var code = new List<string>();
                index++;
                while (index < lines.Length && !Closes(lines[index], open))
                {
                    code.Add(lines[index]);
                    index++;
                }

                blocks.Add(new ReplyBlock.Code(open.Language, string.Join('\n', code)));
                continue;
            }

            if (string.IsNullOrWhiteSpace(line))
            {
                Flush(prose, blocks);
                continue;
            }

            if (Heading(line) is { } heading)
            {
                Flush(prose, blocks);
                blocks.Add(new ReplyBlock.Paragraph(Spans(heading), IsHeading: true));
                continue;
            }

            prose.Add(Bullet(line));
        }

        Flush(prose, blocks);
        return blocks;
    }

    // Bold and inline code; a marker with no partner is text.
    public static IReadOnlyList<ReplySpan> Spans(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var spans = new List<ReplySpan>();
        var plain = new StringBuilder();
        var index = 0;
        while (index < text.Length)
        {
            if (text[index] == '`' && text.IndexOf('`', index + 1) is var end and > 0)
            {
                Add(spans, plain, ReplySpanStyle.Plain);
                plain.Append(text, index + 1, end - index - 1);
                Add(spans, plain, ReplySpanStyle.Code);
                index = end + 1;
                continue;
            }

            if (text.AsSpan(index).StartsWith("**", StringComparison.Ordinal)
                && text.IndexOf("**", index + 2, StringComparison.Ordinal) is var close and > 0
                && close > index + 2)
            {
                Add(spans, plain, ReplySpanStyle.Plain);
                plain.Append(text, index + 2, close - index - 2);
                Add(spans, plain, ReplySpanStyle.Bold);
                index = close + 2;
                continue;
            }

            plain.Append(text[index]);
            index++;
        }

        Add(spans, plain, ReplySpanStyle.Plain);
        return spans;
    }

    private static void Add(List<ReplySpan> spans, StringBuilder text, ReplySpanStyle style)
    {
        if (text.Length > 0)
        {
            spans.Add(new ReplySpan(text.ToString(), style));
            text.Clear();
        }
    }

    private static void Flush(List<string> prose, List<ReplyBlock> blocks)
    {
        if (prose.Count > 0)
        {
            blocks.Add(new ReplyBlock.Paragraph(Spans(string.Join('\n', prose))));
            prose.Clear();
        }
    }

    private sealed record Opening(char Mark, int Length, string Language);

    // Up to three spaces before it, as CommonMark allows.
    private static Opening? Fence(string line)
    {
        var trimmed = line.TrimStart(' ');
        if (line.Length - trimmed.Length > 3 || trimmed.Length < 3 || trimmed[0] is not ('`' or '~'))
        {
            return null;
        }

        var mark = trimmed[0];
        var length = 0;
        while (length < trimmed.Length && trimmed[length] == mark)
        {
            length++;
        }

        var info = trimmed[length..].Trim();
        if (length < 3 || (mark == '`' && info.Contains('`', StringComparison.Ordinal)))
        {
            return null;
        }

        return new Opening(mark, length, info.Split(' ', 2)[0]);
    }

    private static bool Closes(string line, Opening open)
    {
        var trimmed = line.Trim();
        return trimmed.Length >= open.Length && trimmed.All(c => c == open.Mark);
    }

    private static string? Heading(string line)
    {
        var trimmed = line.TrimStart();
        var level = 0;
        while (level < trimmed.Length && trimmed[level] == '#')
        {
            level++;
        }

        return level is >= 1 and <= 6 && level < trimmed.Length && trimmed[level] == ' '
            ? trimmed[(level + 1)..].Trim()
            : null;
    }

    private static string Bullet(string line)
    {
        var trimmed = line.TrimStart();
        var indent = line[..(line.Length - trimmed.Length)];
        return trimmed.Length > 1 && trimmed[0] is ('-' or '*' or '+') && trimmed[1] == ' '
            ? indent + "• " + trimmed[2..]
            : line;
    }
}
