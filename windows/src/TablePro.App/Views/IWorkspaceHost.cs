using Microsoft.UI;
using Microsoft.UI.Xaml.Controls;

namespace TablePro.App.Views;

// The window a workspace shows in, which moves its tabs between windows.
internal interface IWorkspaceHost
{
    // The window that holds the rail; TabView hides and closes the window whose last tab is dragged away.
    bool IsPrimary { get; }

    // False for a window kept hidden for the next drag, which no tab may be dropped into.
    bool AcceptsTabs { get; }

    bool CanMoveTabs { get; }

    WindowId TearOutWindow(OpenConnection connection);

    void TearOut(TabViewItem tab, WindowId window);

    void MoveToNewWindow(TabViewItem tab);
}
