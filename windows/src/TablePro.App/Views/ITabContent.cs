using TablePro.App.Model;
using TablePro.Editor;

namespace TablePro.App.Views;

// What the window's commands reach in the front tab of a connection.
internal interface ITabContent
{
    event EventHandler? StateChanged;

    string Title { get; }

    bool IsRunning { get; }

    SqlEditor? Editor { get; }

    void Run();

    void Stop();

    void FocusContent();

    SessionTab Snapshot();

    Task CloseAsync();
}
