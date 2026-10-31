using System.Globalization;
using TablePro.Core.Localization;

namespace TablePro.Core.Sql.Analysis;

/// <summary>
/// The non-ASCII characters no engine reads as SQL although they look like it: full-width punctuation and letters,
/// curly quotes and non-ASCII spaces, which arrive by pasting from a word processor or typing with a CJK input method.
/// Every other non-ASCII character continues a word, which is how unquoted non-Latin identifiers stay whole.
/// </summary>
/// <remarks>The rules and messages follow the macOS app's SQLConfusableCharacterScanner word for word.</remarks>
internal static class ConfusableCharacters
{
    private const char FullWidthFirst = '\xFF01';
    private const char FullWidthLast = '\xFF5E';
    private const int FullWidthOffset = 0xFEE0;

    public static bool IsFullWidthWordUnit(char c) =>
        c is (>= '\xFF10' and <= '\xFF19') or (>= '\xFF21' and <= '\xFF3A') or '\xFF3F' or (>= '\xFF41' and <= '\xFF5A');

    public static bool IsSeparating(char c) => Kind(c) is not null;

    /// <summary>Scans one stretch of code, never a literal or comment, and adds a warning per confusable run or word.</summary>
    public static void Scan(ReadOnlySpan<char> text, int start, int end, List<SqlDiagnostic> output)
    {
        var i = start;
        while (i < end)
        {
            var c = text[i];
            if (IsWordUnit(c))
            {
                i = ScanWord(text, i, end, output);
                continue;
            }

            if (Kind(c) is { } kind)
            {
                var runStart = i;
                while (i < end && text[i] == c)
                {
                    i++;
                }

                output.Add(Warning(runStart, i - runStart, kind == SeparatorKind.FullWidthPunctuation ? PunctuationMessage(c)
                    : kind == SeparatorKind.CurlyQuote ? CurlyQuoteMessage(c)
                    : SpaceMessage(c)));
                continue;
            }

            i++;
        }
    }

    private static int ScanWord(ReadOnlySpan<char> text, int i, int end, List<SqlDiagnostic> output)
    {
        var firstFullWidth = -1;
        var lastFullWidth = i;
        var isNativeScript = false;
        while (i < end && IsWordUnit(text[i]))
        {
            var c = text[i];
            if (IsFullWidthWordUnit(c))
            {
                firstFullWidth = firstFullWidth < 0 ? i : firstFullWidth;
                lastFullWidth = i;
            }
            else if (IsNativeScript(c))
            {
                isNativeScript = true;
            }

            i++;
        }

        // A full-width digit inside a Japanese or Chinese name is how that name is spelled, not a typing slip.
        if (firstFullWidth >= 0 && !isNativeScript)
        {
            var length = lastFullWidth - firstFullWidth + 1;
            var buffer = length <= 128 ? stackalloc char[length] : new char[length];
            var source = text.Slice(firstFullWidth, length);
            for (var k = 0; k < length; k++)
            {
                var unit = source[k];
                buffer[k] = unit is >= FullWidthFirst and <= FullWidthLast ? (char)(unit - FullWidthOffset) : unit;
            }

            output.Add(Warning(firstFullWidth, length, CoreStrings.Format("Analysis/FullWidthWord", ((ReadOnlySpan<char>)buffer).ToString())));
        }

        return i;
    }

    private static bool IsWordUnit(char c) =>
        c < 0x80 ? char.IsAsciiLetterOrDigit(c) || c is '_' or '$' : !IsSeparating(c);

    private static bool IsNativeScript(char c) => c >= 0x80 && (char.IsSurrogate(c) || char.IsLetter(c) || char.IsNumber(c));

    private enum SeparatorKind
    {
        FullWidthPunctuation,
        CurlyQuote,
        NonAsciiSpace,
    }

