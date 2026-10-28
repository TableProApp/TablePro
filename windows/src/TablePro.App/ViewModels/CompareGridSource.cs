using TablePro.App.Controls.DataGrid;
using TablePro.Core.Compare;
using TablePro.Core.Editing;
using TablePro.Core.Results;

namespace TablePro.App.ViewModels;

/// <summary>
/// A comparison's differences in the data grid, using its edit colors for what a sync would do: a row only in the
/// source shows as inserted, one only in the target as deleted, and a changed cell as modified with the target's value
/// followed by the source's.
/// </summary>
public sealed class CompareGridSource : IGridSource
{
    private const string Arrow = " → ";

    private readonly DataDiffResult _result;
    private readonly IReadOnlySet<string> _excluded;
    private readonly int[] _rows;

    /// <param name="result">The comparison to show.</param>
    /// <param name="kinds">The kinds of difference to list.</param>
    /// <param name="excluded">Row identities the user left out of the sync, read live so toggling only needs a refresh.</param>
    public CompareGridSource(DataDiffResult result, IReadOnlySet<RowDiffKind> kinds, IReadOnlySet<string> excluded)
    {
        ArgumentNullException.ThrowIfNull(result);
        ArgumentNullException.ThrowIfNull(kinds);
        _result = result;
        _excluded = excluded;
        var rows = new List<int>(result.Differences.Count);
        for (var i = 0; i < result.Differences.Count; i++)
        {
            if (kinds.Contains(result.Differences[i].Kind))
            {
                rows.Add(i);
            }
        }

        _rows = [.. rows];
        Columns = [new ResultColumn("Sync", "text", typeof(string)), .. result.Spec.Columns.Select(c => new ResultColumn(c.IsKey ? c.Source + " (key)" : c.Source, c.TargetDataType ?? string.Empty, typeof(object)))];
    }

    public event EventHandler? Changed;

    public int RowCount => _rows.Length;

    public IReadOnlyList<ResultColumn> Columns { get; }

    public bool IsEditable => false;

    public RowDiff Diff(int row) => _result.Differences[_rows[row]];

    public object? GetValue(int row, int column)
    {
        var diff = Diff(row);
        if (column == 0)
        {
            return _excluded.Contains(_result.Spec.KeyIdentity(diff.KeyRow)) ? "Skipped" : diff.Kind switch
            {
                RowDiffKind.OnlyInSource => "Insert",
                RowDiffKind.OnlyInTarget => "Delete",
                RowDiffKind.Changed => "Update",
                _ => "Same",
            };
        }

        var index = column - 1;
        if (diff.Kind == RowDiffKind.Changed && diff.Differs(index))
        {
            return string.Concat(CellFormatter.Format(diff.Target![index]), Arrow, CellFormatter.Format(diff.Source![index]));
        }

        return (diff.Source ?? diff.Target)![index];
    }

    public RowEditState GetRowState(int row) => Diff(row).Kind switch
    {
        RowDiffKind.OnlyInSource => RowEditState.Inserted,
        RowDiffKind.OnlyInTarget => RowEditState.Deleted,
        RowDiffKind.Changed => RowEditState.Modified,
        _ => RowEditState.Unchanged,
    };

    public bool IsCellModified(int row, int column) => column > 0 && Diff(row).Differs(column - 1);

    public bool TrySetValue(int row, int column, string? text, out string? error)
    {
        error = "A comparison is read-only. Edit the table itself, then compare again.";
        return false;
    }

    /// <summary>Redraws after the excluded rows changed.</summary>
    public void NotifyChanged() => Changed?.Invoke(this, EventArgs.Empty);
}
