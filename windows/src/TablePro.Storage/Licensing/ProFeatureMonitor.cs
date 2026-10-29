using TablePro.Core.Licensing;

namespace TablePro.Storage.Licensing;

/// <summary>
/// One paid feature's access, followed as the license changes, so a window already open locks or unlocks the moment a
/// license is activated, removed, expires or fails its check. It follows <see cref="LicenseService.Changed"/> rather than
/// the status alone, because moving from Starter to Team changes access without changing the status, and raises
/// <see cref="AccessChanged"/> only when access actually changed: the service announces every step of a device list
/// load too. Events fire on the thread that changed the license.
/// </summary>
public sealed class ProFeatureMonitor : IDisposable
{
    private readonly LicenseService _license;
    private readonly Lock _lock = new();
    private ProFeatureAccess _access;

    public ProFeatureMonitor(LicenseService license, ProFeature feature)
    {
        ArgumentNullException.ThrowIfNull(license);
        _license = license;
        Feature = feature;
        _access = license.CheckFeature(feature);
        license.Changed += OnLicenseChanged;
    }

    public event EventHandler? AccessChanged;

    public ProFeature Feature { get; }

    public ProFeatureAccess Access
    {
        get
        {
            lock (_lock)
            {
                return _access;
            }
        }
    }

    public bool IsAvailable => Access.IsAvailable;

    public void Dispose() => _license.Changed -= OnLicenseChanged;

    private void OnLicenseChanged(object? sender, EventArgs e)
    {
        var current = _license.CheckFeature(Feature);
        bool changed;
        lock (_lock)
        {
            changed = current != _access;
            _access = current;
        }

        if (changed)
        {
            AccessChanged?.Invoke(this, EventArgs.Empty);
        }
    }
}
