namespace TablePro.Interop;

// The styles of the macOS engine, which the core runs for every app (core ADR 0026).
public enum MaskStyle
{
    Full,
    LastFour,
    Email,
    Hash,
    Null,
}

public enum MaskTarget
{
    Column,
    Type,
}

// Id is null for a rule the form just added. A save drops a rule whose pattern is blank; the first match wins.
public sealed record MaskingRule(Guid? Id, string Pattern, MaskTarget Target, MaskStyle Style);

// What a share does with one column. A column the connection's rules mask never leaves weaker than its rule.
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

// Rule is the style the connection's rules mask the column with on the way out; else Suggestion is what was detected.
public sealed record ShareColumnMasking(string Name, MaskStyle? Rule, MaskSuggestion? Suggestion)
{
    // The column carries no table column of its own, so a connection with rules masks it as Full.
    public bool Untraced { get; init; }
}

// Line counts from 1, where the literal starts.
public sealed record PersonalDataHit(SensitiveKind Kind, int Line);
