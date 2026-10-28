using System.Text.Json;

namespace TablePro.Core.Updates;

/// <summary>
/// The update choices and bookkeeping one installation keeps, in <c>%LOCALAPPDATA%\TablePro\updates.json</c>. They
/// stay out of settings.json because they describe this copy of the app, not the user's preferences that sync.
/// </summary>
public sealed record UpdatePreferences
{
    /// <summary>How long a scheduled check waits after the last one, as <c>SUScheduledCheckInterval</c> on macOS.</summary>
    public static readonly TimeSpan CheckInterval = TimeSpan.FromDays(1);

    public UpdateChannel Channel { get; init; } = UpdateChannel.Stable;

    public bool AutomaticallyChecks { get; init; } = true;

    public DateTimeOffset? LastCheck { get; init; }

    public string? SkippedVersion { get; init; }

    /// <summary>Drawn once on the first check, so the same installation always lands in the same rollout group.</summary>
    public int? RolloutGroup { get; init; }

    public AppVersion? Skipped => AppVersion.TryParse(SkippedVersion, out var version) ? version : null;

    /// <summary>A clock moved backwards counts as due, so a wrong date never stops checks for good.</summary>
    public bool IsCheckDue(DateTimeOffset now) =>
        AutomaticallyChecks && (LastCheck is not { } last || last > now || now - last >= CheckInterval);

    public string Serialize() => JsonSerializer.Serialize(this, UpdateJsonContext.Default.UpdatePreferences);

    /// <summary>A missing or damaged file gives the defaults: losing the last check time only means checking again.</summary>
    public static UpdatePreferences Deserialize(string? json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return new UpdatePreferences();
        }

        try
        {
            var value = JsonSerializer.Deserialize(json, UpdateJsonContext.Default.UpdatePreferences) ?? new UpdatePreferences();
            return value.RolloutGroup is { } group && (group < 0 || group >= UpdateSelector.RolloutGroupCount)
                ? value with { RolloutGroup = null }
                : value;
        }
        catch (JsonException)
        {
            return new UpdatePreferences();
        }
    }
}
