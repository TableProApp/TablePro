using System.Globalization;
using System.Text;
using System.Text.Json.Serialization;
using TablePro.Interop;

namespace TablePro.App.Model;

// A stored cell as a key names it: the kind the core read it as, and its whole text, null for NULL.
public readonly record struct StoredValue(ValueKind Kind, string? Text);

// One column's stored values for rowCount rows from firstRow; throws TableProException when they cannot be read.
public delegate IReadOnlyList<StoredValue> StoredValueReader(int column, int firstRow, int rowCount);

// Pending changes as the session file keeps them; a key names each row, since the next page can hold it elsewhere.
public sealed record SavedEdits
{
    private const int SharedKey = -1;

    // Each changed row once, in the order of its latest change, as a save orders them.
    public IReadOnlyList<SavedRowEdit> Rows { get; set; } = [];

    // A changed cell, a deleted row and a new row count one each.
    [JsonIgnore]
    public int Changes => (Rows ?? []).Sum(row => row?.Changes ?? 0);

    // Null with nothing pending or no key to find rows again; a draft is the open editor's text, kept as if typed.
    public static SavedEdits? From(
        TableEdits edits, StoredValueReader stored, bool uncertain = false, CellDraft? draft = null)
    {
        ArgumentNullException.ThrowIfNull(edits);
        ArgumentNullException.ThrowIfNull(stored);
        var columns = edits.Columns;
        var key = KeyColumns(columns);
        var open = draft is { Row: >= 0, Column: >= 0 } typed
            && typed.Row < edits.RowCount
            && typed.Column < columns.Count
            && !edits.IsDeleted(typed.Row)
                ? typed
                : null;
        if (key.Count == 0 || (!edits.HasChanges && open is null))
        {
            return null;
        }

        var planned = edits.ToRowEdits();
        List<(int Row, SavedRowEdit Edit)> rows = [];
        for (var index = 0; index < planned.Edits.Count; index++)
        {
            var saved = planned.Edits[index] switch
            {
                RowEdit.Insert insert => new SavedRowEdit
                {
                    Cells = Named(columns, insert.Cells.Select((cell, column) => new CellChange(column, cell))),
                    Uncertain = uncertain,
                },
                RowEdit.Delete delete => KeyOf(columns, key, (int)delete.Row, stored) is { } named
                    ? new SavedRowEdit { Key = named, Deleted = true, Uncertain = uncertain }
                    : null,
                RowEdit.Update update => KeyOf(columns, key, (int)update.Row, stored) is { } named
                    ? new SavedRowEdit { Key = named, Cells = Named(columns, update.Cells), Uncertain = uncertain }
                    : null,
                _ => null,
            };
            if (saved is not null)
            {
                rows.Add((planned.Rows[index], saved));
            }
        }

        if (open is not null && Drafted(columns, key, stored, edits, rows, open, uncertain) is { } drafted)
        {
            rows.Add((open.Row, drafted));
        }

        return rows.Count == 0 ? null : new SavedEdits { Rows = [.. rows.Select(row => row.Edit)] };
    }

    // Waiting holds what did not go back; Uncertain says a change that went back may be on the server already.
    public (int Restored, bool Uncertain, SavedEdits? Waiting) RestoreTo(
        TableEdits edits, StoredValueReader stored, Func<int, int, CellEdit, bool> set)
    {
        ArgumentNullException.ThrowIfNull(edits);
        ArgumentNullException.ThrowIfNull(stored);
        ArgumentNullException.ThrowIfNull(set);
        var columns = edits.Columns;
        var byName = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var column = 0; column < columns.Count; column++)
        {
            byName.TryAdd(columns[column].Name, column);
        }

        var key = KeyColumns(columns);
        Dictionary<string, int>? page = null;
        var restored = 0;
        var uncertain = false;
        List<SavedRowEdit> waiting = [];
        foreach (var saved in Rows ?? [])
        {
            if (saved is null)
            {
                continue;
            }

            if (saved.Key is null)
            {
                // A new row goes back whole or waits whole, since each try adds it again.
                var added = edits.AddRow();
                if (PutCells(saved, added, edits, byName, set).Count > 0)
                {
                    edits.DeleteRows([added]);
                    waiting.Add(saved);
                }
                else
                {
                    restored += saved.Changes;
                    uncertain |= saved.Uncertain;
                }

                continue;
            }

            page ??= PageRows(edits.DataRows, key, stored);
            if (Wanted(saved.Key, columns, key) is not { } wanted
                || !page.TryGetValue(wanted, out var row)
                || row == SharedKey)
            {
                waiting.Add(saved);
                continue;
            }

            if (saved.Deleted)
            {
                edits.DeleteRows([row]);
                restored += saved.Changes;
                uncertain |= saved.Uncertain;
                continue;
            }

            var left = PutCells(saved, row, edits, byName, set);
            restored += saved.Changes - left.Count;
            uncertain |= saved.Uncertain && left.Count < saved.Changes;
            if (left.Count > 0)
            {
                waiting.Add(saved with { Cells = left });
            }
        }

