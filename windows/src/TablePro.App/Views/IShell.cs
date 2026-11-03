using TablePro.Interop;

namespace TablePro.App.Views;

// What the pages ask of the window.
internal interface IShell
{
    void NewConnection();

    void EditConnection(SavedConnection connection);

    void Connect(SavedConnection connection);

    Task OpenFileAsync();

    Task ImportAsync();

    Task OpenSampleAsync();

    void ShowSettings();
}
