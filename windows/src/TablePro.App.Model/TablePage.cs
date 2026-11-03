namespace TablePro.App.Model;

// Where a table tab is in its table: the page starts Offset rows in and shows Rows of at most Size. Total is the
// server's count once it arrives. An engine that cannot seek has only the first page, as on macOS.
public sealed record TablePage(long Offset, int Size, long Rows, long? Total, bool CanSeek)
{
    public static TablePage First(int size) => new(0, Math.Max(1, size), 0, null, true);

    public long FirstRow => Rows == 0 ? 0 : Offset + 1;

    public long LastRow => Offset + Rows;

    public bool HasPrevious => CanSeek && Offset > 0;

    // Without a count, a full page may have more after it.
    public bool HasNext => CanSeek && (Total is { } total ? LastRow < total : Rows >= Size);

    public bool HasLast => CanSeek && Total is not null && LastOffset > Offset;

    public long PreviousOffset => Math.Max(0, Offset - Size);

    public long NextOffset => Offset + Size;

    public long LastOffset => Total is { } total && total > 0 ? (total - 1) / Size * Size : 0;

    // Whether the pager is worth showing: there is a page before or after this one.
    public bool IsPaged => HasPrevious || HasNext;

    public TablePage At(long offset) => this with { Offset = Math.Max(0, offset), Rows = 0 };
}
