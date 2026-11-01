namespace TablePro.Core.JoinBuilder;

/// <summary>
/// The widths of the join builder's table list and details column for the width the tab has. Both were fixed (240
/// and 380), so a narrow tab, such as one with a side pane open beside it, gave the canvas between them no width at
/// all and it went blank. The side columns now give way first, down to their minimums, so the canvas keeps room.
/// </summary>
public static class JoinBuilderLayout
{
    public const double ListWidth = 240;
    public const double DetailsWidth = 380;
    public const double ListMinimum = 160;
    public const double DetailsMinimum = 240;
    public const double CanvasMinimum = 280;

    public static (double List, double Details) Columns(double available)
    {
        if (!double.IsFinite(available) || available <= 0)
        {
            return (ListWidth, DetailsWidth);
        }

        var spare = available - CanvasMinimum;
        if (spare >= ListWidth + DetailsWidth)
        {
            return (ListWidth, DetailsWidth);
        }

        // Shrink both side columns by the same share of what they can give up, then let the canvas take less once
        // they are at their minimums.
        var give = (ListWidth - ListMinimum) + (DetailsWidth - DetailsMinimum);
        var needed = ListWidth + DetailsWidth - Math.Max(spare, ListMinimum + DetailsMinimum);
        var share = Math.Clamp(needed / give, 0, 1);
        return (ListWidth - ((ListWidth - ListMinimum) * share), DetailsWidth - ((DetailsWidth - DetailsMinimum) * share));
    }
}
