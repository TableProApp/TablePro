namespace TablePro.Core.Generation;

/// <summary>How one column's values are made, as the macOS row generator offers them.</summary>
public enum RowGeneratorKind
{
    /// <summary>Left out of the INSERT, so the server's default or identity fills it.</summary>
    ServerDefault,

    /// <summary>A value of the parent table's key, sampled from its rows.</summary>
    Reference,
    Sequence,
    IntegerRange,
    DecimalRange,
    Text,
    FirstName,
    LastName,
    FullName,
    Email,
    Phone,
    StreetAddress,
    City,
    Country,
    Date,
    DateTime,
    Time,
    Uuid,
    Boolean,
    List,
    Pattern,
    Json,
}

public enum UuidVersion
{
    V4,

    /// <summary>Time-ordered: the timestamp counts up from 2025-01-01 by the row, so values sort in insert order.</summary>
    V7,
}

public static class RowGeneratorKinds
{
    public static string Title(this RowGeneratorKind kind) => kind switch
    {
        RowGeneratorKind.ServerDefault => "Server Default",
        RowGeneratorKind.Reference => "Referenced Value",
        RowGeneratorKind.Sequence => "Sequence",
        RowGeneratorKind.IntegerRange => "Number Range",
        RowGeneratorKind.DecimalRange => "Decimal Range",
        RowGeneratorKind.Text => "Text",
        RowGeneratorKind.FirstName => "First Name",
        RowGeneratorKind.LastName => "Last Name",
        RowGeneratorKind.FullName => "Full Name",
        RowGeneratorKind.Email => "Email",
        RowGeneratorKind.Phone => "Phone Number",
        RowGeneratorKind.StreetAddress => "Street Address",
        RowGeneratorKind.City => "City",
        RowGeneratorKind.Country => "Country",
        RowGeneratorKind.Date => "Date",
        RowGeneratorKind.DateTime => "Date and Time",
        RowGeneratorKind.Time => "Time",
        RowGeneratorKind.Uuid => "UUID",
        RowGeneratorKind.Boolean => "Boolean",
        RowGeneratorKind.List => "List of Values",
        RowGeneratorKind.Pattern => "Pattern",
        RowGeneratorKind.Json => "JSON",
        _ => kind.ToString(),
    };

    /// <summary>Values made from words or names take a numbered suffix once random draws stop finding a new one.</summary>
    internal static bool TakesDisambiguatingSuffix(this RowGeneratorKind kind) => kind is RowGeneratorKind.Text or RowGeneratorKind.FirstName
        or RowGeneratorKind.LastName or RowGeneratorKind.FullName or RowGeneratorKind.Email or RowGeneratorKind.StreetAddress
        or RowGeneratorKind.City or RowGeneratorKind.Country;
}

/// <summary>What a column can hold, read from its declared type.</summary>
public enum RowValueClass
{
    Integer,
    Decimal,
    FloatingPoint,
    Text,
    Date,
    Time,
    Timestamp,
    Boolean,
    Uuid,
    Json,
    Enumeration,
    Unsupported,
}

public enum ServerOwnership
{
    None,

    /// <summary>Identity BY DEFAULT, a sequence default, a rowid alias: the server fills it when the INSERT leaves it out.</summary>
    Assigned,

    /// <summary>A generated column, SQL Server's identity or rowversion: the server refuses any value for it.</summary>
    Computed,
}

/// <summary>Which referenced key a column takes its value from, and its place in that key.</summary>
public readonly record struct ReferenceSlot(string SourceId, int Position);

public sealed record RowGenerationColumn(string Name, string TypeName, RowValueClass ValueClass)
{
    public long IntegerMinimum { get; init; } = long.MinValue;

    public long IntegerMaximum { get; init; } = long.MaxValue;

    public int? Precision { get; init; }

    public int? Scale { get; init; }

    public int? MaxLength { get; init; }

    public IReadOnlyList<string> Labels { get; init; } = [];

    public bool IsNullable { get; init; } = true;

    public bool HasDefault { get; init; }

    public ServerOwnership Ownership { get; init; }

    public bool IsUnique { get; init; }

    public ReferenceSlot? Reference { get; init; }

    public bool MayBeLeftOut => IsNullable || HasDefault || Ownership != ServerOwnership.None;

