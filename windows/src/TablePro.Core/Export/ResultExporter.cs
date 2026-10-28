using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.Json;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Export;

/// <summary>The formats the macOS app's built-in export plugins write.</summary>
public enum ExportFormat
{
    Csv,
    Tsv,
    Json,
    SqlInsert,
    Markdown,
    Xlsx,
}

public sealed record ExportOptions(
    ExportFormat Format,
    bool IncludeHeader = true,
    string NullText = "",
    ObjectName? TargetTable = null,
    SqlDialect? Dialect = null,
    int InsertBatchSize = 100);

/// <summary>Writes a result to a stream without building the whole document in memory.</summary>
public static class ResultExporter
{
    public static string FileExtension(ExportFormat format) => format switch
    {
        ExportFormat.Csv => ".csv",
        ExportFormat.Tsv => ".tsv",
        ExportFormat.Json => ".json",
        ExportFormat.SqlInsert => ".sql",
        ExportFormat.Markdown => ".md",
        ExportFormat.Xlsx => ".xlsx",
        _ => ".txt",
    };

    public static async Task WriteAsync(ResultSet result, IReadOnlyList<int>? rows, Stream stream, ExportOptions options, CancellationToken cancellationToken)
    {
        if (options.Format == ExportFormat.Xlsx)
        {
            await XlsxWriter.WriteAsync(result, rows, stream, options, cancellationToken);
            return;
        }

        if (options.Format == ExportFormat.Json)
        {
            await WriteJsonAsync(result, rows, stream, cancellationToken);
            return;
        }

        await using var writer = new StreamWriter(stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false), 1 << 16, leaveOpen: true);
        switch (options.Format)
        {
            case ExportFormat.Csv:
                await WriteDelimitedAsync(result, rows, writer, ',', options, cancellationToken);
                break;
            case ExportFormat.Tsv:
                await WriteDelimitedAsync(result, rows, writer, '\t', options, cancellationToken);
                break;
            case ExportFormat.SqlInsert:
                await WriteInsertsAsync(result, rows, writer, options, cancellationToken);
                break;
            case ExportFormat.Markdown:
                await WriteMarkdownAsync(result, rows, writer, options, cancellationToken);
                break;
        }

