namespace TablePro.DataGrid.Model;

public enum SortDirection
{
    None,
    Ascending,
    Descending,
}

public readonly record struct GridSort(int Column, SortDirection Direction)
{
    public static GridSort None { get; } = new(-1, SortDirection.None);

    // A click on a header keeps only that column, ascending, and flips it on a repeat, as the macOS grid does.
    public GridSort Clicked(int column) =>
        column == Column && Direction == SortDirection.Ascending
            ? new GridSort(column, SortDirection.Descending)
            : new GridSort(column, SortDirection.Ascending);
}