        return (restored, uncertain, waiting.Count == 0 ? null : new SavedEdits { Rows = waiting });
    }

    // The changes still waiting, then the ones pending now, which a relaunch puts back in that order.
    public static SavedEdits? Join(SavedEdits? waiting, SavedEdits? pending)
    {
        if (waiting is null || pending is null)
        {
            return waiting ?? pending;
        }

        return new SavedEdits { Rows = [.. waiting.Rows ?? [], .. pending.Rows ?? []] };
    }

    // The open editor's text, as its commit would make it: the cell's edit and the row's latest change.
    private static SavedRowEdit? Drafted(
        IReadOnlyList<EditColumn> columns,
        List<int> key,
        StoredValueReader stored,
        TableEdits edits,
        List<(int Row, SavedRowEdit Edit)> rows,
        CellDraft open,
        bool uncertain)
    {
        var cell = SavedCell.From(new CellEdit.Text(open.Text));
        var name = columns[open.Column].Name;
        var at = rows.FindIndex(row => row.Row == open.Row);
        if (at >= 0)
        {
            var edited = rows[at].Edit;
            rows.RemoveAt(at);
            return edited with
            {
                Cells = new Dictionary<string, SavedCell>(edited.Cells ?? SavedRowEdit.NoCells, StringComparer.Ordinal)
                {
                    [name] = cell,
                },
            };
        }

        return !edits.IsAdded(open.Row) && KeyOf(columns, key, open.Row, stored) is { } named
            ? new SavedRowEdit
            {
                Key = named,
                Cells = new Dictionary<string, SavedCell>(StringComparer.Ordinal) { [name] = cell },
                Uncertain = uncertain,
            }
            : null;
    }

    private static List<int> KeyColumns(IReadOnlyList<EditColumn> columns) =>
        [.. Enumerable.Range(0, columns.Count).Where(column => columns[column].PrimaryKey)];

    private static Dictionary<string, SavedCell> Named(IReadOnlyList<EditColumn> columns, IEnumerable<CellChange> cells)
    {
        var named = new Dictionary<string, SavedCell>(StringComparer.Ordinal);
        foreach (var cell in cells)
        {
            named.TryAdd(columns[cell.Column].Name, SavedCell.From(cell.Edit));
        }

        return named;
    }

    private static Dictionary<string, SavedKeyPart>? KeyOf(
        IReadOnlyList<EditColumn> columns, List<int> key, int row, StoredValueReader stored)
    {
        var named = new Dictionary<string, SavedKeyPart>(StringComparer.Ordinal);
        try
        {
            foreach (var column in key)
            {
                if (stored(column, row, 1) is not [var value])
                {
                    return null;
                }

                named.TryAdd(columns[column].Name, SavedKeyPart.From(value));
            }
        }
        catch (TableProException)
        {
            // A row whose key cannot be read cannot be found again, so it is not kept.
            return null;
        }

        return named;
    }

    // The page's rows by key, each key column read once; a key two rows share finds neither (SharedKey).
    private static Dictionary<string, int> PageRows(int dataRows, List<int> key, StoredValueReader stored)
    {
        var rows = new Dictionary<string, int>(StringComparer.Ordinal);
        if (key.Count == 0 || dataRows == 0)
        {
            return rows;
        }

        IReadOnlyList<StoredValue>[] values;
        try
        {
            values = [.. key.Select(column => stored(column, 0, dataRows))];
        }
        catch (TableProException)
        {
            // Without the page's keys no row can be found, so every change waits.
            return rows;
        }

        var parts = new StoredValue[key.Count];
        // A row a key column did not read cannot be found.
        var readable = values.Min(column => column.Count);
        for (var row = 0; row < Math.Min(dataRows, readable); row++)
        {
            for (var part = 0; part < key.Count; part++)
            {
                parts[part] = values[part][row];
            }

            var joined = Joined(parts);
            if (!rows.TryAdd(joined, row))
            {
                rows[joined] = SharedKey;
            }
        }

        return rows;
    }

    // The key must name the table's key columns now, no more and no fewer, each with a kind this build knows.
    private static string? Wanted(
        IReadOnlyDictionary<string, SavedKeyPart> saved, IReadOnlyList<EditColumn> columns, List<int> key)
    {
        if (key.Count == 0 || saved.Count != key.Count)
        {
            return null;
        }

        var parts = new StoredValue[key.Count];
        for (var part = 0; part < key.Count; part++)
        {
            if (!saved.TryGetValue(columns[key[part]].Name, out var named) || named?.ToValue() is not { } value)
            {
                return null;
            }

            parts[part] = value;
        }

        return Joined(parts);
    }

    // Kind and length first, so a BLOB and a text that read alike differ; a NULL holds its column's kind, so not that.
    private static string Joined(StoredValue[] parts)
    {
        var joined = new StringBuilder();
        foreach (var part in parts)
        {
            if (part.Text is null)
            {
                joined.Append("-;");
            }
            else
            {
                joined.Append(((byte)part.Kind).ToString(CultureInfo.InvariantCulture)).Append(':')
                    .Append(part.Text.Length.ToString(CultureInfo.InvariantCulture)).Append(':').Append(part.Text);
            }
        }

        return joined.ToString();
    }

    // The cells that did not go back, by column name.
    private static Dictionary<string, SavedCell> PutCells(
        SavedRowEdit saved,
        int row,
        TableEdits edits,
        Dictionary<string, int> byName,
        Func<int, int, CellEdit, bool> set)
    {
        var left = new Dictionary<string, SavedCell>(StringComparer.Ordinal);
        foreach (var (name, cell) in saved.Cells ?? SavedRowEdit.NoCells)
        {
            if (name is null || cell is null)
            {
                continue;
            }

            if (!byName.TryGetValue(name, out var column) || cell.ToEdit() is not { } edit)
            {
                left[name] = cell;
                continue;
            }

            // A new row starts with each column's own value, which takes no edit.
            if (edits.IsAdded(row) && Equals(edits.GetCell(row, column), edit))
            {
                continue;
            }

            if (!set(row, column, edit))
            {
                left[name] = cell;
            }
        }

        return left;
    }
}

