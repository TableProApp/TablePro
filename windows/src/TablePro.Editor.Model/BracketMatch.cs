namespace TablePro.Editor.Model;

// The bracket beside the caret and the one it pairs with. Read through the lexer's tokens, so a bracket inside a string,
// a comment or a quoted name never counts; a text the lexer gives no tokens for, such as a MongoDB query, is read as
// plain characters.
public static class BracketMatch
{
    private const string Openers = "([{";
    private const string Closers = ")]}";

    // The bracket before the caret first, as the macOS editor reads it, then the one after. Tokens hold absolute
    // offsets in order and cover at least the window searched; roles null reads plain characters.
    public static (int Open, int Close)? Find(TextDocument document, int caret, IReadOnlyList<SyntaxSpan> tokens,
        SyntaxRoles? roles, int window = 32_768)
    {
        ArgumentNullException.ThrowIfNull(document);
        ArgumentNullException.ThrowIfNull(tokens);
        var plain = roles is null || tokens.Count == 0;
        foreach (var at in new[] { caret - 1, caret })
        {
            if (at < 0 || at >= document.Length)
            {
                continue;
            }
            var c = document.CharAt(at);
            var opener = Openers.IndexOf(c, StringComparison.Ordinal);
            var closer = Closers.IndexOf(c, StringComparison.Ordinal);
            if (opener < 0 && closer < 0)
            {
                continue;
            }
            if (plain)
            {
                var match = ScanPlain(document, at, opener >= 0, window);
                if (match is { } found)
                {
                    return opener >= 0 ? (at, found) : (found, at);
                }
                continue;
            }
            var index = TokenAt(tokens, at);
            if (index < 0 || !IsBracket(tokens[index], roles!) || tokens[index].Start != at)
            {
                continue;
            }
            var pair = ScanTokens(document, tokens, index, opener >= 0, roles!);
            if (pair is { } other)
            {
                return opener >= 0 ? (at, other) : (other, at);
            }
        }
        return null;
    }

    private static int? ScanPlain(TextDocument document, int at, bool forward, int window)
    {
        var self = document.CharAt(at);
        var partner = forward ? Closers[Openers.IndexOf(self, StringComparison.Ordinal)] : Openers[Closers.IndexOf(self, StringComparison.Ordinal)];
        var depth = 0;
        var limit = forward ? Math.Min(document.Length, at + window) : Math.Max(-1, at - window);
        for (var i = forward ? at + 1 : at - 1; forward ? i < limit : i > limit; i += forward ? 1 : -1)
        {
            var c = document.CharAt(i);
            if (c == self)
            {
                depth++;
            }
            else if (c == partner)
            {
                if (depth == 0)
                {
                    return i;
                }
                depth--;
            }
        }
        return null;
    }

    private static int? ScanTokens(TextDocument document, IReadOnlyList<SyntaxSpan> tokens, int index, bool forward, SyntaxRoles roles)
    {
        var self = document.CharAt(tokens[index].Start);
        var partner = forward ? Closers[Openers.IndexOf(self, StringComparison.Ordinal)] : Openers[Closers.IndexOf(self, StringComparison.Ordinal)];
        var depth = 0;
        for (var i = forward ? index + 1 : index - 1; i >= 0 && i < tokens.Count; i += forward ? 1 : -1)
        {
            var token = tokens[i];
            if (!IsBracket(token, roles) || token.Start >= document.Length)
            {
                continue;
            }
            var c = document.CharAt(token.Start);
            if (c == self)
            {
                depth++;
            }
            else if (c == partner)
            {
                if (depth == 0)
                {
                    return token.Start;
                }
                depth--;
            }
        }
        return null;
    }

    private static bool IsBracket(SyntaxSpan token, SyntaxRoles roles) =>
        token.Length == 1 && (token.Kind == roles.Punctuation || token.Kind == roles.Operator);

    private static int TokenAt(IReadOnlyList<SyntaxSpan> tokens, int offset)
    {
        var low = 0;
        var high = tokens.Count - 1;
        while (low <= high)
        {
            var middle = (low + high) >>> 1;
            var token = tokens[middle];
            if (offset < token.Start)
            {
                high = middle - 1;
            }
            else if (offset >= token.End)
            {
                low = middle + 1;
            }
            else
            {
                return middle;
            }
        }
        return -1;
    }
}
