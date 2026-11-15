namespace TablePro.App.Model;

// Without CanSeek an offset reads through every row before it, so the pager steps a page at a time and never jumps.
public sealed record TablePage(long Offset, int Size, long Rows, long? Total, bool CanSeek)
{
    // Past this a typed size is a mistake, not an intent, as macOS caps its Custom size.
    public const int MaximumSize = 1_000_000;

    // All rows can go further, short of int.MaxValue, which the grid counts rows in.
    public const int LargestSize = int.MaxValue - 1;

    // The sizes the macOS page size menu offers.
    public static IReadOnlyList<int> Presets { get; } = [5, 10, 20, 100, 500, 1_000];

    public static TablePage First(int size) => new(0, Math.Clamp(size, 1, LargestSize), 0, null, true);

    public static int Clamp(int size) => Math.Clamp(size, 1, MaximumSize);

    // The engine's estimate of the table, shown as about N while no count gave Total; nothing pages by it.
    public long? Estimate { get; init; }

    // Statistics can lag far behind the table, as MySQL's cached TABLE_ROWS or a table never analysed reading 0.
    public long? ShownEstimate => Estimate is { } estimate && estimate > LastRow ? estimate : null;

    // The server that pages the table said no row follows this page, however full it is.
    public bool EndsTable { get; init; }

    public long FirstRow => Rows == 0 ? 0 : Offset + 1;

    public long LastRow => Offset + Rows;

    public bool HasPrevious => Offset > 0;

    // Without a count, a full page may have more after it.
    public bool HasNext => !EndsTable && (Total is { } total ? LastRow < total : Rows >= Size);

    public bool HasLast => CanSeek && Total is not null && LastOffset > Offset;

    public long PreviousOffset => Math.Max(0, Offset - Size);

    public long NextOffset => Offset + Size;

    public long LastOffset => Total is { } total && total > 0 ? (total - 1) / Size * Size : 0;

    public bool IsPaged => HasPrevious || HasNext;

    public long Number => (Offset / Size) + 1;

    // Known once the table is counted; an empty table is one page.
    public long? Count => Total is { } total ? Math.Max(1, (total / Size) + (total % Size == 0 ? 0 : 1)) : null;

    public TablePage At(long offset) => this with { Offset = Math.Max(0, offset), Rows = 0, EndsTable = false };

    // Only a page the count holds, as macOS goes to a page only within an exact total.
    public bool Accepts(long number) => CanSeek && number >= 1 && Count is { } count && number <= count;

    public long OffsetOf(long number) => (Math.Max(1, number) - 1) * Size;

    // The page that holds the first row shown, as macOS changes the page size.
    public TablePage Resized(int size)
    {
        var clamped = Clamp(size);
        return this with { Size = clamped, Offset = Offset / clamped * clamped, Rows = 0, EndsTable = false };
    }

    public TablePage AllRows() =>
        Total is { } total
            ? this with { Size = (int)Math.Clamp(total, 1, LargestSize), Offset = 0, Rows = 0, EndsTable = false }
            : this;
}
