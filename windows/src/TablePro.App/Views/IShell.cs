using TablePro.Interop;

namespace TablePro.App.Views;

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
