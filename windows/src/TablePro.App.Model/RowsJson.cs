using System.Buffers;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model;

// A value's own kind where its column holds several, as a MongoDB field or a SQLite expression can.
public interface ICellKinds
{
    // In the set's own columns; null past its rows, where the column's kind counts.
    ValueKind? Kind(int row, int column);
}

// The grid's rows as a JSON array: its shown columns in its order, no row marked for deletion, pending edits as typed.
public sealed record RowsJson(string Text, int Rows, int Total, int Deleted, bool Capped)
{
    public const int MaximumRows = 1_000;

    // A TextBox lays out all it holds, so rows stop once the text passes this; the first row is always written.
    public const int MaximumBytes = 1_000_000;

    // A longer JSON value is written as its text, as macOS does.
    public const int MaximumNestedCharacters = 100_000;

    // A cut value is read again only up to MaximumNestedCharacters, so one large cell cannot fill the memory.
    private const int WindowCharacters = 4096;

    private const int CellsPerRead = 16_384;

    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Indented = true,
        NewLine = "\n",
        // Text in any script stays as typed; nothing here is put in a web page.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private static readonly JsonDocumentOptions NestedOptions = new()
    {
        MaxDepth = 256,
        AllowDuplicateProperties = true,
    };

    // Edits are read as the caller took them on the UI thread, or as they stand when none are given.
    public static RowsJson Write(
        IGridData data,
        GridEdits? edits,
        IReadOnlyList<ResultColumn> columns,
        ICellKinds? kinds,
        int firstRow = 0,
        int rowCount = int.MaxValue,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(data);
        ArgumentNullException.ThrowIfNull(columns);
        var edited = data as EditedGridData;
        var pending = edits ?? edited?.Edits ?? GridEdits.None;
        using var reader = edited?.OpenReader(pending) ?? data.OpenReader();
        var dataRows = edited?.Data.RowCount ?? data.RowCount;
        var total = edited is null ? data.RowCount : dataRows + pending.AddedRows;
        var width = data.ColumnCount;
        var names = new string[width];
        var sources = new int[width];
        var columnKinds = new ValueKind[width];
        for (var column = 0; column < width; column++)
        {
            names[column] = data.GetColumnName(column);
            var source = edited?.DataColumn(column) ?? column;
            sources[column] = source;
            columnKinds[column] = source < columns.Count ? columns[source].ValueKind : ValueKind.Other;
        }

        var start = Math.Max(0, firstRow);
        var end = (int)Math.Min((long)start + Math.Max(0, rowCount), total);
        var buffer = new ArrayBufferWriter<byte>();
        var written = 0;
        var deleted = 0;
        var capped = false;
        using (var writer = new Utf8JsonWriter(buffer, WriterOptions))
        {
            writer.WriteStartArray();
            var block = new CellBlock();
            var single = new CellBlock();
            var rowsPerRead = Math.Max(1, CellsPerRead / Math.Max(1, width));
            var first = start;
            while (width > 0 && first < end && !capped)
            {
                cancellationToken.ThrowIfCancellationRequested();
                // One row past the cap is read, so a cut is known; more only where rows are marked for deletion.
                var asked = Math.Min(Math.Min(rowsPerRead, end - first), MaximumRows + 1 - written);
                reader.Read(first, asked, 0, width, WindowCharacters, block);
                for (var row = first; row < first + block.RowCount; row++)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if ((block.Get(row, 0).State & CellState.Deleted) != 0)
                    {
                        deleted++;
                        continue;
                    }

                    var full = written > 0 && writer.BytesCommitted + writer.BytesPending >= MaximumBytes;
                    if (written == MaximumRows || full)
                    {
                        capped = true;
                        break;
                    }

                    writer.WriteStartObject();
                    for (var column = 0; column < width; column++)
                    {
                        writer.WritePropertyName(names[column]);
                        // A pending edit is text the column will read, so it takes the column's kind, not the old value's.
                        var typed = (block.Get(row, column).State & (CellState.Modified | CellState.Inserted)) != 0;
                        var kind = row < dataRows && !typed
                            ? kinds?.Kind(row, sources[column]) ?? columnKinds[column]
                            : columnKinds[column];
                        cancellationToken.ThrowIfCancellationRequested();
                        var left = MaximumBytes - (writer.BytesCommitted + writer.BytesPending);
                        WriteCell(writer, reader, block, single, row, column, kind, left);
                    }

                    writer.WriteEndObject();
                    written++;
                }

                if (block.RowCount < asked)
                {
                    break;
                }

                first += asked;
            }

            writer.WriteEndArray();
        }

