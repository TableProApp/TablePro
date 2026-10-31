using System.Text;

namespace TablePro.Core.Generation;

/// <summary>The generator a column starts with, read from its type first and its name second.</summary>
public static class RowGenerationDefaults
{
    /// <summary>Every column's starting generator, for a fresh run.</summary>
    public static RowGenerationSettings ForTable(RowGenerationTable table, DateOnly today, ulong seed, int rowCount = RowGenerationSettings.DefaultRowCount)
    {
        ArgumentNullException.ThrowIfNull(table);
        var columns = new Dictionary<string, RowGeneratorSettings>(table.Columns.Count, StringComparer.Ordinal);
        foreach (var column in table.Columns)
        {
            columns[column.Name] = Settings(column, table, today);
        }

        return new RowGenerationSettings(rowCount, seed, columns);
    }

    public static RowGeneratorSettings Settings(RowGenerationColumn column, RowGenerationTable table, DateOnly today)
    {
        ArgumentNullException.ThrowIfNull(column);
        ArgumentNullException.ThrowIfNull(table);

        // Absolute dates rather than "the last five years", so the same settings give the same rows next year too.
        var settings = new RowGeneratorSettings(RowGeneratorKind.ServerDefault)
        {
            DateStart = new DateOnly(today.Year - 4, 1, 1),
            DateEnd = new DateOnly(today.Year, 12, 31),
        };
        var tokens = NameTokens(column.Name);
        settings = NumericDefaults(settings, column, table, tokens);
        settings = TextDefaults(settings, column, tokens);
        if (column.ValueClass == RowValueClass.Enumeration)
        {
            settings = settings with { Values = column.Labels };
        }

        var kind = Kind(column, tokens);
        settings = settings with { Kind = kind };
        return kind == RowGeneratorKind.Pattern ? settings with { Pattern = PatternFor(tokens) } : settings;
    }

    public static RowGeneratorKind Kind(RowGenerationColumn column)
    {
        ArgumentNullException.ThrowIfNull(column);
        return Kind(column, NameTokens(column.Name));
    }

    private static RowGeneratorKind Kind(RowGenerationColumn column, string[] tokens)
    {
        if (column.Ownership != ServerOwnership.None)
        {
            return RowGeneratorKind.ServerDefault;
        }

        if (column.Reference is not null)
        {
            return RowGeneratorKind.Reference;
        }

        return column.ValueClass switch
        {
            RowValueClass.Enumeration => RowGeneratorKind.List,
            RowValueClass.Boolean => RowGeneratorKind.Boolean,
            RowValueClass.Uuid => RowGeneratorKind.Uuid,
            RowValueClass.Json => RowGeneratorKind.Json,
            RowValueClass.Date => RowGeneratorKind.Date,
            RowValueClass.Time => RowGeneratorKind.Time,
            RowValueClass.Timestamp => RowGeneratorKind.DateTime,
            RowValueClass.Integer => column.IsUnique ? RowGeneratorKind.Sequence : RowGeneratorKind.IntegerRange,
            RowValueClass.Decimal or RowValueClass.FloatingPoint => RowGeneratorKind.DecimalRange,
            RowValueClass.Text => TextKind(tokens),
            _ => RowGeneratorKind.ServerDefault,
        };
    }

    private static readonly string[] People = ["display", "contact", "customer", "user", "owner", "employee", "person", "member", "client"];

    private static RowGeneratorKind TextKind(string[] tokens)
    {
        var joined = string.Concat(tokens);
        bool Has(params string[] words) => words.Any(tokens.Contains);
        if (Has("email", "mail"))
        {
            return RowGeneratorKind.Email;
        }

        if (joined.Contains("firstname", StringComparison.Ordinal) || Has("forename", "fname") || joined.Contains("givenname", StringComparison.Ordinal))
        {
            return RowGeneratorKind.FirstName;
        }

        if (joined.Contains("lastname", StringComparison.Ordinal) || Has("surname", "lname") || joined.Contains("familyname", StringComparison.Ordinal))
        {
            return RowGeneratorKind.LastName;
        }

        if (Has("phone", "mobile", "tel", "telephone", "fax", "cell"))
        {
            return RowGeneratorKind.Phone;
        }

        if (Has("address", "street", "addr"))
        {
            return RowGeneratorKind.StreetAddress;
        }

        if (Has("city", "town"))
        {
            return RowGeneratorKind.City;
        }

        if (Has("country"))
        {
            return RowGeneratorKind.Country;
        }

        if (Has("uuid", "guid"))
        {
            return RowGeneratorKind.Uuid;
        }

        if (Has("zip", "postal", "postcode", "url", "website", "homepage", "link", "sku", "code"))
        {
            return RowGeneratorKind.Pattern;
        }

        if (joined == "name" || joined.EndsWith("fullname", StringComparison.Ordinal) || Has("author"))
        {
            return RowGeneratorKind.FullName;
        }

        return Has("name") && tokens.Any(People.Contains) ? RowGeneratorKind.FullName : RowGeneratorKind.Text;
    }

