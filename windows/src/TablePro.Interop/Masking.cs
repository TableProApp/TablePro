namespace TablePro.Interop;

// The styles of the macOS engine, which the core computes for a share (core ADR 0028).
public enum MaskStyle
{
    Full,
    LastFour,
    Email,
    Hash,
    Null,
}

// What a share does with one column; Mask sends each value in that style, computed on this machine.
public abstract record ShareColumnChoice
{
    private ShareColumnChoice()
    {
    }

    public sealed record Keep : ShareColumnChoice
    {
        public static Keep Instance { get; } = new();
    }

    public sealed record Mask(MaskStyle Style) : ShareColumnChoice;

    public sealed record Remove : ShareColumnChoice
    {
        public static Remove Instance { get; } = new();
    }
}

public enum SensitiveKind
{
    Card,
    Iban,
    Jwt,
    ApiKey,
    Email,
    Phone,
    Ip,
}

public abstract record MaskReason
{
    private MaskReason()
    {
    }

    // The term as its words join, such as "apikey" for stripe_api_key.
    public sealed record ColumnName(string Term) : MaskReason;

    public sealed record Values(SensitiveKind Kind) : MaskReason;
}

public sealed record MaskSuggestion(MaskStyle Style, MaskReason Reason);

// Suggestion is what the detectors saw in the column's name or its values, null when they saw nothing.
public sealed record ShareColumnMasking(string Name, MaskSuggestion? Suggestion);

// What a share with the sheet's choices sends, by the plan and the body budget create uses: RowsSent can be fewer than
// the plan's rows, and none when Refused says why the link cannot go.
public sealed record ShareSummary(long RowsSent, int ColumnsSent, bool ColumnsTruncated, ShareRefusal? Refused);

public abstract record ShareRefusal
{
    private ShareRefusal()
    {
    }

    // A value of the column is over 256 KiB.
    public sealed record Cell(string Column) : ShareRefusal;

    // The first row alone is over the 4.5 MB a link's body may weigh.
    public sealed record FirstRow : ShareRefusal
    {
        public static FirstRow Instance { get; } = new();
    }

    // Every column was removed; CreateShareAsync refuses it with ffi.share_no_columns.
    public sealed record NoColumns : ShareRefusal
    {
        public static NoColumns Instance { get; } = new();
    }
}

// Line counts from 1, where the literal starts.
public sealed record PersonalDataHit(SensitiveKind Kind, int Line);
