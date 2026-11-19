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
}