public sealed record SavedRowEdit
{
    internal static readonly IReadOnlyDictionary<string, SavedCell> NoCells = new Dictionary<string, SavedCell>();

    // A data row's primary key by column name, each value with its kind; none for a new row.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyDictionary<string, SavedKeyPart>? Key { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
    public bool Deleted { get; set; }

    // From a save whose outcome is unknown, or one running as the file was written: the server may hold it already.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
    public bool Uncertain { get; set; }

    // By column name: a data row's changed cells, or every cell of a new row.
    public IReadOnlyDictionary<string, SavedCell> Cells { get; set; } = NoCells;

    [JsonIgnore]
    public int Changes => Deleted || Key is null ? 1 : (Cells ?? NoCells).Count;
}

// A key value by its ValueKind's name and its whole text, null for NULL; a kind this build does not know finds no row.
public sealed record SavedKeyPart
{
    public string Kind { get; set; } = string.Empty;

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Text { get; set; }

    public static SavedKeyPart From(StoredValue value) => new()
    {
        Kind = Enum.GetName(value.Kind) ?? ((byte)value.Kind).ToString(CultureInfo.InvariantCulture),
        Text = value.Text,
    };

    public StoredValue? ToValue()
    {
        if (Text is null)
        {
            return new StoredValue(ValueKind.Other, null);
        }

        return SavedName.TryParse(Kind, out ValueKind kind) ? new StoredValue(kind, Text) : null;
    }
}

// A cell's edit by its CellEdit kind's name, so a kind a later build adds reads as none here, not as a broken file.
public sealed record SavedCell
{
    public string Kind { get; set; } = nameof(CellEdit.Text);

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Text { get; set; }

    public static SavedCell From(CellEdit edit)
    {
        ArgumentNullException.ThrowIfNull(edit);
        return edit switch
        {
            CellEdit.Text text => new SavedCell { Kind = nameof(CellEdit.Text), Text = text.Value },
            CellEdit.Null => new SavedCell { Kind = nameof(CellEdit.Null) },
            _ => new SavedCell { Kind = nameof(CellEdit.ServerDefault) },
        };
    }

    public CellEdit? ToEdit() => Kind switch
    {
        nameof(CellEdit.Text) => new CellEdit.Text(Text ?? string.Empty),
        nameof(CellEdit.Null) => CellEdit.Null.Instance,
        nameof(CellEdit.ServerDefault) => CellEdit.ServerDefault.Instance,
        _ => null,
    };
}
