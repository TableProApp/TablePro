using System.Text;

namespace TablePro.Core.Generation;

/// <summary>A pattern such as <c>???-####</c>: <c>#</c> is a digit, <c>?</c> a letter, <c>*</c> either, and <c>\</c> makes the next character literal.</summary>
public static class RowGenerationPattern
{
    private const string Digits = "0123456789";
    private const string Letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    private const string Alphanumerics = Letters + Digits;

    private readonly record struct Token(char Literal, string? Choices);

    // A column shorter than the pattern keeps only the first characters, so only their slots tell values apart.
    private static List<Token> Tokens(string pattern, int? length = null)
    {
        var tokens = new List<Token>(pattern.Length);
        var escaped = false;
        foreach (var c in pattern)
        {
            if (escaped)
            {
                tokens.Add(new Token(c, null));
                escaped = false;
                continue;
            }

            switch (c)
            {
                case '\\':
                    escaped = true;
                    break;
                case '#':
                    tokens.Add(new Token('\0', Digits));
                    break;
                case '?':
                    tokens.Add(new Token('\0', Letters));
                    break;
                case '*':
                    tokens.Add(new Token('\0', Alphanumerics));
                    break;
                default:
                    tokens.Add(new Token(c, null));
                    break;
            }
        }

        if (length is { } limit && tokens.Count > limit)
        {
            tokens.RemoveRange(Math.Max(0, limit), tokens.Count - Math.Max(0, limit));
        }

        return tokens;
    }

    internal static string Expand(string pattern, ref SeededRandom random)
    {
        var tokens = Tokens(pattern);
        var result = new StringBuilder(tokens.Count);
        foreach (var token in tokens)
        {
            result.Append(token.Choices is { } choices ? choices[random.Index(choices.Length)] : token.Literal);
        }

        return result.ToString();
    }

    /// <summary>The value at one position of every value the pattern can make, counting the last slot fastest.</summary>
    public static string ValueAt(long position, string pattern, int? length = null)
    {
        var tokens = Tokens(pattern, length);
        var remaining = Math.Max(0, position);
        var characters = new char[tokens.Count];
        for (var i = tokens.Count - 1; i >= 0; i--)
        {
            if (tokens[i].Choices is { } choices)
            {
                characters[i] = choices[(int)(remaining % choices.Length)];
                remaining /= choices.Length;
            }
            else
            {
                characters[i] = tokens[i].Literal;
            }
        }

        return new string(characters);
    }

    /// <summary>How many different values the pattern makes, or null when that overflows a long.</summary>
    public static long? Combinations(string pattern, int? length = null)
    {
        long total = 1;
        foreach (var token in Tokens(pattern, length))
        {
            if (token.Choices is { } choices)
            {
                if (total > long.MaxValue / choices.Length)
                {
                    return null;
                }

                total *= choices.Length;
            }
        }

        return total;
    }
}
