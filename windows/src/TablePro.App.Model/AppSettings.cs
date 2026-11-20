using System.Text.Json;
using System.Text.Json.Serialization;
using TablePro.Interop;

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

    public const int DefaultNotifyAfterSeconds = 20;

    // As macOS offers them, in seconds: 5, 10, 20 or 30 seconds, or 1, 2, 5 or 10 minutes.
    public static IReadOnlyList<int> NotifyAfterChoices { get; } = [5, 10, 20, 30, 60, 120, 300, 600];

    // The Linux app's default, so a key is all a new user needs.
    public const string DefaultAnthropicModel = "claude-opus-5-5";

    public const string DefaultCompatibleAddress = "http://localhost:11434/v1";

    // The MCP server's, as the other apps listen on: McpServer.DefaultPort.
    public const int DefaultMcpServerPort = 23508;

    // Ports below are the system's, as the Linux app's settings schema keeps them out.
    public const int LowestMcpServerPort = 1024;

    public AppTheme Theme { get; set; } = AppTheme.System;

    // A query that ran at least NotifyAfterSeconds and finished where the user is not looking posts a notification.
    public bool NotifyLongWork { get; set; } = true;

    public int NotifyAfterSeconds { get; set; } = DefaultNotifyAfterSeconds;

    public bool ReopenSession { get; set; } = true;

    public double EditorFontSize { get; set; } = 14;

    // Null keeps the editor's own monospaced family.
    public string? EditorFontFamily { get; set; }

    public bool WordWrap { get; set; }

    public bool HighlightCurrentStatement { get; set; } = true;

    public bool CodeFolding { get; set; } = true;

    // Vim's modes and keys in the SQL editor, off as on macOS.
    public bool VimMode { get; set; }

    // A color scheme's id; null keeps the editor's default colors.
    public string? EditorLightScheme { get; set; }

    public string? EditorDarkScheme { get; set; }

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

    // Who answers the AI assistant; null while it is off, which is how it starts, so nothing is sent anywhere.
    public AiProvider? AiProvider { get; set; }

    public string AnthropicModel { get; set; } = DefaultAnthropicModel;

    public string OpenAIModel { get; set; } = string.Empty;

    public string CompatibleModel { get; set; } = string.Empty;

    // An Ollama or other OpenAI-compatible server, version path included; the hosted providers' are fixed.
    public string CompatibleAddress { get; set; } = DefaultCompatibleAddress;

    // Off until the user turns it on, as on macOS and Linux. The tablepro command reads both names from this file.
    public bool McpServerEnabled { get; set; }

    public int McpServerPort { get; set; } = DefaultMcpServerPort;

    // The project the Connections page shows, on this PC only; null, and an id no project holds, show all connections.
    public Guid? ActiveProjectId { get; set; }

    // The channel Settings chose; null follows the App Installer file the app was installed from.
    public UpdateChannel? UpdateChannel { get; set; }

    // The package version that last started, so the first start of a newer one says it was updated.
    public string? LastLaunchedVersion { get; set; }

    // What the chosen provider's requests take, or null while the assistant is off.
    [JsonIgnore]
    public AiSettings? Assistant => AiProvider is { } provider ? AssistantFor(provider) : null;

    public AiSettings AssistantFor(AiProvider provider) => new(
        provider,
        ModelOf(provider),
        provider == Interop.AiProvider.OpenAICompatible ? CompatibleAddress : null);

    public string ModelOf(AiProvider provider) => provider switch
    {
        Interop.AiProvider.Anthropic => AnthropicModel,
        Interop.AiProvider.OpenAI => OpenAIModel,
        _ => CompatibleModel,
    };

    public AppSettings WithModel(AiProvider provider, string model) => provider switch
    {
        Interop.AiProvider.Anthropic => this with { AnthropicModel = model },
        Interop.AiProvider.OpenAI => this with { OpenAIModel = model },
        _ => this with { CompatibleModel = model },
    };

    public AppSettings Normalized() => this with
    {
        Theme = Enum.IsDefined(Theme) ? Theme : AppTheme.System,
        EditorFontSize = Math.Clamp(EditorFontSize, 8, 36),
        EditorFontFamily = string.IsNullOrWhiteSpace(EditorFontFamily) ? null : EditorFontFamily.Trim(),
        EditorLightScheme = string.IsNullOrWhiteSpace(EditorLightScheme) ? null : EditorLightScheme.Trim(),
        EditorDarkScheme = string.IsNullOrWhiteSpace(EditorDarkScheme) ? null : EditorDarkScheme.Trim(),
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
        NotifyAfterSeconds = NotifyAfterChoices.Contains(NotifyAfterSeconds) ? NotifyAfterSeconds : DefaultNotifyAfterSeconds,
        AiProvider = AiProvider is { } provider && Enum.IsDefined(provider) ? provider : null,
        AnthropicModel = (AnthropicModel ?? string.Empty).Trim(),
        OpenAIModel = (OpenAIModel ?? string.Empty).Trim(),
        CompatibleModel = (CompatibleModel ?? string.Empty).Trim(),
        CompatibleAddress = string.IsNullOrWhiteSpace(CompatibleAddress)
            ? DefaultCompatibleAddress
            : CompatibleAddress.Trim(),
        McpServerPort = Math.Clamp(McpServerPort, LowestMcpServerPort, ushort.MaxValue),
        UpdateChannel = UpdateChannel is { } channel && Enum.IsDefined(channel) ? channel : null,
        LastLaunchedVersion = ReleaseVersions.TryParse(LastLaunchedVersion, out var launched) ? launched.ToString() : null,
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
[JsonSerializable(typeof(TableFilterFile))]
[JsonSerializable(typeof(ColumnLayoutFile))]
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