        return new RowsJson(Encoding.UTF8.GetString(buffer.WrittenSpan), written, total, deleted, capped);
    }

    // The text's start, without splitting a character, for a view that cannot hold it all.
    public (string Text, bool Cut) TextUpTo(int maxCharacters)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(maxCharacters);
        if (Text.Length <= maxCharacters)
        {
            return (Text, false);
        }

        var end = maxCharacters > 0 && char.IsHighSurrogate(Text[maxCharacters - 1])
            ? maxCharacters - 1
            : maxCharacters;
        return (Text[..end], true);
    }

    // JSON's own number grammar, so a number written bare reads back as the same number.
    public static bool IsJsonNumber(ReadOnlySpan<char> text)
    {
        var at = 0;
        if (at < text.Length && text[at] == '-')
        {
            at++;
        }

        if (at >= text.Length || !char.IsAsciiDigit(text[at]))
        {
            return false;
        }

        if (text[at++] != '0')
        {
            at = Digits(text, at);
        }

        if (at < text.Length && text[at] == '.')
        {
            var digits = ++at;
            at = Digits(text, at);
            if (at == digits)
            {
                return false;
            }
        }

        if (at < text.Length && text[at] is 'e' or 'E')
        {
            at++;
            if (at < text.Length && text[at] is '+' or '-')
            {
                at++;
            }

            var digits = at;
            at = Digits(text, at);
            if (at == digits)
            {
                return false;
            }
        }

        return at == text.Length;
    }

    private static int Digits(ReadOnlySpan<char> text, int at)
    {
        while (at < text.Length && char.IsAsciiDigit(text[at]))
        {
            at++;
        }

        return at;
    }

    // Left is what the size cap still allows; past it a cell goes out as the text the grid shows, never nested.
    private static void WriteCell(
        Utf8JsonWriter writer,
        IGridReader reader,
        CellBlock block,
        CellBlock single,
        int row,
        int column,
        ValueKind kind,
        long left)
    {
        var cell = block.Get(row, column);
        // DEFAULT has no value until the server gives it one.
        if ((cell.State & (CellState.Null | CellState.Default | CellState.Missing)) != 0)
        {
            writer.WriteNullValue();
            return;
        }

        if (left <= 0)
        {
            WriteText(writer, cell.Text, kind == ValueKind.Json ? ValueKind.Text : kind, left);
            return;
        }

        // Binary keeps the grid's 0x text, cut where the grid cuts it, rather than its whole hex.
        if (kind == ValueKind.Bytes || (cell.State & (CellState.Truncated | CellState.Lossy)) == 0)
        {
            WriteText(writer, cell.Text, kind, left);
            return;
        }

        if ((cell.State & CellState.Truncated) != 0)
        {
            reader.Read(row, 1, column, 1, MaximumNestedCharacters, single);
            var longer = single.Get(row, column);
            // Still cut, it goes out as the text it shows, its ellipsis included, never as a document.
            if (longer.IsTruncated || (longer.State & CellState.Lossy) == 0)
            {
                WriteText(writer, longer.Text, longer.IsTruncated ? ValueKind.Text : kind, left);
                return;
            }
        }

        // Control characters show as spaces in a window, so a short value with one is read as it is stored.
        if (reader.ReadWhole(row, column) is { } whole)
        {
            WriteText(writer, whole, kind, left);
        }
        else
        {
            writer.WriteNullValue();
        }
    }

    private static void WriteText(Utf8JsonWriter writer, ReadOnlySpan<char> text, ValueKind kind, long left)
    {
        switch (kind)
        {
            case ValueKind.Bool when text.Equals("true", StringComparison.OrdinalIgnoreCase):
                writer.WriteBooleanValue(true);
                return;
            case ValueKind.Bool when text.Equals("false", StringComparison.OrdinalIgnoreCase):
                writer.WriteBooleanValue(false);
                return;
            case ValueKind.Integer or ValueKind.UnsignedInteger or ValueKind.WideInteger or ValueKind.Float
                or ValueKind.Decimal when IsJsonNumber(text):
                // Written as its digits, so a value past a double's precision keeps every one.
                writer.WriteRawValue(text, skipInputValidation: true);
                return;
            case ValueKind.Json when text.Length <= MaximumNestedCharacters:
                if (TryWriteJson(writer, text, left))
                {
                    return;
                }

                break;
            default:
                break;
        }

        writer.WriteStringValue(text);
    }

    // A document whose indented form would pass what is left goes out as its text: nesting can grow it many times over.
    private static bool TryWriteJson(Utf8JsonWriter writer, ReadOnlySpan<char> text, long left)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(text.ToString(), NestedOptions);
        }
        catch (JsonException)
        {
            return false;
        }

        using (document)
        {
            if (IndentedSize(document.RootElement, writer.CurrentDepth, left) > left)
            {
                return false;
            }

            // Keeps each member in its order, a repeated key and each number's digits.
            document.RootElement.WriteTo(writer);
        }

        return true;
    }

    // The bytes the element takes written indented at this depth, counted only until it passes the limit.
    private static long IndentedSize(JsonElement element, int depth, long limit)
    {
        const int Indent = 2;
        long size;
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                size = 2 + ((long)depth * Indent);
                foreach (var member in element.EnumerateObject())
                {
                    size += ((depth + 1L) * Indent) + Encoding.UTF8.GetByteCount(member.Name) + 5
                        + IndentedSize(member.Value, depth + 1, limit - size);
                    if (size > limit)
                    {
                        return size;
                    }
                }

                return size;
            case JsonValueKind.Array:
                size = 2 + ((long)depth * Indent);
                foreach (var item in element.EnumerateArray())
                {
                    size += ((depth + 1L) * Indent) + 2 + IndentedSize(item, depth + 1, limit - size);
                    if (size > limit)
                    {
                        return size;
                    }
                }

                return size;
            default:
                return JsonMarshal.GetRawUtf8Value(element).Length;
        }
    }
}