    private static string PatternFor(string[] tokens)
    {
        if (tokens.Any(t => t is "zip" or "postal" or "postcode"))
        {
            return "#####";
        }

        return tokens.Any(t => t is "url" or "website" or "homepage" or "link") ? "https://example.com/????????" : "???-####";
    }

    private static RowGeneratorSettings NumericDefaults(RowGeneratorSettings settings, RowGenerationColumn column, RowGenerationTable table, string[] tokens)
    {
        bool Has(params string[] words) => words.Any(tokens.Contains);
        switch (column.ValueClass)
        {
            case RowValueClass.Integer:
            {
                var (low, high) = Has("age") ? (18L, 90L) : Has("year") ? (1_990L, 2_030L) : Has("quantity", "qty", "count", "stock") ? (0L, 100L) : (1L, 1_000L);
                var minimum = Math.Min(Math.Max(low, column.IntegerMinimum), column.IntegerMaximum);
                var maximum = Math.Max(Math.Min(high, column.IntegerMaximum), minimum);
                if (column.IsUnique)
                {
                    var current = table.KeyMaximums.TryGetValue(column.Name, out var max) ? max : 0;
                    minimum = current == long.MaxValue ? column.IntegerMaximum : Math.Min(Math.Max(current + 1, column.IntegerMinimum), column.IntegerMaximum);
                    maximum = column.IntegerMaximum;
                }

                return settings with { IntegerMinimum = minimum, IntegerMaximum = maximum };
            }

            case RowValueClass.Decimal:
            {
                var scale = column.Scale ?? 2;
                var (low, high) = (0d, 1_000d);
                if (Has("lat", "latitude"))
                {
                    (low, high, scale) = (-90, 90, Math.Min(6, column.Scale ?? 6));
                }
                else if (Has("lng", "lon", "long", "longitude"))
                {
                    (low, high, scale) = (-180, 180, Math.Min(6, column.Scale ?? 6));
                }
                else if (Has("rating", "score"))
                {
                    (low, high, scale) = (0, 5, Math.Min(1, column.Scale ?? 1));
                }
                else if (Has("price", "amount", "cost", "total", "salary", "balance", "fee"))
                {
                    (low, high) = (1, 1_000);
                }

                var limit = RowGenerationValidation.DecimalLimit(column.Precision, column.Scale);
                var minimum = Math.Max(low, -limit);
                var maximum = Math.Min(high, limit);
                return settings with
                {
                    DecimalScale = scale,
                    DecimalMinimum = minimum,
                    DecimalMaximum = maximum,
                    IntegerMinimum = (long)Math.Ceiling(minimum),
                    IntegerMaximum = (long)Math.Floor(maximum),
                };
            }

            case RowValueClass.FloatingPoint:
            {
                var latitude = Has("lat", "latitude");
                var longitude = Has("lng", "lon", "longitude");
                return settings with
                {
                    DecimalScale = latitude || longitude ? 6 : 2,
                    DecimalMinimum = latitude ? -90 : longitude ? -180 : 0,
                    DecimalMaximum = latitude ? 90 : longitude ? 180 : 1_000,
                };
            }

            default:
                return settings;
        }
    }

    private static RowGeneratorSettings TextDefaults(RowGeneratorSettings settings, RowGenerationColumn column, string[] tokens)
    {
        bool Has(params string[] words) => words.Any(tokens.Contains);
        var (low, high) = Has("description", "notes", "note", "bio", "comment", "comments", "body", "content", "summary", "message") ? (20, 200)
            : Has("title", "subject", "headline", "label") ? (10, 60)
            : (5, 30);
        var maximum = Math.Max(1, Math.Min(high, column.MaxLength ?? int.MaxValue));
        return settings with { MaxLength = maximum, MinLength = Math.Min(low, maximum) };
    }

    /// <summary><c>customerEmail</c>, <c>customer_email</c> and <c>CUSTOMER-EMAIL</c> all read as ["customer", "email"].</summary>
    public static string[] NameTokens(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        var tokens = new List<string>();
        var current = new StringBuilder();
        var previousIsLower = false;
        foreach (var c in name)
        {
            if (!char.IsLetterOrDigit(c))
            {
                Flush();
                previousIsLower = false;
                continue;
            }

            if (char.IsUpper(c) && previousIsLower && current.Length > 0)
            {
                Flush();
            }

            current.Append(c);
            previousIsLower = char.IsLower(c) || char.IsDigit(c);
        }

        Flush();
        return [.. tokens];

        void Flush()
        {
            if (current.Length > 0)
            {
                tokens.Add(current.ToString().ToLowerInvariant());
                current.Clear();
            }
        }
    }
}