        await writer.FlushAsync(cancellationToken);
    }

    /// <summary>Text for the clipboard, in the same format a file export writes.</summary>
    public static string ToText(ResultSet result, IReadOnlyList<int>? rows, ExportOptions options)
    {
        using var stream = new MemoryStream();
        WriteAsync(result, rows, stream, options, CancellationToken.None).GetAwaiter().GetResult();
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    private static IEnumerable<object?[]> Select(ResultSet result, IReadOnlyList<int>? rows) =>
        rows is null ? result.Rows : rows.Select(i => result.Rows[i]);

    private static async Task WriteDelimitedAsync(ResultSet result, IReadOnlyList<int>? rows, StreamWriter writer, char separator, ExportOptions options, CancellationToken ct)
    {
        var line = new StringBuilder(256);
        if (options.IncludeHeader)
        {
            AppendDelimited(line, result.Columns.Select(c => (object?)c.Name), separator, options.NullText);
            await writer.WriteLineAsync(line, ct);
        }

        foreach (var row in Select(result, rows))
        {
            line.Clear();
            AppendDelimited(line, row, separator, options.NullText);
            await writer.WriteLineAsync(line, ct);
        }
    }

    private static void AppendDelimited(StringBuilder line, IEnumerable<object?> values, char separator, string nullText)
    {
        var first = true;
        foreach (var value in values)
        {
            if (!first)
            {
                line.Append(separator);
            }

            first = false;
            var text = value is null ? nullText : CellFormatter.Format(value);
            if (text.AsSpan().IndexOfAny(['"', separator, '\n', '\r']) >= 0)
            {
                line.Append('"').Append(text.Replace("\"", "\"\"", StringComparison.Ordinal)).Append('"');
            }
            else
            {
                line.Append(text);
            }
        }
    }

    private static async Task WriteJsonAsync(ResultSet result, IReadOnlyList<int>? rows, Stream stream, CancellationToken ct)
    {
        await using var json = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true });
        json.WriteStartArray();
        var names = result.Columns.Select(c => JsonEncodedText.Encode(c.Name)).ToArray();
        var count = 0;
        foreach (var row in Select(result, rows))
        {
            json.WriteStartObject();
            for (var i = 0; i < names.Length; i++)
            {
                json.WritePropertyName(names[i]);
                WriteJsonValue(json, row[i]);
            }

            json.WriteEndObject();
            if (++count % 1000 == 0)
            {
                await json.FlushAsync(ct);
            }
        }

        json.WriteEndArray();
        await json.FlushAsync(ct);
    }

    private static void WriteJsonValue(Utf8JsonWriter json, object? value)
    {
        switch (value)
        {
            case null:
                json.WriteNullValue();
                break;
            case bool b:
                json.WriteBooleanValue(b);
                break;
            case int i:
                json.WriteNumberValue(i);
                break;
            case long l:
                json.WriteNumberValue(l);
                break;
            case short s:
                json.WriteNumberValue(s);
                break;
            case byte by:
                json.WriteNumberValue(by);
                break;
            case sbyte sb:
                json.WriteNumberValue(sb);
                break;
            case ushort us:
                json.WriteNumberValue(us);
                break;
            case uint ui:
                json.WriteNumberValue(ui);
                break;
            case ulong ul:
                json.WriteNumberValue(ul);
                break;
            case BigInteger big:
                // The writer has no BigInteger overload; its invariant digits are already a valid JSON number.
                json.WriteRawValue(big.ToString(CultureInfo.InvariantCulture), skipInputValidation: true);
                break;
            case decimal m:
                json.WriteNumberValue(m);
                break;
            case double d when double.IsFinite(d):
                json.WriteNumberValue(d);
                break;
            case float f when float.IsFinite(f):
                json.WriteNumberValue(f);
                break;
            case byte[] bytes:
                json.WriteBase64StringValue(bytes);
                break;
            default:
                json.WriteStringValue(CellFormatter.Format(value));
                break;
        }
    }

    private static async Task WriteInsertsAsync(ResultSet result, IReadOnlyList<int>? rows, StreamWriter writer, ExportOptions options, CancellationToken ct)
    {
        var dialect = options.Dialect ?? SqliteDialect.Instance;
        var table = dialect.Qualify(options.TargetTable ?? new ObjectName(null, "exported"));
        var columns = string.Join(", ", result.Columns.Select(c => dialect.QuoteIdentifier(c.Name)));
        var batch = Math.Max(1, options.InsertBatchSize);
        var sb = new StringBuilder();
        var inBatch = 0;
        foreach (var row in Select(result, rows))
        {
            if (inBatch == 0)
            {
                sb.Append("INSERT INTO ").Append(table).Append(" (").Append(columns).Append(") VALUES\n");
            }
            else
            {
                sb.Append(",\n");
            }

            sb.Append("  (").AppendJoin(", ", row.Select(dialect.Literal)).Append(')');
            if (++inBatch == batch)
            {
                sb.Append(";\n");
                await writer.WriteAsync(sb, ct);
                sb.Clear();
                inBatch = 0;
            }
        }

        if (inBatch > 0)
        {
            sb.Append(";\n");
            await writer.WriteAsync(sb, ct);
        }
    }

    private static async Task WriteMarkdownAsync(ResultSet result, IReadOnlyList<int>? rows, StreamWriter writer, ExportOptions options, CancellationToken ct)
    {
        var sb = new StringBuilder("| ");
        sb.AppendJoin(" | ", result.Columns.Select(c => EscapeMarkdown(c.Name))).Append(" |");
        await writer.WriteLineAsync(sb, ct);

        sb.Clear().Append('|');
        foreach (var column in result.Columns)
        {
            sb.Append(column.IsNumeric ? " ---: |" : " --- |");
        }

        await writer.WriteLineAsync(sb, ct);
        foreach (var row in Select(result, rows))
        {
            sb.Clear().Append("| ");
            sb.AppendJoin(" | ", row.Select(v => EscapeMarkdown(v is null ? options.NullText : CellFormatter.FormatForCell(v)))).Append(" |");
            await writer.WriteLineAsync(sb, ct);
        }
    }

    private static string EscapeMarkdown(string text) => text.Replace("|", "\\|", StringComparison.Ordinal);

    internal static string Invariant(IFormattable value) => value.ToString(null, CultureInfo.InvariantCulture);
}
