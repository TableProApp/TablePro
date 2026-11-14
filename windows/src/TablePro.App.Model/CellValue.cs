using System.Text;
using System.Text.Json;
using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model;

// One cell as the value viewer shows it: the text, or the bytes of a binary value. Neither is set for NULL.
public sealed record CellValue(string Column, string? Text, byte[]? Bytes, bool IsDefault)
{
    // A TextBox lays out all it holds, so the viewer shows a long value's start; Copy takes the whole.
    public const int MaximumShownCharacters = 1_000_000;

    public const int MaximumHexBytes = 256 * 1024;

    public bool IsNull => Text is null && Bytes is null && !IsDefault;

    // The grid's text with its pending edit, and a binary value's bytes as the server holds them. A deleted row
    // still shows what it holds; a new row and a changed cell have no bytes, only the text typed.
    public static CellValue? Read(IGridData data, ResultSet? rows, int row, int column)
    {
        ArgumentNullException.ThrowIfNull(data);
        if (row < 0 || row >= data.RowCount || column < 0 || column >= data.ColumnCount)
        {
            return null;
        }

        using var reader = data.OpenReader();
        var block = new CellBlock();
        reader.Read(row, 1, column, 1, 1, block);
        var state = block.Get(row, column).State;
        if ((state & CellState.Missing) != 0)
        {
            return null;
        }

        var name = data.GetColumnName(column);
        if ((state & CellState.Default) != 0)
        {
            return new CellValue(name, null, null, IsDefault: true);
        }

        var pending = (state & (CellState.Modified | CellState.Inserted)) != 0;
        if (!pending && rows is not null && row < rows.RowCount && rows.GetCellBytes(row, column) is { } bytes)
        {
            return new CellValue(name, null, bytes, IsDefault: false);
        }

        return new CellValue(name, reader.ReadWhole(row, column), null, IsDefault: false);
    }

    // What Copy puts on the clipboard: the text, or a binary value in the 0x form the grid shows. Built only when
    // asked, since a large value's hex is twice its size.
    public string? CopyText() => Bytes is { } bytes ? "0x" + Convert.ToHexStringLower(bytes) : Text;

    public (string Text, bool Cut) ShownText()
    {
        if (Text is not { Length: > MaximumShownCharacters } text)
        {
            return (Text ?? string.Empty, false);
        }

        var end = char.IsHighSurrogate(text[MaximumShownCharacters - 1]) ? MaximumShownCharacters - 1 : MaximumShownCharacters;
        return (text[..end], true);
    }

    // The 0x form of the first MaximumHexBytes, the way the grid shows a binary value.
    public (string Text, bool Cut) Hex()
    {
        if (Bytes is not { } bytes)
        {
            return (string.Empty, false);
        }

        var shown = bytes.AsSpan(0, Math.Min(bytes.Length, MaximumHexBytes));
        return ("0x" + Convert.ToHexStringLower(shown), shown.Length < bytes.Length);
    }

    public (string Text, bool Cut)? Json() => Text is { } text ? JsonText.Indent(text, MaximumShownCharacters) : null;

    public bool CanCopy => Text is not null || Bytes is not null;
}

// JSON laid out one member per line, token by token from the reader's raw spans, so each string keeps the escapes
// it was stored with and each number its digits; a serializer would escape non-ASCII text and could reformat numbers.
public static class JsonText
{
    public const int MaximumCharacters = 4_000_000;

    private const int IndentWidth = 2;

    // Only an object or an array, read whole as one JSON value; anything else is null. Nesting can make the layout
    // many times the text, so past maxCharacters the rest is only checked, not laid out.
    public static (string Text, bool Cut)? Indent(string text, int maxCharacters = int.MaxValue)
    {
        ArgumentNullException.ThrowIfNull(text);
        var trimmed = text.AsSpan().TrimStart();
        if (text.Length > MaximumCharacters || trimmed.IsEmpty || (trimmed[0] != '{' && trimmed[0] != '['))
        {
            return null;
        }

        var utf8 = Encoding.UTF8.GetBytes(text);
        var reader = new Utf8JsonReader(utf8, new JsonReaderOptions { MaxDepth = 512 });
        var output = new StringBuilder(Math.Min(maxCharacters, text.Length + (text.Length / 2)));
        var open = new Stack<bool>();
        var afterName = false;
        var cut = false;
        try
        {
            while (reader.Read())
            {
                if (cut || output.Length > maxCharacters)
                {
                    cut = true;
                    continue;
                }

                switch (reader.TokenType)
                {
                    case JsonTokenType.StartObject or JsonTokenType.StartArray:
                        BeginItem(output, open, ref afterName);
                        output.Append(reader.TokenType == JsonTokenType.StartObject ? '{' : '[');
                        open.Push(false);
                        break;
                    case JsonTokenType.EndObject or JsonTokenType.EndArray:
                        if (open.Pop())
                        {
                            NewLine(output, open.Count);
                        }

                        output.Append(reader.TokenType == JsonTokenType.EndObject ? '}' : ']');
                        break;
                    case JsonTokenType.PropertyName:
                        BeginItem(output, open, ref afterName);
                        output.Append('"').Append(Encoding.UTF8.GetString(reader.ValueSpan)).Append("\": ");
                        afterName = true;
                        break;
                    case JsonTokenType.String:
                        BeginItem(output, open, ref afterName);
                        output.Append('"').Append(Encoding.UTF8.GetString(reader.ValueSpan)).Append('"');
                        break;
                    default:
                        BeginItem(output, open, ref afterName);
                        output.Append(Encoding.UTF8.GetString(reader.ValueSpan));
                        break;
                }
            }
        }
        catch (JsonException)
        {
            return null;
        }

        return cut ? (output.ToString(0, Math.Min(output.Length, maxCharacters)), true) : (output.ToString(), false);
    }

    private static void BeginItem(StringBuilder output, Stack<bool> open, ref bool afterName)
    {
        if (afterName)
        {
            afterName = false;
            return;
        }

        if (open.Count == 0)
        {
            return;
        }

        if (open.Pop())
        {
            output.Append(',');
        }

        open.Push(true);
        NewLine(output, open.Count);
    }

    private static void NewLine(StringBuilder output, int depth) => output.Append('\n').Append(' ', depth * IndentWidth);
}
