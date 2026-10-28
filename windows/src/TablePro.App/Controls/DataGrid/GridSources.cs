using TablePro.Core.Editing;
using TablePro.Core.Results;

namespace TablePro.App.Controls.DataGrid;

/// <summary>What the grid draws. It asks only for visible cells, so sources format lazily.</summary>
public interface IGridSource
{
    int RowCount { get; }

    IReadOnlyList<ResultColumn> Columns { get; }

    bool IsEditable { get; }

    object? GetValue(int row, int column);

    RowEditState GetRowState(int row);

    bool IsCellModified(int row, int column);

    /// <summary>Parses the typed text for the column's type. False leaves the cell as it was and explains why.</summary>
    bool TrySetValue(int row, int column, string? text, out string? error);

    event EventHandler? Changed;
}

public sealed class ResultGridSource(ResultSet result) : IGridSource
{
    public ResultSet Result { get; } = result;

    public int RowCount => Result.RowCount;

    public IReadOnlyList<ResultColumn> Columns => Result.Columns;

    public bool IsEditable => false;

    public object? GetValue(int row, int column) => Result[row, column];

    public RowEditState GetRowState(int row) => RowEditState.Unchanged;

    public bool IsCellModified(int row, int column) => false;

    public bool TrySetValue(int row, int column, string? text, out string? error)
    {
        error = "This result is read-only.";
        return false;
    }

    public event EventHandler? Changed
    {
        add { }
        remove { }
    }
}

public sealed class EditableGridSource : IGridSource
{
    public EditableGridSource(TableEditBuffer buffer, bool isEditable)
    {
        Buffer = buffer;
        IsEditable = isEditable;
        buffer.Changed += (_, _) => Changed?.Invoke(this, EventArgs.Empty);
    }

    public event EventHandler? Changed;

    public TableEditBuffer Buffer { get; }

    public int RowCount => Buffer.RowCount;

    public IReadOnlyList<ResultColumn> Columns => Buffer.Baseline.Columns;

    public bool IsEditable { get; }

    public object? GetValue(int row, int column) => Buffer.GetValue(row, column);

    public RowEditState GetRowState(int row) => Buffer.GetRowState(row);

    public bool IsCellModified(int row, int column) => Buffer.IsCellModified(row, column);

    public bool TrySetValue(int row, int column, string? text, out string? error)
    {
        if (!IsEditable)
        {
            error = "This table is read-only.";
            return false;
        }

        if (!ValueParser.TryParse(text, Columns[column].ClrType, out var value))
        {
            error = $"'{text}' is not a valid {Columns[column].DataType}.";
            return false;
        }

        Buffer.SetValue(row, column, value);
        error = null;
        return true;
    }
}
