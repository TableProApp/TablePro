namespace TablePro.Core.Licensing;

/// <summary>The license state the app acts on, after the signed payload, the clock and the server have all had their say.</summary>
public enum LicenseStatus
{
    Unlicensed,
    Active,
    Expired,
    Suspended,
    Deactivated,
    ValidationFailed,
}

public static class LicenseStatusExtensions
{
    /// <summary>Only an active license entitles anything; every other state withholds paid features.</summary>
    public static bool IsValid(this LicenseStatus status) => status == LicenseStatus.Active;
}
