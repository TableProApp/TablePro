using System.Globalization;

namespace TablePro.Core.Generation;

/// <summary>One reason the settings cannot run, for a column or (with a null column) the whole table.</summary>
public sealed record RowGenerationIssue(string? Column, string Message);

/// <summary>Checks the settings before anything runs, so a run never fails half way on something the form could have said.</summary>
public static class RowGenerationValidation
{
    public const int SecondsPerDay = 86_400;

    public const int MaximumScale = 10;

    /// <summary>The largest value a DECIMAL(precision, scale) holds; unbounded precision is capped where a double stays exact.</summary>
    public static double DecimalLimit(int? precision, int? scale)
    {
        if (precision is null)
        {
            return 1e15;
        }

        var fraction = Math.Max(0, scale ?? 0);
        var digits = Math.Max(0, precision.Value - fraction);
        return Math.Pow(10, digits) - Math.Pow(10, -fraction);
    }

    /// <summary>A value as a count of steps of 10^-scale, so 123.45 at scale 2 is 12345 with no binary rounding afterwards.</summary>
    public static long Steps(double value, int scale)
    {
        var scaled = Math.Round(value * Math.Pow(10, scale), MidpointRounding.AwayFromZero);
        return double.IsFinite(scaled) ? (long)Math.Clamp(scaled, long.MinValue / 2, long.MaxValue / 2) : 0;
    }

    public static IReadOnlyList<RowGenerationIssue> Issues(RowGenerationSettings settings, RowGenerationTable table)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(table);
        var issues = new List<RowGenerationIssue>();
        if (settings.RowCount is < 1 or > RowGenerationSettings.MaximumRowCount)
        {
            issues.Add(new RowGenerationIssue(null, string.Create(CultureInfo.CurrentCulture, $"Enter a number of rows from 1 to {RowGenerationSettings.MaximumRowCount:N0}.")));
        }

        var writesAnyColumn = false;
        foreach (var column in table.Columns)
        {
            if (!settings.Columns.TryGetValue(column.Name, out var columnSettings))
            {
                continue;
            }

            writesAnyColumn |= columnSettings.Kind != RowGeneratorKind.ServerDefault;
            if (ColumnIssue(column, columnSettings, settings.RowCount, table) is { } message)
            {
                issues.Add(new RowGenerationIssue(column.Name, message));
            }
        }

        if (!writesAnyColumn)
        {
            issues.Add(new RowGenerationIssue(null, "Choose a generator for at least one column."));
        }

