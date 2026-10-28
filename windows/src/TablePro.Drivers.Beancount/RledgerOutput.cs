using System.Text.Json;
using TablePro.Core.Results;

namespace TablePro.Drivers.Beancount;

/// <summary>Reads what <c>rledger query -f json</c> prints.</summary>
internal static class RledgerOutput
{
    private const string InvalidOutput = "Invalid rustledger JSON output";

    /// <summary>The column names, which must be present.</summary>
    public static IReadOnlyList<string> Columns(ReadOnlySpan<byte> json) =>
        Parse(json).Columns ?? throw new BeancountException(InvalidOutput);

    /// <summary>Each row keyed by column name. Where two columns share a name, the first one wins.</summary>
    public static List<LedgerRow> Rows(ReadOnlySpan<byte> json)
    {
        var (columns, rows) = Parse(json);
        var keyedRows = new List<LedgerRow>(rows.Count);
        foreach (var row in rows)
        {
            if (row is LedgerRow keyed)
            {
                keyedRows.Add(keyed);
                continue;
            }

            if (columns is null)
            {
                throw new BeancountException(InvalidOutput);
            }

            var values = Positional(row, columns);
            var result = new LedgerRow(columns.Count, StringComparer.Ordinal);
            for (var i = 0; i < columns.Count; i++)
            {
                result.TryAdd(columns[i], values[i]);
            }

            keyedRows.Add(result);
        }

        return keyedRows;
    }

    /// <summary>A BQL result for the editor: every value as the text <c>rledger query</c> prints.</summary>
    public static ResultSet QueryResult(ReadOnlySpan<byte> json, int rowLimit)
    {
        var (columns, rows) = Parse(json);
        if (columns is null)
        {
            throw new BeancountException(InvalidOutput);
        }

        var resultColumns = new ResultColumn[columns.Count];
        for (var i = 0; i < columns.Count; i++)
        {
            resultColumns[i] = new ResultColumn(columns[i], "TEXT", typeof(string));
        }

        var take = Math.Min(rows.Count, Math.Max(rowLimit, 0));
        var resultRows = new List<object?[]>(take);
        for (var r = 0; r < take; r++)
        {
            var values = Positional(rows[r], columns);
            var cells = new object?[columns.Count];
            for (var i = 0; i < cells.Length; i++)
            {
                cells[i] = values[i] is { } value ? CellText(value) : null;
            }

            resultRows.Add(cells);
        }

        return new ResultSet(resultColumns, resultRows, rows.Count > take);
    }

    /// <summary>
    /// The text <c>rledger query</c> prints for each value its JSON carries: a posting's position is
    /// <c>{units, cost}</c>, an inventory <c>{positions}</c>, tags and links an array, an interval <c>{count, unit}</c>.
    /// </summary>
    public static string CellText(object value) => value switch
    {
        string s => s,
        bool b => b ? "TRUE" : "FALSE",
        long or int or decimal or double => LedgerValues.Text(value)!,
        List<object?> list => string.Join(", ", list.Select(item => item is null ? "null" : CellText(item))),
        LedgerRow row => AmountText(row) ?? PositionText(row) ?? InventoryText(row) ?? IntervalText(row) ?? LedgerValues.Json(row),
        _ => value.ToString() ?? string.Empty,
    };

    // rledger 0.22 writes each row as an object keyed by column name. From 0.23 a row is an array positional against
    // `columns`, because BQL can return two columns with the same name.
    private static (List<string>? Columns, List<object?> Rows) Parse(ReadOnlySpan<byte> json)
    {
        object? parsed;
        try
        {
            var reader = new Utf8JsonReader(json);
            using var document = JsonDocument.ParseValue(ref reader);
            parsed = LedgerValues.FromJson(document.RootElement);
        }
        catch (JsonException ex)
        {
            throw new BeancountException(InvalidOutput, ex);
        }

        if (parsed is not LedgerRow root)
        {
            throw new BeancountException(InvalidOutput);
        }

        List<string>? columns = null;
        if (root.Get("columns") is List<object?> names)
        {
            columns = new List<string>(names.Count);
            foreach (var name in names)
            {
                if (name is not string text)
                {
                    columns = null;
                    break;
                }

                columns.Add(text);
            }
        }

        return root.Get("rows") switch
        {
            null => (columns, []),
            List<object?> rows => (columns, rows),
            _ => throw new BeancountException(InvalidOutput),
        };
    }

    private static object?[] Positional(object? row, List<string> columns)
    {
        var values = new object?[columns.Count];
        switch (row)
        {
            case List<object?> list:
                for (var i = 0; i < values.Length && i < list.Count; i++)
                {
                    values[i] = list[i];
                }

                return values;
            case LedgerRow keyed:
                for (var i = 0; i < values.Length; i++)
                {
                    values[i] = keyed.Get(columns[i]);
                }

                return values;
            default:
                throw new BeancountException(InvalidOutput);
        }
    }

    private static string? AmountText(LedgerRow row) =>
        row.Get("number") is string number && row.Get("currency") is string currency ? number + " " + currency : null;

    private static string? PositionText(LedgerRow row)
    {
        if (row.Get("units") is not LedgerRow unitsRow || AmountText(unitsRow) is not { } units)
        {
            return null;
        }

        return row.Get("cost") switch
        {
            null => units,
            LedgerRow cost when AmountText(cost) is { } costText => $"{units} {{{costText}}}",
            _ => null,
        };
    }

    private static string? InventoryText(LedgerRow row)
    {
        if (row.Get("positions") is not List<object?> positions)
        {
            return null;
        }

        var texts = new List<string>(positions.Count);
        foreach (var position in positions)
        {
            if (position is not LedgerRow positionRow || (AmountText(positionRow) ?? PositionText(positionRow)) is not { } text)
            {
                return null;
            }

            texts.Add(text);
        }

        return string.Join(", ", texts);
    }

    private static string? IntervalText(LedgerRow row)
    {
        if (row.Count != 2 || row.Get("count") is not long count || row.Get("unit") is not string unit)
        {
            return null;
        }

        return $"{count} {unit}{(count is 1 or -1 ? string.Empty : "s")}";
    }
}
