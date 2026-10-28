using System.Globalization;

namespace TablePro.Core.Plans;

/// <summary>One spelling for every plan number, so a node row and the summary above it never render a cost two ways.</summary>
public static class QueryPlanValueFormatter
{
    /// <summary>Shown where a plan reports no value at all, as opposed to reporting zero.</summary>
    public const string Absent = "–";

    public static string Format(QueryPlanFieldValue? value, QueryPlanUnit? unit, IFormatProvider? provider = null)
    {
        if (value is not { } present)
        {
            return Absent;
        }

        return present.Text ?? (present.Number is { } number ? Format(number, unit ?? QueryPlanUnit.Cost, provider) : Absent);
    }

    public static string Format(double value, QueryPlanUnit unit, IFormatProvider? provider = null)
    {
        provider ??= CultureInfo.CurrentCulture;
        return unit switch
        {
            QueryPlanUnit.Cost => value.ToString("#,##0.##", provider),
            QueryPlanUnit.Milliseconds => value.ToString("#,##0.###", provider) + " ms",
            _ => value.ToString("#,##0", provider),
        };
    }

    /// <summary>
    /// Short enough to sit at the end of a bar without stealing the track: a plan's costs run to eight digits, and
    /// <c>7,876,009.47</c> beside a bar is the number crowding out the picture. Past a second, seconds read better.
    /// </summary>
    public static string Compact(double value, QueryPlanUnit unit, IFormatProvider? provider = null)
    {
        provider ??= CultureInfo.CurrentCulture;
        if (unit == QueryPlanUnit.Milliseconds)
        {
            return Math.Abs(value) >= 1_000
                ? (value / 1_000).ToString("0.##", provider) + "s"
                : value.ToString("0.###", provider) + "ms";
        }

        var magnitude = Math.Abs(value);
        return magnitude switch
        {
            >= 1e12 => (value / 1e12).ToString("0.#", provider) + "T",
            >= 1e9 => (value / 1e9).ToString("0.#", provider) + "B",
            >= 1e6 => (value / 1e6).ToString("0.#", provider) + "M",
            >= 1e4 => (value / 1e3).ToString("0.#", provider) + "K",
            _ => Format(value, unit, provider),
        };
    }

    /// <summary>The signed difference, with the percentage when there is a baseline; null when nothing moved.</summary>
    public static string? Change(QueryPlanFieldChange change, IFormatProvider? provider = null)
    {
        ArgumentNullException.ThrowIfNull(change);
        if (!change.HasChange)
        {
            return null;
        }

        if (change.Delta is not { } delta || change.Field.Unit is not { } unit)
        {
            return "Changed";
        }

        var magnitude = Format(Math.Abs(delta), unit, provider);
        var signed = delta switch
        {
            > 0 => "+" + magnitude,
            < 0 => "−" + magnitude,
            _ => magnitude,
        };

        if (change.Ratio is not { } ratio)
        {
            return signed;
        }

        var percent = (ratio - 1) * 100;
        var sign = percent >= 0 ? "+" : "−";
        return $"{signed} ({sign}{Math.Abs(percent).ToString("0.#", provider ?? CultureInfo.CurrentCulture)}%)";
    }
}
