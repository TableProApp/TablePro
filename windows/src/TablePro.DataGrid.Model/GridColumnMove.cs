namespace TablePro.DataGrid.Model;

// A header dragged from display position From; To is the position it takes once moved.
public readonly record struct GridColumnMove(int From, int To)
{
    // Dropped before a boundary, 0 to the column count; null where it lands where it was.
    public static GridColumnMove? Dropped(int column, int boundary)
    {
        var to = boundary > column ? boundary - 1 : boundary;
        return to == column ? null : new GridColumnMove(column, to);
    }
}
