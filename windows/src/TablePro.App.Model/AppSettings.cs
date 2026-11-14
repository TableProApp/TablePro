using System.Text.Json;
using System.Text.Json.Serialization;

namespace TablePro.App.Model;

public enum AppTheme
{
    System,
    Light,
    Dark,
}

public sealed record AppSettings
{
    public const int DefaultRowLimit = 10_000;

    public const int DefaultPageSize = 1_000;

    public const long DefaultCountRowsBelow = 100_000;

    // Counts every table whatever its estimate, as macOS's "Always count".
    public const long AlwaysCount = long.MaxValue;

    // The sizes the Settings page offers for a new table tab, as macOS offers them.
    public static IReadOnlyList<int> PageSizeChoices { get; } = [100, 500, 1_000, 5_000, 10_000];

    // The thresholds the Settings page offers, as macOS offers them.
    public static IReadOnlyList<long> CountThresholdChoices { get; } = [1_000, 10_000, 100_000, 1_000_000, AlwaysCount];

    // As macOS offers them; 0 keeps every result.
    public static IReadOnlyList<int> ResultsKeptChoices { get; } = [0, 10, 20, 50, 100, 200, 500, 1_000];

    public const string DefaultNullDisplay = "NULL";

    // macOS caps the NULL text at 20 characters.
    public const int NullDisplayMaxLength = 20;

    public const double DefaultGridFontSize = 14;

    public const int DefaultHistoryRetentionDays = 90;

    public const int DefaultHistoryMaxEntries = 10_000;

    // As macOS offers them; 0 keeps every age.
    public static IReadOnlyList<int> HistoryRetentionChoices { get; } = [7, 30, 90, 180, 365, 0];

    // As macOS offers them; 0 keeps as many as the store holds.
    public static IReadOnlyList<int> HistoryMaxEntriesChoices { get; } = [100, 500, 1_000, 5_000, 10_000, 0];

    public AppTheme Theme { get; set; } = AppTheme.System;

    public bool ReopenSession { get; set; } = true;

    public double EditorFontSize { get; set; } = 14;

    // Null keeps the editor's own monospaced family.
    public string? EditorFontFamily { get; set; }

    // Null keeps the grid's own family.
    public string? GridFontFamily { get; set; }

    public double GridFontSize { get; set; } = DefaultGridFontSize;

    // What a grid shows in a NULL cell.
    public string NullDisplay { get; set; } = DefaultNullDisplay;

    // Unpinned history older than this is dropped; 0 keeps every age.
    public int HistoryRetentionDays { get; set; } = DefaultHistoryRetentionDays;

    // The newest unpinned runs the history keeps; 0 keeps as many as the store holds.
    public int HistoryMaxEntries { get; set; } = DefaultHistoryMaxEntries;

    public int RowLimit { get; set; } = DefaultRowLimit;

    // Rows a new table tab shows on each page; a tab can pick its own.
    public int PageSize { get; set; } = DefaultPageSize;

    // Zero leaves the statement to the connection's own limit.
    public int QueryTimeoutSeconds { get; set; }

    // A table tab whose table the engine estimates at this many rows or more counts them only when asked.
    public long CountRowsIfEstimateLessThan { get; set; } = DefaultCountRowsBelow;

    // Results with rows a run keeps, the newest; 0 keeps them all.
    public int ResultSetsKeptPerRun { get; set; }

    public AppSettings Normalized() => this with
    {
        Theme = Enum.IsDefined(Theme) ? Theme : AppTheme.System,
        EditorFontSize = Math.Clamp(EditorFontSize, 8, 36),
        EditorFontFamily = string.IsNullOrWhiteSpace(EditorFontFamily) ? null : EditorFontFamily.Trim(),
        GridFontFamily = string.IsNullOrWhiteSpace(GridFontFamily) ? null : GridFontFamily.Trim(),
        GridFontSize = double.IsFinite(GridFontSize) ? Math.Clamp(GridFontSize, 8, 36) : DefaultGridFontSize,
        NullDisplay = string.IsNullOrEmpty(NullDisplay)
            ? DefaultNullDisplay
            : NullDisplay[..Math.Min(NullDisplay.Length, NullDisplayMaxLength)],
        HistoryRetentionDays = Math.Max(0, HistoryRetentionDays),
        HistoryMaxEntries = Math.Max(0, HistoryMaxEntries),
        RowLimit = Math.Clamp(RowLimit, 1, 1_000_000),
        PageSize = Math.Clamp(PageSize, 10, 100_000),
        QueryTimeoutSeconds = Math.Clamp(QueryTimeoutSeconds, 0, 86_400),
        CountRowsIfEstimateLessThan = Math.Max(0, CountRowsIfEstimateLessThan),
        ResultSetsKeptPerRun = Math.Max(0, ResultSetsKeptPerRun),
    };
}

// A file that does not read gives the defaults, and the next save replaces it.
public sealed class SettingsStore(string path)
{
    public string Path { get; } = path;

    public AppSettings Load()
    {
        var settings = JsonFile.Read(Path, ModelJson.Default.AppSettings);
        return (settings ?? new AppSettings()).Normalized();
    }

    public void Save(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        JsonFile.Write(Path, settings.Normalized(), ModelJson.Default.AppSettings);
    }
}

[JsonSourceGenerationOptions(
    WriteIndented = true,
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    UseStringEnumConverter = true)]
[JsonSerializable(typeof(AppSettings))]
[JsonSerializable(typeof(SessionState))]
internal sealed partial class ModelJson : JsonSerializerContext;

internal static class JsonFile
{
    public static T? Read<T>(string path, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type)
        where T : class
    {
        try
        {
            using var stream = File.OpenRead(path);
            return JsonSerializer.Deserialize(stream, type);
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    // Written beside the file, then moved over it, so a crash mid-write leaves the old file whole.
    public static void Write<T>(string path, T value, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type)
    {
        var directory = System.IO.Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var temporary = path + ".tmp";
        using (var stream = File.Create(temporary))
        {
            JsonSerializer.Serialize(stream, value, type);
            // On disk before the rename is, so a power cut after the move cannot leave a file of zeros.
            stream.Flush(flushToDisk: true);
        }

        File.Move(temporary, path, overwrite: true);
    }
}