    private static SeparatorKind? Kind(char c) => c switch
    {
        >= FullWidthFirst and <= FullWidthLast when !IsFullWidthWordUnit(c) => SeparatorKind.FullWidthPunctuation,
        '\x2018' or '\x2019' or '\x201C' or '\x201D' => SeparatorKind.CurlyQuote,
        '\x00A0' or (>= '\x2000' and <= '\x200A') or '\x202F' or '\x205F' or '\x3000' => SeparatorKind.NonAsciiSpace,
        _ => null,
    };

    private static SqlDiagnostic Warning(int start, int length, string message) =>
        new(start, length, SqlDiagnosticSeverity.Warning, SqlDiagnosticCode.ConfusableCharacter, message);

    internal static string PunctuationMessage(char c)
    {
        var ascii = (char)(c - FullWidthOffset);
        return ascii == ';'
            ? CoreStrings.Get("Analysis/FullWidthSemicolon")
            : CoreStrings.Format("Analysis/FullWidthPunctuation", PunctuationName(ascii), CodePoint(c), CodePoint(ascii));
    }

    internal static string CurlyQuoteMessage(char c) =>
        CoreStrings.Format("Analysis/CurlyQuote", CodePoint(c), CodePoint(c is '\x201C' or '\x201D' ? '"' : '\''));

    internal static string SpaceMessage(char c) => CoreStrings.Format("Analysis/NonAsciiSpace", CodePoint(c));

    private static string CodePoint(char c) => string.Create(CultureInfo.InvariantCulture, $"U+{(int)c:X4}");

    private static string PunctuationName(char ascii) => ascii switch
    {
        '!' => CoreStrings.Get("Analysis/CharExclamationMark"),
        '"' => CoreStrings.Get("Analysis/CharQuotationMark"),
        '#' => CoreStrings.Get("Analysis/CharNumberSign"),
        '$' => CoreStrings.Get("Analysis/CharDollarSign"),
        '%' => CoreStrings.Get("Analysis/CharPercentSign"),
        '&' => CoreStrings.Get("Analysis/CharAmpersand"),
        '\'' => CoreStrings.Get("Analysis/CharApostrophe"),
        '(' => CoreStrings.Get("Analysis/CharLeftParenthesis"),
        ')' => CoreStrings.Get("Analysis/CharRightParenthesis"),
        '*' => CoreStrings.Get("Analysis/CharAsterisk"),
        '+' => CoreStrings.Get("Analysis/CharPlusSign"),
        ',' => CoreStrings.Get("Analysis/CharComma"),
        '-' => CoreStrings.Get("Analysis/CharHyphen"),
        '.' => CoreStrings.Get("Analysis/CharPeriod"),
        '/' => CoreStrings.Get("Analysis/CharSlash"),
        ':' => CoreStrings.Get("Analysis/CharColon"),
        '<' => CoreStrings.Get("Analysis/CharLessThanSign"),
        '=' => CoreStrings.Get("Analysis/CharEqualsSign"),
        '>' => CoreStrings.Get("Analysis/CharGreaterThanSign"),
        '?' => CoreStrings.Get("Analysis/CharQuestionMark"),
        '@' => CoreStrings.Get("Analysis/CharAtSign"),
        '[' => CoreStrings.Get("Analysis/CharLeftSquareBracket"),
        '\\' => CoreStrings.Get("Analysis/CharBackslash"),
        ']' => CoreStrings.Get("Analysis/CharRightSquareBracket"),
        '^' => CoreStrings.Get("Analysis/CharCaret"),
        '`' => CoreStrings.Get("Analysis/CharBacktick"),
        '{' => CoreStrings.Get("Analysis/CharLeftCurlyBracket"),
        '|' => CoreStrings.Get("Analysis/CharVerticalBar"),
        '}' => CoreStrings.Get("Analysis/CharRightCurlyBracket"),
        '~' => CoreStrings.Get("Analysis/CharTilde"),
        _ => ascii.ToString(),
    };
}
