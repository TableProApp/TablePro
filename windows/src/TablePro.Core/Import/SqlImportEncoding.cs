using System.Text;
using System.Text.RegularExpressions;
using TablePro.Core.Sql;

namespace TablePro.Core.Import;

/// <summary>
/// The text encodings the SQL import offers, the macOS list. Latin-1 and Windows-1252 are both here because they
/// disagree over 0x80 to 0x9F, which is where a dump written by MySQL keeps its curly quotes, en dashes and euro sign.
/// </summary>
/// <param name="Id">The stable name, as the macOS app stores it.</param>
/// <param name="Label">What the menu shows; an encoding name, so it is not translated.</param>
/// <param name="CodePage">The Windows code page .NET reads it with.</param>
public sealed record SqlImportEncoding(string Id, string Label, int CodePage)
{
    public static SqlImportEncoding Utf8 { get; } = new("UTF-8", "UTF-8", 65001);

    public static IReadOnlyList<SqlImportEncoding> All { get; } =
    [
        Utf8,
        new("UTF-16", "UTF-16", 1200),
        new("UTF-16LE", "UTF-16 LE", 1200),
        new("UTF-16BE", "UTF-16 BE", 1201),
        new("Latin1", "Latin-1", 28591),
        new("Windows-1252", "Windows-1252", 1252),
        new("ASCII", "ASCII", 20127),
        new("Shift_JIS", "Shift JIS", 932),
        new("EUC-JP", "EUC-JP", 51932),
        new("GB18030", "GB 18030", 54936),
        new("Big5", "Big5", 950),
        new("EUC-KR", "EUC-KR", 51949),
    ];

    // The legacy code pages are not in .NET's default set; the provider ships in the framework itself.
    static SqlImportEncoding() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    public static SqlImportEncoding? Find(string? id) => All.FirstOrDefault(e => string.Equals(e.Id, id, StringComparison.OrdinalIgnoreCase));

    /// <summary>The decoder. A byte order mark in the file still wins, as it does for the default UTF-8 read.</summary>
    public Encoding GetEncoding() => Encoding.GetEncoding(CodePage);
}

/// <summary>
/// Reads the encoding a dump declares in its first statements, such as MySQL's <c>SET NAMES latin1</c> or PostgreSQL's
/// <c>SET client_encoding = 'WIN1252'</c>, so the import reads the file the way its server wrote it.
/// </summary>
public static partial class SqlDumpEncoding
{
    /// <summary>How much of the file the declaration is looked for in: a dump states it in its header.</summary>
    public const int ScanLength = 65_536;

    private static readonly Dictionary<string, string> DeclaredNames = new(StringComparer.Ordinal)
    {
        ["UTF8"] = "UTF-8", ["UTF8MB4"] = "UTF-8", ["UTF8MB3"] = "UTF-8", ["UNICODE"] = "UTF-8",
        ["CP1252"] = "Windows-1252", ["WIN1252"] = "Windows-1252", ["WINDOWS1252"] = "Windows-1252",
        ["LATIN1MYSQL"] = "Windows-1252", ["LATIN1"] = "Latin1", ["ISO88591"] = "Latin1",
        ["ASCII"] = "ASCII", ["SQLASCII"] = "ASCII",
        ["CP932"] = "Shift_JIS", ["SJIS"] = "Shift_JIS", ["SHIFTJIS"] = "Shift_JIS", ["SHIFTJIS2004"] = "Shift_JIS",
        ["UJIS"] = "EUC-JP", ["EUCJPMS"] = "EUC-JP", ["EUCJP"] = "EUC-JP",
        ["GBK"] = "GB18030", ["GB2312"] = "GB18030", ["GB18030"] = "GB18030", ["EUCCN"] = "GB18030",
        ["BIG5"] = "Big5", ["CP950"] = "Big5",
        ["EUCKR"] = "EUC-KR", ["UHC"] = "EUC-KR", ["CP949"] = "EUC-KR",
    };

    /// <summary>
    /// The encoding the head of a dump declares, or null. The head is read as Latin-1, which maps every byte to one
    /// character, so the ASCII statement is found whatever the rest of the file holds. MySQL's latin1 is really
    /// Windows-1252, so it maps there.
    /// </summary>
    public static SqlImportEncoding? Declared(string head, SqlDialect dialect)
    {
        ArgumentNullException.ThrowIfNull(head);
        ArgumentNullException.ThrowIfNull(dialect);
        var mySql = dialect is MySqlDialect;
        foreach (var candidate in Candidates(head, dialect))
        {
            var match = DeclarationPattern().Match(candidate);
            if (!match.Success)
            {
                continue;
            }

            var name = new string([.. match.Groups[1].Value.Where(char.IsAsciiLetterOrDigit)]).ToUpperInvariant();
            var key = name == "LATIN1" && mySql ? "LATIN1MYSQL" : name;
            if (DeclaredNames.TryGetValue(key, out var id))
            {
                return SqlImportEncoding.Find(id);
            }
        }

        return null;
    }

    /// <summary>
    /// The head's statements in order, with mysqldump's <c>/*!40101 SET NAMES ... */</c> among them: the splitter reads
    /// such a comment as trivia, while MySQL runs it, so it is taken from the lexer where it stands.
    /// </summary>
    private static List<string> Candidates(string head, SqlDialect dialect)
    {
        var found = new List<(int Start, string Text)>();
        foreach (var statement in dialect.Split(head))
        {
            found.Add((statement.Start, statement.Text));
        }

        var span = head.AsSpan();
        var lexer = new SqlLexer(span, dialect.LexerFeatures);
        while (lexer.TryRead(out var token))
        {
            if (token.Kind == SqlTokenKind.BlockComment && (span[token.Start..].StartsWith("/*!") || span[token.Start..].StartsWith("/*M!")))
            {
                found.Add((token.Start, token.Slice(span).ToString()));
            }
        }

        return [.. found.OrderBy(f => f.Start).Select(f => f.Text)];
    }

    /// <summary>Reads the head of a file, gzip included, as Latin-1 and looks for a declaration in it.</summary>
    public static async Task<SqlImportEncoding?> DeclaredInFileAsync(string path, SqlDialect dialect, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(path);
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.Asynchronous | FileOptions.SequentialScan);
        Stream source = path.EndsWith(".gz", StringComparison.OrdinalIgnoreCase) ? new System.IO.Compression.GZipStream(file, System.IO.Compression.CompressionMode.Decompress) : file;
        await using (source)
        {
            var buffer = new byte[ScanLength];
            var read = await source.ReadAtLeastAsync(buffer, ScanLength, throwOnEndOfStream: false, cancellationToken);
            return Declared(Encoding.Latin1.GetString(buffer, 0, read), dialect);
        }
    }

    [GeneratedRegex(
        """\A(?:\s+|--[^\n]*(?:\n|\z)|\#[^\n]*(?:\n|\z)|/\*(?!M?!)[\s\S]*?\*/)*(?:/\*M?!\d*\s*)?SET\s+(?:(?:SESSION|LOCAL)\s+)?(?:NAMES|CHARACTER\s+SET|CHARSET|character_set_client\s*=|client_encoding\s*(?:=|TO))\s*['"]?([A-Za-z0-9_-]+)""",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DeclarationPattern();
}
