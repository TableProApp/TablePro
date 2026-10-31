namespace TablePro.Core.Interaction;

/// <summary>A track of a grid next to a splitter, as the splitter sees it.</summary>
/// <param name="Size">Its laid-out size.</param>
/// <param name="MinSize">Its declared minimum.</param>
/// <param name="IsStar">Whether it takes a share of the remaining space, in which case only its minimum is owed to it.</param>
public readonly record struct SplitterTrack(double Size, double MinSize, bool IsStar);

/// <summary>
/// The size a splitter may give the track it resizes. The results splitter clamped only against the whole grid, so a
/// drag could ask for more height than the toolbar, the splitter itself and the editor's minimum left. The grid then
/// overflowed and clipped the results from the bottom, which looked like the pane moving the wrong way, and later
/// drags changed a size nobody could see, which looked like it stuck.
/// </summary>
public static class SplitterMath
{
    /// <param name="desired">The size the drag asks for.</param>
    /// <param name="available">The grid's size along the drag.</param>
    /// <param name="target">The track being resized.</param>
    /// <param name="others">Every other track along the drag.</param>
    /// <param name="floor">The smallest size the splitter ever leaves, whatever the track's own minimum.</param>
    /// <param name="starFloor">The least a star track keeps when it declares a smaller minimum, so a pane never vanishes.</param>
    public static double Clamp(double desired, double available, SplitterTrack target, IEnumerable<SplitterTrack> others, double floor = 48, double starFloor = 0)
    {
        ArgumentNullException.ThrowIfNull(others);
        var owed = others.Sum(t => t.IsStar ? Math.Max(t.MinSize, starFloor) : t.Size);
        var minimum = Math.Max(floor, target.MinSize);
        var maximum = Math.Max(minimum, available - owed);
        return double.IsFinite(desired) ? Math.Clamp(desired, minimum, maximum) : minimum;
    }
}