    /// <summary>The generators this column offers, the server's default first when it may be left out.</summary>
    public IReadOnlyList<RowGeneratorKind> AvailableKinds
    {
        get
        {
            if (Ownership == ServerOwnership.Computed)
            {
                return [RowGeneratorKind.ServerDefault];
            }

            var kinds = new List<RowGeneratorKind>(18);
            if (MayBeLeftOut)
            {
                kinds.Add(RowGeneratorKind.ServerDefault);
            }

            if (Reference is not null)
            {
                kinds.Add(RowGeneratorKind.Reference);
            }

            kinds.AddRange(ValueClass switch
            {
                RowValueClass.Integer => [RowGeneratorKind.Sequence, RowGeneratorKind.IntegerRange, RowGeneratorKind.List],
                RowValueClass.Decimal or RowValueClass.FloatingPoint => [RowGeneratorKind.DecimalRange, RowGeneratorKind.IntegerRange, RowGeneratorKind.List],
                RowValueClass.Text =>
                [
                    RowGeneratorKind.Text, RowGeneratorKind.FirstName, RowGeneratorKind.LastName, RowGeneratorKind.FullName, RowGeneratorKind.Email,
                    RowGeneratorKind.Phone, RowGeneratorKind.StreetAddress, RowGeneratorKind.City, RowGeneratorKind.Country, RowGeneratorKind.Pattern,
                    RowGeneratorKind.Uuid, RowGeneratorKind.Sequence, RowGeneratorKind.IntegerRange, RowGeneratorKind.Date, RowGeneratorKind.DateTime,
                    RowGeneratorKind.List,
                ],
                RowValueClass.Date => [RowGeneratorKind.Date, RowGeneratorKind.List],
                RowValueClass.Time => [RowGeneratorKind.Time, RowGeneratorKind.List],
                RowValueClass.Timestamp => [RowGeneratorKind.DateTime, RowGeneratorKind.Date, RowGeneratorKind.List],
                RowValueClass.Boolean => [RowGeneratorKind.Boolean],
                RowValueClass.Uuid => [RowGeneratorKind.Uuid, RowGeneratorKind.List],
                RowValueClass.Json => [RowGeneratorKind.Json, RowGeneratorKind.List],
                RowValueClass.Enumeration => [RowGeneratorKind.List],
                _ => [],
            });
            return kinds;
        }
    }
}

/// <summary>A sample of a parent table's key: up to <see cref="RowGenerationLoader.ReferenceSampleLimit"/> distinct tuples, in key order.</summary>
public sealed record ReferenceSource(string Id, string ReferencedTable, IReadOnlyList<string> Columns, IReadOnlyList<object?[]> Tuples);

public sealed record RowGenerationTable(IReadOnlyList<RowGenerationColumn> Columns)
{
    /// <summary>Composite unique keys and primary keys; a single-column one is the column's <see cref="RowGenerationColumn.IsUnique"/>.</summary>
    public IReadOnlyList<IReadOnlyList<string>> UniqueGroups { get; init; } = [];

    public IReadOnlyList<ReferenceSource> References { get; init; } = [];

    /// <summary>The largest value each integer key column holds now, so a sequence starts past it.</summary>
    public IReadOnlyDictionary<string, long> KeyMaximums { get; init; } = new Dictionary<string, long>();

    public RowGenerationColumn? Column(string name) => Columns.FirstOrDefault(c => c.Name == name);

    public ReferenceSource? Reference(string id) => References.FirstOrDefault(r => r.Id == id);
}

/// <summary>One column's generator and its options. Immutable, changed with <c>with</c>.</summary>
public sealed record RowGeneratorSettings(RowGeneratorKind Kind)
{
    public long IntegerMinimum { get; init; } = 1;

    public long IntegerMaximum { get; init; } = 1_000;

    public long SequenceStep { get; init; } = 1;

    public double DecimalMinimum { get; init; }

    public double DecimalMaximum { get; init; } = 1_000;

    public int DecimalScale { get; init; } = 2;

    public int MinLength { get; init; } = 5;

    public int MaxLength { get; init; } = 30;

    public DateOnly DateStart { get; init; } = new(2020, 1, 1);

    public DateOnly DateEnd { get; init; } = new(2024, 12, 31);

    public UuidVersion UuidVersion { get; init; }

    public double TrueRatio { get; init; } = 0.5;

    public IReadOnlyList<string> Values { get; init; } = [];

    public string Pattern { get; init; } = "???-####";

    /// <summary>The share of rows, from 0 to 1, that get NULL in a nullable column.</summary>
    public double NullRatio { get; init; }
}

public sealed record RowGenerationSettings(int RowCount, ulong Seed, IReadOnlyDictionary<string, RowGeneratorSettings> Columns)
{
    public const int MaximumRowCount = 1_000_000;

    public const int DefaultRowCount = 100;

    public RowGenerationSettings With(string column, RowGeneratorSettings settings)
    {
        var columns = new Dictionary<string, RowGeneratorSettings>(Columns, StringComparer.Ordinal) { [column] = settings };
        return this with { Columns = columns };
    }

    /// <summary>A seed a person can read and type back, as on macOS.</summary>
    public static ulong RandomSeed() => (ulong)System.Security.Cryptography.RandomNumberGenerator.GetInt32(1, 1_000_000);
}
