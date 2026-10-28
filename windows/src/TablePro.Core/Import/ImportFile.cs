using System.IO.Compression;
using System.Runtime.CompilerServices;

namespace TablePro.Core.Import;

public enum ImportFileFormat
{
    /// <summary>Delimited text: CSV, TSV or any single-character delimiter.</summary>
    Csv,

    /// <summary>A JSON array of objects, or one object per line.</summary>
    Json,

    /// <summary>A SQL script, run statement by statement rather than mapped to columns.</summary>
    Sql,
}

/// <summary>How a delimited file is read, the options the macOS CSV import offers.</summary>
/// <param name="Delimiter">The field separator, or null to detect it from the first line.</param>
/// <param name="HasHeaderRow">Whether the first record names the fields; without one they are <c>Column 1</c>, <c>Column 2</c>.</param>
/// <param name="TrimWhitespace">Whether spaces around a value are dropped.</param>
/// <param name="EmptyAsNull">Whether an empty field imports as null rather than an empty string.</param>
/// <param name="NullText">A value that imports as null, such as <c>NULL</c> or <c>\N</c>; empty for none.</param>
public sealed record CsvImportOptions(
    char? Delimiter = null,
    bool HasHeaderRow = true,
    bool TrimWhitespace = false,
    bool EmptyAsNull = true,
    string NullText = "")
{
    public static CsvImportOptions Default { get; } = new();

    /// <summary>The value a raw field imports as.</summary>
    public string? Clean(string raw)
    {
        ArgumentNullException.ThrowIfNull(raw);
        var value = TrimWhitespace ? raw.Trim() : raw;
        if (EmptyAsNull && value.Length == 0)
        {
            return null;
        }

        return NullText.Length > 0 && value == NullText ? null : value;
    }
}

/// <summary>Opens and reads the files the table import accepts, one record at a time.</summary>
public static class ImportFile
{
    /// <summary>The format a file's extension names. A <c>.gz</c> is read through its inner extension.</summary>
    public static ImportFileFormat DetectFormat(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        var name = path.EndsWith(".gz", StringComparison.OrdinalIgnoreCase) ? path[..^3] : path;
        return Path.GetExtension(name).ToUpperInvariant() switch
        {
            ".JSON" or ".NDJSON" or ".JSONL" => ImportFileFormat.Json,
            ".SQL" or ".DUMP" => ImportFileFormat.Sql,
            _ => ImportFileFormat.Csv,
        };
    }

    /// <summary>The extension's delimiter: a tab for <c>.tsv</c> and <c>.tab</c>, otherwise null to detect it.</summary>
    public static char? DelimiterFor(string path) =>
        Path.GetExtension(path.EndsWith(".gz", StringComparison.OrdinalIgnoreCase) ? path[..^3] : path).ToUpperInvariant() is ".TSV" or ".TAB" ? '\t' : null;

    /// <summary>Opens a file for reading, decompressing a gzip file on the fly as the macOS SQL import does.</summary>
    public static Stream Open(string path)
    {
        var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.Asynchronous | FileOptions.SequentialScan);
        return path.EndsWith(".gz", StringComparison.OrdinalIgnoreCase) ? new GZipStream(file, CompressionMode.Decompress) : file;
    }

    /// <summary>The field names of a delimited file, from its header or numbered when it has none.</summary>
    public static async Task<(CsvReader Reader, string[] Names, string[]? FirstRecord)> OpenCsvAsync(TextReader text, CsvImportOptions options)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(options);
        var delimiter = options.Delimiter;
        if (delimiter is null)
        {
            // The first line decides the delimiter; a buffered peek would cost a reopen, so the line is put back in front.
            var firstLine = await text.ReadLineAsync() ?? string.Empty;
            delimiter = CsvReader.DetectDelimiter(firstLine);
            text = new PrefixedReader(firstLine + "\n", text);
        }

        var csv = new CsvReader(text, delimiter.Value);
        var first = csv.ReadRecord();
        if (first is null)
        {
            return (csv, [], null);
        }

        if (options.HasHeaderRow)
        {
            return (csv, ImportFieldNaming.UniqueNames(first), null);
        }

        var placeholders = new string[first.Length];
        for (var i = 0; i < placeholders.Length; i++)
        {
            placeholders[i] = ImportFieldNaming.Placeholder(i);
        }

        return (csv, placeholders, first);
    }

    /// <summary>
    /// Every record of a CSV or JSON file, keyed by field name. A CSV value is cleaned text; a JSON value keeps its
    /// JSON kind (long, decimal, bool, string, <see cref="JsonText"/>).
    /// </summary>
    public static async IAsyncEnumerable<IReadOnlyDictionary<string, object?>> ReadRecordsAsync(
        Stream stream, ImportFileFormat format, CsvImportOptions? csvOptions, [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(stream);
        if (format == ImportFileFormat.Json)
        {
            // The JSON reader rewinds to sniff the first byte, which a gzip stream cannot do.
            var source = stream.CanSeek ? stream : await BufferAsync(stream, cancellationToken);
            await foreach (var row in JsonRowReader.ReadAsync(source, cancellationToken))
            {
                yield return row;
            }

            yield break;
        }

        if (format != ImportFileFormat.Csv)
        {
            throw new NotSupportedException("A SQL file is run as a script, not read as rows.");
        }

        var options = csvOptions ?? CsvImportOptions.Default;
        using var text = new StreamReader(stream, detectEncodingFromByteOrderMarks: true, leaveOpen: true);
        var (csv, names, first) = await OpenCsvAsync(text, options);
        var record = first ?? csv.ReadRecord();
        while (record is not null)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!IsBlank(record))
            {
                var row = new Dictionary<string, object?>(names.Length, StringComparer.OrdinalIgnoreCase);
                for (var i = 0; i < names.Length; i++)
                {
                    row[names[i]] = i < record.Length ? options.Clean(record[i]) : null;
                }

                yield return row;
            }

            record = csv.ReadRecord();
        }
    }

    private static bool IsBlank(string[] record)
    {
        foreach (var field in record)
        {
            if (field.Length > 0)
            {
                return false;
            }
        }

        return true;
    }

    private static async Task<Stream> BufferAsync(Stream stream, CancellationToken cancellationToken)
    {
        var buffer = new MemoryStream();
        await stream.CopyToAsync(buffer, cancellationToken);
        buffer.Position = 0;
        return buffer;
    }

    /// <summary>Reads a string first, then the rest of another reader.</summary>
    private sealed class PrefixedReader(string prefix, TextReader rest) : TextReader
    {
        private int _position;

        public override int Peek() => _position < prefix.Length ? prefix[_position] : rest.Peek();

        public override int Read() => _position < prefix.Length ? prefix[_position++] : rest.Read();
    }
}
