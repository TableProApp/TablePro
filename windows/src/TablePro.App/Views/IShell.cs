using TablePro.App.Model;
using TablePro.Interop;

namespace TablePro.App.Views;

internal interface IShell
{
    void NewConnection();

    // A new connection the form opens on, filled from a pasted URL.
    void NewConnection(ConnectionDraft draft);

    void EditConnection(SavedConnection connection);

    void Connect(SavedConnection connection);

    Task OpenFileAsync();

    Task ImportAsync();

    Task ImportFromAppAsync();

    Task OpenSampleAsync();

    void ShowSettings();

    void ShowKeyboardShortcuts();

    // Settings > Sync > End-to-end encryption, which leads back to Settings.
    void ShowAccountKeys();

    // Asks what a close asks, then has Windows install the update the check found and restart the app.
    Task InstallUpdateAsync();

    // The paid-feature gate's dialog: false once it showed what the feature needs (docs/decisions/0023).
    Task<bool> RequirePlanAsync(string feature);
}
