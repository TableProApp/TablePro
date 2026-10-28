namespace TablePro.Core.Connections;

/// <summary>
/// How much the app guards statements that change data, ordered from least to most strict.
/// The names and order match the macOS app's <c>SafeModeLevel</c>.
/// </summary>
public enum SafeModeLevel
{
    Silent,
    Alert,
    AlertFull,
    SafeMode,
    SafeModeFull,
    ReadOnly,
}

public static class SafeModeLevelExtensions
{
    public static bool BlocksAllWrites(this SafeModeLevel level) => level == SafeModeLevel.ReadOnly;

    public static bool RequiresConfirmation(this SafeModeLevel level) =>
        level is SafeModeLevel.Alert or SafeModeLevel.AlertFull or SafeModeLevel.SafeMode or SafeModeLevel.SafeModeFull;

    /// <summary>The Full levels confirm every statement, the others only statements that write.</summary>
    public static bool ConfirmsReads(this SafeModeLevel level) =>
        level is SafeModeLevel.AlertFull or SafeModeLevel.SafeModeFull;
}