        issues.AddRange(GroupIssues(settings, table));
        return issues;
    }

    /// <summary>How many different values the generator can make, or null when that is effectively unlimited.</summary>
    public static long? DomainSize(RowGeneratorSettings settings, RowGenerationColumn column, RowGenerationTable table)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(column);
        ArgumentNullException.ThrowIfNull(table);
        switch (settings.Kind)
        {
            case RowGeneratorKind.IntegerRange:
            {
                if (settings.IntegerMinimum > settings.IntegerMaximum)
                {
                    return 0;
                }

                var span = (Int128)settings.IntegerMaximum - settings.IntegerMinimum;
                return span >= long.MaxValue ? null : (long)span + 1;
            }

            case RowGeneratorKind.DecimalRange:
            {
                if (settings.DecimalMinimum > settings.DecimalMaximum)
                {
                    return 0;
                }

                var span = (Int128)Steps(settings.DecimalMaximum, settings.DecimalScale) - Steps(settings.DecimalMinimum, settings.DecimalScale);
                return span >= long.MaxValue ? null : (long)span + 1;
            }

            case RowGeneratorKind.List:
                return settings.Values.Where(v => v.Length > 0).Distinct(StringComparer.Ordinal).LongCount();
            case RowGeneratorKind.Reference:
            {
                if (column.Reference is not { } slot || table.Reference(slot.SourceId) is not { } source)
                {
                    return 0;
                }

                return source.Tuples.Select(t => slot.Position < t.Length ? RowFingerprint.Of(t[slot.Position]) : default).Distinct().LongCount();
            }

            case RowGeneratorKind.Boolean:
                return 2;
            case RowGeneratorKind.Date:
                return DayCount(settings);
            case RowGeneratorKind.DateTime:
                return DayCount(settings) * SecondsPerDay;
            case RowGeneratorKind.Time:
                return SecondsPerDay;
            case RowGeneratorKind.Pattern:
                return RowGenerationPattern.Combinations(settings.Pattern, column.MaxLength);
            default:
                return null;
        }
    }

    private static long DayCount(RowGeneratorSettings settings) => Math.Max(0, settings.DateEnd.DayNumber - settings.DateStart.DayNumber + 1);

    private static string? ColumnIssue(RowGenerationColumn column, RowGeneratorSettings settings, int rowCount, RowGenerationTable table)
    {
        var name = column.Name;
        var kinds = column.AvailableKinds;
        if (kinds.Count == 0)
        {
            return $"No generator can fill {name} ({column.TypeName}), and it cannot be left empty.";
        }

        if (!kinds.Contains(settings.Kind))
        {
            return $"{name} cannot use this generator.";
        }

        if (RangeIssue(column, settings, rowCount, table) is { } range)
        {
            return range;
        }

        if (column.IsUnique && DomainSize(settings, column, table) is { } size && size < rowCount)
        {
            return string.Create(CultureInfo.CurrentCulture, $"{name} must not repeat, but its generator makes only {size:N0} different values.");
        }

        return null;
    }

    private static string? RangeIssue(RowGenerationColumn column, RowGeneratorSettings settings, int rowCount, RowGenerationTable table)
    {
        var name = column.Name;
        switch (settings.Kind)
        {
            case RowGeneratorKind.IntegerRange:
                return settings.IntegerMinimum > settings.IntegerMaximum
                    ? $"{name}: the minimum is larger than the maximum."
                    : IntegerBoundsIssue(column, settings.IntegerMinimum, settings.IntegerMaximum);
            case RowGeneratorKind.Sequence:
            {
                if (settings.SequenceStep == 0)
                {
                    return $"{name}: the step cannot be 0.";
                }

                var last = (Int128)settings.IntegerMinimum + ((Int128)settings.SequenceStep * Math.Max(0, rowCount - 1));
                if (last > long.MaxValue || last < long.MinValue)
                {
                    return $"The sequence for {name} runs past the largest number it can hold.";
                }

                return IntegerBoundsIssue(column, Math.Min(settings.IntegerMinimum, (long)last), Math.Max(settings.IntegerMinimum, (long)last));
            }

            case RowGeneratorKind.DecimalRange:
            {
                if (settings.DecimalScale is < 0 or > MaximumScale)
                {
                    return $"{name}: decimal places run from 0 to {MaximumScale}.";
                }

                if (settings.DecimalMinimum > settings.DecimalMaximum)
                {
                    return $"{name}: the minimum is larger than the maximum.";
                }

                // Values are counted in steps of the last decimal place, which have to fit a 64-bit integer.
                var stepLimit = Math.Pow(10, 18 - settings.DecimalScale);
                if (Math.Abs(settings.DecimalMinimum) >= stepLimit || Math.Abs(settings.DecimalMaximum) >= stepLimit)
                {
                    return $"{name}: the range is too wide for that many decimal places.";
                }

                if (column.ValueClass == RowValueClass.Decimal)
                {
                    // A value with more places than the column keeps is rounded on the way in, and can then repeat.
                    if (column.Scale is { } scale && settings.DecimalScale > scale)
                    {
                        return string.Create(CultureInfo.CurrentCulture, $"{name} keeps {scale} decimal places.");
                    }

                    var limit = DecimalLimit(column.Precision, column.Scale);
                    if (Math.Abs(settings.DecimalMinimum) > limit || Math.Abs(settings.DecimalMaximum) > limit)
                    {
                        return string.Create(CultureInfo.CurrentCulture, $"{name} holds values up to {limit:N0}.");
                    }
                }

                return null;
            }

            case RowGeneratorKind.Text:
                return settings.MinLength < 0 || settings.MinLength > settings.MaxLength ? $"{name}: the shortest length is longer than the longest." : null;
            case RowGeneratorKind.Date or RowGeneratorKind.DateTime:
                return DayCount(settings) <= 0 ? $"{name}: the first date is after the last." : null;
            case RowGeneratorKind.List:
                return settings.Values.Any(v => v.Length > 0) ? null : $"Enter at least one value for {name}.";
            case RowGeneratorKind.Pattern:
                return settings.Pattern.Length == 0 ? $"Enter a pattern for {name}." : null;
            case RowGeneratorKind.Reference:
                return column.Reference is { } slot && table.Reference(slot.SourceId) is { Tuples.Count: 0 } source && !column.IsNullable
                    ? $"{name} references {source.ReferencedTable}, which has no rows."
                    : null;
            default:
                return null;
        }
    }

    private static string? IntegerBoundsIssue(RowGenerationColumn column, long low, long high)
    {
        if (column.ValueClass != RowValueClass.Integer || (low >= column.IntegerMinimum && high <= column.IntegerMaximum))
        {
            return null;
        }

        return string.Create(CultureInfo.CurrentCulture, $"{column.Name} holds numbers from {column.IntegerMinimum:N0} to {column.IntegerMaximum:N0}.");
    }

    private static IEnumerable<RowGenerationIssue> GroupIssues(RowGenerationSettings settings, RowGenerationTable table)
    {
        foreach (var group in table.UniqueGroups)
        {
            long combinations = 1;
            var writesMember = false;
            var settled = false;
            foreach (var name in group)
            {
                if (table.Column(name) is not { } column || !settings.Columns.TryGetValue(name, out var columnSettings))
                {
                    settled = true;
                    break;
                }

                // A column that never repeats, or one the server numbers, already keeps the whole key unique.
                if (column.IsUnique || columnSettings.Kind == RowGeneratorKind.Sequence)
                {
                    settled = true;
                    break;
                }

                if (columnSettings.Kind == RowGeneratorKind.ServerDefault)
                {
                    if (column.Ownership == ServerOwnership.Assigned)
                    {
                        settled = true;
                        break;
                    }

                    // Any other default is the same in every row, so the rest of the key carries it.
                    continue;
                }

                writesMember = true;
                if (DomainSize(columnSettings, column, table) is not { } size || combinations > long.MaxValue / Math.Max(1, size))
                {
                    settled = true;
                    break;
                }

                combinations *= size;
            }

            var key = string.Join(", ", group);
            if (settled)
            {
                continue;
            }

            if (!writesMember)
            {
                if (settings.RowCount > 1)
                {
                    yield return new RowGenerationIssue(null, $"({key}) must not repeat, but every column of it is left to its default.");
                }

                continue;
            }

            if (combinations < settings.RowCount)
            {
                yield return new RowGenerationIssue(null, string.Create(CultureInfo.CurrentCulture, $"({key}) must not repeat, but the generators make only {combinations:N0} combinations."));
            }
        }
    }
}
