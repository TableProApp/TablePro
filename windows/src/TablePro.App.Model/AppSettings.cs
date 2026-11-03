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

    public AppTheme Theme { get; set; } = AppTheme.System;

    public bool ReopenSession { get; set; } = true;

    public double EditorFontSize { get; set; } = 14;

    public int RowLimit { get; set; } = DefaultRowLimit;

    // Zero leaves the statement to the connection's own limit.
    public int QueryTimeoutSeconds { get; set; }

    public AppSettings Normalized() => this with
    {
        Theme = Enum.IsDefined(Theme) ? Theme : AppTheme.System,
        EditorFontSize = Math.Clamp(EditorFontSize, 8, 36),
        RowLimit = Math.Clamp(RowLimit, 1, 1_000_000),
        QueryTimeoutSeconds = Math.Clamp(QueryTimeoutSeconds, 0, 86_400),
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
        }

        File.Move(temporary, path, overwrite: true);
    }
}
