namespace TablePro.Editor.Model.Tests;

// Words, '...' strings and /* */ comments, both of which may span lines: enough to drive the highlighter.
internal sealed class FakeLexer : ISyntaxLexer
{
    public const byte Word = 1;
    public const byte Comment = 2;
    public const byte String = 3;
    public const byte Punctuation = 4;

    public int Tokenize(ReadOnlySpan<char> text, Span<SyntaxSpan> spans)
    {
        var count = 0;
        var i = 0;
        while (i < text.Length)
        {
            var c = text[i];
            int end;
            byte kind;
            if (char.IsWhiteSpace(c))
            {
                i++;
                continue;
            }
            if (c == '/' && i + 1 < text.Length && text[i + 1] == '*')
            {
                var close = text[(i + 2)..].IndexOf("*/", StringComparison.Ordinal);
                end = close < 0 ? text.Length : i + 2 + close + 2;
                kind = Comment;
            }
            else if (c == '\'')
            {
                var close = text[(i + 1)..].IndexOf('\'');
                end = close < 0 ? text.Length : i + 1 + close + 1;
                kind = String;
            }
            else if (char.IsLetterOrDigit(c) || c == '_')
            {
                end = i + 1;
                while (end < text.Length && (char.IsLetterOrDigit(text[end]) || text[end] == '_'))
                {
                    end++;
                }
                kind = Word;
            }
            else
            {
                end = i + 1;
                kind = Punctuation;
            }
            spans[count++] = new SyntaxSpan(i, end - i, kind);
            i = end;
        }
        return count;
    }
}
