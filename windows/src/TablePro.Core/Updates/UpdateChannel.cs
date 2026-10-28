namespace TablePro.Core.Updates;

/// <summary>
/// Which releases the app offers, as Settings > General > Get beta updates chooses on macOS. A release's own
/// channel follows from its version (<see cref="AppVersion.Channel"/>).
/// </summary>
public enum UpdateChannel
{
    Stable,
    Beta,
}

public static class UpdateChannelExtensions
{
    /// <summary>The beta channel takes stables too, so a beta user moves on to the stable that follows.</summary>
    public static bool Accepts(this UpdateChannel selected, UpdateChannel release) =>
        selected == UpdateChannel.Beta || release == UpdateChannel.Stable;
}
