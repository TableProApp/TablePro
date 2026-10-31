using System.Globalization;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;
using TablePro.Drivers.BigQuery.Localization;

namespace TablePro.Drivers.BigQuery;

/// <summary>
/// What a BigQuery session reads from the form: Database (or Host, or AdditionalOptions <c>projectId</c>) as the
/// project, FilePath as a service account or authorized user JSON file (empty uses Application Default Credentials),
/// and AdditionalOptions <c>location</c>, <c>dataset</c>, <c>maxBytesBilled</c> and <c>keyColumns</c>.
/// </summary>
public sealed record BigQuerySettings(
    string ProjectId,
    string? CredentialsFile,
    string? Location,
    string? DefaultDataset,
    long? MaxBytesBilled,
    IReadOnlyDictionary<string, string[]> KeyColumns,
    IReadOnlyList<string> DefaultKeyColumns)
{
    public const string ProjectOption = "projectId";
    public const string LocationOption = "location";
    public const string DatasetOption = "dataset";
    public const string MaxBytesBilledOption = "maxBytesBilled";
    public const string KeyColumnsOption = "keyColumns";

    public static BigQuerySettings From(ConnectionRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var profile = request.Profile;
        var options = profile.AdditionalOptions;
        var host = string.IsNullOrWhiteSpace(profile.Host) || profile.Host.Trim() is "localhost" or "127.0.0.1" ? null : profile.Host.Trim();
        var project = Option(options, ProjectOption)
            ?? (string.IsNullOrWhiteSpace(request.Database) ? null : request.Database.Trim())
            ?? host
            ?? throw new ArgumentException(BigQueryStrings.Get("BigQuery/NeedsProjectId"), nameof(request));

        var limitText = Option(options, MaxBytesBilledOption);
        long? limit = null;
        if (limitText is not null)
        {
            limit = BigQueryCost.ParseBytes(limitText)
                ?? throw new ArgumentException(BigQueryStrings.Format("BigQuery/NotAByteCount", limitText), nameof(request));
        }

        var (keys, defaults) = ParseKeyColumns(Option(options, KeyColumnsOption));
        return new BigQuerySettings(
            project,
            string.IsNullOrWhiteSpace(profile.FilePath) ? null : profile.FilePath.Trim(),
            Option(options, LocationOption),
            Option(options, DatasetOption),
            limit,
            keys,
            defaults);
    }

    /// <summary>The columns that identify a row of the table when the user named them, else null for all columns.</summary>
    public IReadOnlyList<string>? KeyColumnsFor(ObjectName table)
    {
        if (KeyColumns.TryGetValue(table.ToString(), out var named) || KeyColumns.TryGetValue(table.Name, out named))
        {
            return named;
        }

        return DefaultKeyColumns.Count > 0 ? DefaultKeyColumns : null;
    }

    /// <summary>
    /// <c>dataset.table=col1,col2; other=id</c> names keys per table; an entry without <c>=</c>, such as <c>id</c>,
    /// applies to every table that has those columns.
    /// </summary>
    internal static (IReadOnlyDictionary<string, string[]> PerTable, string[] Default) ParseKeyColumns(string? text)
    {
        var perTable = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
        string[] defaults = [];
        if (string.IsNullOrWhiteSpace(text))
        {
            return (perTable, defaults);
        }

        foreach (var entry in text.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var separator = entry.IndexOf('=', StringComparison.Ordinal);
            var columns = (separator < 0 ? entry : entry[(separator + 1)..]).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (columns.Length == 0)
            {
                continue;
            }

            if (separator < 0)
            {
                defaults = columns;
            }
            else
            {
                perTable[entry[..separator].Trim()] = columns;
            }
        }

        return (perTable, defaults);
    }

    private static string? Option(IReadOnlyDictionary<string, string> options, string key)
    {
        foreach (var (name, value) in options)
        {
            if (string.Equals(name, key, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(value))
            {
                return value.Trim();
            }
        }

        return null;
    }
}

/// <summary>What a dry run said and whether the statement may run.</summary>
public readonly record struct BigQueryCostCheck(bool Allowed, string Message);

/// <summary>The scan limit: every editor statement is dry-run first when a limit is set, and refused above it.</summary>
public static class BigQueryCost
{
    private static readonly string[] Units = ["B", "KB", "MB", "GB", "TB", "PB"];

    public static BigQueryCostCheck Evaluate(long estimatedBytes, long? limit)
    {
        var estimate = FormatBytes(estimatedBytes);
        if (limit is not { } max)
        {
            return new BigQueryCostCheck(true, BigQueryStrings.Format("BigQuery/EstimatedScan", estimate));
        }

        return estimatedBytes <= max
            ? new BigQueryCostCheck(true, BigQueryStrings.Format("BigQuery/EstimatedScanWithLimit", estimate, FormatBytes(max)))
            : new BigQueryCostCheck(false, BigQueryStrings.Format("BigQuery/OverLimit", estimate, FormatBytes(max)));
    }

    public static string FormatBytes(long bytes)
    {
        if (bytes < 1024)
        {
            return string.Create(CultureInfo.InvariantCulture, $"{Math.Max(bytes, 0)} B");
        }

        double value = bytes;
        var unit = 0;
        while (value >= 1024 && unit < Units.Length - 1)
        {
            value /= 1024;
            unit++;
        }

        return string.Create(CultureInfo.InvariantCulture, $"{value:0.##} {Units[unit]}");
    }

    /// <summary>A plain count, optionally with a binary unit: <c>1000000</c>, <c>500 MB</c>, <c>10GB</c>, <c>1_000</c>.</summary>
    public static long? ParseBytes(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var span = text.Replace("_", string.Empty, StringComparison.Ordinal).Replace(",", string.Empty, StringComparison.Ordinal).Trim();
        var digits = 0;
        while (digits < span.Length && (char.IsAsciiDigit(span[digits]) || span[digits] == '.'))
        {
            digits++;
        }

        if (digits == 0 || !double.TryParse(span[..digits], NumberStyles.Float, CultureInfo.InvariantCulture, out var number))
        {
            return null;
        }

        var multiplier = span[digits..].Trim().ToUpperInvariant() switch
        {
            "" or "B" => 1d,
            "K" or "KB" or "KIB" => 1024d,
            "M" or "MB" or "MIB" => 1024d * 1024,
            "G" or "GB" or "GIB" => 1024d * 1024 * 1024,
            "T" or "TB" or "TIB" => 1024d * 1024 * 1024 * 1024,
            _ => double.NaN,
        };

        var bytes = number * multiplier;
        return double.IsNaN(bytes) || bytes < 0 || bytes > long.MaxValue ? null : (long)bytes;
    }
}
